# Workflow determinism and history replay

Cadence's durability guarantee rests on a single mental model: **a workflow's behavior is reconstructed by replaying its event history through the same workflow function**. Everything else in this document follows from that.

## The replay contract

A workflow is deterministic when, **given the same event history as input, the workflow function emits the same sequence of commands**. Cadence does not require your code to be pure in the absolute sense — it only requires that the commands it produces depend exclusively on values present in (or recoverable from) history.

When a worker picks up a workflow execution that already has history, it does the following:

1. Loads the recorded events from the Cadence cluster.
2. Re-executes the workflow function from the top.
3. As the code reaches each operation that would create new history (start a timer, call an activity, send a signal, complete the workflow), the SDK compares the operation the code wants to issue with the next event in history.
4. If they match, the SDK substitutes the recorded result (or short-circuits, in the case of timers and activities that have completed) and continues.
5. If they do not match, the SDK raises a non-determinism error and the workflow stops making progress.

This re-execution is called **replay**. It happens any time a worker has no cached state for a workflow (process restart, sticky cache eviction, scheduler decision to evict).

## What history looks like

A workflow's history is an append-only log of events stored on the Cadence cluster. The event types you will see most often (as named in the [Cadence types package](https://github.com/cadence-workflow/cadence/blob/master/common/types/shared.go)) include:

- `WorkflowExecutionStarted` — the workflow's initial event, carrying its input.
- `DecisionTaskScheduled`, `DecisionTaskStarted`, `DecisionTaskCompleted` — the three-step lifecycle of a decision task, which is the unit of work a worker pulls to run workflow code. *(Cadence retains the historical name "decision task" in the protocol and history; some newer Go-client APIs use the term `WorkflowTask` for the same concept.)*
- `ActivityTaskScheduled`, `ActivityTaskStarted`, `ActivityTaskCompleted`, `ActivityTaskFailed`, `ActivityTaskTimedOut` — the activity lifecycle.
- `TimerStarted`, `TimerFired` — timers created with `workflow.NewTimer` or `workflow.Sleep`.
- `MarkerRecorded` — used internally by helpers like `workflow.SideEffect` and `workflow.GetVersion`.
- `ChildWorkflowExecutionStarted`, `ChildWorkflowExecutionCompleted` — child workflow lifecycle.
- `WorkflowExecutionSignaled`, `WorkflowExecutionCompleted`, `WorkflowExecutionFailed`, `WorkflowExecutionContinuedAsNew`, `WorkflowExecutionTerminated` — terminal and signal events.

Each event has a monotonically increasing `EventID`. The full history is visible in Cadence Web and via the CLI (`cadence --domain <d> workflow showid <wid>`).

## Sources of non-determinism

Any value that can differ between two runs of the same workflow function is a source of non-determinism. The common ones:

- **Wall-clock time.** `time.Now()` returns a different value every call. Use `workflow.Now(ctx)` instead.
- **Random numbers and UUIDs.** `rand.Intn`, `uuid.NewV4`, etc. produce different values each time. Wrap them in `workflow.SideEffect` so the result is captured in history (recorded as a `MarkerRecorded` event) and replayed.
- **Map iteration order (Go).** Ranging over a `map` produces a different order on each run. Sort keys explicitly, or move map iteration into an activity.
- **Goroutines, channels, mutexes, select on stdlib channels.** Standard concurrency primitives are not replay-aware. Use `workflow.Go`, `workflow.NewChannel`, and `workflow.NewSelector` instead. The Go SDK does not ship a workflow-aware mutex — serialize mutable state through a single coroutine, or use a channel as a token-passing lock.
- **External I/O.** HTTP calls, database queries, file reads, environment-variable lookups. Move these into activities, where retries and results are recorded.
- **System state.** `os.Hostname()`, `os.Getenv()`, process IDs — all may change between worker restarts. Pass values through workflow input or read them in an activity.
- **Floating-point math whose result depends on library versions.** Rare but real. Pin the SDK version of any code path you rely on, or move sensitive math into activities.
- **Mutable package-level state.** Globals modified by one workflow visible to another break replay assumptions in subtle ways. Treat workflow code as pure with respect to its inputs.

