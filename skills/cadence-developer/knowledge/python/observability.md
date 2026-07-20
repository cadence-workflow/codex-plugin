# Observability in the Cadence Python SDK

> **Alpha note.** Several observability features present in the Go and Java SDKs — a replay-aware logger, a public `is_replaying` flag, a `ContextPropagator` for request-scoped values, and first-class tracer integration at the worker level — are **not yet implemented** in `cadence-python-client`. This file documents the surface that exists today and flags the gaps explicitly.

This file covers what a Python worker emits so you can monitor it in production: standard-library logging, the `MetricsEmitter` protocol and its built-in Prometheus implementation, the canonical `cadence-*` metric catalog, gRPC interceptors for transport-level tracing, and worker identity for fleet correlation.

For language-agnostic concepts see [`shared/determinism.md`](../shared/determinism.md); for setup see [`workers.md`](workers.md).

## Logging

The Python SDK uses the standard `logging` module. The library code emits logs through `logging.getLogger(__name__)` and does not configure handlers itself — wire up handlers and a formatter at application startup as you would for any Python service.

```python
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(name)s %(levelname)s %(message)s',
)
```

The SDK loggers worth knowing about:

| Logger | What it emits |
| --- | --- |
| `cadence.worker._worker` | Worker lifecycle, shutdown errors. |
| `cadence.worker._poller` | Poll-loop errors and retries. |
| `cadence._internal.activity._heartbeat` | Heartbeat send failures (logged as warnings; do not raise). |
| `cadence._internal.activity._activity_executor` | Activity execution failures before they're reported to the cluster. |
| `cadence._internal.rpc.retry` | RPC retry decisions on transient frontend failures. |
| `cadence._internal.workflow.*` | Decision-task execution, state-machine transitions, non-determinism detection. |

For correlation, attach the workflow IDs to log records inside workflow code:

```python
from cadence.workflow import WorkflowContext

info = WorkflowContext.get().info()
logger.info(
    "starting batch",
    extra={
        "workflow_id": info.workflow_id,
        "run_id": info.workflow_run_id,
        "workflow_type": info.workflow_type,
    },
)
```

Inside activity code, the equivalent fields are on `activity.info()`:

```python
from cadence import activity

info = activity.info()
logger.info(
    "processing item",
    extra={
        "workflow_id": info.workflow_id,
        "run_id": info.workflow_run_id,
        "activity_id": info.activity_id,
        "attempt": info.attempt,
    },
)
```

> **Alpha gap.** Unlike `Workflow.getLogger(...)` in Java or `workflow.GetLogger(ctx)` in Go, the Python SDK does **not** suppress log output during replay. A workflow that logs from inside its run method will emit the same log line on every replay (worker restart, query, retry, history replay). Practical mitigations until this lands:
>
> - Keep workflow-code logging minimal — log decisions, not data.
> - Push detailed logging into activities. Activity code has no replay concept; whatever it logs runs exactly once per attempt.
> - Treat query handlers like workflow code: they run on the replay-aware workflow runtime, so direct logging can duplicate during replay.
> - Avoid class-level `private static Logger` analogs (`logger = logging.getLogger(__name__)` at module top is fine; logging *from inside* workflow code is the problem).

## Metrics

The SDK exposes a small `MetricsEmitter` protocol and ships a `NoOpMetricsEmitter` (default) and a `PrometheusMetrics` implementation. Wire your chosen emitter into the `Client`:

```python
from cadence.client import Client
from cadence.metrics import PrometheusMetrics, PrometheusConfig

metrics = PrometheusMetrics(PrometheusConfig(
    default_labels={"service": "orders", "deploy": os.getenv("DEPLOY_ID", "dev")},
))

async with Client(
    target="localhost:7833",
    domain="my-domain",
    metrics_emitter=metrics,
) as client:
    ...
```

The `MetricsEmitter` protocol:

```python
class MetricsEmitter(Protocol):
    def counter(self, key: str, n: int = 1, tags: Optional[dict[str, str]] = None) -> None: ...
    def gauge(self, key: str, value: float, tags: Optional[dict[str, str]] = None) -> None: ...
    def histogram(self, key: str, value: float, tags: Optional[dict[str, str]] = None) -> None: ...
```

