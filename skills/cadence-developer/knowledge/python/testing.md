# Testing the Cadence Python SDK

> **Alpha note.** The Python SDK does **not** ship a `TestWorkflowEnvironment` / `WorkflowReplayer` / `WorkflowShadower` analog at this stage. There is no in-memory test cluster, no virtual-time clock, and no offline replay verifier. Testing today relies on plain `pytest` + `pytest-asyncio` plus integration tests against a real Cadence cluster. This file documents the practical patterns that exist; the Go and Java SDKs are richer if your testing strategy requires hermetic replay tests.

For language-agnostic concepts see [`shared/determinism.md`](../shared/determinism.md) and [`shared/versioning.md`](../shared/versioning.md). For setup see [`getting-started.md`](getting-started.md); for the runtime surfaces see [`workflows.md`](workflows.md), [`activities.md`](activities.md), and [`workers.md`](workers.md).

## What the SDK provides

- `pytest-asyncio` compatibility — workflow and activity code is async, so tests are `async def` with `asyncio_mode = "auto"` in the pytest config.
- The standard `Client` and `Worker` classes work in tests the same way they work in production. There is no test-specific subclass.
- The SDK's own integration test suite (under `tests/integration_tests/`) is itself a reasonable template — it spins up Cadence via `pytest-docker` and runs workflows end-to-end against it.

## Activity-level unit tests

Activities are plain Python functions; test them as plain Python functions. No worker, no client, no Cadence cluster required.

```python
import pytest
from myapp.activities import compute_total


async def test_compute_total_sums_line_items():
    result = await compute_total({"items": [{"price": 10}, {"price": 25}]})
    assert result["total"] == 35


async def test_compute_total_handles_empty_items():
    result = await compute_total({"items": []})
    assert result["total"] == 0
```

If your activity needs `activity.info()`, `activity.heartbeat(...)`, or `activity.client()`, it isn't unit-testable without an `ActivityContext` in scope. Two practical options:

1. Pass the runtime pieces in as parameters and call those helpers only in a thin outer function.
2. Test the activity end-to-end with the integration pattern below.

Heartbeats are no-ops without an active context — `activity.heartbeat(...)` outside an activity raises `LookupError` from the `ContextVar`. Wrap heartbeat calls in `if activity.in_activity():` if you want the same code path to run in both contexts.

## Workflow integration tests against a real cluster

The recommended pattern is a `pytest-docker` fixture that spins up Cadence and exposes a helper for building per-test clients and workers. The SDK's own `tests/integration_tests/helper.py` is a reasonable template:

```python
import pytest
from contextlib import asynccontextmanager
from typing import Unpack

from cadence import Registry
from cadence.client import Client, ClientOptions
from cadence.worker import Worker, WorkerOptions

DOMAIN = "test-domain"


class CadenceHelper:
    def __init__(self, options: ClientOptions, test_name: str) -> None:
        self.options = options
        self.test_name = test_name

    @asynccontextmanager
    async def worker(self, registry: Registry, **kwargs: Unpack[WorkerOptions]):
        async with self.client() as client:
            async with Worker(client, self.test_name, registry, **kwargs) as w:
                yield w

    def client(self) -> Client:
        return Client(**self.options)


@pytest.fixture
async def helper(client_options, request):
    return CadenceHelper(client_options, request.node.name)
```

The trick is keying the **task list** to the test name. Each test gets its own task list, so workflow code from one test never lands in another test's worker — even when tests register the same workflow type, the polling task lists keep them isolated.

A test then looks like:

```python
from datetime import timedelta
from cadence import workflow, Registry

reg = Registry()


@reg.workflow(name="EchoWorkflow")
class EchoWorkflow:
    @workflow.run
    async def echo(self, message: str) -> str:
        return message


async def test_echo_workflow(helper):
    async with helper.worker(reg) as worker:
        execution = await worker.client.start_workflow(
            "EchoWorkflow",
            "hello world",
            task_list=worker.task_list,
            execution_start_to_close_timeout=timedelta(seconds=10),
        )
        # ... fetch result via the history-capture pattern below
```

