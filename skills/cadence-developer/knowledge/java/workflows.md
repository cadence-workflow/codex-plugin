# Workflows in the Cadence Java SDK

This file covers the workflow-author surface in Java: how to declare a workflow, what its implementation can do, and which `Workflow.*` static methods are deterministic-replay-safe. For minimum setup and worker wiring see [`getting-started.md`](getting-started.md); for activity-author details see [`activities.md`](activities.md), and for the error model see [`shared/error-reference.md`](../shared/error-reference.md).

## Interface and implementation

A Cadence workflow is two types: an **interface** declaring the workflow's entry point and any signals/queries, plus an **implementation class** containing the code.

```java
public interface OrderWorkflow {
    @WorkflowMethod
    OrderResult run(OrderInput input);

    @SignalMethod
    void cancel();

    @QueryMethod
    OrderStatus status();
}

public class OrderWorkflowImpl implements OrderWorkflow {
    private OrderStatus state = OrderStatus.PENDING;
    private boolean canceled = false;

    @Override
    public OrderResult run(OrderInput input) { /* ... */ }

    @Override
    public void cancel() { canceled = true; }

    @Override
    public OrderStatus status() { return state; }
}
```

Exactly one method on the interface must carry `@WorkflowMethod`. Zero or more may carry `@SignalMethod` or `@QueryMethod`. The implementation class is what you pass to `worker.registerWorkflowImplementationTypes(...)` — Cadence constructs a fresh instance per workflow execution, so the impl's fields hold per-execution state without you having to think about it.

## `@WorkflowMethod`

The annotation's attributes set defaults that callers can still override via `WorkflowOptions` at start time.

| Attribute | Default | Purpose |
| --- | --- | --- |
| `name` | empty (uses `Class$Method`) | Registered workflow type name. Pin it explicitly; renames strand in-flight executions. |
| `executionStartToCloseTimeoutSeconds` | required (no default) | End-to-end execution deadline. |
| `taskStartToCloseTimeoutSeconds` | 10 | Per-decision-task deadline. |
| `taskList` | empty | Default task list workers poll for this workflow type. |
| `workflowIdReusePolicy` | `AllowDuplicateFailedOnly` | What happens when a starter reuses a workflow ID. |

```java
@WorkflowMethod(
    name = "myapp.OrderWorkflow",
    executionStartToCloseTimeoutSeconds = 3600,
    taskStartToCloseTimeoutSeconds = 30,
    taskList = "orders"
)
OrderResult run(OrderInput input);
```

Treat `name` as a wire contract — once a deployed worker has registered it and started workflows, do not change it without a migration path.

## Calling activities

Inside workflow code, get a typed stub from the activity interface:

```java
private final OrderActivities activities = Workflow.newActivityStub(
    OrderActivities.class,
    new ActivityOptions.Builder()
        .setScheduleToCloseTimeout(Duration.ofMinutes(5))
        .setStartToCloseTimeout(Duration.ofSeconds(30))
        .setRetryOptions(
            new RetryOptions.Builder()
                .setInitialInterval(Duration.ofSeconds(1))
                .setMaximumInterval(Duration.ofMinutes(1))
                .setMaximumAttempts(5)
                .setDoNotRetry(NonRetryableException.class)
                .build())
        .build());

ChargeResult result = activities.chargeCard(input);
```

The stub looks like a normal Java object — every interface method becomes a synchronous call that blocks the workflow until the activity completes. The SDK records the activity result into history; on replay the next worker reads the recorded result instead of calling the activity again.

`newActivityStub(Class)` (no options) is allowed when defaults set elsewhere are acceptable, but production code should configure timeouts and a retry policy explicitly. Per-method overrides go through `MethodRetry` annotations on the activity interface.

## Async activity invocation

For fan-out, use `Async`:

```java
List<Promise<Result>> futures = new ArrayList<>();
for (Item item : input.items()) {
    futures.add(Async.function(activities::process, item));
}
Promise.allOf(futures).get();
```