Any backend implementing this Protocol works — StatsD, Datadog, OpenTelemetry-via-Prometheus-bridge, in-memory test sinks, etc. Built-in `PrometheusMetrics` lazily creates one Prometheus collector per metric name on first emission, using the merged default labels from `PrometheusConfig` plus per-emission `tags`. `metrics.get_metrics_text()` returns the Prometheus exposition format for scraping endpoints.

### Canonical metric catalog

The SDK uses the `cadence-` prefix and the same naming convention as the Go and Java clients. All names are defined in `cadence/metrics/constants.py`.

**Worker and process**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-worker-start` | counter | Worker on this process started polling. |
| `cadence-poller-start` | counter | Individual poller within a worker began polling. |
| `cadence-worker-panic` | counter | Worker recovered from an uncaught exception. |

**Workflow lifecycle (client-side)**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-workflow-start` | counter | Synchronous `Client.start_workflow`. |
| `cadence-workflow-start-async` | counter | Async start. |
| `cadence-workflow-signal-with-start` | counter | Signal-with-start. |
| `cadence-workflow-signal-with-start-async` | counter | Async signal-with-start. |
| `cadence-workflow-completed` | counter | Workflow reached terminal Completed state. |
| `cadence-workflow-canceled` | counter | Workflow reached terminal Canceled state. |
| `cadence-workflow-failed` | counter | Workflow reached terminal Failed state. |
| `cadence-workflow-continue-as-new` | counter | Workflow continued as new. |
| `cadence-workflow-endtoend-latency` | histogram | Start-to-close latency observed by the client. |
| `cadence-workflow-get-history-total` | counter | History fetches. |
| `cadence-workflow-get-history-succeed` | counter | Successful history fetches. |
| `cadence-workflow-get-history-failed` | counter | Failed history fetches. |
| `cadence-workflow-get-history-latency` | histogram | History-fetch latency. |

**Decision (workflow task) execution**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-decision-poll-total` | counter | Decision-task long-poll attempts. |
| `cadence-decision-poll-succeed` | counter | Polls that returned a task. |
| `cadence-decision-poll-no-task` | counter | Polls that returned no work. |
| `cadence-decision-poll-failed` | counter | Permanent poll failures. |
| `cadence-decision-poll-transient-failed` | counter | Retryable poll failures. |
| `cadence-decision-poll-invalid` | counter | Polls rejected as invalid. |
| `cadence-decision-poll-latency` | histogram | Successful-poll latency. |
| `cadence-decision-scheduled-to-start-latency` | histogram | Time the task waited before this worker started it. **Key indicator** of poller saturation. |
| `cadence-decision-execution-latency` | histogram | Time computing the decision response. |
| `cadence-decision-execution-failed` | counter | Decision computation failed. |
| `cadence-decision-response-latency` | histogram | Time reporting the decision back. |
| `cadence-decision-response-failed` | counter | Failed to report the decision. |
| `cadence-decision-task-panic` | counter | Decision task raised an uncaught exception. |
| `cadence-decision-task-completed` | counter | Decision task completed successfully. |
| `cadence-decision-task-force-completed` | counter | Decision force-completed because of a non-determinism policy. |
| `cadence-decision-timeout` | counter | Decision task timed out. |

**Activity execution**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-activity-poll-total` | counter | Activity-task long-poll attempts. |
| `cadence-activity-poll-succeed` | counter | Polls that returned a task. |
| `cadence-activity-poll-no-task` | counter | Polls that returned no work. |
| `cadence-activity-poll-failed` | counter | Permanent poll failures. |
| `cadence-activity-poll-transient-failed` | counter | Retryable poll failures. |
| `cadence-activity-poll-latency` | histogram | Successful-poll latency. |
| `cadence-activity-scheduled-to-start-latency` | histogram | Time the activity waited before this worker started it. |
| `cadence-activity-execution-latency` | histogram | Activity-body execution latency. |
| `cadence-activity-execution-failed` | counter | Activity-body raised. |
| `cadence-activity-response-latency` | histogram | Time reporting completion. |
| `cadence-activity-response-failed` | counter | Failed to report completion. |
| `cadence-activity-endtoend-latency` | histogram | Activity start-to-close including retries. |
| `cadence-activity-task-panic` | counter | Activity raised an uncaught exception. |
| `cadence-activity-task-completed` | counter | Activity completed successfully. |
| `cadence-activity-task-failed` | counter | Activity returned an error. |
| `cadence-activity-task-canceled` | counter | Activity was canceled. |
| `cadence-activity-task-completed-by-id` / `-failed-by-id` / `-canceled-by-id` | counters | Tagged by activity ID. |

