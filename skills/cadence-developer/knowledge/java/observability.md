# Observability in the Cadence Java SDK

This file covers what a Java worker emits so you can monitor it in production: replay-safe logging from workflow code, the canonical `cadence-*` Tally metric catalog, OpenTracing integration, context propagation across workflow and activity boundaries, and worker identity for fleet correlation. For the conceptual basis of replay-aware logging and metrics see [`shared/determinism.md`](../shared/determinism.md).

## Logging

Workflow code logs through `Workflow.getLogger(...)`, which returns an SLF4J `Logger` that the SDK silences during replay. Replay happens every time the worker rebuilds workflow state from history — directly using `LoggerFactory.getLogger(...)` on a workflow class produces duplicate log lines on every retry, restart, or query.

```java
public class OrderWorkflowImpl implements OrderWorkflow {
    private static final Logger log = Workflow.getLogger(OrderWorkflowImpl.class);

    @Override
    public OrderResult run(OrderInput input) {
        log.info("starting order {}", input.id());
        // ...
    }
}
```

For most diagnostic needs the workflow-info fields are the right tags to attach via MDC:

```java
WorkflowInfo info = Workflow.getWorkflowInfo();
MDC.put("workflowId", info.getWorkflowId());
MDC.put("runId", info.getRunId());
MDC.put("workflowType", info.getWorkflowType());
try {
    log.info("processing batch");
} finally {
    MDC.clear();
}
```

To diagnose a replay specifically — for example to skip a noisy log statement during retries — guard the call with `Workflow.isReplaying()`:

```java
if (!Workflow.isReplaying()) {
    log.info("first-time observation: {}", details);
}
```

Activity code has no replay concept; any SLF4J logger works fine. Tag activity logs with workflow context from `Activity.getWorkflowExecution()` and `Activity.getTask().getActivityId()` for cross-pillar correlation.

If you genuinely need to see replay activity logged — for instance during local debugging — flip `WorkerFactoryOptions.setEnableLoggingInReplay(true)`. Keep it off in production.

## Metrics

The SDK emits a fixed catalog of `cadence-*` Tally metrics on the `Scope` you configure via `WorkflowClientOptions.setMetricsScope(...)`. Configure a single root scope per process and let the SDK tag it with `workflowType`, `activityType`, `taskList`, and `domain` automatically.

```java
import com.uber.m3.tally.RootScopeBuilder;
import com.uber.m3.tally.Scope;
import com.uber.m3.util.Duration;

Scope rootScope = new RootScopeBuilder()
    .reporter(new MyStatsReporter())   // your Tally reporter
    .reportEvery(Duration.ofSeconds(10));

WorkflowClient client = WorkflowClient.newInstance(
    new Thrift2ProtoAdapter(IGrpcServiceStubs.newInstance()),
    WorkflowClientOptions.newBuilder()
        .setDomain("my-domain")
        .setMetricsScope(rootScope)
        .build());
```

### Worker and process

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-worker-start` | counter | A worker on this process started polling. |
| `cadence-poller-start` | counter | A poller goroutine within a worker began polling. |
| `cadence-java-client-version` | gauge | Reports the embedded client version as a tag. |

### Workflow lifecycle (client-side)

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-workflow-start` | counter | Synchronous `WorkflowClient` start. |
| `cadence-workflow-start-async` | counter | Async start. |
| `cadence-workflow-signal-with-start` | counter | Signal-with-start. |
| `cadence-workflow-signal-with-start-async` | counter | Async signal-with-start. |
| `cadence-workflow-completed` | counter | Workflow reached terminal Completed state. |
| `cadence-workflow-canceled` | counter | Workflow reached terminal Canceled state. |
| `cadence-workflow-failed` | counter | Workflow reached terminal Failed state. |
| `cadence-workflow-continue-as-new` | counter | Workflow continued as new. |
| `cadence-workflow-endtoend-latency` | timer | Start-to-close latency observed by the client. |
| `cadence-workflow-get-history-total` | counter | History fetches from `WorkflowStub.getResult` and friends. |
| `cadence-workflow-get-history-succeed` | counter | Successful history fetches. |
| `cadence-workflow-get-history-failed` | counter | Failed history fetches. |
| `cadence-workflow-get-history-latency` | timer | Latency of a successful history fetch. |

