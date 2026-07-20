# Workers in the Cadence Java SDK

A Cadence Java application has three long-lived process objects: a `WorkflowClient` that talks to the Cadence frontend, a `WorkerFactory` that owns the polling and execution threads, and one or more `Worker` instances — one per task list — that the factory creates. This file covers wiring those three, the option surface on each, the lifecycle, and the topology patterns you'll reach for in production.

## Building the WorkflowClient

The client wraps a gRPC connection to the Cadence frontend. The canonical wiring uses `IGrpcServiceStubs` (targeting the frontend's gRPC port, `7833` on the default development server) wrapped with `Thrift2ProtoAdapter` so the SDK's Thrift-shaped service interface keeps working over the gRPC wire.

```java
import com.uber.cadence.client.WorkflowClient;
import com.uber.cadence.client.WorkflowClientOptions;
import com.uber.cadence.internal.compatibility.Thrift2ProtoAdapter;
import com.uber.cadence.internal.compatibility.proto.serviceclient.IGrpcServiceStubs;

WorkflowClient client = WorkflowClient.newInstance(
    new Thrift2ProtoAdapter(IGrpcServiceStubs.newInstance()),
    WorkflowClientOptions.newBuilder()
        .setDomain("my-domain")
        .setIdentity("orders-service@" + InetAddress.getLocalHost().getHostName())
        .setMetricsScope(metricsScope)
        .build()
);
```

Build one `WorkflowClient` per process and share it across every worker and every starter. It is thread-safe and pools connections internally.

### `WorkflowClientOptions`

| Field | Purpose |
| --- | --- |
| `setDomain(String)` | Required. Cadence domain workflows live in. |
| `setIdentity(String)` | Identifier the cluster records for this process (deployment, canary cohort, host). |
| `setDataConverter(DataConverter)` | Custom serializer for workflow and activity arguments. Must match between starters and workers. |
| `setMetricsScope(Scope)` | Tally scope; the SDK populates the canonical `cadence-*` metric families on it. |
| `setContextPropagators(List<ContextPropagator>)` | Propagate request-scoped values (tenant ID, trace baggage) into workflows and activities. |
| `setInterceptors(WorkflowClientInterceptor...)` | Middleware around `start`, `signal`, and query calls. |
| `setQueryRejectCondition(QueryRejectCondition)` | Reject queries against not-open or not-completed workflows. |

## Creating the WorkerFactory

The factory owns the polling threads, the sticky cache, and the workflow-execution thread pool. Build one per process from the `WorkflowClient`:

```java
import com.uber.cadence.worker.WorkerFactory;
import com.uber.cadence.worker.WorkerFactoryOptions;

WorkerFactory factory = WorkerFactory.newInstance(
    client,
    WorkerFactoryOptions.newBuilder()
        .setStickyCacheSize(10000)
        .setMaxWorkflowThreadCount(600)
        .build()
);
```

### `WorkerFactoryOptions`

These apply across every worker the factory creates.

| Field | Default | Purpose |
| --- | --- | --- |
| `setStickyCacheSize(int)` | 600 | Maximum sticky-cached workflow executions across all workers in this factory. Raise it when workers hold a large concurrent working set. |
| `setDisableStickyExecution(boolean)` | false | When true, every decision task replays from the start. Useful for debugging non-determinism. |
| `setMaxWorkflowThreadCount(int)` | 600 | Upper bound on workflow-execution threads. Workflow code is logically single-threaded per execution but uses real threads under the hood. |
| `setEnableLoggingInReplay(boolean)` | false | Override the SDK's default replay-time log suppression. Diagnostic use only. |
| `setExecutorWrapper(ExecutorWrapper)` | none | Wraps the SDK's internal executors. Advanced; use sparingly. |

## Adding Workers

A `Worker` instance represents this process polling a specific task list. Create one per task list you want this binary to host:

```java
import com.uber.cadence.worker.Worker;
import com.uber.cadence.worker.WorkerOptions;
import java.time.Duration;

Worker orders = factory.newWorker(
    "orders-tasklist",
    new WorkerOptions.Builder()
        .setMaxConcurrentWorkflowExecutionSize(50)
        .setMaxConcurrentActivityExecutionSize(200)
        .setStickyTaskListScheduleToStartTimeout(Duration.ofSeconds(5))
        .build()
);

orders.registerWorkflowImplementationTypes(OrderWorkflowImpl.class);
orders.registerActivitiesImplementations(new OrderActivitiesImpl(dependencies));
```

`factory.newWorker(taskList)` (with no options) is allowed when defaults are acceptable.

### Registration

- `registerWorkflowImplementationTypes(Class<?>... classes)` takes the **class**. The SDK constructs a fresh instance per workflow execution, so impl fields hold per-execution state without you having to think about it. Re-registering the same workflow type throws — wrap a second registration in a try/catch only in tests.
- `registerWorkflowImplementationTypes(WorkflowImplementationOptions, Class<?>... classes)` takes a per-type `WorkflowImplementationOptions` (currently exposes a `failWorkflowExceptionTypes` filter that turns matched exceptions into terminal failures instead of decision-task retries).
- `registerActivitiesImplementations(Object... impls)` takes **instances**. The worker uses one instance for every invocation — constructor-inject dependencies, keep methods thread-safe.

Both methods must be called before `factory.start()`.

### `WorkerOptions`

Per-worker concurrency and rate limits:

| Field | Default | Purpose |
| --- | --- | --- |
| `setMaxConcurrentWorkflowExecutionSize(int)` | 50 | Decision tasks in flight on this worker. |
| `setMaxConcurrentActivityExecutionSize(int)` | 100 | Activity tasks in flight on this worker. |
| `setMaxConcurrentLocalActivityExecutionSize(int)` | 100 | Local activities in flight on this worker. |
| `setWorkerActivitiesPerSecond(double)` | 0 (unlimited) | Per-worker activity rate limit. |
| `setTaskListActivitiesPerSecond(double)` | 0 (unlimited) | Whole-task-list activity rate limit, enforced server-side. Useful for protecting downstream APIs. |
| `setWorkflowPollerOptions(PollerOptions)` | defaults | Long-poll concurrency, identity, and back-off for decision-task pollers. |
| `setActivityPollerOptions(PollerOptions)` | defaults | Same for activity-task pollers. |
| `setStickyTaskListScheduleToStartTimeout(Duration)` | 5s | How long the cluster waits for the sticky worker before falling back to any worker on the task list. |
| `setTracer(Tracer)` | NoopTracer | OpenTracing tracer for spans across workflow and activity boundaries. |
| `setInterceptorFactory(Function<WorkflowInterceptor, WorkflowInterceptor>)` | none | Per-replay middleware around workflow function execution. |

These defaults are Java SDK defaults from `WorkerOptions`; they intentionally differ from the Go SDK's larger execution-slot defaults.

Raising poller counts (via `PollerOptions`) lets a single worker pull more work off the task list per second; raising execution sizes lets it run more in parallel. Watch the SDK's `cadence-decision-scheduled-to-start-latency` metric — if it grows, the bottleneck is poller count or worker count, not execution slots.

## Lifecycle

### Start

```java
factory.start();
```

Returns immediately. Workers run on background threads. Always call `factory.start()` after every `register*` call.

### Suspend and resume

`factory.suspendPolling()` halts polling without tearing the worker down; in-flight tasks still complete. `factory.resumePolling()` re-enables it. Useful for backpressure-driven cooldowns.

### Graceful shutdown

Wire a JVM shutdown hook so container shutdowns drain cleanly:

```java
Runtime.getRuntime().addShutdownHook(new Thread(() -> {
    factory.shutdown();
    factory.awaitTermination(30, TimeUnit.SECONDS);
}));
```

What happens during `shutdown()`:

1. Pollers stop accepting new tasks.
2. In-flight workflow decisions and activities continue.
3. Any subsequent call to `Activity.heartbeat(...)` from a still-running activity throws `ActivityWorkerShutdownException`. Catch it, do cleanup, and rethrow.
4. `awaitTermination(timeout, unit)` blocks until everything finishes or the timeout fires.

Tune the timeout to your orchestrator's grace period (Kubernetes' default `terminationGracePeriodSeconds` is 30; pick a value a few seconds under that). For forceful exit, `factory.shutdownNow()` interrupts running threads via `Thread.interrupt()`; activities that don't honour interruption may never terminate.

