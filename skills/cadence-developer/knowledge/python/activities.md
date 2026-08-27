# Activities in the Cadence Python SDK

> **Alpha note.** Several activity capabilities present in the Go and Java SDKs — async completion via `do_not_complete_on_return` / `ActivityCompletionClient`, local activities, and a public cancellation signal delivered through `heartbeat` — are **not yet implemented** in `cadence-python-client`. This file documents the surface as it exists today and flags those gaps explicitly.

For language-agnostic concepts see [`shared/patterns.md`](../shared/patterns.md), [`shared/pitfalls.md`](../shared/pitfalls.md), and [`shared/error-reference.md`](../shared/error-reference.md). For workflow-side invocation see [`workflows.md`](workflows.md).

## Defining activities

There are three idiomatic ways to declare an activity in the Python SDK. All three produce an `ActivityDefinition` that gets registered with a `Registry`.

### 1. Inline on the registry

```python
from cadence.worker import Registry

registry = Registry()


@registry.activity(name="charge_card")
async def charge_card(input: dict) -> dict:
    return {"transaction_id": "..."}
```

`@registry.activity(name="…")` both decorates the function and registers it. Use it for top-level activity functions whose lifetime matches the registry's.

### 2. Standalone decorator, manual registration

```python
from cadence import activity

@activity.defn(name="charge_card")
async def charge_card(input: dict) -> dict:
    return {"transaction_id": "..."}


# Later, in worker setup:
registry.register_activity(charge_card)
```

Useful when activity code lives in a separate module from worker wiring. `@activity.defn` returns an `ActivityDefinition` that `registry.register_activity(defn)` accepts directly.

### 3. Class-based activities

```python
from cadence import activity


class PaymentActivities:
    def __init__(self, stripe_client) -> None:
        self.stripe = stripe_client

    @activity.method(name="charge_card")
    async def charge_card(self, input: dict) -> dict:
        return await self.stripe.charge(input)

    @activity.method(name="refund")
    async def refund(self, charge_id: str) -> None:
        await self.stripe.refund(charge_id)


# In worker setup:
payments = PaymentActivities(stripe_client)
registry.register_activities(payments)
```

`@activity.method(name="…")` marks an instance method as an activity; `registry.register_activities(obj)` walks the instance, picks up every `@activity.method` and `@activity.defn`, and registers them all. This is the recommended pattern when activities share dependencies (database clients, third-party SDKs).

### Sync vs async activities

All three decorators accept either `def` or `async def`:

```python
@registry.activity(name="generate_report")
def generate_report(input: dict) -> dict:
    return _compute_report(input)   # CPU-bound, blocks the calling thread


@registry.activity(name="call_api")
async def call_api(url: str) -> dict:
    async with aiohttp.ClientSession() as s:
        async with s.get(url) as r:
            return await r.json()
```

- **Async activities** run on the worker's asyncio event loop. Use them for IO-bound work that you can express with `async/await`.
- **Sync activities** run on a thread-pool executor. Use them for CPU-bound work or for libraries that don't have an async API.

Sync activities don't block the worker's event loop, but they do consume thread-pool slots. Long-running sync activities will exhaust the executor; prefer async, or split the work into smaller activities.

Don't mix the two on the same instance and expect them to share state without locking — `asyncio` primitives (`asyncio.Lock`, `asyncio.Event`) only synchronize the event-loop side. Use `threading` primitives or, better, push the shared state into an external store.

## Workflow-side invocation

Activities can be called two ways from workflow code (see [`workflows.md`](workflows.md) for the workflow side):

**Typed style (preferred when the workflow can import the activity).** Call `.with_options(**opts).execute(*args)` directly on the activity definition:

```python
from myapp.activities import charge_card

result = await charge_card.with_options(
    start_to_close_timeout=timedelta(seconds=30),
    retry_policy={"maximum_attempts": 5, "non_retryable_error_reasons": ["PaymentDeclined"]},
).execute(input)
```

The return type is inferred from the activity's type hints, so `mypy` and IDE tooling check the call statically.

**String-keyed style.** Pass the registered name and an explicit result type:

```python
result = await workflow.execute_activity(
    "charge_card",
    dict,
    input,
    start_to_close_timeout=timedelta(seconds=30),
)
```

Use the string form when the workflow doesn't (or shouldn't) import the activity — for instance in a dispatcher workflow that routes by activity-name string, or when the workflow module needs to stay free of activity dependencies.

## Activity execution context

Inside an activity body, `cadence.activity` exposes the current task's context through module-level helpers:

```python
from cadence import activity

info: activity.ActivityInfo = activity.info()
# info.task_token, info.workflow_type, info.workflow_domain,
# info.workflow_id, info.workflow_run_id,
# info.activity_id, info.activity_type, info.task_list,
# info.heartbeat_timeout, info.scheduled_timestamp,
# info.started_timestamp, info.start_to_close_timeout, info.attempt

client = activity.client()       # the Cadence Client this worker is using
in_activity = activity.in_activity()  # True only when executing under an activity context
```

These are backed by a `ContextVar`, so they're safe to call from anywhere on the activity-execution thread (or async task).