**Local activities**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-local-activity-total` | counter | Local activity invocations. |
| `cadence-local-activity-canceled` | counter | Local activity cancellations. |
| `cadence-local-activity-failed` | counter | Local activity application failures. |
| `cadence-local-activity-panic` | counter | Local activity raised an uncaught exception. |
| `cadence-local-activity-timeout` | counter | Local activity timed out. |
| `cadence-local-activity-execution-latency` | histogram | Local-activity execution latency. |
| `cadence-locally-dispatched-activity-poll-total` / `-no-task` / `-succeed` | counters | Locally dispatched activity poll results. |
| `cadence-activity-local-dispatch-succeed` / `-failed` | counters | Local-dispatch outcomes. |

These names are defined for parity with Go/Java; local activities themselves are **not yet emitted** by this SDK (see [`activities.md`](activities.md)).

**Sticky cache and replay**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-sticky-cache-hit` | counter | Cache hit on a decision task. |
| `cadence-sticky-cache-miss` | counter | Cache miss; full history replay required. |
| `cadence-sticky-cache-evict` | counter | Workflow evicted from the cache. |
| `cadence-sticky-cache-stall` | counter | Cache lookup stalled. |
| `cadence-sticky-cache-size` | gauge | Current cache occupancy. |
| `cadence-replay-succeed` | counter | History replays that completed successfully. |
| `cadence-replay-failed` | counter | History replays that diverged from the recorded history. |
| `cadence-replay-skipped` | counter | Replays the SDK chose to skip. |
| `cadence-replay-latency` | histogram | Replay latency. |
| `cadence-non-deterministic-error` | counter | Non-deterministic-error encounters surfaced by the SDK. |

**Signals**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-unhandled-signals` | counter | Signals delivered with no matching handler. |
| `cadence-corrupted-signals` | counter | Signal payloads that failed to deserialize. |

**Service requests**

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-request` | counter | gRPC request to the frontend. Tagged by operation. |
| `cadence-error` | counter | gRPC error response. Tagged by operation and error type. |
| `cadence-invalid-request` | counter | gRPC `INVALID_ARGUMENT` responses. |
| `cadence-latency` | histogram | gRPC call latency. |

### Custom metrics from your code

Reach for the same `MetricsEmitter` you handed to the `Client` to emit your own metrics on the same backend with the same default labels:

```python
# Inside an activity:
from cadence import activity
activity.client().metrics_emitter.counter("orders.charge.attempted", tags={"payment_method": "card"})

# Inside a workflow:
# NOT replay-safe — the SDK does not suppress emissions during replay.
# Push the metric emission into an activity, or accept that the counter
# will increment N+1 times for N retries.
```

> **Alpha gap.** Metric emissions from workflow code fire on every replay. There is no equivalent of `Workflow.getMetricsScope()` that suppresses non-replay emissions. Emit metrics from activities until this lands.

## Tracing

The SDK does not expose a first-class tracer option at the worker level (no `WorkerOptions.tracer` analog to the Java SDK). What is available:

- The `Client` accepts a list of `grpc.aio.ClientInterceptor` via `interceptors=[...]`. Insert an interceptor that creates client-side gRPC spans for every request to the frontend.
- The SDK's dev dependencies include `opentelemetry-instrumentation-grpc`, which auto-instruments the gRPC client side. Calling its setup function before constructing the `Client` instruments outgoing RPCs without code changes.

