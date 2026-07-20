# Testing the Cadence Java SDK

The Java SDK ships three test utilities that cover the realistic spectrum of Cadence test scenarios: `TestWorkflowEnvironment` for fast end-to-end workflow tests with an in-memory cluster, `TestActivityEnvironment` for unit testing activities in isolation, and `WorkflowReplayer` plus `WorkflowShadower` for replay-safety checks against recorded or live histories.

For the bigger picture of why replay tests matter, see [`shared/determinism.md`](../shared/determinism.md) and [`shared/versioning.md`](../shared/versioning.md).

## TestWorkflowEnvironment

A `TestWorkflowEnvironment` is an in-memory Cadence service. It exposes a `WorkerFactory` for creating workers and a `WorkflowClient` for starting executions, both pre-wired to the in-memory service. Time skips forward automatically whenever the workflow is waiting on a timer.

```java
public class OrderWorkflowTest {
    private TestWorkflowEnvironment testEnv;
    private Worker worker;
    private WorkflowClient client;

    @Before
    public void setUp() {
        testEnv = TestWorkflowEnvironment.newInstance();
        worker = testEnv.newWorker("orders-tasklist");
        worker.registerWorkflowImplementationTypes(OrderWorkflowImpl.class);
        client = testEnv.newWorkflowClient();
    }

    @After
    public void tearDown() {
        testEnv.close();
    }

    @Test
    public void runsHappyPath() {
        worker.registerActivitiesImplementations(new OrderActivitiesImpl(deps));
        testEnv.start();

        OrderWorkflow workflow = client.newWorkflowStub(OrderWorkflow.class);
        OrderResult result = workflow.run(input);

        assertThat(result.status(), is(OrderStatus.SHIPPED));
    }
}
```

`TestWorkflowEnvironment.newInstance()` builds the in-memory service. `testEnv.newWorker(taskList)` returns a worker connected to it; `testEnv.newWorkflowClient()` returns a client pointed at the same in-memory frontend. After registration, call `testEnv.start()` exactly once before invoking workflow code, and call `testEnv.close()` in teardown so the service threads exit.

### Mocking activities

Replace one or more activity implementations with mocks to isolate the workflow's logic. Cadence's `registerActivitiesImplementations` takes any object that implements the activity interface, so Mockito drops in directly:

```java
@Test
public void shortCircuitsOnDeclinedPayment() {
    PaymentActivities mockPayments = mock(PaymentActivities.class);
    when(mockPayments.charge(any())).thenThrow(new PaymentDeclinedException("card_declined"));

    worker.registerActivitiesImplementations(mockPayments, new ShippingActivitiesImpl());
    testEnv.start();

    OrderWorkflow workflow = client.newWorkflowStub(OrderWorkflow.class);
    OrderResult result = workflow.run(input);

    assertThat(result.status(), is(OrderStatus.PAYMENT_FAILED));
    verify(mockPayments).charge(any());
}
```

The same trick works for child workflow types — register a mock implementation of the child interface.

### Virtual time

The environment runs against a simulated clock. Any `Workflow.sleep(Duration)` inside workflow code returns instantly in test wall-clock time; the SDK advances the in-memory service clock to the timer's scheduled instant. Two helpers control the clock from outside the workflow:

- `testEnv.sleep(Duration)` — advance the service clock by the given duration. Use it from test code to wait past sleep timers or activity timeouts.
- `testEnv.registerDelayedCallback(Duration, Runnable)` — run the callback at a specific virtual offset. Use it to send signals, cancel workflows, or complete async activities at simulated times.

```java
@Test
public void exitsAfterSignalledTimeout() {
    worker.registerActivitiesImplementations(new GreetingActivitiesImpl());
    testEnv.start();

    GreetingWorkflow workflow = client.newWorkflowStub(GreetingWorkflow.class);
    CompletableFuture<String> result = WorkflowClient.execute(workflow::run, "input");

    testEnv.registerDelayedCallback(Duration.ofHours(1), workflow::exit);
    testEnv.sleep(Duration.ofHours(2));

    assertEquals("EXITED", result.get());
}
```

`testEnv.currentTimeMillis()` returns the in-memory service's current time — useful in assertions over timestamps the workflow records.

### Diagnostics on failure

When a test fails it's often because the workflow's history did not match expectations. `testEnv.getDiagnostics()` returns a printable rendering of every workflow history in the in-memory service:

```java
@Rule
public TestWatcher watchman = new TestWatcher() {
    @Override
    protected void failed(Throwable e, Description description) {
        System.err.println(testEnv.getDiagnostics());
        testEnv.close();
    }
};
```

Prints the same event stream you'd see in `cadence workflow showid` for each execution the test ran.

## TestActivityEnvironment

For activity-only unit tests, use `TestActivityEnvironment`. It hosts your activity implementation, hands you a typed stub, and exposes the activity-execution context (`Activity.heartbeat`, `Activity.getTaskToken`, etc.) so the activity behaves the same way it would inside a worker:

```java
@Test
public void chargeRecordsHeartbeat() {
    TestActivityEnvironment env = TestActivityEnvironment.newInstance();
    env.registerActivitiesImplementations(new PaymentActivitiesImpl(stripe));

    PaymentActivities activities = env.newActivityStub(PaymentActivities.class);
    ChargeResult result = activities.charge(input);

    assertThat(result.transactionId(), startsWith("tx_"));
}
```

This is the right place to test heartbeat behavior, async completion (the env supplies a real `Activity.getTaskToken()`), and exception-to-retry-policy interactions, without the overhead of running the full workflow loop.

## Replay tests

A replay test takes a recorded workflow history and replays it against the current workflow code. If the code's decisions diverge from the recorded events, the replayer fails — the same failure mode the worker would report in production. Every workflow code change should ship with at least one replay test against a representative history.

### Capturing a history

```bash
cadence --do my-domain workflow showid <workflowId> -of order-happy-path.json
```

Commit the JSON file into the test resources.

### Running the replay

```java
@Test
public void replaysHappyPath() throws Exception {
    WorkflowReplayer.replayWorkflowExecutionFromResource(
        "order-happy-path.json",
        OrderWorkflowImpl.class
    );
}
```

The replayer registers the workflow class against a fresh in-memory environment and re-executes the recorded history. Other `replayWorkflowExecution` overloads accept a `File`, a `String` of JSON, or a live `IWorkflowService` + execution descriptor for pulling histories from a real cluster on demand.

Pair this with a small suite of histories covering the failure modes you care about (cancellation, retries, signal arrivals at different timings) and run them in CI on every change to workflow code.

## Workflow Shadower

The shadower runs a non-mutating replay against the real cluster. It pulls workflow histories matching a visibility query and replays each one with your local code, surfacing non-determinism before you ship.

```java
WorkflowShadower shadower = new WorkflowShadower(
    workflowService,
    "my-domain",
    new ShadowingOptions.Builder()
        .setWorkflowQuery("WorkflowType='myapp.OrderWorkflow' AND CloseTime IS NULL")
        .setSamplingRate(0.1)
        .setShadowMode(ShadowMode.Normal)
        .build()
);
shadower.registerWorkflowImplementationTypes(OrderWorkflowImpl.class);
shadower.run();
```

`ShadowMode.Normal` exits when every matching workflow has been replayed once; `ShadowMode.Continuous` keeps polling for new candidates indefinitely. Use the continuous mode in a long-running canary process; use the normal mode as a pre-deploy gate. See [`shared/versioning.md`](../shared/versioning.md) for how the shadower fits into a workflow code rollout.

## Patterns that compose

A typical Cadence test suite layers all three:

- Fast `TestWorkflowEnvironment` tests for every workflow scenario you can describe declaratively.
- `TestActivityEnvironment` tests for activities whose retry, heartbeat, or external-IO behavior is non-trivial.
- A small `WorkflowReplayer` set keyed to histories captured from production, refreshed periodically.
- A `WorkflowShadower` continuous run in staging or a low-traffic production cohort, alerting on replay failures.

The `TestWorkflowEnvironment` tests run in unit-test time scales (milliseconds); the shadower runs continuously against real traffic. Together they catch divergence between intended behavior, expressed behavior, and recorded behavior.

## Sources of truth

- `TestWorkflowEnvironment`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/testing/TestWorkflowEnvironment.java`
- `TestActivityEnvironment`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/testing/TestActivityEnvironment.java`
- `WorkflowReplayer`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/testing/WorkflowReplayer.java`
- `WorkflowShadower`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/testing/WorkflowShadower.java`
- Worked test examples: `cadence-workflow/cadence-java-samples` → `src/test/java/com/uber/cadence/samples/hello/`
