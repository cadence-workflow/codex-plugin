# Observability in the Cadence Go SDK

The Go SDK exposes three observability hooks: **logging** via [zap](https://github.com/uber-go/zap), **metrics** via [tally](https://github.com/uber-go/tally), and **tracing** via [opentracing-go](https://github.com/opentracing/opentracing-go). All three are wired through `worker.Options` when you build the worker and surfaced inside workflow and activity code via the SDK's replay-aware helpers. This file covers how to configure each pillar, how to correlate signals across them, and which built-in SDK metrics matter operationally.

## Logging

The Go SDK uses zap. Two rules govern logging in workflow code:

1. Always log through `workflow.GetLogger(ctx)`. Direct `log.Printf`/`fmt.Println`/zap.L() calls fire on every replay and produce duplicate output.
2. By default the SDK suppresses logs during replay. Override with `worker.Options.EnableLoggingInReplay = true` only when debugging replay itself.

```go
workflow.GetLogger(ctx).Info(
    "order received",
    zap.String("orderID", in.OrderID),
    zap.Int("items", len(in.Items)),
)
```

Activities use `activity.GetLogger(ctx)`, which is a plain zap logger with no replay suppression because activities don't replay.

### Worker logger

Set a logger explicitly when building the worker; otherwise the SDK creates a default zap logger and logs a warning.

```go
logger, _ := zap.NewProduction()
w, err := worker.NewV2(serviceClient, "my-domain", "my-task-list", worker.Options{
    Logger: logger,
})
```

The same logger is used by the SDK itself for internal events (poller startup, decision processing, non-determinism errors, sticky-cache notes) — give it a name like `cadence-worker` so SDK logs are easy to separate from application logs.

## Metrics

The SDK emits tally counters and timers prefixed with `cadence-`. Provide a `tally.Scope` and the SDK starts populating it.

```go
scope, closer := tally.NewRootScope(tally.ScopeOptions{
    Prefix:   "myapp.",
    Tags:     map[string]string{"service": "checkout"},
    Reporter: prometheusReporter,
}, time.Second)
defer closer.Close()

w, err := worker.NewV2(serviceClient, "my-domain", "my-task-list", worker.Options{
    MetricsScope: scope,
})
```

If you leave `MetricsScope` nil, the SDK uses `tally.NoopScope` and logs a notice. You can still emit your own metrics from inside workflow and activity code:

```go
workflow.GetMetricsScope(ctx).Counter("order.received").Inc(1)
activity.GetMetricsScope(ctx).Timer("payment.gateway.latency").Record(latency)
```

`workflow.GetMetricsScope` is replay-aware — emissions only happen once per logical event, not on every replay. `activity.GetMetricsScope` is a thin wrapper around the worker's scope.

### Canonical SDK metrics

Every metric name below is prefixed with `cadence-` and lives in `internal/common/metrics/constants.go`. Tags include `workflowType`, `activityType`, `tasklist`, and `domain` where relevant. Group them by what they tell you.

**Workflow lifecycle.**

| Metric | Meaning |
| --- | --- |
| `cadence-workflow-start` | A workflow execution was started by this worker's client. |
| `cadence-workflow-completed`, `-canceled`, `-failed` | Terminal outcomes. |
| `cadence-workflow-continue-as-new` | A workflow chained itself with `NewContinueAsNewError`. |
| `cadence-workflow-endtoend-latency` | Wall-clock from `WorkflowExecutionStarted` to terminal event. |

**Decision (workflow task) processing.**

| Metric | Meaning |
| --- | --- |
| `cadence-decision-poll-total`, `-no-task`, `-succeed`, `-failed`, `-transient-failed` | Outcomes of long-polls for workflow tasks. |
| `cadence-decision-poll-latency` | Successful poll latency. |
| `cadence-decision-scheduled-to-start-latency` | How long a workflow task waited in matching before this worker picked it up. Watch this — sustained growth means the worker fleet is under-scaled. |
| `cadence-decision-execution-latency` | Time spent running workflow code per decision task. |
| `cadence-decision-task-panic` | Workflow code panicked. Should be zero. |
| `cadence-decision-task-completed`, `-force-completed` | Successful and forced (timeout) completions. |
| `cadence-decision-timeout` | Decision task did not complete inside `DecisionTaskStartToCloseTimeout`. |

**Activity processing.**

| Metric | Meaning |
| --- | --- |
| `cadence-activity-poll-*` | Same shape as decision polls. |
| `cadence-activity-scheduled-to-start-latency` | How long the activity waited for a worker. Spikes here also point to under-provisioned workers. |
| `cadence-activity-execution-latency`, `-endtoend-latency` | Single-attempt vs total (across retries). |
| `cadence-activity-task-completed`, `-failed`, `-canceled` | Per-attempt outcomes. |
| `cadence-activity-task-panic` | Activity code panicked. |

**Local activities.**

| Metric | Meaning |
| --- | --- |
| `cadence-local-activity-total`, `-failed`, `-canceled`, `-timeout`, `-panic` | Local activity outcomes; no poll metrics because they bypass matching. |
| `cadence-local-activity-execution-latency` | Per-attempt latency. |

**Sticky execution cache.**

| Metric | Meaning |
| --- | --- |
| `cadence-sticky-cache-hit`, `-miss`, `-evict`, `-stall`, `-size` | Indicators of how often workflows replay. High miss/evict rates mean replays are frequent — non-determinism bugs surface sooner, but throughput drops. Tune `worker.SetStickyWorkflowCacheSize` and worker memory. See [`workers.md`](workers.md). |

**Determinism and replay.**

| Metric | Meaning |
| --- | --- |
| `cadence-non-deterministic-error` | The SDK detected a replay/code mismatch. Any non-zero value is a release-blocker incident. |
| `cadence-replay-succeed`, `-failed`, `-skipped`, `-latency` | Emitted by `WorkflowReplayer` and the Workflow Shadower. |

**History size pressure.**

| Metric | Meaning |
| --- | --- |
| `cadence-estimated-history-size` | Worker's local estimate of the current workflow's history bytes. |
| `cadence-server-side-history-size` | Authoritative size reported by the server. Watch the warning threshold (50 MB) — workflows close to it should be checked for missing `ContinueAsNew`. |

**RPC and worker health.**

| Metric | Meaning |
| --- | --- |
| `cadence-request`, `-error`, `-latency`, `-invalid-request` | Outbound calls to the Cadence frontend. Tagged by operation. |
| `cadence-worker-start`, `-poller-start` | Process startup signals. |
| `cadence-worker-panic` | Uncaught panic in worker code paths outside workflows/activities. Should be zero. |
| `cadence-unhandled-signals`, `cadence-corrupted-signals` | Indicate workflows receiving signals their code does not handle. |

### What to alert on

A reasonable alert starter pack:

- **Sustained `cadence-decision-scheduled-to-start-latency` or `cadence-activity-scheduled-to-start-latency` above SLO.** Worker fleet is under-provisioned.
- **Any `cadence-non-deterministic-error`.** Page immediately; either roll back the deploy or apply a reset.
- **`cadence-decision-task-panic` or `cadence-activity-task-panic` non-zero.** Bug in workflow/activity code.
- **`cadence-server-side-history-size` p99 approaching 200 MB.** A workflow is growing without `ContinueAsNew`.
- **High `cadence-sticky-cache-miss` rate.** Worker fleet is bouncing or undersized; replays cost more than they should.
- **`cadence-decision-poll-failed` and `cadence-activity-poll-failed` non-transient counts.** Connectivity to the cluster is degraded.

## Tracing

Tracing is OpenTracing-based. Set `worker.Options.Tracer` and the SDK automatically wires a `TracingContextPropagator` so spans cross workflow and activity boundaries.

```go
tracer, closer := jaeger.NewTracer("my-service", jaeger.NewConstSampler(true), reporter)
defer closer.Close()

w, err := worker.NewV2(serviceClient, "my-domain", "my-task-list", worker.Options{
    Tracer: tracer,
})
```

Inside a workflow:

```go
parentSpan := workflow.GetSpanContext(ctx)
childSpan := tracer.StartSpan("riskCheck", opentracing.ChildOf(parentSpan))
defer childSpan.Finish()
ctx = workflow.WithSpanContext(ctx, childSpan.Context())
```

`workflow.GetSpanContext` and `workflow.WithSpanContext` are the supported entry points for span propagation through workflow code. Don't use `opentracing.SpanFromContext` against a `workflow.Context` — it doesn't carry the span the way a stdlib context does.

If you don't set `Tracer`, the SDK uses `opentracing.NoopTracer{}` and no spans are emitted.

## Context propagation

Arbitrary key/value data can be propagated from workflow start through every activity and child workflow via `ContextPropagator`. Implement the interface from `go.uber.org/cadence/workflow` and register it on the worker:

```go
type tenantPropagator struct{}

func (tenantPropagator) Inject(ctx context.Context, hw workflow.HeaderWriter) error { /* ... */ }
func (tenantPropagator) Extract(ctx context.Context, hr workflow.HeaderReader) (context.Context, error) { /* ... */ }
func (tenantPropagator) InjectFromWorkflow(ctx workflow.Context, hw workflow.HeaderWriter) error { /* ... */ }
func (tenantPropagator) ExtractToWorkflow(ctx workflow.Context, hr workflow.HeaderReader) (workflow.Context, error) { /* ... */ }

w, err := worker.NewV2(serviceClient, domain, tasklist, worker.Options{
    ContextPropagators: []workflow.ContextPropagator{tenantPropagator{}},
})
```

Common uses: tenant ID, request ID, security principal, trace baggage. Avoid putting large payloads through propagators — every value is serialized into the workflow's start headers and travels with every history event.

## Correlation across logs, metrics, and traces

Use the SDK info helpers to tag your own emissions with workflow identifiers:

```go
info := workflow.GetInfo(ctx)
workflow.GetLogger(ctx).Info(
    "step completed",
    zap.String("workflowID", info.WorkflowExecution.ID),
    zap.String("runID", info.WorkflowExecution.RunID),
    zap.String("workflowType", info.WorkflowType.Name),
)
```

`activity.GetInfo(ctx)` exposes the same identifiers plus the activity ID, type, and attempt number. Tagging logs and custom metrics with these fields keeps observability pipelines stitched together with the event history visible in Cadence Web.

## Worker identity

`worker.Options.Identity` sets the string Cadence records on every poll and every recorded event as the "who". The default is `<pid>@<hostname>:<tasklist>`; override with something stable per deployment when you want metrics tagged by deployment generation or by canary cohort. The identity is what appears in `cadence workflow describe`'s pending-activity table as the worker handling each task.

## Sources of truth

- Logger/metrics helpers (workflow side): `cadence-workflow/cadence-go-client` → `workflow/workflow.go` (`GetLogger`, `GetMetricsScope`)
- Logger/metrics helpers (activity side): `cadence-workflow/cadence-go-client` → `activity/activity.go`
- Worker options: `cadence-workflow/cadence-go-client` → `internal/internal_worker.go` (`Logger`, `MetricsScope`, `Tracer`, `Identity`, `ContextPropagators`, `EnableLoggingInReplay`)
- Canonical metric names: `cadence-workflow/cadence-go-client` → `internal/common/metrics/constants.go`
- Tracing helpers: `cadence-workflow/cadence-go-client` → `workflow/context.go` (`GetSpanContext`, `WithSpanContext`)
- Context propagator interface: `cadence-workflow/cadence-go-client` → `workflow/context_propagator.go`