## Heartbeats

Activities expected to take more than a few seconds should heartbeat. Heartbeats record liveness against the activity's `heartbeat_timeout` and carry resumable progress for retries:

```python
@registry.activity(name="process_batch")
def process_batch(items: list[dict]) -> list[dict]:
    start_index, = activity.heartbeat_details(int) or (0,)
    results: list[dict] = []

    for i, item in enumerate(items[start_index:], start=start_index):
        results.append(_process(item))
        activity.heartbeat(i + 1)

    return results
```

- `activity.heartbeat(*details)` sends a heartbeat with the given payload.
- `activity.heartbeat_details(int, str, ...)` returns the previous attempt's heartbeat details, decoded into the requested types. Returns an empty list when there were no previous heartbeats.

> **Alpha gap.** `heartbeat` does **not raise on cancellation** in the current Python SDK — the underlying RPC logs a warning and continues. Long-running activities cannot react to workflow cancellation via heartbeat as they can in Go and Java. Plan around this limitation: keep activity bodies bounded, prefer many short activities over one long one, and treat cancellation as best-effort until the SDK exposes it.

Pair heartbeats with a configured `heartbeat_timeout` on the workflow's `execute_activity(...)` call — without a heartbeat timeout, heartbeating is purely a way to checkpoint resumable state, not a liveness signal.

## Idempotency

Activities are retried by Cadence according to the configured `RetryPolicy`. Design every activity to be safe to run more than once with the same input. Use the activity context to build a deterministic dedup key:

```python
info = activity.info()
dedup_key = f"{info.workflow_id}/{info.workflow_run_id}/{info.activity_id}"
```

This triple is unique per logical activity invocation within a workflow: `workflow_id` is stable for the whole execution, `workflow_run_id` changes only with continue-as-new or reset, and `activity_id` is unique within a run. Use it as the idempotency key for downstream APIs (Stripe `Idempotency-Key`, database `INSERT ... ON CONFLICT`, etc.).

## Errors and retries

An activity that raises an exception:

1. Has the exception's class name (or a configured reason string from the SDK's error machinery) recorded as the failure **reason**.
2. Is consulted against the configured `RetryPolicy`:
   - If the reason matches any entry in `retry_policy["non_retryable_error_reasons"]`, the activity fails immediately and the workflow sees the error.
   - Otherwise it retries up to `maximum_attempts` (or until `expiration_interval` / `schedule_to_close_timeout` is hit).

```python
retry_policy = {
    "initial_interval": timedelta(seconds=1),
    "backoff_coefficient": 2.0,
    "maximum_attempts": 5,
    "non_retryable_error_reasons": ["PaymentDeclinedError", "InvalidInputError"],
}
```

The reason-string convention is shared with the Go SDK — see [`shared/error-reference.md`](../shared/error-reference.md) for how reasons are derived from typed errors and how they flow through retry policies.

Keep `non_retryable_error_reasons` to a small, stable list. Anything that's a true business outcome (declined payment, invalid input, resource not found) should be a distinct reason; anything that's transient (network blip, throttling, lock contention) should retry.

## Not yet in the Python SDK

These activity capabilities exist in Go and Java but are not yet in `cadence-python-client`:

- **Async completion.** No `activity.do_not_complete_on_return()` and no `ActivityCompletionClient`. An activity that needs to wait for an external event has to block (a thread or the event loop) for the duration. Workarounds: keep external-event-waiting outside Cadence (a separate service holds the wait; signals the workflow when ready), or model the wait as a polling loop of short activities.
- **Cancellation through `heartbeat`.** The SDK's heartbeat sender swallows errors with a warning log; workflow cancellation does not raise from `activity.heartbeat(...)`. Activities cannot reliably observe cancellation today.
- **Local activities.** No `Workflow.newLocalActivityStub` equivalent. Even tiny activities (input validation, format conversion) record full history events. Functionally fine; just more expensive than the Go/Java equivalent.
- **External completion outside the worker process.** The SDK does not expose `RespondActivityTaskCompletedByID` / `RespondActivityTaskFailedByID` style helpers for completing activities from another process via their `task_token`.

When the user's question requires any of these, recommend either the Go or Java SDK or design the system to stage the missing capability outside Cadence.

## Sources of truth

- Activity decorators (`@activity.defn`, `@activity.method`), `ActivityInfo`, and the context helpers (`activity.info`, `activity.client`, `activity.heartbeat`, `activity.heartbeat_details`): `cadence-workflow/cadence-python-client` → `cadence/activity.py`.
- Registry behaviour (`register_activity`, `register_activities`, `@registry.activity`): `cadence-workflow/cadence-python-client` → `cadence/worker/_registry.py`.
- Heartbeat implementation (error swallowing, payload decode): `cadence-workflow/cadence-python-client` → `cadence/_internal/activity/_heartbeat.py`.
- Activity executor (the worker code that calls `RespondActivityTaskCompleted` / `RespondActivityTaskFailed`): `cadence-workflow/cadence-python-client` → `cadence/_internal/activity/_activity_executor.py`.
