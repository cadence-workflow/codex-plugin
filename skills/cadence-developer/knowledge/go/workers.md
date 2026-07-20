# Workers in the Cadence Go SDK

A **worker** is a long-running Go process that owns workflow and activity code. It opens a connection to the Cadence frontend, long-polls a task list for work, executes the corresponding code, and reports results back. Most production Cadence applications run two kinds of worker binary — usually with the same code — split by whether they host the workflow code, the activity code, or both.

This file covers: building the workflow service client, constructing the worker, registering workflows and activities, the `worker.Options` reference, the poll/execute concurrency model, sticky execution, lifecycle and graceful shutdown, and common topology patterns.

## Build the workflow service client

The Go SDK reaches the Cadence server through the `workflowserviceclient.Interface`. The current canonical wiring uses YARPC with the gRPC transport and Cadence's Thrift-to-proto adapter so SDK code that still expects the Thrift interface keeps working over the gRPC wire.

```go
import (
    apiv1 "github.com/uber/cadence-idl/go/proto/api/v1"
    "go.uber.org/cadence/.gen/go/cadence/workflowserviceclient"
    "go.uber.org/cadence/compatibility"
    "go.uber.org/yarpc"
    "go.uber.org/yarpc/peer"
    yarpchostport "go.uber.org/yarpc/peer/hostport"
    "go.uber.org/yarpc/transport/grpc"
)

const (
    hostPort       = "127.0.0.1:7833"      // Cadence frontend gRPC port
    clientName     = "my-cadence-worker"    // identifies *your* service
    cadenceService = "cadence-frontend"     // YARPC outbound key; matches Cadence's service name
)

func newServiceClient() workflowserviceclient.Interface {
    grpcTransport := grpc.NewTransport()
    chooser := peer.NewSingle(
        yarpchostport.Identify(hostPort),
        grpcTransport.NewDialer(),
    )
    dispatcher := yarpc.NewDispatcher(yarpc.Config{
        Name: clientName,
        Outbounds: yarpc.Outbounds{
            cadenceService: {Unary: grpcTransport.NewOutbound(chooser)},
        },
    })
    if err := dispatcher.Start(); err != nil {
        panic(err)
    }

    cc := dispatcher.ClientConfig(cadenceService)
    return compatibility.NewThrift2ProtoAdapter(
        apiv1.NewDomainAPIYARPCClient(cc),
        apiv1.NewWorkflowAPIYARPCClient(cc),
        apiv1.NewWorkerAPIYARPCClient(cc),
        apiv1.NewVisibilityAPIYARPCClient(cc),
    )
}
```

The default Cadence development server listens on `7933` (Thrift TChannel) and `7833` (gRPC). New code should target gRPC. Reuse one dispatcher and one service client across every worker in the process — they are safe to share and pool connections internally.

## Construct the worker

```go
import "go.uber.org/cadence/worker"

w, err := worker.NewV2(
    serviceClient,
    "my-domain",
    "my-task-list",
    worker.Options{
        Logger:       logger,
        MetricsScope: scope,
    },
)
if err != nil {
    return err
}
```

`worker.NewV2` returns an error; `worker.New` is the legacy entry point and panics instead. Prefer `NewV2` for any new code. The signature is fixed: `(service, domain, taskList, options) -> (Worker, error)`.

## Register workflows and activities

Always register with explicit names. The registered name becomes part of the workflow's history; renaming it strands every in-flight execution.

```go
import (
    "go.uber.org/cadence/activity"
    "go.uber.org/cadence/workflow"
)

w.RegisterWorkflowWithOptions(
    OrderWorkflow,
    workflow.RegisterOptions{Name: "myapp.OrderWorkflow"},
)

w.RegisterActivityWithOptions(
    ChargeCard,
    activity.RegisterOptions{Name: "myapp.ChargeCard"},
)
```

For struct-based activities, the struct method names are registered as activities prefixed by the supplied `Name`. The receiver's exported fields can carry dependencies (clients, configs) — they survive across activity invocations because the worker holds a single instance.

