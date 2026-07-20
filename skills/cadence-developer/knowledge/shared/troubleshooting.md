# Troubleshooting Cadence workflows

When something is wrong, the event history is the single most useful tool. Almost every diagnostic in this file starts there. The CLI's `--domain` flag can be shortened to `--do` in every command shown below.

## Start here

You almost always need the workflow ID, optionally the run ID, and the domain. Given those, get the history:

```bash
cadence --do my-domain workflow describe -w <wid>            # current status, last events
cadence --do my-domain workflow describeid <wid>             # same, positional form
cadence --do my-domain workflow showid <wid>                 # full event history
cadence --do my-domain workflow showid <wid> -r <rid>        # specific run
cadence --do my-domain workflow showid <wid> --output_filename history.json
```

`workflow describe` tells you the current status (`RUNNING`, `COMPLETED`, `FAILED`, `TIMED_OUT`, `CANCELED`, `TERMINATED`, `CONTINUED_AS_NEW`), the last event, the assigned task list, and any pending activities. `workflow showid` dumps every event.

## Diagnose by symptom

### Workflow is `RUNNING` but not making progress

The history's last few events tell you what it is waiting for.

| Last event | What it means | Where to look next |
| --- | --- | --- |
| `ActivityTaskScheduled` (and no `ActivityTaskStarted`) | No worker is polling the activity's task list, or all workers are busy | Worker health, task list naming, worker concurrency limits |
| `ActivityTaskStarted` (and nothing after for a long time) | A worker picked up the activity but hasn't reported anything | Worker logs, heartbeat timeout, activity code stuck or blocked |
| `TimerStarted` | The workflow is sleeping; check the timer's duration in the event details | Wait for it to fire; if the duration is unreasonably long, that's a bug |
| `WorkflowExecutionSignaled` waited on but not received | The workflow expects a signal that hasn't arrived | Check the external caller; verify the signal name exactly matches |
| `DecisionTaskScheduled` (and no `Started`) | No worker is polling the workflow's task list | Worker health on the workflow side |

If the last event is much older than the workflow's age, something is stuck. If the last event was a moment ago and history is growing, the workflow is working as intended.

### Workflow is `FAILED`

`workflow describe` shows the failure reason and (for `*CustomError`) the reason string. Tail back through the history for the `ActivityTaskFailed` or `WorkflowExecutionFailed` event whose `details` contain the underlying error message.

Common failure shapes:

- **Activity exhausted retries.** A series of `ActivityTaskFailed` events under increasing attempt counts, ending with a `WorkflowExecutionFailed`. Inspect the activity's error and decide whether the retry policy needs widening or the failure is permanent.
- **Non-determinism.** The history shows the workflow running normally, then `WorkflowExecutionFailed` with a message containing `nondeterministic`. See the dedicated section below.
- **Workflow code returned an error.** A `WorkflowExecutionFailed` event with the application error reason and details. The workflow code itself decided to fail.

### Workflow is `TIMED_OUT`

Either `ExecutionStartToCloseTimeout` was reached (whole-workflow timeout) or no worker picked up a decision task in time (`DecisionTaskStartToCloseTimeout`). The history's `WorkflowExecutionTimedOut` event includes the timeout type.

### Activity stuck after `ActivityTaskStarted`

Three common causes:

1. The activity itself is blocked (a long external call, a deadlock).
2. The worker hosting the activity crashed without reporting.
3. The activity is not heartbeating and you are waiting for `HeartbeatTimeout` to surface the problem.

Worker logs are the next step. If the worker process is alive, attach a profiler or take a stack dump.

### Worker is healthy but no work is being picked up

Check the task list name. The worker registers against a specific task list (third arg to `worker.NewV2`); the workflow's `StartWorkflowOptions.TaskList` must match exactly. Misspellings are common and silent — Cadence will accept the workflow and schedule tasks on a list no worker is polling.

```bash
cadence --do my-domain tasklist describe --tl my-task-list
cadence --do my-domain admin tl list-tasks --tl my-task-list --tl_type Activity --max_tasks 10
```

The first command shows pollers attached to the task list. Zero pollers means nothing will pick the work up.

## Diagnosing non-determinism specifically

When a workflow fails with a `nondeterministic` error, you need to compare what the code wants to do *now* against what history says happened *the first time*.

1. Pull the failing workflow's history with `workflow showid --output_filename history.json`.
2. Run the current code against it with a `WorkflowReplayer` (see [`../go/testing.md`](../go/testing.md) or [`../java/testing.md`](../java/testing.md)). The replayer fails at the exact event that disagrees, and the error names the mismatch.
3. Inspect the diff between what the SDK expected and what the code produced. The most frequent causes:
   - A new activity call was added between two existing calls.
   - The order of two parallel branches changed.
   - A timer duration was made dependent on `time.Now()` instead of `workflow.Now`.
   - A new `if` branch was taken because of new code reading external state.
4. Either revert the code, gate the change with `workflow.GetVersion`, or terminate and restart the workflow if its state can be discarded.

## Recovery procedures

### Fix the code and let it heal