Required infrastructure: `pytest-docker` (in the SDK's own `[project.optional-dependencies].dev`), a `docker-compose.yml` that brings up `cadence:latest` and its dependencies, and a session-scoped fixture that registers a test domain once.

## Capturing workflow history for assertions

The SDK does not return workflow results directly from `start_workflow`. To assert on a workflow's outcome, fetch its history and read the close-event attributes:

```python
from cadence.api.v1.history_pb2 import EventFilterType
from cadence.api.v1.service_workflow_pb2 import (
    GetWorkflowExecutionHistoryRequest,
    GetWorkflowExecutionHistoryResponse,
)


async def test_echo_workflow(helper):
    async with helper.worker(reg) as worker:
        execution = await worker.client.start_workflow(
            "EchoWorkflow",
            "hello world",
            task_list=worker.task_list,
            execution_start_to_close_timeout=timedelta(seconds=10),
        )

        response: GetWorkflowExecutionHistoryResponse = (
            await worker.client.workflow_stub.GetWorkflowExecutionHistory(
                GetWorkflowExecutionHistoryRequest(
                    domain=DOMAIN,
                    workflow_execution=execution,
                    wait_for_new_event=True,
                    history_event_filter_type=EventFilterType.EVENT_FILTER_TYPE_CLOSE_EVENT,
                    skip_archival=True,
                )
            )
        )

        close = response.history.events[-1]
        assert (
            close.workflow_execution_completed_event_attributes.result.data
            == b'"hello world"'
        )
```

`wait_for_new_event=True` blocks the call until a new event appears; combined with `EVENT_FILTER_TYPE_CLOSE_EVENT` it effectively waits for the workflow to terminate. The result payload is raw bytes — apply the same `DataConverter` your application uses (or decode JSON inline for the default) to compare against typed Python values.

## Mocking activities

Two common shapes:

**Replace the activity at registration time.** Define a fake function with the same name and signature; register it on a test-only `Registry`:

```python
reg = Registry()


@reg.activity(name="charge_card")
async def fake_charge_card(input):
    return {"transaction_id": "test-txn", "status": "approved"}


@reg.workflow(name="OrderWorkflow")
class OrderWorkflow:
    @workflow.run
    async def run(self, order):
        return await workflow.execute_activity(
            "charge_card", dict, order, start_to_close_timeout=timedelta(seconds=10)
        )
```

This works because activity invocation is name-keyed. The workflow doesn't know — or care — whether the registered `"charge_card"` is the real implementation or a fake.

**Replace the dependency, keep the activity.** When the activity is a thin wrapper over a third-party SDK (Stripe, S3, your database), inject a fake of the underlying client into the activity class:

```python
class PaymentActivitiesImpl:
    def __init__(self, stripe_client):
        self.stripe = stripe_client

    @activity.method(name="charge_card")
    async def charge_card(self, input):
        return await self.stripe.charge(input)


payments = PaymentActivitiesImpl(FakeStripeClient())
reg.register_activities(payments)
```

This is the preferred shape — your activity body is exercised, but external side effects route to a controllable fake.

## Testing query handlers

Query handlers are ordinary sync methods on the workflow class, but exercise them through the client in integration tests so the SDK validates the query name, payload decoding, and workflow replay path:

```python
status = await worker.client.query_workflow(
    execution.workflow_id,
    execution.run_id,
    "status",
    result_type=str,
)
assert status == "ready"
```

Keep query handlers side-effect-free in tests too. A passing query assertion should prove that the workflow state can be read synchronously, not that the query mutated state or kicked off more work.

## Determinism testing

There is no offline replayer in `cadence-python-client`. The closest analog is what the SDK's own `tests/integration_tests/nondeterminism/test_nondeterministic_workflows.py` does: start a workflow with one version of the code, capture its history, then make a non-deterministic change to the workflow code and re-run against the recorded history through the live cluster's replay machinery.

If you can spare a cluster, the practical workflow is:

1. Run the workflow with the current code; let it complete and capture history.
2. Modify the workflow code (the change you're worried about).
3. Restart the worker (so the new code is registered).
4. Re-run with the same task list, using `cadence workflow reset` to replay from the start.
5. Watch for `NonDeterministicError` events in history, or worker logs.

This is much heavier than the Go/Java offline replay tests; tests of this shape are best gated to staging or pre-release CI rather than per-commit.

For language-agnostic strategy on safe workflow code changes, see [`shared/versioning.md`](../shared/versioning.md). The Python SDK does not yet expose `get_version`-style change markers, so the safer rollout shape is **register a new workflow type for the new code** and let old workflows complete under the old worker.

## Not yet in the Python SDK

These testing capabilities exist in Go and Java but are not yet in `cadence-python-client`:

- **In-memory test cluster.** No `TestWorkflowEnvironment` — every integration test needs a real Cadence server. Tests are slower (seconds, not milliseconds) and cannot be run in a sandbox without docker.
- **Virtual time / time skipping.** No `testEnv.sleep(duration)` analog. A workflow that includes a one-hour `workflow.sleep` waits a real hour in a test.
- **Workflow replayer.** No offline `WorkflowReplayer` for asserting that current code can replay a captured history. Determinism checks happen via the live cluster only.
- **Workflow shadower.** No `WorkflowShadower` for continuous replay against production traffic.
- **Built-in activity mocks.** The SDK does not provide a Mockito-style harness; the patterns above are conventions, not framework features.

When the user's testing strategy needs hermetic replay tests, virtual time, or a continuous shadow against production, recommend the Go or Java SDK or budget for the operational cost of a real-cluster integration suite.

## Sources of truth

- `pytest`/`pytest-asyncio` configuration: `cadence-workflow/cadence-python-client` → `pyproject.toml` (`[tool.pytest.ini_options]`, `asyncio_mode = "auto"`).
- Integration-test helper template: `cadence-workflow/cadence-python-client` → `tests/integration_tests/helper.py` (`CadenceHelper`).
- Session-scoped docker + domain fixtures: `cadence-workflow/cadence-python-client` → `tests/integration_tests/conftest.py`.
- Worked example of history-capture assertions: `cadence-workflow/cadence-python-client` → `tests/integration_tests/workflow/test_workflows.py`.
- Query client entry point: `cadence-workflow/cadence-python-client` → `cadence/client.py` (`Client.query_workflow`).
- Determinism integration suite: `cadence-workflow/cadence-python-client` → `tests/integration_tests/nondeterminism/`.
