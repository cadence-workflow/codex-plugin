# Cadence patterns

Durable execution unlocks orchestration shapes that are awkward to express against raw queues or cron. This file catalogues the patterns that come up most often, with the conceptual sketch for each and pointers to the language-specific details.

## Signal: external message into a running workflow

A signal is an asynchronous, fire-and-forget message addressed by workflow ID and signal name. Cadence buffers signals until the workflow consumes them.

**When to use.** Any external event that should change in-flight workflow state: approvals, configuration changes, user actions, downstream callbacks.

**Sketch.** The workflow registers a signal channel by name and reads it inside its main loop. External callers invoke the client's `SignalWorkflow` (or `SignalWithStart` if the workflow may not yet exist).

**Watch for.** Signals delivered while the workflow is not running are buffered and replayed in order; do not assume real-time ordering relative to other external events. Signals are processed inside workflow code, so signal handlers must remain deterministic — push side effects out to activities.

See [`../go/workflows.md`](../go/workflows.md) for the Go API (`workflow.GetSignalChannel(ctx, name)`, `Channel.Receive(ctx, &v)`, `client.SignalWorkflow`) or [`../java/workflows.md`](../java/workflows.md) for the Java equivalent (`@SignalMethod` on the workflow interface, paired with `Workflow.await`).

## Query: synchronous read of workflow state

A query is a request-response call that reads computed state without modifying the workflow. The Cadence server forwards the query to a worker, which evaluates the registered handler against the current workflow state and returns the result inline.

**When to use.** External tooling needs visibility into workflow progress that is more structured than the event history (a percent-complete number, the next pending step, a per-customer summary).

**Constraints.** Query handlers must be side-effect-free and deterministic. They cannot call activities, start child workflows, or block. They run on the same replay-aware scheduler as the workflow body.

See `workflow.SetQueryHandler` in [`../go/workflows.md`](../go/workflows.md), or `@QueryMethod` in [`../java/workflows.md`](../java/workflows.md).

## Child workflow: composition with its own lifecycle

A child workflow is a workflow execution started by another workflow. The parent gets two futures: one for the child's start (so the parent has its workflow ID and run ID) and one for its result.

