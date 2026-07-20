# Workers in the Cadence Python SDK

A Cadence Python application has three long-lived process objects: a `Client` that talks to the Cadence frontend, a `Registry` that holds workflow and activity definitions, and one or more `Worker` instances — one per task list — that the application owns. Unlike the Go and Java SDKs there is no separate worker-factory layer; the `Worker` itself spawns the decision and activity pollers internally.

For minimum end-to-end setup see [`getting-started.md`](getting-started.md), and for cluster topology background see [`shared/architecture.md`](../shared/architecture.md). For the workflow- and activity-author surfaces see [`workflows.md`](workflows.md) and [`activities.md`](activities.md).

## Building the Client

The client wraps an async gRPC channel to the Cadence frontend. The default development cluster listens on `localhost:7833`.

```python
from cadence.client import Client


async with Client(
    target="localhost:7833",
    domain="my-domain",
    identity=f"orders-service@{hostname}",
) as client:
    ...
```

`Client` is an async context manager — `__aenter__` calls `channel.channel_ready()` (so the client only exits the `async with` once gRPC is healthy), and `__aexit__` closes the channel. Build one `Client` per process and share it across every worker and every starter.

### `ClientOptions`

All fields are keyword arguments on `Client(...)`:

| Field | Default | Purpose |
| --- | --- | --- |
| `domain` | required | Cadence domain workflows live in. |
| `target` | required | `host:port` for the Cadence frontend gRPC endpoint. |
| `data_converter` | `DefaultDataConverter()` | Serializer for workflow and activity arguments. Must match between starters and workers. |
| `identity` | `f"{os.getpid()}@{socket.gethostname()}"` | Identifier the cluster records on every poll and every history event. |
| `service_name` | `"cadence-frontend"` | YARPC service name advertised on the wire. |
| `caller_name` | `"cadence-client"` | YARPC caller name advertised on the wire. |
| `channel_arguments` | `{}` | Extra gRPC channel arguments (keep-alive, max message size, etc.). |
| `credentials` | `None` | `grpc.ChannelCredentials` for TLS. |
| `compression` | `Compression.NoCompression` | gRPC compression algorithm. |
| `metrics_emitter` | `NoOpMetricsEmitter()` | Tally-like metrics sink; see [`observability.md`](observability.md). |
| `interceptors` | `[]` | List of `grpc.aio.ClientInterceptor` for cross-cutting middleware. |

The default identity (`pid@hostname`) is fine for local development. In a fleet, set it to something that includes the deployment ID and service name so `cadence workflow showid` output points at the exact binary that produced a problem decision.

## Building the Registry

A `Registry` is the in-memory map of workflow types and activity types this worker process can handle.

```python
from cadence.worker import Registry

registry = Registry()

# Decorator form (registers in place):
@registry.workflow(name="OrderWorkflow")
class OrderWorkflow:
    ...

@registry.activity(name="charge_card")
async def charge_card(input):
    ...

# Or compose pre-built registries:
combined = Registry.of(orders_registry, shipping_registry)
```

The registry detects duplicate registrations and raises `KeyError("Workflow 'X' is already registered")` or `KeyError("Activity 'Y' is already registered")` at registration time. For activity bundles defined as classes, `registry.register_activities(instance)` walks the instance and registers every `@activity.method` / `@activity.defn`.

## Building the Worker

```python
from cadence.worker import Worker


async def main() -> None:
    async with Client(target="localhost:7833", domain="my-domain") as client:
        async with Worker(
            client,
            "orders-tasklist",
            registry,
            max_concurrent_activity_execution_size=200,
            max_concurrent_decision_task_execution_size=50,
            activity_task_pollers=4,
            decision_task_pollers=4,
        ):
            await asyncio.Event().wait()
```

`Worker(client, task_list, registry, **options)` accepts the same `WorkerOptions` as keyword arguments. The worker is an async context manager: `__aenter__` calls `worker.run()` (spawning two internal asyncio tasks — one decision worker, one activity worker — plus their pollers), and `__aexit__` calls `worker.close()` to cancel and await those tasks.

### `WorkerOptions`

All fields are `total=False` keyword arguments:

| Field | Default | Purpose |
| --- | --- | --- |
| `max_concurrent_activity_execution_size` | 1000 | Activity tasks in flight on this worker. |
| `max_concurrent_decision_task_execution_size` | 1000 | Decision tasks in flight on this worker. |
| `activity_task_pollers` | 2 | Activity-task long-poll count. |
| `decision_task_pollers` | 2 | Decision-task long-poll count. |
| `task_list_activities_per_second` | 0.0 (no limit) | Whole-task-list activity rate limit enforced server-side. Useful for protecting downstream APIs. |
| `disable_workflow_worker` | `False` | Skip spawning the decision worker. |
| `disable_activity_worker` | `False` | Skip spawning the activity worker. |
| `identity` | `f"{client.identity}@{task_list}@{uuid4()}"` | Per-worker identity, recorded on every poll. The default appends a UUID so distinct `Worker` instances in the same process are distinguishable. |

Raising `*_pollers` increases the rate at which a single worker pulls work off the task list. Raising `max_concurrent_*_execution_size` lets it process more in parallel. The two knobs are independent — they bottleneck at different stages.

## Topology patterns

**Single-process worker.** One `Client`, one `Registry`, one `Worker`. The default for a service that owns a single workflow family.

