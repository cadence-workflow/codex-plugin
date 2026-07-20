# Cadence workflows in Go

A workflow in the Cadence Go SDK is a regular Go function bound by the determinism rules in [`../shared/determinism.md`](../shared/determinism.md). This file walks through the workflow API surface: function shape, the workflow context, signals, queries, child workflows, continue-as-new, versioning, side effects, cancellation, and errors. Activity-side concerns live in [`activities.md`](activities.md).

## The workflow function

A workflow is a Go function whose first argument is `workflow.Context`. Any additional arguments are the workflow's input; the function returns `error` and optionally a single result value.

```go
func MyWorkflow(ctx workflow.Context, input MyInput) (MyResult, error) {
    // orchestration
}
```

Input and output types must be serializable by the SDK's data converter (JSON by default). Stick to plain structs without unexported fields, function values, channels, or `unsafe` references.

## Registration

A worker hosts a workflow only if it is registered before `worker.Start()`. Prefer the explicit form so the workflow type recorded in history is decoupled from the Go function name:

```go
worker.RegisterWorkflowWithOptions(MyWorkflow, workflow.RegisterOptions{
    Name: "MyWorkflow",
})
```

Treat the registered `Name` as a wire contract: once a workflow is running under that type, you cannot rename it without breaking replay for in-flight executions.

## The workflow context

`workflow.Context` carries the cooperative scheduler, the activity/child-workflow defaults, cancellation, the replay-safe logger, and the value bag passed via `workflow.WithValue`. Several `With*` helpers return a derived context with overridden options. The common ones:

```go
ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
    StartToCloseTimeout: time.Minute,
})
ctx = workflow.WithChildOptions(ctx, workflow.ChildWorkflowOptions{
    ExecutionStartToCloseTimeout: time.Hour,
})
ctx = workflow.WithRetryPolicy(ctx, workflow.RetryPolicy{
    InitialInterval:    time.Second,
    BackoffCoefficient: 2.0,
    MaximumAttempts:    5,
})
```

Workflow code must never use `context.Context` from the standard library. Always pass `workflow.Context` through your helper functions.

## Activities

Activities are invoked through `workflow.ExecuteActivity(ctx, activity, args...)`. The call returns a `workflow.Future`; resolve it with `Get(ctx, &result)`:

```go
var result string
if err := workflow.ExecuteActivity(ctx, MyActivity, "hello").Get(ctx, &result); err != nil {
    return err
}
```

For activities that should run inside the worker process without going through the task list, use `workflow.ExecuteLocalActivity`. Local activities are cheaper but bypass the task list's retry and visibility behavior; see [`activities.md`](activities.md) for trade-offs.

## Timers and waiting

| Need | API |
| --- | --- |
| Sleep for a duration | `workflow.Sleep(ctx, d)` |
| Cancellable timer | `workflow.NewTimer(ctx, d)` |
| Wait on a condition | `workflow.Await(ctx, func() bool { ... })` |
| Current time | `workflow.Now(ctx)` |

`workflow.Await` is the cleanest way to gate execution on shared state changing — typically state that a signal handler has updated.

## Signals

A signal is an external message sent to a running workflow. Inside the workflow, signals arrive on a named channel:

```go
ch := workflow.GetSignalChannel(ctx, "approval")
var approved bool
ch.Receive(ctx, &approved)
```

Senders use the `client.Client` interface:

```go
cadenceClient.SignalWorkflow(ctx, workflowID, "", "approval", true)
```

A workflow that wants to handle multiple signal types fans them out with `workflow.NewSelector`:

```go
s := workflow.NewSelector(ctx)
s.AddReceive(approvalCh, func(c workflow.Channel, ok bool) { ... })
s.AddReceive(cancelCh,   func(c workflow.Channel, ok bool) { ... })
s.Select(ctx)
```

A common pattern is to spawn a `workflow.Go` goroutine that pumps each signal channel into shared state and then `workflow.Await` on that state.

## Queries

Queries let an external caller synchronously read computed workflow state without changing it. Register a query handler before any code that might block:

```go
if err := workflow.SetQueryHandler(ctx, "status", func() (string, error) {
    return currentStatus, nil
}); err != nil {
    return err
}
```

Query handlers must be deterministic and side-effect free. They run on the same replay-aware scheduler as the workflow body.

## Child workflows

A child workflow is invoked with `workflow.ExecuteChildWorkflow`. The call returns a `ChildWorkflowFuture` with two futures: one for the child's start and one for its result.

```go
ctx = workflow.WithChildOptions(ctx, workflow.ChildWorkflowOptions{
    WorkflowID:                   "billing-" + customerID,
    ExecutionStartToCloseTimeout: time.Hour,
})
childFuture := workflow.ExecuteChildWorkflow(ctx, BillingWorkflow, customerID)
var childExecution workflow.Execution
if err := childFuture.GetChildWorkflowExecution().Get(ctx, &childExecution); err != nil {
    return err
}
var result BillingResult
if err := childFuture.Get(ctx, &result); err != nil {
    return err
}
```