### Decision (workflow task) execution

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-decision-poll-total` | counter | Decision task long-poll attempts. |
| `cadence-decision-poll-succeed` | counter | Polls that returned a task. |
| `cadence-decision-poll-no-task` | counter | Polls that returned no work. |
| `cadence-decision-poll-failed` | counter | Permanent poll failures. |
| `cadence-decision-poll-transient-failed` | counter | Retryable poll failures. |
| `cadence-decision-poll-latency` | timer | Latency of a successful poll. |
| `cadence-decision-scheduled-to-start-latency` | timer | Time a decision task waited in the matching service before this worker started it. **Key indicator** of poller saturation. |
| `cadence-decision-execution-latency` | timer | Time the worker spent computing the decision response. |
| `cadence-decision-response-latency` | timer | Time spent reporting the decision back to the frontend. |
| `cadence-decision-execution-failed` | counter | Decision computation failed. |
| `cadence-decision-task-error` | counter | Generic decision-task error. |
| `cadence-decision-task-completed` | counter | Decision task completed successfully. |
| `cadence-decision-task-force-completed` | counter | Decision task was force-completed because of a non-deterministic error policy. |

### Activity execution

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-activity-poll-total` | counter | Activity-task long-poll attempts. |
| `cadence-activity-poll-succeed` | counter | Polls that returned a task. |
| `cadence-activity-poll-no-task` | counter | Polls that returned no work. |
| `cadence-activity-poll-failed` | counter | Permanent poll failures. |
| `cadence-activity-poll-transient-failed` | counter | Retryable poll failures. |
| `cadence-activity-poll-latency` | timer | Latency of a successful poll. |
| `cadence-activity-scheduled-to-start-latency` | timer | Time the activity waited before this worker started it. |
| `cadence-activity-execution-latency` | timer | Time the worker spent running the activity. |
| `cadence-activity-response-latency` | timer | Time spent reporting completion. |
| `cadence-activity-endtoend-latency` | timer | Activity start-to-close including retries. |
| `cadence-activity-task-completed` | counter | Activity completed successfully. |
| `cadence-activity-task-failed` | counter | Activity returned an error. |
| `cadence-activity-task-canceled` | counter | Activity was canceled. |
| `cadence-activity-task-error` | counter | Generic activity-task error. |
| `cadence-activity-task-completed-by-id` / `-failed-by-id` / `-canceled-by-id` | counters | Tagged with the activity ID. |
| `cadence-activity_active_thread_count` | gauge | Activity threads currently in flight on this worker. |

### Local activities

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-local-activity-total` | counter | Local activity invocations. |
| `cadence-local-activity-canceled` | counter | Local activity cancellations. |
| `cadence-local-activity-failed` | counter | Local activity application failures. |
| `cadence-local-activity-panic` | counter | Local activity threw an uncaught exception. |
| `cadence-local-activity-execution-latency` | timer | Local activity execution latency. |
| `cadence-local_activity_active_thread_count` | gauge | Local activity threads currently in flight. |
| `cadence-locally-dispatched-activity-poll-succeed` / `-no-task` | counters | Locally dispatched activity poll results. |
| `cadence-activity-local-dispatch-succeed` / `-failed` | counters | Local-dispatch outcomes. |

### Sticky cache and replay

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-sticky-cache-hit` | counter | Sticky cache hit on decision task. |
| `cadence-sticky-cache-miss` | counter | Sticky cache miss; full history replay required. |
| `cadence-sticky-cache-size` | gauge | Current cache occupancy. |
| `cadence-sticky-cache-total-forced-eviction` | counter | Evictions caused by cache pressure. |
| `cadence-sticky-cache-thread-forced-eviction` | counter | Evictions caused by workflow-thread limits. |
| `cadence-workflow_active_thread_count` | gauge | Workflow threads currently in flight. |
| `cadence-replay-succeed` | counter | History replays that completed successfully. |
| `cadence-replay-failed` | counter | History replays that diverged from the recorded history. |
| `cadence-replay-skipped` | counter | Replays the SDK chose to skip. |
| `cadence-replay-latency` | timer | Replay latency. |
| `cadence-non-deterministic-error` | counter | Non-deterministic-error encounters surfaced by the SDK. |

### Service requests

| Metric | Type | Meaning |
| --- | --- | --- |
| `cadence-request` | counter | gRPC request to the frontend. Tagged by operation. |
| `cadence-error` | counter | gRPC error response. Tagged by operation and error type. |
| `cadence-invalid-request` | counter | gRPC `INVALID_ARGUMENT` responses. |
| `cadence-latency` | timer | gRPC call latency. |
| `cadence-corrupted-signals` | counter | Signal payloads that failed to deserialize. |