`Async.function` returns a `Promise<R>`; `Async.procedure` is the void-returning equivalent. `Promise.allOf(...)`, `Promise.anyOf(...)`, `Promise.get()`, and `Promise.thenApply(...)` mirror Java's `CompletableFuture` API but are replay-safe.

## Timers and waits

The deterministic equivalents of `Thread.sleep`, `System.currentTimeMillis`, and `Object.wait`:

- `Workflow.sleep(Duration)` / `Workflow.sleep(long millis)` — blocks workflow code for the given duration.
- `Workflow.newTimer(Duration)` — returns a `Promise<Void>` you can compose with other promises.
- `Workflow.currentTimeMillis()` — wall clock at the current event-time.
- `Workflow.await(Supplier<Boolean>)` — block until the predicate returns true. Re-evaluated on every state change.
- `Workflow.await(Duration, Supplier<Boolean>)` — same with a timeout; returns `true` if unblocked, `false` if timed out.

Never use `Thread.sleep`, `Object.wait`, or stdlib `CompletableFuture.get(timeout, …)` inside workflow code — they're non-deterministic.

## Signals

A signal is a workflow-interface method annotated with `@SignalMethod`. Calling it from outside the workflow appends a `WorkflowExecutionSignaled` event to history and invokes the method on the impl. The body typically mutates shared fields the `@WorkflowMethod` is waiting on:

```java
public class GreetingWorkflowImpl implements GreetingWorkflow {
    private final List<String> messageQueue = new ArrayList<>();
    private boolean exit = false;

    @Override
    public List<String> getGreetings() {
        List<String> received = new ArrayList<>();
        while (true) {
            Workflow.await(() -> !messageQueue.isEmpty() || exit);
            if (messageQueue.isEmpty() && exit) return received;
            received.add(messageQueue.remove(0));
        }
    }

    @Override
    public void waitForName(String name) { messageQueue.add("Hello " + name + "!"); }

    @Override
    public void exit() { exit = true; }
}
```

From client code:

```java
GreetingWorkflow stub = client.newWorkflowStub(GreetingWorkflow.class, workflowId);
stub.waitForName("World");
```

Signal handlers run on the workflow thread, in the order they appear in history. They must not block on activities or timers — keep the body to assignments and small bookkeeping; do real work in the `@WorkflowMethod` after the signal flips a flag.

## Queries

Query methods are read-only — they must not mutate workflow state and must not call activities, timers, or signals. They return synchronously to the caller.

```java
@Override
public OrderStatus status() { return state; }
```

From client code:

```java
OrderStatus s = client.newWorkflowStub(OrderWorkflow.class, workflowId).status();
```

Because queries run by replaying the workflow history on the worker, a long-running workflow that has accumulated thousands of events will have a perceptible query latency.

## Child workflows

```java
ChildWorkflowOptions opts = new ChildWorkflowOptions.Builder()
    .setExecutionStartToCloseTimeout(Duration.ofMinutes(30))
    .setTaskList("child-list")
    .build();

ShippingWorkflow shipping = Workflow.newChildWorkflowStub(ShippingWorkflow.class, opts);
ShipmentResult result = shipping.ship(item); // blocks until the child completes

// Or async:
Promise<ShipmentResult> p = Async.function(shipping::ship, item);
Promise<WorkflowExecution> execution = Workflow.getWorkflowExecution(shipping);
```

`Workflow.getWorkflowExecution(stub)` lets you grab the child's `workflowId`/`runId` for cross-references in logs or for signalling from elsewhere.

## Continue-as-new

When a workflow's history grows too large, hand off to a fresh execution:

```java
Workflow.continueAsNew(nextInput);
```

This terminates the current execution and starts a new run with the same workflow ID and the supplied arguments. For changing arguments or workflow type at the same time, get a continue-as-new stub:

```java
OrderWorkflow next = Workflow.newContinueAsNewStub(OrderWorkflow.class, opts);
next.run(nextInput); // does not return — chains the new execution
```

