# Workflows in the Cadence Python SDK

> **Alpha note.** The Cadence Python SDK exposes a deliberately narrow workflow API at this stage. Several capabilities present in the Go and Java SDKs — child workflows, external-workflow signalling from inside a workflow, side effects, mutable side effects, deterministic randomness, `get_version`-style versioning, and a public replay flag — are **not yet implemented** in this client. Verify the version of `cadence-python-client` you depend on; this file documents the canonical repository state.

This file covers what is in the SDK today: defining a workflow class, the run method, signals, queries, activity invocation, timers, waiting on predicates, continue-as-new, and the determinism rules the workflow event loop enforces.

For language-agnostic concepts see [`shared/determinism.md`](../shared/determinism.md), [`shared/patterns.md`](../shared/patterns.md), and [`shared/error-reference.md`](../shared/error-reference.md). For getting started end-to-end see [`getting-started.md`](getting-started.md).

## Defining a workflow

A workflow is a **class** with exactly one method decorated `@workflow.run`. Cadence constructs a fresh instance per workflow execution, so the class's attributes are per-execution state.

```python
from cadence import workflow
from cadence.worker import Registry

registry = Registry()


@registry.workflow(name="OrderWorkflow")
class OrderWorkflow:
    def __init__(self) -> None:
        self._cancelled = False

    @workflow.run
    async def run(self, input: dict) -> dict:
        # ...
        return {"status": "ok"}
```

Three rules to remember:

1. **Class-based only.** Plain async functions are not supported by `@registry.workflow`.
2. **Exactly one `@workflow.run` method.** Adding a second raises `ValueError("Multiple @workflow.run methods found")` at registration time.
3. **The run method must be `async def`.** Sync `def` raises `ValueError("Workflow run method 'run' must be async")` at decoration time.

`@registry.workflow(name="…")` pins the registered workflow type. Without a `name`, the class name is used; if you ever rename the class the registered type drifts. Pin it explicitly for any workflow that has been deployed.

## Calling activities

The SDK supports two invocation styles. The **typed style** uses the activity definition directly — preferred when the workflow can import the activity module — and gives you static typing on arguments and return values. The **string-keyed style** uses `workflow.execute_activity(name, result_type, *args, **opts)` — preferred when the activity lives in a module the workflow shouldn't import, or when activities are registered dynamically.

### Typed style (preferred)

```python
from datetime import timedelta
from myapp.activities import charge_card  # the @activity.defn-decorated function


@registry.workflow(name="OrderWorkflow")
class OrderWorkflow:
    @workflow.run
    async def run(self, input: dict) -> dict:
        charge = await charge_card.with_options(
            start_to_close_timeout=timedelta(seconds=30),
            schedule_to_close_timeout=timedelta(minutes=5),
            heartbeat_timeout=timedelta(seconds=10),
            retry_policy={
                "initial_interval": timedelta(seconds=1),
                "backoff_coefficient": 2.0,
                "maximum_interval": timedelta(minutes=1),
                "maximum_attempts": 5,
                "non_retryable_error_reasons": ["PaymentDeclined"],
            },
        ).execute(input)
        return {"transaction_id": charge["transaction_id"]}
```

`activity_def.with_options(**opts)` returns a new `ActivityDefinition` carrying those options; `.execute(*args)` invokes it. The result type is inferred from the activity's type hints, so `mypy` and IDE tooling see the correct return type without you passing it explicitly.

For parallel fan-out the typed form composes well with `asyncio.TaskGroup`:

```python
async with asyncio.TaskGroup() as tg:
    a = tg.create_task(parallel_one.with_options(start_to_close_timeout=timedelta(seconds=10)).execute("1"))
    b = tg.create_task(parallel_two.with_options(start_to_close_timeout=timedelta(seconds=10)).execute("2"))
# a.result() and b.result() now hold the typed return values
```

### String-keyed style

```python
charge = await workflow.execute_activity(
    "charge_card",
    dict,
    input,
    start_to_close_timeout=timedelta(seconds=30),
)
```

The result type (`dict` above) is passed explicitly so the SDK can decode the payload. Use this form when the activity's registered name is the only identifier the workflow has — for instance, in a dispatcher workflow that routes by activity-name string, or when the workflow module shouldn't pull in activity dependencies.

### `ActivityOptions`

`workflow.execute_activity` accepts these keyword arguments (all `total=False`):

| Field | Type | Purpose |
| --- | --- | --- |
| `task_list` | `str` | Override the task list this activity runs on. Defaults to the workflow's task list. |
| `schedule_to_start_timeout` | `timedelta` | How long the task may wait in the matching service before a worker picks it up. |
| `start_to_close_timeout` | `timedelta` | Per-attempt deadline once a worker starts the activity. |
| `schedule_to_close_timeout` | `timedelta` | End-to-end deadline including queuing and all retries. |
| `heartbeat_timeout` | `timedelta` | Maximum time between heartbeats; the activity fails if it stops heartbeating. |
| `retry_policy` | `RetryPolicy` | See below. |

