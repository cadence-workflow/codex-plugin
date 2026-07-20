# Cadence error reference

Cadence has a small, deliberately structured error model. Application errors, cancellations, timeouts, panics, and termination each have their own type, and they all carry enough information for retry policies and recovery code to route on. This file is the canonical catalogue: every error type a workflow or client can observe, where it comes from, how to inspect it, and how to dispatch on it.

The concepts are language-agnostic. Type names below are from the Go SDK because that's the SDK this skill currently covers in depth; the Java and Python SDKs surface the same set under matching names.

## How errors flow

When an activity, child workflow, or client call fails, Cadence converts the underlying Go error into one of a fixed set of structured types before returning it to the workflow code:

| Source | Workflow code receives |
| --- | --- |
| Activity returns `cadence.NewCustomError(reason, details...)` | `*cadence.CustomError` with the same reason and details. |
| Activity returns any other non-nil error | `*workflow.GenericError` wrapping `err.Error()`. |
| Activity is canceled | `*cadence.CanceledError`. |
| Activity exceeds a configured timeout | `*workflow.TimeoutError` with the `TimeoutType` set. |
| Activity panics | `*workflow.PanicError` with the stack trace. |
| Workflow is terminated externally | `*workflow.TerminatedError`. |
| Workflow code returns `workflow.NewContinueAsNewError(...)` | Not an error to callers; Cadence chains a new execution. |
| Replay diverges from history | `*cadence.NonDeterministicError` surfaced to the worker (not to workflow code). |

Workflow code returning an error follows the same conversion rules from the perspective of its parent (if any). A child workflow cannot raise `PanicError` — workflow panics become decision-task timeouts and retry automatically. See [`shared/determinism.md`](determinism.md).

## Workflow-observable error types

### `cadence.CustomError`

Application-defined business errors. Built with `cadence.NewCustomError(reason string, details ...interface{})`. The `reason` is a short stable string the workflow can dispatch on. The `details` are serialized using the registered data converter and decoded on the workflow side with `Details(&v)`.

```go
// activity side
return ChargeResult{}, cadence.NewCustomError("PaymentDeclined", apiResponse)

// workflow side
var customErr *cadence.CustomError
if errors.As(err, &customErr) {
    switch customErr.Reason() {
    case "PaymentDeclined":
        var resp APIResponse
        _ = customErr.Details(&resp)
        // handle
    }
}
```

The reserved prefix `cadenceInternal:` is forbidden for application reasons — the SDK uses it for synthetic reasons it assigns to other error types (see "Retry policy and the `Reason` convention" below).

### `cadence.CanceledError`

Returned when an activity or child workflow was canceled. Built with `cadence.NewCanceledError(details...)`. From workflow code use `cadence.IsCanceledError(err)` to dispatch, or `errors.As(err, &canceledErr)` if you need the details.

```go
err := workflow.ExecuteActivity(ctx, expensive, input).Get(ctx, nil)
if cadence.IsCanceledError(err) {
    // run cleanup on a disconnected context so the cleanup itself isn't canceled
}
```

The matching context-level signal is `workflow.ErrCanceled`, returned by futures when their parent context is canceled before they complete.

### `workflow.TimeoutError`

Returned when an activity or child workflow blew a timeout. Inspect `err.TimeoutType()` to learn which one:

| `TimeoutType` value | Meaning |
| --- | --- |
| `shared.TimeoutTypeScheduleToStart` | The task waited too long for a worker to pick it up. |
| `shared.TimeoutTypeStartToClose` | The worker picked the task up but did not finish in time. |
| `shared.TimeoutTypeScheduleToClose` | End-to-end deadline including queuing and all retries. |
| `shared.TimeoutTypeHeartbeat` | An activity stopped heartbeating inside `HeartbeatTimeout`. |

The error carries the last-recorded heartbeat details for `Heartbeat` timeouts, recoverable with `err.Details(&v)`. See [`go/activities.md`](../go/activities.md) for timeout configuration.

### `workflow.PanicError`