The default non-determinism policy is `BlockWorkflow`. Once you deploy code that matches history again, the next decision task replays cleanly and the workflow resumes. No manual intervention required.

### Reset to an earlier point

`workflow reset` rewinds the workflow to a specified decision-task event ID, discarding events after that point. Cadence retains the new run ID; downstream effects already committed are not undone.

```bash
cadence --do my-domain workflow reset -w <wid> -r <rid> \
    --reset_type LastDecisionCompleted --reason "rolling back bad deploy"

cadence --do my-domain workflow reset -w <wid> -r <rid> \
    --event_id <decision_finish_event_id> --reason "manual fix"

cadence --do my-domain workflow reset-batch \
    --input_file workflows.csv \
    --reset_type LastDecisionCompleted \
    --reason "release 1.2.3 rollback"
```

Common `--reset_type` values: `LastDecisionCompleted`, `FirstDecisionCompleted`, `LastContinuedAsNew`, `BadBinary`. Use `--reset_type BadBinary` after registering a bad binary checksum on the domain so all workflows that ran under that binary can be reset in bulk.

### Terminate and restart

When the workflow's state is unrecoverable but you need a fresh execution under the same workflow ID:

```bash
cadence --do my-domain workflow terminate -w <wid> --reason "schema changed beyond recovery"
```

Then start a new execution with `WorkflowIDReusePolicy` set appropriately (typically `AllowDuplicate`).

### Bail out via `ContinueAsNew`

If a workflow is stuck because its history grew too large, push a continue-as-new from the workflow itself (if you can still run decision tasks) so the next run starts fresh. If the workflow cannot make any progress at all, you must reset or terminate.

## Worker-side checks

- **Registration drift.** A worker that has rolled out new code but kept the old registered workflow type silently strands all in-flight workflows. Verify the `Name` argument passed to `RegisterWorkflowWithOptions` matches the type used by every workflow currently running on that task list.
- **Sticky cache mismatch.** A worker caches workflow state by run ID; if you frequently bounce workers, the cache eviction rate goes up and replay happens more often. This makes non-determinism bugs surface that would otherwise hide.
- **Polling configuration.** `worker.Options.MaxConcurrentDecisionTaskPollers` and `MaxConcurrentActivityTaskPollers` (Go), or the equivalent `WorkerOptions` fields in Java, cap how many tasks the worker is willing to handle in parallel. If utilization is at the cap, you have a worker-side bottleneck, not a server-side one. See [`go/workers.md`](../go/workers.md) or [`java/workers.md`](../java/workers.md) for the full concurrency-tuning reference.
- **Built-in worker metrics.** The SDK exports `cadence-decision-scheduled-to-start-latency`, `cadence-activity-scheduled-to-start-latency`, `cadence-sticky-cache-*`, and `cadence-non-deterministic-error`. See [`go/observability.md`](../go/observability.md), [`java/observability.md`](../java/observability.md), or [`python/observability.md`](../python/observability.md) for the full catalogue and recommended alerts.

## Cluster-side concerns

These are rare in healthy deployments but worth knowing:

- **Shard ownership churn.** History shards moving between hosts produces brief unavailability windows. Watch the history service's logs and the shard distributor for repeated re-elections.
- **Persistence degradation.** Cassandra slow nodes, MySQL replica lag, or a saturated visibility store affect all workflows in a domain. Check the persistence layer's own dashboards.
- **Domain configuration.** A misconfigured retention policy can age out workflow history sooner than expected. `cadence --do my-domain domain describe` shows the current policy.

## CLI cheat sheet

```bash
cadence --do <domain> workflow list                          # recent
cadence --do <domain> workflow listall                       # all (paginated)
cadence --do <domain> workflow list -q "WorkflowType='X'"    # advanced visibility query
cadence --do <domain> workflow describe -w <wid> [-r <rid>]
cadence --do <domain> workflow showid <wid> [-r <rid>] [--output_filename file.json]
cadence --do <domain> workflow stack -w <wid>                # query the workflow's coroutine stack
cadence --do <domain> workflow query -w <wid> --qt <queryType>
cadence --do <domain> workflow signal -w <wid> -n <name> -i '<json>'
cadence --do <domain> workflow cancel -w <wid>
cadence --do <domain> workflow terminate -w <wid> --reason "..."
cadence --do <domain> workflow reset -w <wid> -r <rid> --reset_type <type> --reason "..."
cadence --do <domain> workflow reset-batch --input_file <file> --reset_type <type> --reason "..."
cadence --do <domain> tasklist describe --tl <name>
cadence --do <domain> domain describe
cadence --do <domain> admin wf describe -w <wid>             # raw internal mutable-state view
```

## Sources of truth

- CLI command sources: `cadence-workflow/cadence` → `tools/cli/`
- Operator docs: <https://cadenceworkflow.io/docs/operation-guide/troubleshooting>
- Reset type semantics: `cadence-workflow/cadence` → `tools/cli/workflow_commands.go` (search for `resetType*` constants)
- Replayer for non-determinism diagnosis: [`../go/testing.md`](../go/testing.md), [`../java/testing.md`](../java/testing.md)