### Health probe

```java
boolean healthy = factory.isHealthy().get(2, TimeUnit.SECONDS);
```

Returns a `CompletableFuture<Boolean>` that resolves true only if every worker in the factory has a valid connection. Useful for Kubernetes readiness probes.

## Topology patterns

**Single-process worker.** One factory, one worker, one task list. The default for a service that owns a single workflow family.

**Separate workflow and activity workers.** Two factory instances (or two worker instances on the same factory) targeting the same task list, where only one registers workflow types and the other only registers activity implementations. Useful when activity work is CPU-heavy and would starve workflow decisions, or when activities and workflows need different scaling profiles. Since registration is the only thing that controls what a worker handles, omit the unused registration calls.

**Multi-task-list factory.** A single factory can create any number of workers, each registered against a different task list. Reuse the same `WorkflowClient` across them. Standard pattern for a service owning several workflow families with different SLOs.

**Domain-per-tenant.** A domain typically gets its own factory because workflow code, registered names, and retention policies vary per tenant.

## Starting workflows from client code

The same `WorkflowClient` you handed to the factory is also how you start executions from outside the worker:

```java
WorkflowOptions opts = new WorkflowOptions.Builder()
    .setWorkflowId("order-" + orderId)
    .setTaskList("orders-tasklist")
    .setExecutionStartToCloseTimeout(Duration.ofHours(1))
    .setWorkflowIdReusePolicy(WorkflowIdReusePolicy.AllowDuplicateFailedOnly)
    .build();

OrderWorkflow workflow = client.newWorkflowStub(OrderWorkflow.class, opts);

// Synchronous start — blocks until the workflow completes:
OrderResult result = workflow.run(input);

// Async start — returns immediately with a handle:
WorkflowExecution execution = WorkflowClient.start(workflow::run, input);
```

