# Cadence activities in Go

Activities are where your workflow touches the outside world — HTTP, database, file I/O, anything non-deterministic. Cadence schedules, runs, retries, and records the result of each activity invocation in workflow history. This file covers the Go activity API; the workflow-side surface is in [`workflows.md`](workflows.md).

## The activity function

An activity is a regular Go function whose first argument is a stdlib `context.Context`. Additional arguments are the input; the return values are an optional result and an `error`.

```go
import (
    "context"
    "go.uber.org/cadence/activity"
)

func ChargeCard(ctx context.Context, in ChargeInput) (ChargeResult, error) {
    activity.GetLogger(ctx).Info("charging", zap.String("cardID", in.CardID))
    // call your payment provider here
    return ChargeResult{TransactionID: txnID}, nil
}
```

Input and output types must be serializable by the SDK's data converter (JSON by default). Avoid function values, channels, and unexported fields in payloads.

Activities can also be methods on a struct, which is useful for injecting dependencies (HTTP clients, database handles, configuration). Register one method per activity by passing a pointer to the struct.

## Registration

A worker hosts an activity only if it is registered before `worker.Start()`:

```go
worker.RegisterActivityWithOptions(ChargeCard, activity.RegisterOptions{
    Name: "ChargeCard",
})
```

As with workflows, the registered `Name` is the wire identifier and should be treated as a contract. If you register a struct, every exported method becomes an activity named `<Struct>.<Method>` unless you override it.

## The activity context

`activity.GetInfo(ctx)` exposes the running execution's metadata: `WorkflowExecution`, `ActivityID`, `ActivityType`, `Attempt`, `ScheduledTimestamp`, `Deadline`, and so on. The most useful fields:

- `ActivityInfo.WorkflowExecution.ID` and `RunID` — identifies the parent workflow execution.
- `ActivityInfo.Attempt` — 1 on the first try, incremented on each retry. Useful for idempotency keys.
- `ActivityInfo.HeartbeatDetails` — the last details recorded via `RecordHeartbeat` on a previous attempt, available so a retry can resume rather than restart.

Other useful context helpers:

- `activity.GetLogger(ctx)` — a `*zap.Logger`.
- `activity.GetMetricsScope(ctx)` — a `tally.Scope`.
- `activity.GetWorkerStopChannel(ctx)` — closes when the worker is shutting down so long-running activities can exit cleanly.

## Activity options (set on the workflow side)

The workflow that calls the activity controls its timeouts and retry policy by configuring `workflow.ActivityOptions`. Three timeouts matter:

| Timeout | Bounds |
| --- | --- |
| `ScheduleToStartTimeout` | how long the task may sit in the task list before a worker picks it up |
| `StartToCloseTimeout` | a single attempt's runtime, from worker-pickup to result |
| `ScheduleToCloseTimeout` | total budget across all retry attempts |

`HeartbeatTimeout` is enforced only if the activity calls `activity.RecordHeartbeat`. Set it 3× the longest expected heartbeat interval — see [`../shared/pitfalls.md`](../shared/pitfalls.md).

## Retry policy

Activities retry by default with sensible backoff (initial interval 1s, exponential coefficient 2, no max attempts). Override the policy in `workflow.ActivityOptions.RetryPolicy`:

```go
ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
    StartToCloseTimeout: time.Minute,
    RetryPolicy: &cadence.RetryPolicy{
        InitialInterval:    time.Second,
        BackoffCoefficient: 2.0,
        MaximumInterval:    time.Minute,
        MaximumAttempts:    5,
        NonRetriableErrorReasons: []string{"PaymentDeclined"},
    },
})
```

`NonRetriableErrorReasons` is matched against the `Reason` of a `*cadence.CustomError` returned by the activity. Use it for permanent failures the caller should surface immediately.

To mark a failure as non-retryable, return:

```go
return ChargeResult{}, cadence.NewCustomError("PaymentDeclined", apiResponse)
```

`NewCustomError` lives in the top-level `go.uber.org/cadence` package; the `workflow` package does not re-export it. See [`shared/error-reference.md`](../shared/error-reference.md) for the full taxonomy of workflow-observable errors.

## Heartbeats