```go
type PaymentActivities struct {
    Stripe *stripe.Client
}

func (p *PaymentActivities) ChargeCard(ctx context.Context, req ChargeReq) (ChargeResp, error) { /* ... */ }
func (p *PaymentActivities) RefundCharge(ctx context.Context, chargeID string) error           { /* ... */ }

w.RegisterActivityWithOptions(
    &PaymentActivities{Stripe: stripeClient},
    activity.RegisterOptions{Name: "myapp.Payment_"}, // registers myapp.Payment_ChargeCard, myapp.Payment_RefundCharge
)
```

Re-registering the same name on a worker panics by default. Set `DisableAlreadyRegisteredCheck` on the register options when you intentionally want a second registration (mainly for tests).

## Start and stop

```go
if err := w.Start(); err != nil {       // non-blocking
    return err
}
defer w.Stop()                          // graceful shutdown bounded by WorkerStopTimeout

// or, block until killed:
if err := w.Run(); err != nil {         // calls Start, then waits on SIGINT/SIGTERM, then Stop
    return err
}
```

Set `worker.Options.WorkerStopTimeout` to give in-flight activities a deadline to wind down. After that timeout `Stop()` returns regardless of whether the work finished. Always wire a process-level signal handler if you use `Start()`/`Stop()` directly so that container shutdowns close pollers cleanly instead of dropping mid-task.

## `worker.Options` reference

Every field is optional. The defaults are sane for a development single-process setup; production deployments routinely override the concurrency caps and the metrics/logger fields. Grouped by concern below.

### Identity and isolation

| Field | Default | Purpose |
| --- | --- | --- |
| `Identity` | `<pid>@<hostname>:<tasklist>` | The string Cadence records as the worker handling each task. |
| `IsolationGroup` | empty | Failure-group/zone tag. The server uses this for partitioning and routing when isolation groups are enabled. |

### Logging, metrics, tracing

`Logger` (`*zap.Logger`), `MetricsScope` (`tally.Scope`), `Tracer` (`opentracing.Tracer`), `EnableLoggingInReplay`, and `ContextPropagators` are covered in [`observability.md`](observability.md).

### Concurrency caps

| Field | Default | Purpose |
| --- | --- | --- |
| `MaxConcurrentDecisionTaskPollers` | 2 | Goroutines polling for workflow tasks. |
| `MaxConcurrentActivityTaskPollers` | 2 | Goroutines polling for activity tasks. |
| `MaxConcurrentDecisionTaskExecutionSize` | 1000 | Concurrently executing decision (workflow) tasks. |
| `MaxConcurrentActivityExecutionSize` | 1000 | Concurrently executing activity tasks. |
| `MaxConcurrentLocalActivityExecutionSize` | 1000 | Concurrently executing local activities. |
| `MaxConcurrentSessionExecutionSize` | 1000 | Concurrent sessions when `EnableSessionWorker` is true. |

Raising poller counts lets a single worker pull more work off the task list per second; raising execution sizes lets it run more in parallel. Watch [`cadence-decision-scheduled-to-start-latency`](observability.md) — if it grows the bottleneck is *poller* count or worker count, not execution slots.

### Rate limits

| Field | Default | Purpose |
| --- | --- | --- |
| `WorkerDecisionTasksPerSecond` | 100000 | Per-worker decision task rate. |
| `WorkerActivitiesPerSecond` | 100000 | Per-worker activity task rate. |
| `WorkerLocalActivitiesPerSecond` | 100000 | Per-worker local activity rate. |
| `TaskListActivitiesPerSecond` | 100000 | Whole-task-list activity rate, enforced server-side. |

Useful for protecting downstream systems behind activities. Per-worker limits don't aggregate across the fleet; use `TaskListActivitiesPerSecond` for whole-fleet caps.

### Sticky execution

| Field | Default | Purpose |
| --- | --- | --- |
| `DisableStickyExecution` | false | If false, workers cache running workflows by run ID so subsequent decision tasks for the same execution land on the same worker and skip replay. |
| `StickyScheduleToStartTimeout` | 5s | How long the cluster waits for the sticky worker before falling back to any worker on the task list. |