**Separate workflow and activity workers.** Two `Worker` instances on the same `Client` and same task list, where one passes `disable_activity_worker=True` and the other passes `disable_workflow_worker=True`. Useful when activity work is CPU-heavy and would starve workflow decisions, or when activities and workflows need different scaling profiles.

```python
async with (
    Client(...) as client,
    Worker(client, "orders", registry, disable_activity_worker=True) as wf_worker,
    Worker(client, "orders", registry, disable_workflow_worker=True) as act_worker,
):
    await asyncio.Event().wait()
```

**Multi-task-list worker process.** Create one `Worker` per task list on the same `Client`:

```python
async with Client(...) as client:
    async with (
        Worker(client, "orders", orders_registry),
        Worker(client, "shipping", shipping_registry),
    ):
        await asyncio.Event().wait()
```

**Domain-per-tenant.** A domain typically gets its own `Client` because data converters, identity, and retention policies vary per tenant.

## Starting workflows from client code

The same `Client` you hand to a worker is also how you start workflows from outside:

```python
from datetime import timedelta

execution = await client.start_workflow(
    "OrderWorkflow",
    order_input,
    workflow_id=f"order-{order_id}",
    task_list="orders-tasklist",
    execution_start_to_close_timeout=timedelta(hours=1),
    task_start_to_close_timeout=timedelta(seconds=30),
    workflow_id_reuse_policy=workflow_pb2.WORKFLOW_ID_REUSE_POLICY_ALLOW_DUPLICATE_FAILED_ONLY,
)
print(f"started workflow {execution.workflow_id} run {execution.run_id}")
```

`start_workflow` returns a `WorkflowExecution` carrying `workflow_id` and `run_id`. Required keyword arguments: `task_list` and `execution_start_to_close_timeout`. Optional and useful: `workflow_id` (auto-generated if omitted), `task_start_to_close_timeout` (defaults to 10s), `retry_policy`, `cron_schedule`, `delay_start`, `jitter_start`, `first_run_at`, `workflow_id_reuse_policy`.

Other client entry points:

- `await client.signal_workflow(workflow_id, run_id, signal_name, *args)` — signal an existing execution.
- `await client.signal_with_start_workflow(workflow, signal_name, signal_args, *workflow_args, **start_options)` — atomic start-or-signal. Default `workflow_id_reuse_policy` here is `ALLOW_DUPLICATE` (matches the Go SDK).
- `await client.cancel_workflow(workflow_id, run_id)`.

## Lifecycle and graceful shutdown

Because everything is async-context-managed, the canonical shutdown shape is a signal handler that triggers the outer `async with` to exit:

```python
import asyncio
import signal


async def main() -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    async with Client(target="localhost:7833", domain="my-domain") as client:
        async with Worker(client, "orders-tasklist", registry):
            await stop.wait()


if __name__ == "__main__":
    asyncio.run(main())
```

When `stop` is set, `Worker.__aexit__` runs `worker.close()`, which cancels the internal asyncio tasks and `asyncio.gather`s their results. Any exception in those background tasks is logged through `cadence.worker._worker` rather than re-raised — check that logger if shutdown seems to swallow real failures.

## Common pitfalls

- **Re-registering under a new name across deploys.** The registered workflow or activity type lands in history. Renaming the class without pinning `name="..."` strands in-flight workflows. Pin the name and treat it as a wire contract.
- **One `Client` per worker.** Multiple `Worker` instances should share a `Client`; building a `Client` per worker duplicates the gRPC channel and connection pool with no upside.
- **`DataConverter` mismatch between starter and worker.** If you set a custom `data_converter` on the starter's `Client`, configure it identically on the worker's `Client`. Otherwise arguments deserialize as garbage.
- **Forgetting `await client.ready()` outside `async with`.** The `async with Client(...)` form handles this for you, but if you instantiate the client manually (e.g. for tests), call `await client.ready()` before any RPC.
- **Activity worker registered without the activity code.** A deploy that lost the activity registration stalls every activity invocation. Boot-time assertion that critical activity types are registered catches this in CI.

## Not yet in the Python SDK

These worker-layer capabilities exist in Go and Java but are not yet in `cadence-python-client`:

- **Sticky cache configuration.** No `sticky_cache_size` or `disable_sticky_execution` knobs. The SDK manages workflow caching internally with whatever defaults the runtime picks; tuning is not user-controllable today.
- **Worker factory pattern.** There is no `WorkerFactory` analog — you instantiate each `Worker` directly. For most applications this is fine; very high-fanout deployments lose the convenience of a single shared workflow-thread pool.
- **`suspend_polling` / `resume_polling`.** No backpressure-driven cooldown primitive. Use `disable_*_worker` at worker construction or scale horizontally.
- **Health probe.** No `worker.is_healthy()`-equivalent. Roll your own readiness probe (a small async call to `client.describe_domain` or `client.workflow_stub.GetSearchAttributes` works as a liveness check against the frontend).

## Sources of truth

- `Client` and `ClientOptions`: `cadence-workflow/cadence-python-client` → `cadence/client.py`.
- `Worker`: `cadence-workflow/cadence-python-client` → `cadence/worker/_worker.py`.
- `WorkerOptions` defaults: `cadence-workflow/cadence-python-client` → `cadence/worker/_types.py`.
- `Registry`: `cadence-workflow/cadence-python-client` → `cadence/worker/_registry.py`.
- Worked client + worker setup: `cadence-workflow/cadence-python-client` → `cadence/sample/client_example.py`.