## Deterministic equivalents in the Cadence Go SDK

The Go SDK provides drop-in replacements for the most common needs. All functions take `workflow.Context` and produce results that are replay-safe.

| Need | Use |
| --- | --- |
| Current time | `workflow.Now(ctx)` |
| Sleep / delay | `workflow.Sleep(ctx, d)` |
| Timer with future | `workflow.NewTimer(ctx, d)` |
| Capture a one-off non-deterministic value | `workflow.SideEffect(ctx, func(ctx workflow.Context) interface{} { return rand.Intn(100) })` |
| Capture a value that may safely change across deploys | `workflow.MutableSideEffect(ctx, id, fn, equals)` |
| Spawn cooperative coroutine | `workflow.Go(ctx, fn)` |
| Channel between coroutines | `workflow.NewChannel(ctx)` |
| Logger that suppresses output during replay | `workflow.GetLogger(ctx)` |
| Branch workflow logic safely across deploys | `workflow.GetVersion(ctx, changeID, min, max)` |

If you need something else and there is no SDK-provided equivalent, the answer is almost always to move the operation into an activity.

## How Cadence surfaces non-determinism

When the SDK detects that the next command produced by your code does not match the next event in history, it returns an error whose message contains the substring `nondeterministic`. The worker's reaction is governed by its `NonDeterministicWorkflowPolicy`:

- `NonDeterministicWorkflowPolicyBlockWorkflow` *(default)* — the workflow execution is left in a stuck state. New decision tasks continue to be scheduled and retried, giving you a chance to fix the code and let the workflow resume on the next replay.
- `NonDeterministicWorkflowPolicyFailWorkflow` — the workflow fails with a `NonDeterministicWorkflowPolicyFailWorkflow` error. The workflow does not retry on its own; an external caller must start a new execution.

The policy is set on the worker via `worker.Options.NonDeterministicWorkflowPolicy`. The default is appropriate for most teams: a stuck workflow is preferable to a failed one because the underlying state is recoverable.

## Detecting non-determinism before deployment

Cadence ships a **Workflow Shadower** in the Go SDK (`worker.NewWorkflowShadower`). A shadower runs in a non-production worker, pulls real workflow executions from a configured domain, and replays them against your local workflow code. Any non-determinism encountered surfaces as an error before the new code reaches a production worker.

Recommended usage:

1. Add a shadow-mode build target alongside your normal worker.
2. Configure the shadower with a domain, a workflow type, and a query for recent executions.
3. Run the shadower in CI or as a pre-deploy gate after any workflow-code change.
4. Treat any non-determinism error from the shadower as a release blocker.

See [`../go/testing.md`](../go/testing.md) and [`../java/testing.md`](../java/testing.md) for the SDK-specific configuration and the recommended CI integration patterns. The companion file [`versioning.md`](versioning.md) covers the safe-evolution side: when to gate changes with `workflow.GetVersion` versus when to register a new workflow type.

## Recovery patterns

**Accidental non-determinism (you changed code that's already in flight).**

1. Revert the workflow code to the pre-change behavior.
2. Restart the affected workers.
3. The next replay matches history again and stuck workflows resume.

**Intentional code change for running workflows.**

Use `workflow.GetVersion(ctx, changeID, minSupported, maxSupported)` to introduce a branching point. Existing workflows replay through the old branch (because the `MarkerRecorded` event pins the version they were started with); new workflows take the new branch. Increment `maxSupported` for each subsequent revision.

**Workflows you do not need to keep.**

If a workflow is broken beyond recovery and its in-flight state does not matter, terminate it with `cadence --domain <d> workflow terminate -w <wid> --reason "<reason>"` and start a new execution under the corrected code.

## Sources of truth

- Event type definitions: `cadence-workflow/cadence` → `common/types/shared.go`
- Deterministic helpers: `cadence-workflow/cadence-go-client` → `workflow/deterministic_wrappers.go`, `workflow/workflow.go`
- Workflow Shadower: `cadence-workflow/cadence-go-client` → `worker/worker.go` (`NewWorkflowShadower`)
- Non-determinism policy: `cadence-workflow/cadence-go-client` → `internal/internal_worker.go`