Beyond this struct, sticky cache size is **process-wide** and must be set before any worker starts:

```go
worker.SetStickyWorkflowCacheSize(10000)
```

The default is 10000 workflows. Memory cost is roughly proportional to current decision state — measure if you raise it. The cache is shared across all `Worker` instances in the same process.

### Disabling sub-workers

| Field | Default | Purpose |
| --- | --- | --- |
| `DisableWorkflowWorker` | false | Run an activity-only worker. |
| `DisableActivityWorker` | false | Run a workflow-only worker. |
| `EnableSessionWorker` | false | Enable activity sessions (pinning a sequence of activities to the same worker). |

### Non-determinism policy

| Field | Default | Purpose |
| --- | --- | --- |
| `NonDeterministicWorkflowPolicy` | `BlockWorkflow` | What to do when replay diverges from history. `BlockWorkflow` logs and stops responding so the task times out; `FailWorkflow` actively fails the execution. |

See [`shared/determinism.md`](../shared/determinism.md) for the trade-offs.

### Serialization and context

| Field | Default | Purpose |
| --- | --- | --- |
| `DataConverter` | thrift+JSON default | Custom serializer for workflow/activity arguments and results. Must match between the worker and any starter/client. |
| `BackgroundActivityContext` | `context.Background()` | Base context handed to every activity invocation; use it to inject dependencies that activity code reads via `ctx.Value`. |
| `ContextPropagators` | none | See [`observability.md`](observability.md). |
| `WorkflowInterceptorChainFactories` | none | Per-replay middleware around workflow function execution. Advanced; use sparingly. |

### Autoscaling and lifecycle

| Field | Default | Purpose |
| --- | --- | --- |
| `AutoScalerOptions` | disabled | Dynamic poller-count scaling based on poll outcomes. When enabled the static `MaxConcurrent*Pollers` field becomes the initial value. |
| `WorkerStopTimeout` | 0s | Bounds in-flight activity completion during `Stop()`. Set this to a real value in production. |
| `Authorization` | none | Implementation of `auth.AuthorizationProvider` if the cluster requires JWT/OAuth tokens. |
| `FeatureFlags` | all off | Opts into experimental server-side behaviors. |

### Workflow shadower

| Field | Default | Purpose |
| --- | --- | --- |
| `EnableShadowWorker` | false | Turns this worker into a shadower; all other sub-workers are disabled. |
| `ShadowOptions` | — | Visibility query, sampling, and exit condition. See [`shared/versioning.md`](../shared/versioning.md). |

## Concurrency model

Each worker runs two independent polling loops by default:

- The **decision (workflow) pool** has `MaxConcurrentDecisionTaskPollers` goroutines long-polling for workflow tasks and `MaxConcurrentDecisionTaskExecutionSize` slots for executing them.
- The **activity pool** has `MaxConcurrentActivityTaskPollers` goroutines polling and `MaxConcurrentActivityExecutionSize` slots for executing them.

Each poller blocks for up to a minute waiting for the matching service to dispatch a task. When a task arrives the poller hands it off to the executor pool and goes back to polling. Increasing poller count helps when matching-side dispatch is the bottleneck (scheduled-to-start latency rising); increasing executor size helps when execution time is the bottleneck (slots saturated, no scheduled-to-start growth).

Picking starting values:

- A single small worker handling a few workflows: leave the defaults.
- A high-throughput task list: `MaxConcurrentDecisionTaskPollers` and `MaxConcurrentActivityTaskPollers` of 10–20, paired with execution sizes sized to the worker's CPU budget. Add workers horizontally before pushing pollers above ~50 per worker.

## Sticky execution

When sticky execution is enabled (the default), the cluster tries to send every subsequent decision task for a given workflow run to the worker that last handled it. That worker caches the workflow state in memory under the run ID and resumes from the cache instead of replaying the full history.

What it costs you when sticky cache misses:

- An eviction (cache full, process restart, or sticky-schedule-to-start timeout) triggers a full replay from history on whichever worker picks up the task next. This is correct, just slower.
- The `cadence-sticky-cache-hit/miss/evict` metrics quantify this. High eviction rates usually mean the cache is undersized for the worker's working set or workers are being bounced too often.