See [`shared/patterns.md`](../shared/patterns.md) for when to reach for this pattern.

## Versioning

When you need to change workflow code without breaking in-flight executions, mark the change point:

```java
int v = Workflow.getVersion("payment-retry-fix", Workflow.DEFAULT_VERSION, 1);
if (v == Workflow.DEFAULT_VERSION) {
    // legacy branch — preserved for histories that recorded DEFAULT_VERSION
    return activities.chargeOld(input);
}
return activities.chargeNew(input);
```

`Workflow.DEFAULT_VERSION` is `-1` — the marker value the SDK records for executions that ran before the `getVersion` call existed. See [`shared/versioning.md`](../shared/versioning.md) for the retirement schedule and bad-binary reset workflow.

## Side effects and randomness

Wrap any non-deterministic read so its result is recorded into history and replayed deterministically:

```java
UUID id = Workflow.sideEffect(UUID.class, UUID::randomUUID);
int sample = Workflow.sideEffect(Integer.class, () -> Workflow.newRandom().nextInt(100));
```

For "I want a value that can change between executions but must stay the same within one execution" use `Workflow.mutableSideEffect`. Convenience helpers `Workflow.randomUUID()` and `Workflow.newRandom()` already wrap their underlying randomness so you don't have to write `sideEffect` yourself.

`Workflow.isReplaying()` is available for the (rare) case where you want code to behave differently on replay — useful for skipping log lines, never for branching that produces a different result.

## Cancellation

Workflow cancellation arrives via `WorkflowExecutionCancelRequested` events and surfaces as a `CancellationException` from any blocking call (`activities.x()`, `Workflow.sleep`, `Workflow.await`, child workflow stubs, `Async.function(...).get()`). Catch it for cleanup, but run cleanup in a detached scope or it inherits the cancellation:

```java
try {
    activities.expensive(input);
} catch (CancellationException e) {
    Workflow.newDetachedCancellationScope(() -> {
        activities.releaseResources();
    }).run();
    throw e;
}
```

`Workflow.newCancellationScope(Runnable)` creates a child scope whose cancellation propagates from the parent; `Workflow.newDetachedCancellationScope(Runnable)` ignores parent cancellation for cleanup code.

## Errors

Activities raise `ActivityFailureException` whose cause is the original activity exception. Child workflows raise `ChildWorkflowFailureException`. Both unwrap to the original cause via `Workflow.unwrap(e)`. Application errors should subclass a small set of exception types you control — anything not subclassing them surfaces to callers as a generic remote-failure cause.

See [`shared/error-reference.md`](../shared/error-reference.md) for the full taxonomy (the concepts are language-agnostic; Go names map to Java exception classes one-to-one).

## Logger and metrics

```java
private static final Logger logger = Workflow.getLogger(OrderWorkflowImpl.class);
```

`Workflow.getLogger(...)` returns an SLF4J `Logger` that suppresses output during replay. `Workflow.getMetricsScope()` returns the Tally `Scope` configured on the worker — emissions are replay-safe.

Do not use a class-level `private static final Logger logger = LoggerFactory.getLogger(...)`. Direct SLF4J logging fires on every replay and produces duplicate lines.

## Workflow info

```java
WorkflowInfo info = Workflow.getWorkflowInfo();
String wid = info.getWorkflowId();
String runId = info.getRunId();
String type = info.getWorkflowType();
String taskList = info.getTaskList();
```

Use these to tag custom logs and metrics so they correlate with the execution in Cadence Web.

## Sources of truth

- Workflow static helpers: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/workflow/Workflow.java`
- Annotations: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/workflow/{WorkflowMethod,SignalMethod,QueryMethod}.java`
- Async helpers and Promise: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/workflow/{Async.java, Promise.java}`
- Cancellation scopes: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/workflow/CancellationScope.java`
- Worked examples for every section: `cadence-workflow/cadence-java-samples` → `src/main/java/com/uber/cadence/samples/hello/`
