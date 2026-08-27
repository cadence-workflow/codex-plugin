# Testing Cadence Go workflows

Cadence ships a comprehensive testing toolkit in `go.uber.org/cadence/testsuite` plus replay and shadow-mode tools in `go.uber.org/cadence/worker`. Combined, they let you cover three distinct concerns:

1. **Unit tests** — exercise workflow logic against mocked activities under simulated time.
2. **Replay tests** — confirm that current workflow code can deterministically replay an event history recorded earlier.
3. **Shadow tests** — replay production workflows against new code as a pre-deploy gate.

Use all three.

## The test fixture

Embed `testsuite.WorkflowTestSuite` in your test struct (or use it as a field). It provides factory methods for the two test environments.

```go
import (
    "testing"
    "go.uber.org/cadence/testsuite"
    "github.com/stretchr/testify/suite"
)

type UnitTestSuite struct {
    suite.Suite
    testsuite.WorkflowTestSuite
}

func TestUnitTestSuite(t *testing.T) {
    suite.Run(t, new(UnitTestSuite))
}
```

## Testing a workflow end-to-end

`NewTestWorkflowEnvironment` runs a workflow in a single goroutine against virtual time. Register the workflow under test plus any activities it calls (or mock them), execute, then assert on the outcome.

```go
func (s *UnitTestSuite) TestHello() {
    env := s.NewTestWorkflowEnvironment()
    env.RegisterWorkflow(HelloWorkflow)
    env.RegisterActivity(HelloActivity)

    env.ExecuteWorkflow(HelloWorkflow, "Cadence")

    s.True(env.IsWorkflowCompleted())
    s.NoError(env.GetWorkflowError())

    var result string
    s.NoError(env.GetWorkflowResult(&result))
    s.Equal("Hello Cadence!", result)
}
```

`ExecuteWorkflow` blocks until the workflow terminates. If the workflow gets stuck (waiting on a signal that never arrives, sleeping past a deadlock detector), the call fails the test.

## Testing an activity in isolation

`NewTestActivityEnvironment` runs an activity function under the same harness without a surrounding workflow. Useful when the activity's logic is the part under test.

```go
func (s *UnitTestSuite) TestHelloActivity() {
    env := s.NewTestActivityEnvironment()
    env.RegisterActivity(HelloActivity)

    val, err := env.ExecuteActivity(HelloActivity, "Cadence")
    s.NoError(err)
    var result string
    s.NoError(val.Get(&result))
    s.Equal("Hello Cadence!", result)
}
```

## Mocking activities and child workflows

When you only want to test workflow orchestration, stub out the activities with `OnActivity`. The chain returns a `*MockCallWrapper` that exposes the testify-style `.Return(...)` plus Cadence-specific helpers like `.After(d time.Duration)` (advance virtual time before returning) and `.Times(n int)`.

```go
env.OnActivity(ChargeCard, mock.Anything, mock.Anything).
    Return(ChargeResult{TransactionID: "tx_123"}, nil)
```

`OnWorkflow` does the same for child workflows. For activities that should fail in some scenarios, return an error built with `cadence.NewCustomError("Reason", details)` so the test exercises the same error path production code would.

## Virtual time

`TestWorkflowEnvironment` runs workflow code against a simulated clock. `workflow.Sleep(ctx, 24*time.Hour)` returns instantly; timers fire at their scheduled virtual times in deterministic order. Two helpers control the clock from outside the workflow:

- `env.RegisterDelayedCallback(func() { ... }, d)` — runs the callback at virtual time `+d` from "now". Use it to send signals, complete async activities, or cancel the workflow at a specific simulated time.
- `env.SetOnTimerScheduledListener` / `env.SetOnTimerFiredListener` — observe timer activity.

A test that sends a signal mid-flight looks like:

```go
env.RegisterDelayedCallback(func() {
    env.SignalWorkflow("approval", true)
}, time.Hour)
env.ExecuteWorkflow(ApprovalWorkflow, request)
```

The workflow believes an hour has elapsed even though the test ran in milliseconds.

## Signals and queries

