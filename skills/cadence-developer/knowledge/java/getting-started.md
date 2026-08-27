# Getting started with the Cadence Java SDK

This file walks through the smallest useful Java program: an activity that returns a greeting, a workflow that invokes it, a worker that hosts both, and a client that triggers an execution. It's modelled on the upstream `HelloActivity` sample in [`cadence-java-samples`](https://github.com/cadence-workflow/cadence-java-samples) so the patterns line up with what you'll find in production code.

## What you'll build

A Cadence Java application has four pieces:

1. A **workflow client** that talks to the Cadence frontend over gRPC.
2. A **worker factory** that owns one or more **workers**, each polling a task list for work.
3. **Workflows** defined as a Java interface (with `@WorkflowMethod`) plus an implementation class.
4. **Activities** defined the same way: an interface (with `@ActivityMethod`) plus an implementation.

Workflows and activities are registered with the worker before the factory is started. Once the factory is running, any client that knows the domain and task list can trigger an execution by name.

## Add the dependency

The examples in this skill use the Java 3.x client API shape (`Thrift2ProtoAdapter` around `IGrpcServiceStubs`). The snippets below pin `3.13.1`, the current stable 3.x release as of this update. Use a newer 3.x release if one is available, or intentionally migrate to the 4.x client line, which removes thrift-shaped APIs and requires source changes.

Gradle:

```groovy
dependencies {
    implementation 'com.uber.cadence:cadence-client:3.13.1'
}
```

Maven:

```xml
<dependency>
    <groupId>com.uber.cadence</groupId>
    <artifactId>cadence-client</artifactId>
    <version>3.13.1</version>
</dependency>
```

The artifact pulls in gRPC, Thrift, Tally, and the SLF4J API. Provide an SLF4J binding (Logback, log4j2, …) in your application.

## Define the workflow

Workflows are declared as interfaces. Exactly one method must carry `@WorkflowMethod` — that method's signature is the workflow's entry point.

```java
import com.uber.cadence.workflow.WorkflowMethod;

public interface GreetingWorkflow {
    @WorkflowMethod(
        executionStartToCloseTimeoutSeconds = 10,
        taskList = "HelloActivity"
    )
    String getGreeting(String name);
}
```

`executionStartToCloseTimeoutSeconds` is the end-to-end deadline for the workflow execution. `taskList` is the name workers poll on for this workflow type — the same name you'll register on the worker.

## Define the activity

Activities are also interfaces; methods carry `@ActivityMethod`:

```java
import com.uber.cadence.activity.ActivityMethod;

public interface GreetingActivities {
    @ActivityMethod(scheduleToCloseTimeoutSeconds = 2)
    String composeGreeting(String greeting, String name);
}
```

`scheduleToCloseTimeoutSeconds` bounds the end-to-end time including any retries.

## Implement both

The activity implementation is a plain Java class. Activities are stateless from Cadence's perspective; a single instance handles every invocation, so make method bodies thread-safe.

```java
public class GreetingActivitiesImpl implements GreetingActivities {
    @Override
    public String composeGreeting(String greeting, String name) {
        return greeting + " " + name + "!";
    }
}
```

The workflow implementation calls activities through a stub that the SDK creates from the interface:

```java
import com.uber.cadence.workflow.Workflow;

public class GreetingWorkflowImpl implements GreetingWorkflow {
    private final GreetingActivities activities =
        Workflow.newActivityStub(GreetingActivities.class);

    @Override
    public String getGreeting(String name) {
        return activities.composeGreeting("Hello", name);
    }
}
```

`activities.composeGreeting(...)` looks like a normal Java call but the SDK rewrites it into an activity task that the worker schedules, executes, and records into the workflow's history. The workflow code blocks until the activity returns, surviving worker restarts in the meantime.

## Wire the worker

The worker setup builds a `WorkflowClient`, a `WorkerFactory`, and one `Worker` per task list, registers types, then starts the factory.