Disable stickiness (`DisableStickyExecution: true`) only when debugging non-determinism — full replay every decision makes mismatches surface immediately.

## Worker topology patterns

**Single-process worker, single task list.** The default. One `worker.NewV2` call hosting both workflow and activity code. Simple, good for low-throughput services.

**Separate workflow and activity workers.** Two binaries (or two `Worker` instances in one process) pointing at the same task list, one with `DisableActivityWorker: true` and the other with `DisableWorkflowWorker: true`. Useful when activity work is CPU-heavy and would starve workflow decisions, or when activities and workflows need different scaling profiles.

**Multi-task-list process.** One process can host any number of workers, each registered to a different task list. Reuse the same `workflowserviceclient.Interface` across them. This is the standard pattern for a service that owns several workflow families with different SLOs.

**Domain-per-tenant.** Each domain typically gets its own worker fleet because workflow code, registered names, and retention policies vary per tenant. Cross-domain processes are rare.

## Graceful shutdown

```go
sigCh := make(chan os.Signal, 1)
signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

if err := w.Start(); err != nil {
    log.Fatal(err)
}

<-sigCh
w.Stop() // bounded by WorkerStopTimeout
```

What happens during `Stop()`:

1. Pollers stop accepting new tasks.
2. In-flight activities receive cancellation via their `context.Context`. They should observe `ctx.Done()` between work units.
3. After `WorkerStopTimeout` elapses, `Stop()` returns even if activities are still running.

Always set `WorkerStopTimeout` to a value tied to your container orchestrator's grace period (Kubernetes' default is 30 seconds; pick something a few seconds under that). Activities that exceed it return as "worker shutdown" errors and Cadence retries them on a new worker.

## Binary checksum and bad-binary resets

```go
worker.SetBinaryChecksum("myapp@v1.42.0")
```

Sets the binary identifier Cadence records on the first decision completed by this process for each workflow. Setting it intentionally (rather than relying on the SDK's default hash) makes the bad-binary reset path operationally usable — see [`shared/versioning.md`](../shared/versioning.md). Call this **before** `Start()`.

## Common pitfalls

- **Re-registering under a new name across deploys.** The registered name lands in workflow history; renaming strands in-flight workflows. Always pass `Name:` explicitly and treat it as a wire contract.
- **Sharing dispatchers vs service clients.** Build one YARPC dispatcher and one service client per process and pass it to every worker. Spinning up one dispatcher per worker leaks connections and pollers.
- **Mismatched `DataConverter` between starter and worker.** If you customize `DataConverter` you must do so identically wherever workflows are started and wherever they execute. Otherwise arguments deserialize as garbage.
- **Sticky cache too small.** A worker with a high concurrent-workflow count and the default 10000 sticky cache size evicts constantly. Either raise `SetStickyWorkflowCacheSize` or scale workers horizontally so each holds fewer workflows.
- **`MaxConcurrentDecisionTaskPollers` set high on many workers.** Pollers cost long-poll slots on the matching service. Past a point you're just adding tail latency. Scale workers, not pollers.
- **Activity worker registered without the activity code.** A workflow-only deploy that accidentally lost the activity registrations stalls every activity invocation until either the worker is rolled or workers with the registration are scaled up. Boot-time assertion that critical activity names are registered catches this in CI.

## Sources of truth

- Worker entry points and lifecycle: `cadence-workflow/cadence-go-client` → `worker/worker.go`
- `worker.Options` field reference: `cadence-workflow/cadence-go-client` → `internal/worker.go` (`WorkerOptions struct`)
- Sticky cache and binary checksum globals: `cadence-workflow/cadence-go-client` → `worker/worker.go` (`SetStickyWorkflowCacheSize`, `SetBinaryChecksum`)
- Canonical service client wiring: `cadence-workflow/cadence-samples` → `new_samples/hello_world/worker.go`
- Default frontend ports: `cadence-workflow/cadence` → `config/development.yaml` (`port: 7933`, `grpcPort: 7833`)