- `env.SignalWorkflow(signalName, input)` — send a signal to the workflow under test.
- `env.SignalWorkflowByID(workflowID, signalName, input) error` — same, addressed by workflow ID (useful when multiple test workflows run concurrently).
- `env.QueryWorkflow(queryType, args...) (encoded.Value, error)` — invoke a registered query handler synchronously.
- `env.CancelWorkflow()` — request cancellation through `ctx.Done()`.

## Async-completion activities

If a real activity returns `activity.ErrResultPending` and is completed later by an external system, simulate that in tests via `env.CompleteActivity(taskToken, result, err)`. Combine with `RegisterDelayedCallback` to deliver the completion at a chosen virtual time.

## Replay tests

A replay test feeds a previously recorded event history through a workflow function and fails if any non-determinism is detected. This is the safety net for refactoring workflow code.

Capture history from a real execution:

```bash
cadence --domain my-domain workflow showid <workflow-id> --output_filename history.json
```

Then run the replayer in a test:

```go
func TestReplay(t *testing.T) {
    replayer := worker.NewWorkflowReplayer()
    replayer.RegisterWorkflow(HelloWorkflow)
    f, err := os.Open("history.json")
    require.NoError(t, err)
    defer f.Close()
    err = replayer.ReplayWorkflowHistoryFromJSON(zap.NewNop(), f)
    require.NoError(t, err)
}
```

`ReplayWorkflowHistory` is the lower-level form that takes an already-decoded `*shared.History`. `ReplayWorkflowHistoryFromJSONFile` is deprecated in favor of `ReplayWorkflowHistoryFromJSON`.

Keep a small library of representative histories under `testdata/` and run the replayer against all of them in CI. Any non-determinism surfaces before code reaches production.

## Workflow Shadower

The Workflow Shadower is Cadence's pre-deploy detection tool: a worker that pulls real workflow executions from a domain and replays them against your local workflow code. Stand it up via `worker.NewWorkflowShadower` and run it in shadow mode.

```go
shadowOptions := worker.ShadowOptions{
    WorkflowTypes:  []string{"HelloWorkflow"},
    WorkflowStatus: []string{"Completed"},
    ExitCondition: worker.ShadowExitCondition{
        ShadowCount: 100,
    },
}
shadower, err := worker.NewWorkflowShadower(serviceClient, "my-domain", shadowOptions, worker.ReplayOptions{}, logger)
if err != nil {
    return err
}
shadower.RegisterWorkflow(HelloWorkflow)
if err := shadower.Run(); err != nil {
    return err
}
```

Or run a regular worker with `EnableShadowWorker: true` and `ShadowOptions` set on `worker.Options`, as the helloworld recipe demonstrates (`-m shadower`). Patterns:

- **CI gate**: run the shadower with `ShadowCount` of a few hundred against the workflow types you changed. Fail the build on any non-determinism error.
- **Continuous shadowing**: deploy a low-traffic shadower in a pre-prod environment with `ShadowMode: ShadowModeContinuous` plus an `ExitCondition` (time- or count-bounded) so the process is bounded.

The shadower is the same idea as a replay test but sourced from live history instead of canned `testdata/` files, so it catches drift between your test fixtures and real production traffic.

## CI integration

A workable layout:

1. Unit tests under `*_test.go` next to each workflow file, exercising orchestration with mocked activities. Run on every push.
2. Replay tests under `internal/replay/`, with checked-in `testdata/*.json` histories representing each notable workflow shape. Run on every push.
3. A shadow-mode job, scheduled or kicked off by deploy pipelines, pulling fresh production histories and running them through the candidate binary. Required to pass before promoting a release.

Treat every replay/shadow failure as a release blocker until the failing code path is either rolled back or guarded with `workflow.GetVersion`.

## Sources of truth

- Test environment: `cadence-workflow/cadence-go-client` → `testsuite/testsuite.go`, `internal/workflow_testsuite.go`
- Replayer: `cadence-workflow/cadence-go-client` → `worker/worker.go` (`NewWorkflowReplayer`, `ReplayWorkflowHistoryFromJSON`)
- Workflow Shadower: `cadence-workflow/cadence-go-client` → `worker/worker.go` (`NewWorkflowShadower`), `internal/workflow_shadower.go`
- Sample replay and shadow tests: `cmd/samples/recipes/helloworld/replay_test.go` and `shadow_test.go` in `cadence-workflow/cadence-samples`.