Child workflows are useful when the child has its own lifecycle, retry policy, or task list. Use a child only when those properties differ from the parent; otherwise call activities.

## Continue-as-new

Long-running workflows that accumulate many events should periodically reset their history by chaining a fresh execution. Return a `*ContinueAsNewError` constructed with the new arguments:

```go
return workflow.NewContinueAsNewError(ctx, MyWorkflow, nextInput)
```

The new execution starts with the same workflow ID but a new run ID and an empty history. Save any state you need to carry forward into `nextInput`. Trigger continue-as-new well before hitting the warning thresholds (50 MB / 50K events).

## Versioning

When you change workflow code that has in-flight executions, gate the new branch with `workflow.GetVersion`:

```go
v := workflow.GetVersion(ctx, "addRiskCheck", workflow.DefaultVersion, 1)
if v >= 1 {
    if err := workflow.ExecuteActivity(ctx, riskCheck, input).Get(ctx, nil); err != nil {
        return err
    }
}
```

A `MarkerRecorded` event captures the version selected on the first run; replay always takes the same branch. Increment the `maxSupported` parameter (and add another `if` arm) each subsequent revision. Once no executions remain on the old branch, the dead arm can be removed by also removing the `GetVersion` call (only after confirming with a `WorkflowShadower` run).

## Side effects

Some non-deterministic work must happen inline (a UUID, a feature-flag lookup, a one-off random value). Wrap it in `workflow.SideEffect`:

```go
v := workflow.SideEffect(ctx, func(ctx workflow.Context) interface{} {
    return uuid.New().String()
})
var orderID string
v.Get(&orderID)
```

The captured value is recorded in history (`MarkerRecorded` event) and replayed verbatim. Use `workflow.MutableSideEffect` when you want a value that may change on subsequent runs but only causes a new marker when the `equals` function reports a difference.

## Cancellation

A workflow becomes cancellable when external code calls `client.CancelWorkflow`. Cancellation propagates to the workflow as `ctx.Done()` firing. Activities and child workflows inherit the cancellation and return a cancellation error.

```go
err := workflow.ExecuteActivity(ctx, expensive, input).Get(ctx, nil)
if cadence.IsCanceledError(err) {
    // perform cleanup, then:
    return nil
}
```

When you need to run cleanup activities after the workflow's main context has been cancelled, derive a context that is detached from cancellation:

```go
cleanupCtx, cancel := workflow.NewDisconnectedContext(ctx)
defer cancel()
_ = workflow.ExecuteActivity(cleanupCtx, releaseResources).Get(cleanupCtx, nil)
```

## Errors

Application errors from activities or child workflows are returned through `Future.Get`. Use `cadence.NewCustomError(reason, details...)` inside an activity to convey structured failures the workflow can inspect:

```go
var customErr *cadence.CustomError
if errors.As(err, &customErr) && customErr.Reason() == "PaymentDeclined" {
    var details PaymentError
    _ = customErr.Details(&details)
    return cadence.NewCustomError("PaymentRefused", details)
}
```

Useful predicates and type assertions:

- `cadence.IsCanceledError(err)` — workflow or activity cancellation.
- `cadence.IsCustomError(err)`, `cadence.IsTimeoutError(err)`, `cadence.IsPanicError(err)`, `cadence.IsTerminatedError(err)`, `cadence.IsGenericError(err)` — predicates for the corresponding error types.
- `errors.As(err, &continueAs)` where `continueAs` is `*workflow.ContinueAsNewError` — the workflow is being chained as new (no `Is…` helper exists for this).

`workflow.CustomError` and `workflow.IsCanceledError` are common typos: those identifiers live in the top-level `cadence` package, while the `workflow` package re-exports `GenericError`, `TimeoutError`, `TerminatedError`, `PanicError`, and `ContinueAsNewError`. See [`shared/error-reference.md`](../shared/error-reference.md) for the full catalogue.

## Logger and metrics

Replay-safe observability:

- `workflow.GetLogger(ctx)` returns a `*zap.Logger` that suppresses output during replay.
- `workflow.GetMetricsScope(ctx)` returns a `tally.Scope` that emits only once per logical event (not on every replay).

Do not import a stdlib logger or third-party metric scope directly in workflow code — every replay would emit again.

## Sources of truth

- API entry points: `cadence-workflow/cadence-go-client` → `workflow/workflow.go`, `workflow/deterministic_wrappers.go`, `workflow/workflow_options.go`
- Errors and predicates: `cadence-workflow/cadence-go-client` → `workflow/error.go`
- Worked recipes: <https://github.com/cadence-workflow/cadence-samples/tree/master/cmd/samples/recipes>
- GoDoc: <https://pkg.go.dev/go.uber.org/cadence/workflow>