Activities longer than a few seconds should heartbeat. Heartbeating proves the worker is alive, records resumable progress, and surfaces cancellation:

```go
for i, item := range batch {
    if err := process(item); err != nil {
        return err
    }
    activity.RecordHeartbeat(ctx, ActivityProgress{Index: i + 1})
    if ctx.Err() != nil {
        return ctx.Err()
    }
}
```

On a retry, recover the previous progress so you do not redo completed work:

```go
var progress ActivityProgress
info := activity.GetInfo(ctx)
if len(info.HeartbeatDetails) > 0 {
    _ = encoded.NewValue(info.HeartbeatDetails).Get(&progress)
}
```

When the workflow cancels (or the activity times out for missing heartbeats), `ctx.Done()` is closed. Return as soon as you can after observing the cancellation; Cadence will record the cancellation and either retry or surface the cancellation to the workflow.

## Idempotency

Activities run at-least-once. The same payload may execute repeatedly under several conditions: worker crash after the side effect but before reporting success, network blip during result reporting, or workflow-driven retry. Make external side effects idempotent by passing a deterministic dedup key:

1. The workflow generates a key (`workflow.SideEffect` if it needs a fresh value, or a hash of stable inputs).
2. The workflow passes the key to the activity as an input parameter.
3. The activity uses the key as the idempotency token in the external system (Stripe idempotency keys, INSERT … ON CONFLICT DO NOTHING, etc.).

`activity.GetInfo(ctx).WorkflowExecution.RunID + ActivityID` works as a fallback when the workflow author hasn't pre-supplied a key, but a workflow-supplied key is preferred because it survives `ContinueAsNew`.

## Local activities

Local activities (`workflow.ExecuteLocalActivity`) run inside the worker process without going through the matching service. They are appropriate when:

- The activity is short (sub-second).
- The activity is co-located with the worker (no extra hop).
- Strict at-most-once visibility is not required.

Trade-offs versus regular activities:

- No task list retry; you must configure `LocalActivityOptions.RetryPolicy` if you need retries.
- No heartbeats — local activities cannot survive a worker restart.
- A worker crash mid-execution rolls back the activity's history; on replay it may or may not be retried by the next worker.

Use them as a performance optimization, not as the default. Reach for them after profiling shows the matching round-trip is the bottleneck.

## Async completion

Some activities cannot complete synchronously — a human approval, a callback from an external system, a long batch job. Return `activity.ErrResultPending`:

```go
func RequestApproval(ctx context.Context, req Request) (string, error) {
    info := activity.GetInfo(ctx)
    if err := submitForApproval(req, info.TaskToken); err != nil {
        return "", err
    }
    return "", activity.ErrResultPending
}
```

`info.TaskToken` is the opaque handle the external system uses to complete the activity later, via a client call:

```go
cadenceClient.CompleteActivity(ctx, taskToken, approvalResult, nil)
```

Or, if the workflow ID and activity ID are easier to thread through, `cadenceClient.CompleteActivityByID(ctx, domain, workflowID, runID, activityID, result, err)`. Until the completion call lands, the activity is held by Cadence and heartbeat-time outs still apply.

## Errors

- Return a plain `error` for retryable failures.
- Return `cadence.NewCustomError("Reason", details...)` for application-specific failures the workflow can introspect.
- Return `cadence.NewCanceledError(...)` to surface cancellation cleanly (rare; usually `ctx.Err()` is enough).
- Use `NonRetriableErrorReasons` in the workflow's `RetryPolicy` to short-circuit retries for permanent failures.
- A panic inside an activity is recovered by the SDK and surfaces as an error; the activity then retries. Don't use panic as a control-flow tool.

## Sources of truth

- Activity helpers: `cadence-workflow/cadence-go-client` → `activity/activity.go`
- Async completion and `ErrResultPending`: `cadence-workflow/cadence-go-client` → `activity/activity.go`, `client/client.go`
- Errors and retry policy: `cadence-workflow/cadence-go-client` → `error.go`, `workflow/activity_options.go`
- Worked recipes: <https://github.com/cadence-workflow/cadence-samples/tree/master/cmd/samples/recipes>
- GoDoc: <https://pkg.go.dev/go.uber.org/cadence/activity>