Returned when an activity panicked. Contains `err.Error()` (the panic value's string form) and `err.StackTrace()` (a captured stack). Workflows do not emit `PanicError`; the SDK turns workflow panics into decision-task timeouts that retry automatically.

### `workflow.TerminatedError`

Returned by a parent workflow when a child it spawned was terminated externally (via `cadence workflow terminate` or `client.TerminateWorkflow`). No details — termination is a brute-force operation. Workflows in your own process do not return this; it is observed from the outside.

### `workflow.GenericError`

The fallback wrapper for any error an activity returns that isn't one of the structured types above. `err.Error()` round-trips through the wire as a string, so you lose typing across the activity boundary. Prefer `CustomError` when the workflow needs to dispatch on the failure mode.

### `workflow.ContinueAsNewError`

Not really an error — it is a control-flow signal. A workflow returning `workflow.NewContinueAsNewError(ctx, NextWorkflow, args...)` ends its own execution and chains a fresh one with the same workflow ID and a new run ID. See [`shared/patterns.md`](patterns.md) and [`shared/versioning.md`](versioning.md).

No `IsContinueAsNewError` helper ships in the SDK. Detect it with a type assertion when needed:

```go
var contErr *workflow.ContinueAsNewError
if errors.As(err, &contErr) { /* … */ }
```

### `cadence.NonDeterministicError`

Raised by the SDK when replay diverges from recorded history. The exposed fields (`Reason`, `WorkflowType`, `WorkflowID`, `RunID`, `TaskList`, `DomainName`, `HistoryEventText`, `DecisionText`) are intended for diagnostics — log them, page on them, and treat the underlying workflow as poisoned.

`Reason` currently takes one of `"missing replay decision"`, `"extra replay decision"`, or `"mismatch"`. Cadence may add more values in the future; do not branch on the exact strings.

What you do about it lives in [`shared/determinism.md`](determinism.md) and [`shared/troubleshooting.md`](troubleshooting.md): mostly, fix the code or apply a workflow reset.

### `workflow.UnknownExternalWorkflowExecutionError`

Returned when a workflow uses `workflow.SignalExternalWorkflow` or `workflow.RequestCancelExternalWorkflow` against a workflow ID or run ID the cluster cannot find. The execution may have completed, been archived, or never existed.

## Retry policy and the `Reason` convention

`RetryPolicy.NonRetriableErrorReasons` is matched against the `Reason()` of the returned error. Each error type contributes the following reason:

| Error type | Reason string |
| --- | --- |
| `*cadence.CustomError` | The reason you supplied to `NewCustomError`. |
| `*workflow.GenericError` | `cadenceInternal:Generic` |
| `*cadence.CanceledError` | `cadenceInternal:Canceled` |
| `*workflow.TimeoutError` | `cadenceInternal:Timeout` |
| `*workflow.PanicError` | `cadenceInternal:Panic` |

The reserved `cadenceInternal:*` reasons are addressable from a retry policy — for instance, listing `cadenceInternal:Panic` in `NonRetriableErrorReasons` short-circuits panic retries — but you cannot create custom errors with that prefix yourself. The constructor panics if you try.

A practical convention: declare a small set of reason constants in a shared package and reference them from both activity returns and retry policy lists.

```go
package errs

const (
    PaymentDeclined = "PaymentDeclined"
    StockExhausted  = "StockExhausted"
    InvalidRequest  = "InvalidRequest"
)
```

That keeps the wire-level reason string in one place where compatibility changes are visible at code-review time.

## Async activity completion: `ErrResultPending`

`activity.ErrResultPending` is not a failure mode — it is the sentinel an activity returns to signal "I will complete out-of-band via `Client.CompleteActivity`." It does not flow through the structured error types because the activity is intentionally pending, not failed.

```go
func ApproveExpense(ctx context.Context, req Request) (Approval, error) {
    activity.RecordActivityHeartbeat(ctx, "awaiting reviewer")
    return Approval{}, activity.ErrResultPending
}
```

See [`go/activities.md`](../go/activities.md) for the full async-completion pattern.

## Helper predicates

The top-level `cadence` package ships these convenience predicates. They are plain type assertions internally — use them when they read more clearly than the assertion.

| Helper | Returns true for |
| --- | --- |
| `cadence.IsCustomError(err)` | `*cadence.CustomError` |
| `cadence.IsCanceledError(err)` | `*cadence.CanceledError` |
| `cadence.IsTimeoutError(err)` | `*workflow.TimeoutError` |
| `cadence.IsPanicError(err)` | `*workflow.PanicError` |
| `cadence.IsTerminatedError(err)` | `*workflow.TerminatedError` |
| `cadence.IsGenericError(err)` | `*workflow.GenericError` |
| `cadence.IsWorkflowExecutionAlreadyStartedError(err)` | `*shared.WorkflowExecutionAlreadyStartedError` |

No predicate ships for `ContinueAsNewError` or `NonDeterministicError`; use `errors.As`.

`workflow.CustomError`, `workflow.CanceledError`, `workflow.NewCustomError`, `workflow.NewCanceledError`, and `workflow.IsCanceledError` do **not** exist — the corresponding identifiers live only in the `cadence` package. The `workflow` package re-exports `GenericError`, `TimeoutError`, `TerminatedError`, `PanicError`, and `ContinueAsNewError` (plus `workflow.ErrCanceled`).

## Client- and server-side errors

These come from the Thrift definitions in `cadence-go-client/.gen/go/shared` and surface on calls made by `client.Client` or by SDK internals talking to the frontend.

| Type | When it appears |
| --- | --- |
| `*shared.BadRequestError` | Malformed request, invalid argument, or an invariant the server enforces. |
| `*shared.EntityNotExistsError` | Referenced workflow ID, run ID, domain, or task list does not exist. |
| `*shared.WorkflowExecutionAlreadyStartedError` | `StartWorkflow` against an in-use workflow ID without an explicit `WorkflowIDReusePolicy` that permits re-use. |
| `*shared.WorkflowExecutionAlreadyCompletedError` | Signal, query, or cancellation targeting a workflow that has already closed. |
| `*shared.DomainAlreadyExistsError` | `domain register` against a name that already exists. |
| `*shared.DomainNotActiveError` | Operation routed to a passive cluster in an XDC setup; usually retry against the active cluster. |
| `*shared.CancellationAlreadyRequestedError` | A second `CancelWorkflow` call after one is already in flight. |
| `*shared.ServiceBusyError` | Backpressure from the frontend. Clients should back off and retry. |
| `*shared.LimitExceededError` | Server-side rate or size limit was hit. |
| `*shared.ClientVersionNotSupportedError` | Client SDK version is below the server's minimum supported version. |

Calls into the cluster typically wrap these in a YARPC error; use `errors.As` to extract the typed value.

```go
_, err := client.StartWorkflow(ctx, opts, OrderWorkflow, in)
var already *shared.WorkflowExecutionAlreadyStartedError
if errors.As(err, &already) {
    // workflow ID is taken; load the existing run and resume
}
```

## Inspection patterns

`errors.As` is the safest tool for nested wrapping; type switches still work for the SDK error types because they aren't wrapped further by the SDK itself, but `errors.As` future-proofs against changes elsewhere in your stack.

```go
var (
    customErr  *cadence.CustomError
    timeoutErr *workflow.TimeoutError
    canceled   *cadence.CanceledError
)
switch {
case errors.As(err, &customErr):
    // handle customErr.Reason()
case errors.As(err, &timeoutErr):
    if timeoutErr.TimeoutType() == shared.TimeoutTypeHeartbeat {
        // recover heartbeat details
    }
case errors.As(err, &canceled):
    // graceful shutdown path
default:
    // generic / panic / terminated — log and bubble up
}
```

Two anti-patterns to avoid:

- Comparing `err.Error()` strings. The text is not stable across SDK versions; the `Reason()` string is.
- Returning a `cadenceInternal:*` reason from `NewCustomError`. The constructor panics; pick an application-specific reason instead.

## Sources of truth

- Workflow-observable error types: `cadence-workflow/cadence-go-client` → `internal/error.go`
- `workflow` package re-exports: `cadence-workflow/cadence-go-client` → `workflow/error.go`
- `cadence` package predicates and `CustomError`/`CanceledError`/`NonDeterministicError`: `cadence-workflow/cadence-go-client` → `error.go`
- `TimeoutType` enum: `cadence-workflow/cadence-go-client` → `.gen/go/shared/shared.go` (`TimeoutTypeStartToClose`, `TimeoutTypeScheduleToStart`, `TimeoutTypeScheduleToClose`, `TimeoutTypeHeartbeat`)
- Server/client error types: `cadence-workflow/cadence-go-client` → `.gen/go/shared/shared.go`
- Async completion sentinel: `cadence-workflow/cadence-go-client` → `internal/error.go` (`ErrActivityResultPending`); re-exported as `activity.ErrResultPending`.