**When to use child workflows.** When the child has properties that genuinely differ from the parent — its own retry policy, its own task list (so a different worker fleet executes it), its own history budget (the child's history doesn't count against the parent's 200 MB / 200K-event ceiling), or its own visibility for ad-hoc operator queries.

**When NOT to use child workflows.** As a substitute for activities. If the work is a single side-effecting operation, an activity is cheaper and easier to reason about. (Child workflows are also a recognized strategy for evolving workflow code without breaking in-flight runs — see [`versioning.md`](versioning.md).)

**Parent-close behaviour.** Configure `ParentClosePolicy` deliberately:

- `ParentClosePolicyTerminate` — the child is terminated when the parent closes.
- `ParentClosePolicyAbandon` — the child keeps running independently.
- `ParentClosePolicyRequestCancel` — the parent issues a cancel request to the child on close.

See `workflow.ExecuteChildWorkflow` and `workflow.ChildWorkflowOptions` in [`../go/workflows.md`](../go/workflows.md), or `Workflow.newChildWorkflowStub(Class, ChildWorkflowOptions)` in [`../java/workflows.md`](../java/workflows.md).

## Continue-as-new: bounded history for unbounded orchestrations

A long-running workflow (a per-customer subscription, a recurring schedule, a multi-month escrow) eventually approaches the history size and event count ceilings. `ContinueAsNew` resets the workflow by ending the current execution and starting a new one with the same workflow ID but a fresh run ID and empty history. State you need to carry forward is passed as the new execution's input.

**When to use.** Whenever a workflow loops or accumulates many events. Trigger continue-as-new well before the warning thresholds (50 MB / 50K events).

**Watch for.** Anything still pending — open child workflows, in-flight signals not yet consumed — does not carry over automatically. Drain or hand off explicitly before returning the continue-as-new error. Signals that arrive after the new execution starts hit the new run; signals to the old run ID are lost.

See `workflow.NewContinueAsNewError` in [`../go/workflows.md`](../go/workflows.md), or `Workflow.continueAsNew(...)` / `Workflow.newContinueAsNewStub` in [`../java/workflows.md`](../java/workflows.md).

## Saga: long-running transactions with compensations

When a workflow performs several side-effecting steps that must collectively succeed or be unwound, model it as a saga: maintain a stack of compensating actions, and on failure run them in reverse.

**Sketch.** Each forward activity has a paired "undo" activity. As the workflow successfully completes each step, it pushes the undo onto a list. On error (or cancellation), the workflow iterates the list in reverse, calling each compensator. Compensators should be idempotent — they may run after a partial earlier compensation attempt.

**Watch for.** The compensation phase itself can fail; design compensators to be safe to retry, and consider escalating to a human via a signal or async-completion activity rather than looping forever.

**Concrete shape (Go).**

```go
func TransferWorkflow(ctx workflow.Context, in TransferInput) (err error) {
    var compensations []func(workflow.Context)

    defer func() {
        if err == nil {
            return
        }
        // Run compensations in reverse on failure. Use a disconnected
        // context so cleanup still runs if ctx itself is being cancelled.
        cleanupCtx, cancel := workflow.NewDisconnectedContext(ctx)
        defer cancel()
        for i := len(compensations) - 1; i >= 0; i-- {
            compensations[i](cleanupCtx)
        }
    }()

    if err = workflow.ExecuteActivity(ctx, Debit, in.From, in.Amount).Get(ctx, nil); err != nil {
        return err
    }
    compensations = append(compensations, func(ctx workflow.Context) {
        _ = workflow.ExecuteActivity(ctx, Credit, in.From, in.Amount).Get(ctx, nil)
    })

    if err = workflow.ExecuteActivity(ctx, Credit, in.To, in.Amount).Get(ctx, nil); err != nil {
        return err
    }
    return nil
}
```

Each compensation is a closure that takes a workflow context (so the rollback can run against a disconnected context when the original is cancelled). The compensation list is built deterministically by the forward path, so it survives replay. The `defer` walks the slice in reverse on the way out.

**Concrete shape (Java).**

```java
public class TransferWorkflowImpl implements TransferWorkflow {
    private final AccountActivities accounts = Workflow.newActivityStub(
        AccountActivities.class,
        new ActivityOptions.Builder()
            .setStartToCloseTimeout(Duration.ofSeconds(30))
            .build());

    @Override
    public void transfer(TransferInput input) {
        List<Runnable> compensations = new ArrayList<>();
        try {
            accounts.debit(input.from(), input.amount());
            compensations.add(() -> accounts.credit(input.from(), input.amount()));

            accounts.credit(input.to(), input.amount());
        } catch (RuntimeException e) {
            Workflow.newDetachedCancellationScope(() -> {
                for (int i = compensations.size() - 1; i >= 0; i--) {
                    compensations.get(i).run();
                }
            }).run();
            throw e;
        }
    }
}
```

Java uses `Workflow.newDetachedCancellationScope(...)` for the same reason Go uses `workflow.NewDisconnectedContext`: compensations should still get a chance to run when the main workflow scope is cancelled. Keep the compensation list deterministic and only put activity calls or replay-safe workflow operations inside each `Runnable`.

**Python alpha caveat.**

The Python SDK can model the same activity-failure saga shape with a deterministic list of compensating activity names or callables, but it does not yet expose child workflows, `get_version`, async activity completion, cancellation-via-heartbeat, or a Go/Java-style detached cancellation scope. For Python workflows, use sagas for bounded forward-step failures, keep compensating activities short and idempotent, and prefer Go or Java when cancellation-safe rollback is a core requirement.

## Polling: workflow waits for an external condition

When a workflow needs to wait for some external state to change (a webhook fires, a downstream batch finishes), avoid wall-clock polling inside the workflow. Two clean shapes:

- **Activity polls; workflow sleeps between activity calls.** The activity performs a single check (HTTP GET, DB read) and returns. The workflow loops, calling the activity, sleeping with `workflow.Sleep`, and exiting when the activity reports success. The history grows linearly with poll attempts — set a reasonable cap or wrap the loop in `ContinueAsNew`.
- **Activity blocks; workflow waits.** The activity uses async completion (`activity.ErrResultPending`) and is completed from the external system when the condition is met. The activity's `HeartbeatTimeout` and `ScheduleToCloseTimeout` bound the wait. Cleaner for long waits because no events accumulate.

Prefer the second shape when the wait is long or infrequent.

## Fan-out / fan-in: parallel activities

Launch several activities concurrently and aggregate their results.

**Sketch.** Start each activity without calling `Get` first; collect the futures; resolve them via a selector or by iterating and calling `Get` in turn. The order in which you call `Get` does not affect concurrency — the activities run in parallel once they are scheduled.

**Watch for.** Each activity adds to the workflow's history. A wide fan-out (thousands of parallel activities) can blow the event count budget; either chunk it or push the work into a child workflow whose history is separate. If results are independent, `workflow.NewSelector` lets you handle them as they complete.

## Awaitable condition: gating logic on signal-updated state

A signal handler writes to a shared variable; the workflow body waits for that variable to satisfy a predicate before continuing.

```go
ch := workflow.GetSignalChannel(ctx, "vote")
var votes int
workflow.Go(ctx, func(ctx workflow.Context) {
    for {
        var v int
        ch.Receive(ctx, &v)
        votes += v
    }
})
_ = workflow.Await(ctx, func() bool { return votes >= 3 })
```

`workflow.Await` blocks the workflow's main coroutine until the predicate returns true. The signal-pump coroutine updates the variable that the predicate reads. Both run on Cadence's cooperative scheduler, so there is no data race risk.

## Workflow as state machine

A workflow can model a long-lived entity (a user session, a subscription, a manufacturing job) by:

1. Holding its state in local variables.
2. Receiving state-changing inputs via signals.
3. Exposing the current state via queries.
4. Looping forever until a terminal signal or condition fires, then returning.

Pair with `ContinueAsNew` to cap history growth. Pair with queries so operators can inspect state without resorting to the event log.

## Child task fanout via child workflows

For workloads where each "job" needs its own observable lifecycle (per-tenant batch run, per-document processing pipeline), start a child workflow per job from a parent dispatcher. The dispatcher can throttle concurrency with a counter and `workflow.Await`, and each child has its own retry policy, history, and operator-visible status independent of its siblings.

## Sources of truth

- Signal, query, child-workflow, continue-as-new APIs (Go): `cadence-workflow/cadence-go-client` → `workflow/workflow.go`, `workflow/error.go`
- Saga and fan-out worked examples: `cadence-workflow/cadence-samples` → `cmd/samples/recipes/`; `cadence-workflow/cadence-java-samples` → `src/main/java/com/uber/cadence/samples/hello/`
- Concept overview: <https://cadenceworkflow.io/docs/concepts>