You'll almost always want `start_to_close_timeout` set; `schedule_to_close_timeout` bounds total time with retries.

### `RetryPolicy`

```python
class RetryPolicy(TypedDict, total=False):
    initial_interval: timedelta
    backoff_coefficient: float
    maximum_interval: timedelta
    maximum_attempts: int
    non_retryable_error_reasons: list[str]
    expiration_interval: timedelta
```

`non_retryable_error_reasons` is a list of **string reasons** that, when matched against the activity's failure reason, short-circuit retries. This is the reason-string convention shared with the Go SDK rather than a class-based filter — see [`shared/error-reference.md`](../shared/error-reference.md) for how reason strings are derived.

## Timers and waits

The replay-safe equivalents of `asyncio.sleep` and predicate-based waiting:

- `await workflow.sleep(timedelta(...))` — block workflow code for the given duration.
- `await workflow.wait_condition(predicate)` — block until `predicate()` returns `True`. The predicate is re-evaluated on every workflow state change (signal delivery, activity completion, timer firing). Returns immediately if already true.

Never use `asyncio.sleep`, `asyncio.wait_for(timeout=...)`, `asyncio.to_thread`, `time.sleep`, `datetime.now()`, or `time.time()` inside workflow code — they read wall-clock state and are not replay-safe. Pure asyncio primitives that don't introduce wall-clock dependencies (`asyncio.Event`, `asyncio.Lock`, `asyncio.Queue`) are safe on the workflow's deterministic event loop.

## Signals

A signal is a method on the workflow class decorated with `@workflow.signal(name="...")`. The `name` argument is **required** — passing nothing raises `ValueError("name is required")`. Both sync and async handlers are allowed, and both run on the workflow's deterministic event loop.

```python
@registry.workflow(name="GreetingWorkflow")
class GreetingWorkflow:
    def __init__(self) -> None:
        self._messages: list[str] = []
        self._exit = False

    @workflow.run
    async def run(self) -> list[str]:
        received: list[str] = []
        while True:
            await workflow.wait_condition(lambda: self._messages or self._exit)
            if not self._messages and self._exit:
                return received
            received.append(self._messages.pop(0))

    @workflow.signal(name="add_message")
    def add_message(self, message: str) -> None:
        self._messages.append(message)

    @workflow.signal(name="exit")
    def exit(self) -> None:
        self._exit = True
```

Constraints called out in the SDK's own docstring:

- Signal handlers must return `None`. Any returned value is discarded; the SDK validates this at registration time and raises `ValueError("Signal handler must return None")` for any return-typed handler.
- No native threads inside signal handlers; not replay-safe.
- No wall-clock primitives (`asyncio.sleep`, `asyncio.wait_for(timeout=…)`, `asyncio.to_thread`); not replay-safe.
- Don't rely on the GIL for thread-safety — free-threaded CPython builds can disable it.

Async signal handlers can `await workflow.execute_activity(...)` or `await workflow.sleep(...)`, but design carefully: the handler runs in response to a signal-arrived history event, so anything it does becomes part of the workflow's deterministic timeline. Prefer the standard pattern of "signal flips a flag; the main run method does the work".

Signal names are wire-level identifiers — pin them with `name="..."` and treat renames the same way you treat workflow-type renames.

## Queries

A query is a synchronous, read-only method on the workflow class decorated with `@workflow.query(name="...")`. The `name` argument is **required**. Query handlers must be sync functions, return a non-`None` value, and avoid mutating workflow state.

```python
@registry.workflow(name="GreetingWorkflow")
class GreetingWorkflow:
    def __init__(self) -> None:
        self._messages: list[str] = []
        self._exit = False

    @workflow.run
    async def run(self) -> None:
        await workflow.wait_condition(lambda: self._exit)

    @workflow.signal(name="exit")
    def exit(self) -> None:
        self._exit = True

    @workflow.query(name="message_count")
    def message_count(self) -> int:
        return len(self._messages)
```

External callers use `Client.query_workflow(...)` with the workflow ID, optional run ID, query name, and expected result type:

```python
count = await client.query_workflow(
    workflow_id,
    "",
    "message_count",
    result_type=int,
)
```

Queries run on the same deterministic workflow runtime as the workflow body and signal handlers. Keep them side-effect-free: no activities, timers, network calls, logging-heavy diagnostics, or state mutation.

## Continue-as-new

When a workflow's history grows too large, hand off to a fresh execution:

```python
@workflow.run
async def run(self, state: dict) -> None:
    while True:
        await workflow.wait_condition(lambda: self._next_chunk_ready)
        await workflow.execute_activity("process_chunk", None, state, start_to_close_timeout=timedelta(minutes=2))
        state = self._next_state
        self._next_chunk_ready = False

        if self._history_growing():
            workflow.continue_as_new(state)
```

