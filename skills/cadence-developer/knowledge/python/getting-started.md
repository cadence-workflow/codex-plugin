# Getting started with the Cadence Python SDK

> **Maturity.** The Cadence Python SDK (`cadence-python-client`) is **Alpha** as of writing — its `pyproject.toml` declares `Development Status :: 3 - Alpha`, and the API surface is still evolving. Pin to a specific version, watch the changelog, and prefer the Go or Java SDKs for production workloads that need stability today. This skill documents the API as it exists in the canonical repository; verify against the version you depend on.

This file walks through the minimum end-to-end shape of a Cadence Python application: a workflow, an activity, a worker that hosts them, and a client that starts an execution. For deeper coverage of each surface see the topic files in this directory.

## Prerequisites

- Python 3.11–3.13. The SDK declares `requires-python = ">=3.11,<3.14"` and uses modern typing features (`Unpack`, `Self`, `Concatenate`) that pin the floor at 3.11.
- A local Cadence cluster on the default gRPC port `localhost:7833`. See the skill's [`Getting started`](../../SKILL.md#getting-started) for `cadence-server` and the `cadence` CLI, and [`shared/architecture.md`](../shared/architecture.md) for the cluster topology.
- The `cadence` CLI, used at least once to register a domain before running any worker.

## Installation

The SDK installs from PyPI:

```bash
pip install cadence-python-client
```

Because the SDK is alpha, you may want to install from source for the latest fixes:

```bash
pip install git+https://github.com/cadence-workflow/cadence-python-client.git
```

Verify the install:

```bash
python -c "import cadence; from cadence.client import Client; from cadence.worker import Worker, Registry; print('ok')"
```

## Register a domain

A domain is the unit of isolation Cadence uses for workflows. Register one before starting any worker:

```bash
cadence --do my-domain domain register \
  --description "Python SDK sandbox" \
  --retention 7
```

The `--retention 7` flag is the closed-workflow history retention in days; required at registration time. Confirm with `cadence --do my-domain domain describe`.

## Define a workflow and an activity

```python
from datetime import timedelta

from cadence import workflow, activity
from cadence.worker import Registry

registry = Registry()


@registry.activity(name="greet")
async def greet(name: str) -> str:
    return f"Hello, {name}!"


@registry.workflow(name="GreetingWorkflow")
class GreetingWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        return await workflow.execute_activity(
            "greet",
            str,
            name,
            start_to_close_timeout=timedelta(seconds=10),
        )
```

A few things worth knowing:

- The workflow is a **class** with exactly one `@workflow.run` method. The SDK constructs a fresh instance per workflow execution, so instance attributes are per-execution state.
- The run method must be **`async def`**. The SDK runs workflow code on a deterministic asyncio event loop — never use `asyncio.sleep`, `asyncio.to_thread`, or wall-clock primitives; use `workflow.sleep(timedelta)` and `workflow.wait_condition(predicate)` instead.
- Activity invocations are **string-keyed** through `workflow.execute_activity("name", result_type, *args, **opts)`. The `result_type` is passed so the SDK can decode the payload into the right Python type.
- Activities can be **sync `def` or `async def`**. Sync activities run on a thread pool managed by the worker; async activities run on the asyncio event loop. Both are registered the same way via `@registry.activity(name=...)`.

## Wire the worker

```python
import asyncio

from cadence.client import Client
from cadence.worker import Worker


async def main() -> None:
    async with Client(target="localhost:7833", domain="my-domain") as client:
        async with Worker(client, "greeting-tasklist", registry):
            await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
```

The `Client` and `Worker` are both async context managers — entering the `Worker` block calls `worker.run()`, which spawns background tasks for polling decisions and activities. Exiting the block cancels those tasks via `worker.close()`. The bare `asyncio.Event().wait()` blocks `main` until the process receives a signal (Ctrl-C in a terminal, SIGTERM in a container).

The worker spawns a decision-task poller and an activity-task poller by default; you can disable either via `disable_workflow_worker=True` or `disable_activity_worker=True` on the `Worker` constructor for split-deployment topologies.

## Start a workflow

From client code outside the worker process:

```python
import asyncio
from datetime import timedelta

from cadence.client import Client


async def main() -> None:
    async with Client(target="localhost:7833", domain="my-domain") as client:
        execution = await client.start_workflow(
            "GreetingWorkflow",
            "World",
            task_list="greeting-tasklist",
            execution_start_to_close_timeout=timedelta(minutes=5),
        )
        print(f"started workflow {execution.workflow_id} run {execution.run_id}")


if __name__ == "__main__":
    asyncio.run(main())
```

`start_workflow` returns immediately with a `WorkflowExecution` carrying `workflow_id` and `run_id`. Keep them — they are what you use to signal, cancel, query, or fetch the result later.

Other client entry points:

- `await client.signal_workflow(workflow_id, run_id, signal_name, *args)`
- `await client.query_workflow(workflow_id, run_id, query_type, *args, result_type=...)`
- `await client.signal_with_start_workflow(workflow_type, signal_name, signal_args, *workflow_args, **opts)` for the start-or-signal pattern.
- `await client.cancel_workflow(workflow_id, run_id)`

## Verify with the CLI

After starting an execution, watch it land in the cluster:

```bash
cadence --do my-domain workflow list -op
cadence --do my-domain workflow showid <workflowId>
```

The `showid` output is the canonical view of what the worker recorded — every poll, every decision, every activity attempt. Same artifact the SDK consumes during replay.

## Where to go next

- Workflow API surface, signals, timers, continue-as-new — [`workflows.md`](workflows.md).
- Activity registration, sync vs async, heartbeats — [`activities.md`](activities.md).
- Worker setup, concurrency tuning, graceful shutdown — [`workers.md`](workers.md).
- Testing strategies for the Python SDK — [`testing.md`](testing.md).
- Observability: logging, metrics, tracing — [`observability.md`](observability.md).

For language-agnostic reference, the [`shared/`](../shared/) area covers the determinism, versioning, retry, and pattern concepts that apply to every SDK.

## Sources of truth

- SDK source: [`cadence-workflow/cadence-python-client`](https://github.com/cadence-workflow/cadence-python-client) → `cadence/{workflow,activity,client}.py` and `cadence/worker/`.
- Worked example wiring: `cadence-workflow/cadence-python-client` → `cadence/sample/client_example.py`.
- Maturity declaration: `cadence-workflow/cadence-python-client` → `pyproject.toml` (`Development Status :: 3 - Alpha`).