`WorkflowClient.start(workflow::method, args...)` is the canonical fire-and-forget call. The returned `WorkflowExecution` has the `workflowId` and `runId` you'll want to keep for signals, queries, or later result retrieval via `client.newUntypedWorkflowStub(workflowId)`.

## Common pitfalls

- **Re-registering under a new name across deploys.** The registered workflow or activity type lands in history. Renaming strands in-flight workflows. Pin `name` on `@WorkflowMethod` / `@ActivityMethod` and treat it as a wire contract.
- **One factory per worker.** Spinning up a `WorkerFactory` per task list (instead of one factory with many workers) duplicates the workflow thread pool and sticky cache. Use a single factory and call `newWorker(taskList)` per task list.
- **`DataConverter` mismatch between starter and worker.** If you customize `DataConverter` on `WorkflowClientOptions`, configure it identically on every process that starts workflows. Otherwise arguments deserialize as garbage.
- **Sticky cache too small.** A factory with a high concurrent workflow count and the default cache size evicts constantly. Either raise `WorkerFactoryOptions.setStickyCacheSize` or scale horizontally so each factory holds fewer workflows.
- **Forgotten `factory.start()`.** Without it, the workers are registered but never poll. There is no error message — the workflows simply queue up on the task list forever.
- **Activity worker registered without the activity code.** A deploy that lost the activity registration stalls every activity invocation. Boot-time assertion that critical activity types are registered catches this in CI.

## Sources of truth

- `WorkflowClient` and `WorkflowClientOptions`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/client/{WorkflowClient,WorkflowClientOptions}.java`
- `WorkerFactory` and `WorkerFactoryOptions`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/worker/{WorkerFactory,WorkerFactoryOptions}.java`
- `Worker` and `WorkerOptions`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/worker/{Worker,WorkerOptions}.java`
- Default frontend ports: `cadence-workflow/cadence` → `config/development.yaml` (`port: 7933`, `grpcPort: 7833`)
- Canonical worker-setup sample: `cadence-workflow/cadence-java-samples` → `src/main/java/com/uber/cadence/samples/hello/HelloWorkerSetup.java`