`workflow.continue_as_new(*args, ...)` raises a `ContinueAsNewError` that the SDK catches at the workflow boundary and translates into a continue-as-new decision. It is annotated `NoReturn` — anything after it in the same function is dead code.

Optional keyword arguments:

- `workflow_type` — switch to a different workflow type for the next execution.
- `task_list` — switch task lists.
- `execution_start_to_close_timeout` — new execution's end-to-end deadline.
- `task_start_to_close_timeout` — new execution's per-decision deadline.

See [`shared/patterns.md`](../shared/patterns.md) for when to use continue-as-new versus child workflows.

## Workflow info

Inside workflow code, fetch identity and metadata through the active `WorkflowContext`:

```python
from cadence.workflow import WorkflowContext

info = WorkflowContext.get().info()
# info.workflow_type, info.workflow_domain,
# info.workflow_id, info.workflow_run_id,
# info.workflow_task_list, info.data_converter
```

`WorkflowContext.is_set()` returns `True` only when the call stack is currently executing workflow code; useful in shared helpers that may be reached from both workflow and non-workflow paths. Calling `WorkflowContext.get()` outside a workflow raises `RuntimeError("Workflow function used outside of workflow context")`.

## Determinism rules

The workflow event loop replays every event in history during recovery; the body of `run` and every signal handler **must** produce identical outputs to the recorded outputs. Concrete rules:

- Use `await workflow.sleep(...)` instead of `asyncio.sleep(...)`.
- Use `await workflow.execute_activity(...)` for any external IO. Never call HTTP libraries, database drivers, or `subprocess` directly from workflow code.
- Use `await workflow.wait_condition(predicate)` for conditional waiting. Never use polling loops with `asyncio.sleep` to wait for state changes.
- Never call `datetime.now()`, `time.time()`, `random.*`, `uuid.uuid4()`, or any other non-deterministic standard library function from workflow code. (The SDK does not yet expose `side_effect`-style helpers for these — for now, push the non-determinism into an activity.)
- Iteration order over `dict`, `set` literals, and any container constructed from non-deterministic inputs (e.g. environment variables, hostnames) is non-deterministic. Sort explicitly before iterating, or use ordered structures with deterministic insertion order.
- Inside signal handlers, do not block on real I/O or wall-clock primitives — see the signals section.

For the cross-SDK conceptual foundation, see [`shared/determinism.md`](../shared/determinism.md). The rules are identical; the API surface for staying inside them is what differs.

## Not yet in the Python SDK

For the avoidance of doubt, these Go/Java capabilities are not in `cadence-python-client` at the time of writing:

- **Child workflows.** No `workflow.execute_child_workflow(...)` in the public surface. Compose orchestrations by starting independent top-level workflows from activities (with the caveats from [`shared/patterns.md`](../shared/patterns.md)).
- **External workflow signalling from inside a workflow.** No `workflow.signal_external_workflow(...)`. Use an activity that holds a `Client` and calls `await client.signal_workflow(...)`.
- **`side_effect` / `mutable_side_effect`.** No replay-safe escape hatch for non-determinism. Move the read into an activity.
- **Versioning.** No `workflow.get_version(...)` change-marker. Plan code rollouts via [`shared/versioning.md`](../shared/versioning.md)'s parallel-deployment approach (run old workflows to completion on the old binary, route new workflows to a new workflow type).
- **`is_replaying()`.** No public flag, and the SDK does not suppress workflow-side logs on replay either — a log line inside a workflow emits on every replay. See [`observability.md`](observability.md) for the alpha gap and recommended mitigations.
- **Local activities.** No `Workflow.newLocalActivityStub`-equivalent. Use a normal activity for short operations; activity overhead is higher than in Go/Java but functionally equivalent.

When the user's question requires any of these capabilities, recommend either the Go or Java SDK for that workload, or staging the missing capability through an activity.

## Sources of truth

- Workflow decorators and helpers: `cadence-workflow/cadence-python-client` → `cadence/workflow.py`.
- Query decorator and client entry point: `cadence-workflow/cadence-python-client` → `cadence/workflow.py`, `cadence/query.py`, and `cadence/client.py` (`Client.query_workflow`).
- Signal decorator and constraints (return-type validation, replay rules): `cadence-workflow/cadence-python-client` → `cadence/signal.py` and the docstring of `cadence.workflow.signal`.
- `WorkflowContext` abstract interface: `cadence-workflow/cadence-python-client` → `cadence/workflow.py` (`class WorkflowContext`).
- `ContinueAsNewError`: `cadence-workflow/cadence-python-client` → `cadence/error.py`.
- Determinism rules in code form: the integration suite in `cadence-workflow/cadence-python-client` → `tests/integration_tests/nondeterminism/`.