```java
import com.uber.cadence.client.WorkflowClient;
import com.uber.cadence.client.WorkflowClientOptions;
import com.uber.cadence.internal.compatibility.Thrift2ProtoAdapter;
import com.uber.cadence.internal.compatibility.proto.serviceclient.IGrpcServiceStubs;
import com.uber.cadence.worker.Worker;
import com.uber.cadence.worker.WorkerFactory;

public class HelloWorker {
    static final String DOMAIN = "my-domain";
    static final String TASK_LIST = "HelloActivity";

    public static void main(String[] args) {
        WorkflowClient client = WorkflowClient.newInstance(
            new Thrift2ProtoAdapter(IGrpcServiceStubs.newInstance()),
            WorkflowClientOptions.newBuilder().setDomain(DOMAIN).build()
        );

        WorkerFactory factory = WorkerFactory.newInstance(client);
        Worker worker = factory.newWorker(TASK_LIST);

        worker.registerWorkflowImplementationTypes(GreetingWorkflowImpl.class);
        worker.registerActivitiesImplementations(new GreetingActivitiesImpl());

        factory.start();
    }
}
```

A few things worth knowing:

- `IGrpcServiceStubs.newInstance()` returns a gRPC client wired to the Cadence frontend's gRPC port (`localhost:7833` by default). Wrap it with `Thrift2ProtoAdapter` so the SDK's Thrift-shaped service interface keeps working over the gRPC wire.
- `registerWorkflowImplementationTypes` takes the **class** — Cadence constructs a fresh instance per workflow execution, so workflow fields can hold per-execution state.
- `registerActivitiesImplementations` takes an **instance** — the worker uses the same instance for every invocation, so any mutable state needs to be thread-safe.
- `factory.start()` returns immediately; the workers run on background threads. Block on a shutdown signal in `main`, or use `factory.shutdown()` / `factory.awaitTermination(...)` for graceful exit.

See [`workers.md`](workers.md) for the full `WorkflowClient`, `WorkerFactory`, and `Worker` option reference, sticky cache tuning, and topology patterns.

## Start a workflow from client code

```java
GreetingWorkflow workflow = client.newWorkflowStub(GreetingWorkflow.class);
String greeting = workflow.getGreeting("World");
System.out.println(greeting);
```

`client.newWorkflowStub(GreetingWorkflow.class)` builds a typed client stub. Calling `workflow.getGreeting("World")` blocks until the workflow completes. For asynchronous starts, use `WorkflowClient.start(workflow::getGreeting, "World")` and then wait on a `WorkflowExecution` handle.

## Verify with the CLI

After the run, look at the recorded history:

```bash
cadence --do my-domain workflow list
cadence --do my-domain workflow showid <workflow-id>
```

You should see the `WorkflowExecutionStarted`, `ActivityTaskScheduled`/`Started`/`Completed`, and `WorkflowExecutionCompleted` events.

## Where to go next

The full upstream sample is at <https://github.com/cadence-workflow/cadence-java-samples/blob/main/src/main/java/com/uber/cadence/samples/hello/HelloActivity.java>. The same repo has worked examples for child workflows, signals, queries, cron, periodic execution, sagas, side effects, and async activity completion — start there before reinventing a pattern.

Language-agnostic Cadence concepts that apply identically to Java are in `knowledge/shared/`:

- [`shared/determinism.md`](../shared/determinism.md) — why workflow code must be deterministic and what counts as non-determinism.
- [`shared/patterns.md`](../shared/patterns.md) — signals, queries, child workflows, continue-as-new, saga, polling, fan-out.
- [`shared/versioning.md`](../shared/versioning.md) — evolving workflow code without stranding open executions.
- [`shared/troubleshooting.md`](../shared/troubleshooting.md) — symptom-driven diagnosis with the `cadence` CLI.
- [`shared/error-reference.md`](../shared/error-reference.md) — the workflow-observable error model.

## Sources of truth

- Java SDK: <https://github.com/cadence-workflow/cadence-java-client> (Maven coordinates `com.uber.cadence:cadence-client`; upstream releases include newer 3.x releases after `3.12.7` and a separate 4.x line with breaking API changes).
- Java samples: <https://github.com/cadence-workflow/cadence-java-samples> — anchor file for this walk-through is `src/main/java/com/uber/cadence/samples/hello/HelloActivity.java`.
- Annotations and core APIs: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/workflow/{WorkflowMethod.java, Workflow.java}` and `src/main/java/com/uber/cadence/activity/ActivityMethod.java`.