```python
from opentelemetry.instrumentation.grpc import GrpcAioInstrumentorClient

GrpcAioInstrumentorClient().instrument()  # before the Client is constructed
```

This gives you transport-level spans for every poll, signal, query, and history fetch. It does **not** give you per-workflow or per-activity logical spans the way Go's `interceptors.NewTracingInterceptor(...)` or Java's `WorkerOptions.setTracer(...)` do. Roll your own by wrapping activity bodies in spans:

```python
from opentelemetry import trace

tracer = trace.get_tracer(__name__)


@registry.activity(name="charge_card")
async def charge_card(input):
    info = activity.info()
    with tracer.start_as_current_span(
        "activity.charge_card",
        attributes={
            "cadence.workflow_id": info.workflow_id,
            "cadence.run_id": info.workflow_run_id,
            "cadence.activity_id": info.activity_id,
            "cadence.attempt": info.attempt,
        },
    ):
        return await _real_charge(input)
```

For workflow code, span creation is tricky — spans typically use wall-clock time and may not be replay-safe. Stick to activity-side spans until the SDK exposes a replay-aware tracer.

## Worker identity

Cadence records an identity string on every poll and every history event a worker produces. Two layers of identity in the Python SDK:

- **Client identity** (`Client(identity=...)`) — defaults to `f"{os.getpid()}@{socket.gethostname()}"`.
- **Worker identity** (`Worker(client, task_list, registry, identity=...)`) — defaults to `f"{client.identity}@{task_list}@{uuid4()}"`. The trailing UUID disambiguates distinct `Worker` instances in the same process.

Override the client identity to something that includes deployment context:

```python
identity = f"{os.getenv('SERVICE_NAME')}-{os.getenv('DEPLOY_ID')}@{socket.gethostname()}"

async with Client(
    target="localhost:7833",
    domain="my-domain",
    identity=identity,
) as client:
    ...
```

This lets `cadence workflow showid` output and the Cadence Web UI point at the exact deployed binary that produced any history event.

## Correlation patterns

Three IDs let you correlate any incident:

- **`workflow_id`** — pinned by the starter. Stable across continue-as-new.
- **`run_id`** — per-execution. Changes with continue-as-new and reset.
- **Worker identity** — which process handled the decision or activity.

Log all three at workflow start; emit a single structured "workflow-started" log line that downstream systems can pivot from. The same triple is what `cadence workflow showid` will print and what the SDK records in every history event.

## Not yet in the Python SDK

For the avoidance of doubt, these observability features exist in Go and Java but are not yet in `cadence-python-client`:

- **Replay-aware logger.** No `Workflow.getLogger(...)` analog. Workflow-side logs duplicate on every replay.
- **Replay-aware metrics.** No `Workflow.getMetricsScope()` analog. Workflow-side metric emissions duplicate on every replay; emit from activities instead.
- **Public `is_replaying()` flag.** No way for application code to gate on whether the current execution is replaying. The SDK's internal state machine knows; it just isn't exposed.
- **`ContextPropagator`.** No mechanism for propagating request-scoped values (tenant ID, trace baggage, locale) from starter → workflow → activity. Pass values explicitly as workflow / activity arguments for now.
- **First-class tracer integration.** No `WorkerOptions.tracer` analog. Use `grpc.aio.ClientInterceptor`s for transport-level spans and manual `tracer.start_as_current_span` in activity bodies.

When the user's question requires any of these, recommend either the Go or Java SDK or accept the operational cost of working around the gap.

## Sources of truth

- Canonical metric names: `cadence-workflow/cadence-python-client` → `cadence/metrics/constants.py`.
- `MetricsEmitter` protocol and `NoOpMetricsEmitter`: `cadence-workflow/cadence-python-client` → `cadence/metrics/metrics.py`.
- `PrometheusMetrics` implementation: `cadence-workflow/cadence-python-client` → `cadence/metrics/prometheus.py`.
- `ClientOptions.metrics_emitter` / `ClientOptions.identity`: `cadence-workflow/cadence-python-client` → `cadence/client.py`.
- gRPC interceptors plumbing: `cadence-workflow/cadence-python-client` → `cadence/_internal/rpc/`.
