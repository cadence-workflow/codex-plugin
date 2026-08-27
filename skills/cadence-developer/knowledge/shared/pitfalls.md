# Cadence pitfalls

A catalogue of mistakes that bite teams repeatedly. Each entry names the trap, says what to do instead, and (where relevant) explains why the trap exists.

## Determinism

### Reading the wall clock inside a workflow

**Don't:** call `time.Now()`, `time.Since`, `time.Sleep`, or read process uptime in workflow code.
**Do:** use `workflow.Now(ctx)` and `workflow.Sleep(ctx, d)`. For anything else time-related, capture the value once via `workflow.SideEffect` so the captured value is recorded in history and replayed.

### Using stdlib randomness or UUIDs in a workflow

**Don't:** call `rand.Intn`, `crypto/rand`, `uuid.New`, etc. directly in a workflow.
**Do:** wrap them in `workflow.SideEffect(ctx, func(ctx workflow.Context) interface{} { return uuid.New() })` so the generated value is preserved in the event history.

See [`determinism.md`](determinism.md) for the full rules.

### Iterating a Go `map` directly in a workflow

Go intentionally randomizes map iteration order. Two runs of the same workflow with the same input will iterate keys in different orders, and any side effect that depends on the order breaks replay.

**Do:** copy keys into a slice, sort it, and iterate the slice. Or move map-heavy work into an activity.

## Timeouts

### No `StartToCloseTimeout` on an activity

Activities **must** have a `StartToCloseTimeout` configured via `workflow.ActivityOptions` (or `workflow.WithLocalActivityOptions` for local activities). Without it, the call panics at registration or runtime.

### Heartbeat timeout shorter than the heartbeat interval

If you set `HeartbeatTimeout: 30 * time.Second` but only call `activity.RecordHeartbeat(ctx, ...)` every minute, Cadence will treat the activity as stuck. Configure `HeartbeatTimeout` to comfortably exceed the longest expected heartbeat interval (3× is a reasonable rule of thumb).

### Confusing `ScheduleToStartTimeout` with `StartToCloseTimeout`

- `ScheduleToStartTimeout` — how long the task may sit in the task list waiting for a worker. Use it to surface "no workers are healthy" early.
- `StartToCloseTimeout` — how long a single attempt may run after a worker picks it up.
- `ScheduleToCloseTimeout` — total budget across all retry attempts.

Setting `StartToCloseTimeout` lower than the activity's real runtime causes the worker to be killed mid-call and the activity to retry from scratch.

### Workflow-level timeouts left at zero

`StartWorkflowOptions.ExecutionStartToCloseTimeout` and `DecisionTaskStartToCloseTimeout` are required. The execution timeout bounds the whole workflow; the decision-task timeout bounds a single attempt at running workflow code on a worker. Pick conservative production values (hours/days for the execution; 10–60 s for the decision task).

## State and side effects

### Workflow code reads global mutable state

Package-level variables modified between workflow invocations are invisible to replay. Globals modified inside a workflow leak across executions and break determinism.

**Do:** pass everything you need through workflow input, signals, or activities.

### Workflow code reads files, env vars, or makes HTTP calls

These belong in activities. Activities are the only place where Cadence can record an input/output pair to history.

### `panic()` used as control flow

Panics inside a workflow are caught by the SDK and treated as a non-fatal error that fails the decision task and retries; the workflow keeps trying forever. They are not a substitute for returning an error.

**Do:** return errors. Use `workflow.NewCustomError` for application-defined errors that activities/clients can introspect.

## Concurrency

### Spawning a `go` goroutine inside a workflow

Standard goroutines are not replay-aware and break determinism. Use `workflow.Go` for cooperative coroutines, `workflow.NewChannel` for messaging, and `workflow.NewSelector` for non-blocking selects.

### Mutex-protecting workflow state

The Go SDK does not ship a workflow-aware mutex. Serialize mutable state through a single coroutine, or use a buffered `workflow.NewChannel` as a token-passing lock.

## Activity behavior

### Non-idempotent activity that does real work before retry-failing

Activities can retry many times. If the operation has external side effects (sends an email, charges a card, inserts a row), the same effect can fire repeatedly.

**Do:** make activities idempotent. Use a deterministic dedup key passed by the workflow (`activity.GetInfo(ctx).WorkflowExecution.ID + activity.GetInfo(ctx).Attempt` or a workflow-generated key via `workflow.SideEffect`) and check it before performing the side effect.

### Activity assumes it runs once

An activity may execute, fail to report its result to Cadence (worker dies right after committing the external effect), and then run again on retry. Plan for at-least-once execution.

### Long-running activity that never heartbeats

Activities that take more than a few seconds should call `activity.RecordHeartbeat(ctx, progress)` periodically. Without heartbeats, Cadence cannot tell a stuck worker apart from a working one, and `HeartbeatTimeout` is your only safety net.

## History growth

### Workflow grows past the soft warning thresholds

Cadence enforces per-execution limits (default values, configurable per domain):

- 200 MB of total history.
- ~200K events.
- 256 KB per individual event payload (warning at this size, the absolute hard limit is higher).

Warnings start at 50 MB / 50K events. Long-running orchestrations (per-user, per-account, per-month) often hit these.

**Do:** use `workflow.ContinueAsNew(ctx, newArgs)` to chain a fresh execution that picks up where the previous left off without inflating history.

### Logging large payloads to history

Anything passed to activities and child workflows is recorded in history. Trim verbose payloads (logs, request bodies) before passing them, or store them out-of-band and pass a reference.

## Workflow identity

### Reusing a workflow ID without understanding the reuse policy

The Go SDK defaults to `WorkflowIDReusePolicyAllowDuplicateFailedOnly` on `StartWorkflow` and `ExecuteWorkflow` — a new execution with the same ID succeeds only if the previous one failed. If you need different behavior, set `StartWorkflowOptions.WorkflowIDReusePolicy` explicitly:

- `AllowDuplicateFailedOnly` — default; new run allowed only if prior failed.
- `AllowDuplicate` — always allowed; you manage uniqueness yourself.
- `RejectDuplicate` — never allowed.

### Renaming a workflow function without keeping the registered name

Cadence identifies workflows by their **registered name**, which is recorded in history. Renaming the Go function but registering under the old name keeps in-flight workflows happy; renaming the registered name strands them.

**Do:** when registering, pass an explicit `Name` via `workflow.RegisterOptions`. Treat the registered name as a wire contract.

## Observability

### Using a stdlib logger inside a workflow

Direct `log.Printf` / `fmt.Println` calls fire on every replay, producing duplicate log lines. Use `workflow.GetLogger(ctx)`; the SDK suppresses output during replay.

### Recording metrics from workflow code

Metric emissions are non-deterministic if the underlying counter is host-local. Move metric emission into activities, or use `workflow.GetMetricsScope(ctx)`, which the SDK manages safely.

See [`go/observability.md`](../go/observability.md), [`java/observability.md`](../java/observability.md), or [`python/observability.md`](../python/observability.md) for the full logging, metrics, and tracing setup including the canonical `cadence-*` metric catalogue and recommended alerts.

## Sources of truth

- History size and count defaults: `cadence-workflow/cadence` → `common/dynamicconfig/dynamicproperties/constants.go` (`HistorySizeLimitError`, `HistoryCountLimitError`, `BlobSizeLimitWarn`).
- Workflow ID reuse policy: `cadence-workflow/cadence-go-client` → `internal/client.go`.
- Activity heartbeats and timeouts: `cadence-workflow/cadence-go-client` → `internal/internal_activity.go`.
