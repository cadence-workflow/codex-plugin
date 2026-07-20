# Versioning Cadence workflow code

A workflow may live for minutes, days, or months. Workflow code that was deployed when the workflow started is the code that defines its history forever — even if that code is replaced months later, every replay (and every reset) must produce the same commands. Versioning is how you change workflow code safely while old runs are still in flight.

## The fundamental constraint

Activity code can change freely: activities are not replayed, only retried, and they execute against the current code each time. Workflow code is different — every running workflow replays through the latest code on the worker that picks up its next decision task. Any change that produces a different command sequence than the recorded history breaks that workflow.

You have four strategies, in order of preference for typical changes.

## Strategy 1: Confirm the change is replay-safe

Many changes do not affect the command sequence and need no versioning:

- **Activity body changes.** Renaming variables, refactoring internals, fixing bugs in retryable activities — all fine, because the workflow's history records only that the activity was scheduled and what result it returned.
- **Adding a new workflow type.** New code paths in a different `RegisterWorkflowWithOptions` registration don't touch existing executions.
- **Adding a new activity used only by new workflows.** Same idea.
- **Adding monitoring inside workflow code.** Calls to `workflow.GetLogger` or `workflow.GetMetricsScope` do not emit commands and are replay-safe.
- **Changing return values of an activity** — provided the workflow can still parse the response. (Adding optional fields to a struct is fine; renaming a required field is not.)

When in doubt, run the Workflow Shadower against historical runs of the changed workflow type. If it passes, the change is replay-safe.

## Strategy 2: Use `GetVersion`

When the change does alter the command sequence — adding an activity call, reordering work, changing a timer duration, modifying conditional logic that gates activities — gate the new path with `workflow.GetVersion`.

```go
v := workflow.GetVersion(ctx, "addRiskCheck", workflow.DefaultVersion, 1)
if v == workflow.DefaultVersion {
    // old behavior, exactly as it was before the change
} else {
    // new behavior, only for workflows started after this code shipped
    if err := workflow.ExecuteActivity(ctx, riskCheck, input).Get(ctx, nil); err != nil {
        return err
    }
}
```

How it works:

1. On first execution, `GetVersion` is called and the worker records a `MarkerRecorded` event capturing the selected version.
2. On any subsequent replay, the marker is read from history and the same version is returned without re-evaluating. The old workflow always sees `DefaultVersion`; new workflows see `1`.
3. Each time you change the same code region again, increment the upper bound: `workflow.GetVersion(ctx, "addRiskCheck", workflow.DefaultVersion, 2)`, plus another branch.

### Naming the change ID

The first argument is a string identifier for the code region being versioned. Pick something descriptive (`"addRiskCheck"`, `"useV2PaymentAPI"`); the string is recorded in history and must remain stable for the life of the workflow. Renaming it after the fact looks like a brand-new versioning point and breaks replay.

### Retiring an old branch

You may eventually want to delete the old code path. Two safe sequences:

- **Run the change to extinction first.** Wait until no workflows from the era of the old code remain (use the visibility store to confirm). Then update `GetVersion` to require the new version: `workflow.GetVersion(ctx, "addRiskCheck", 1, 1)`. When that has run long enough that no executions remain on the pre-`GetVersion` history, you can remove the `GetVersion` call entirely.
- **Use the Workflow Shadower as the safety net.** Before deleting any branch, replay the relevant historical workflows against the candidate code. Zero failures means it is safe.

Never delete a `GetVersion` branch (or the `GetVersion` call itself) without one of these checks.

## Strategy 3: Register a new workflow type

When the change is too radical for `GetVersion` (new inputs, new return shape, entirely different orchestration), register the new workflow under a new name and route new starts to it:

```go
worker.RegisterWorkflowWithOptions(OrderFlowV2, workflow.RegisterOptions{Name: "OrderFlowV2"})
```

In-flight `OrderFlow` (V1) executions continue against the V1 code, which you keep deployed until they drain. New `StartWorkflow` calls target `OrderFlowV2`. The histories of V1 and V2 executions never intermingle.

This strategy is heavier than `GetVersion` (you maintain two workflow definitions) but is the only safe option when the changes cannot be expressed as a branch within one workflow function.

## Strategy 4: Terminate and restart

Sometimes the state of in-flight workflows is recoverable from an external source (a database, a queue) and the simplest path is to terminate them and start fresh under the new code. Apply only when restarting will produce the same business outcome.

```bash
cadence --do my-domain workflow terminate -w <wid> --reason "schema migration; restarting under new code"
```

## Catching deployment regressions: bad binary

If you discover that a deployed binary produces broken workflows, mark its checksum bad at the domain level so all executions that have touched it can be reset in bulk:

```bash
cadence --do my-domain domain update \
    --add_bad_binary <checksum> --reason "release 1.4.2 introduced non-determinism in OrderFlow"

cadence --do my-domain workflow reset -w <wid> -r <rid> \
    --reset_type BadBinary --reset_bad_binary_checksum <checksum> \
    --reason "post-incident rollback"

cadence --do my-domain workflow reset-batch \
    --input_file affected_workflows.csv \
    --reset_type BadBinary \
    --reset_bad_binary_checksum <checksum> \
    --reason "post-incident rollback"
```

The reset rewinds each workflow to the last decision task processed before the bad binary observed it. After a clean binary is deployed, replay produces the correct command sequence.

Remove the bad-binary marker with `--remove_bad_binary <checksum>` once the rollback is complete.

## Compatibility rules cheat sheet

| Change | Safe without `GetVersion`? |
| --- | --- |
| Refactor activity internals | yes |
| Add a new activity called from new workflows only | yes |
| Add a new optional field to an activity payload struct | yes (if both sides tolerate older versions) |
| Add `workflow.GetLogger`/`GetMetricsScope` calls | yes |
| Insert a new activity call between existing ones | **no** — use `GetVersion` |
| Reorder existing activity calls | **no** — use `GetVersion` |
| Change a `workflow.Sleep` duration | **no** — use `GetVersion` |
| Add an `if` branch that selects between two existing paths | **no** — use `GetVersion` |
| Change the registered workflow name | **no** — register a new type instead |
| Change a workflow function's input or output shape (incompatibly) | **no** — register a new type instead |

## Pre-deploy validation

Every workflow-code change should pass:

1. **Replay tests** against a checked-in library of representative histories. See [`../go/testing.md`](../go/testing.md) or [`../java/testing.md`](../java/testing.md).
2. **A Workflow Shadower run** against recent production executions of the changed workflow types.

Treat any failure as a release blocker — non-determinism that reaches production blocks workflows until you ship a fix or perform a reset.

## Sources of truth

- `workflow.GetVersion` API: `cadence-workflow/cadence-go-client` → `workflow/workflow.go`
- `GetVersion` marker handling: `cadence-workflow/cadence-go-client` → `internal/internal_event_handlers.go` (`versionMarkerName`)
- Bad binary flow: `cadence-workflow/cadence` → `tools/cli/workflow_commands.go`, `tools/cli/domain_utils.go`
- Versioning concept docs: <https://cadenceworkflow.io/docs/go-client/workflow-versioning/>