### Custom metrics from workflow and activity code

Emit your own metrics through the same scope so they share tags and reporter wiring:

```java
// Inside a workflow — replay-safe:
Workflow.getMetricsScope().counter("orders.processed").inc(1);

// Inside an activity — any timing approach works:
Activity.getMetricsScope().counter("payments.charge.attempted").inc(1);
```

The workflow scope is replay-aware: emissions during replay are suppressed automatically. The activity scope is a regular Tally scope.

## Tracing

The SDK plugs into OpenTracing through `WorkerOptions.setTracer(...)`. When a tracer is set, the SDK starts a span for each workflow execution and propagates it across activity invocations, child workflows, and continue-as-new boundaries.

```java
import io.opentracing.Tracer;

Tracer tracer = GlobalTracer.get();
Worker worker = factory.newWorker(
    "orders-tasklist",
    new WorkerOptions.Builder()
        .setTracer(tracer)
        .build());
```

Inside activity code, the active span is the activity's span; use the tracer directly to add tags, logs, or child spans. Inside workflow code, prefer non-tracer instrumentation (metrics, MDC-tagged logs) — span operations from workflow code must be deterministic, which most tracer APIs don't guarantee.

## Context propagation

`ContextPropagator` carries request-scoped values from the starter, through the workflow, and into each activity invocation. The interface is small:

```java
public interface ContextPropagator {
    Map<String, byte[]> serializeContext(Object context);
    Object deserializeContext(Map<String, byte[]> context);
    Object getCurrentContext();
    void setCurrentContext(Object context);
    void unsetCurrentContext();
}
```

A typical implementation reads from MDC or a ThreadLocal in `getCurrentContext`, serializes the chosen fields in `serializeContext`, and restores them in `setCurrentContext`. Register at the client level so context flows into every workflow and activity:

```java
WorkflowClient.newInstance(service,
    WorkflowClientOptions.newBuilder()
        .setDomain("my-domain")
        .setContextPropagators(List.of(new MdcContextPropagator("tenantId", "requestId")))
        .build());
```

Use cases: tenant ID, trace baggage, locale, request ID — anything the worker should see without explicitly threading it through every activity argument. Keep payloads small; the SDK serializes them into the workflow's headers on every event.

## Worker identity

Cadence records a `WorkerIdentity` string on every poll and every history event a worker produces. Set it via `WorkflowClientOptions.setIdentity(...)`:

```java
String identity = String.format("%s-%s@%s",
    System.getenv("SERVICE_NAME"),
    System.getenv("DEPLOY_ID"),
    InetAddress.getLocalHost().getHostName());

WorkflowClient.newInstance(service,
    WorkflowClientOptions.newBuilder()
        .setDomain("my-domain")
        .setIdentity(identity)
        .build());
```

Visible in `cadence workflow showid` output and in the Cadence Web UI per-event timeline. The default identity is `<pid>@<hostname>` — fine for local development, opaque in a fleet. Including the deployment ID and service name lets you point at the exact binary that produced a problem decision.

## Correlation patterns

Three IDs together let you correlate any incident:

- **`workflowId`** — pinned by the starter. Stable across continue-as-new.
- **`runId`** — per-execution. Changes with continue-as-new and reset.
- **Worker identity** — which process handled the decision or activity.

Log all three at workflow start; emit a single structured "workflow-started" log line that downstream systems can pivot from. The same triple is what `cadence workflow showid` will print and what the SDK records in every history event.

## Sources of truth

- Canonical metric names: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/internal/metrics/MetricsType.java`
- Replay-safe logger: `Workflow.getLogger(Class)` in `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/workflow/Workflow.java`
- Workflow metrics scope: `Workflow.getMetricsScope()` in the same file.
- Activity helpers: `Activity.getMetricsScope`, `Activity.getWorkflowExecution`, `Activity.getTask` in `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/activity/Activity.java`
- `ContextPropagator`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/context/ContextPropagator.java`
- Tracer integration: `WorkerOptions.setTracer(Tracer)` in `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/worker/WorkerOptions.java`
- `WorkflowClientOptions` (metrics scope, identity, context propagators): `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/client/WorkflowClientOptions.java`
