# Activities in the Cadence Java SDK

This file covers the activity-author surface in Java: how to define activities, how the workflow invokes them, how to make them idempotent and observable, and how to use heartbeats, local activities, and async completion. For the bigger picture of when to reach for an activity (versus a workflow or a local activity) see [`shared/patterns.md`](../shared/patterns.md) and [`shared/pitfalls.md`](../shared/pitfalls.md).

## Defining an activity

Like workflows, activities have an **interface** declaring the methods and an **implementation** class. The interface is what workflow code holds as a stub; the impl is what the worker registers.

```java
public interface PaymentActivities {
    @ActivityMethod(
        scheduleToCloseTimeoutSeconds = 60,
        startToCloseTimeoutSeconds = 30,
        heartbeatTimeoutSeconds = 10
    )
    ChargeResult charge(ChargeInput input);

    @ActivityMethod(scheduleToCloseTimeoutSeconds = 30)
    void refund(String chargeId);
}

public class PaymentActivitiesImpl implements PaymentActivities {
    private final StripeClient stripe;

    public PaymentActivitiesImpl(StripeClient stripe) {
        this.stripe = stripe;
    }

    @Override
    public ChargeResult charge(ChargeInput input) { /* ... */ }

    @Override
    public void refund(String chargeId) { /* ... */ }
}
```

Activities are stateless from Cadence's perspective; a single instance handles every invocation, so make field access and method bodies thread-safe. Pass any clients or shared resources through the constructor.

## `@ActivityMethod` attributes

| Attribute | Default | Purpose |
| --- | --- | --- |
| `name` | empty (method name) | Registered activity type. Pin it for stable wire-level identity. |
| `scheduleToStartTimeoutSeconds` | 0 (no separate limit) | How long the task may wait in the matching service before a worker picks it up. |
| `startToCloseTimeoutSeconds` | 0 | Per-attempt deadline once a worker starts the activity. |
| `scheduleToCloseTimeoutSeconds` | 0 | End-to-end deadline including queuing and all retries. |
| `heartbeatTimeoutSeconds` | 0 (no heartbeating) | Maximum time between heartbeats. Activity is failed if it stops heartbeating. |
| `taskList` | empty | Task list this activity runs on; defaults to the workflow's task list. |

`startToCloseTimeoutSeconds` is the one you almost always want to set; `scheduleToCloseTimeoutSeconds` bounds total time with retries. Configure these on the annotation as defaults, then override per-call from workflow code via `ActivityOptions` if needed.

## Per-method retry policy with `@MethodRetry`

For declarative retry tuning that travels with the activity definition:

```java
public interface PaymentActivities {
    @ActivityMethod(scheduleToCloseTimeoutSeconds = 60)
    @MethodRetry(
        initialIntervalSeconds = 1,
        maximumIntervalSeconds = 60,
        backoffCoefficient = 2.0,
        maximumAttempts = 5,
        doNotRetry = { PaymentDeclinedException.class, InvalidInputException.class }
    )
    ChargeResult charge(ChargeInput input);
}
```

`doNotRetry` takes a class array of exception types that should fail the activity immediately rather than retry. Any exception assignable to one of those classes short-circuits the policy.

The same fields are also available imperatively as `RetryOptions.Builder` and passed to `ActivityOptions.setRetryOptions(...)` from the workflow side. When both are present, `ActivityOptions` wins per-call.

## Invoking from a workflow

Workflow code gets a stub from the interface; every method call becomes a scheduled activity task that blocks the workflow until the activity returns.

```java
private final PaymentActivities payments = Workflow.newActivityStub(
    PaymentActivities.class,
    new ActivityOptions.Builder()
        .setStartToCloseTimeout(Duration.ofSeconds(30))
        .setScheduleToCloseTimeout(Duration.ofMinutes(5))
        .setRetryOptions(new RetryOptions.Builder()
            .setInitialInterval(Duration.ofSeconds(1))
            .setMaximumInterval(Duration.ofMinutes(1))
            .setMaximumAttempts(5)
            .setDoNotRetry(PaymentDeclinedException.class)
            .build())
        .build());

ChargeResult result = payments.charge(input);
```

The `Workflow.newActivityStub(Class)` overload uses defaults from the `@ActivityMethod` annotation and any `@MethodRetry`. Use it only if the activity's annotations carry production-appropriate values; otherwise pass an `ActivityOptions` explicitly.

## Activity execution context

Inside activity code, `com.uber.cadence.activity.Activity` provides static helpers for the current task:

| Helper | Use |
| --- | --- |
| `Activity.getTask()` | Full `ActivityTask` (activity ID, attempt, workflow type, scheduled timestamp, …). |
| `Activity.getWorkflowExecution()` | `WorkflowExecution` of the workflow that scheduled this activity. |
| `Activity.getTaskToken()` | Opaque byte token used for async completion. |
| `Activity.getDomain()` | Domain name. |
| `Activity.heartbeat(details)` | Report progress and check for cancellation. |
| `Activity.getHeartbeatDetails(Class)` | Read the last heartbeat payload from a previous attempt. |
| `Activity.doNotCompleteOnReturn()` | Signal async completion (returns no longer completes the activity). |
| `Activity.wrap(e)` | Wrap a checked exception so it can be thrown from a non-checked method. |

These work because the SDK stashes the active task in a thread-local; they are safe to call from anywhere on the activity-execution thread.

## Heartbeats

Activities that take more than a few seconds should heartbeat. Heartbeating proves the worker is alive, records resumable progress, and is the only way the activity learns about cancellation.

```java
public List<Result> processBatch(List<Item> items) {
    int startIndex = Activity.getHeartbeatDetails(Integer.class).orElse(0);
    List<Result> results = new ArrayList<>();

    for (int i = startIndex; i < items.size(); i++) {
        results.add(process(items.get(i)));
        Activity.heartbeat(i + 1);
    }
    return results;
}
```

On a retry — for instance after a worker crash mid-batch — `getHeartbeatDetails` returns the last recorded value so the next attempt resumes from where the previous one left off. Heartbeat payloads are serialized through the same data converter as activity arguments, so use small JSON-friendly types.

Pair heartbeats with `heartbeatTimeoutSeconds` on `@ActivityMethod` or `ActivityOptions.setHeartbeatTimeout(...)`. Without a heartbeat timeout, `Activity.heartbeat(...)` is a no-op for liveness — set the timeout to something a few times your expected heartbeat interval (the SDK throttles heartbeats automatically, so calling `heartbeat` in a tight loop is fine).

## Idempotency

Activities are retried by Cadence according to the configured policy. Design every activity to be safe to run more than once with the same input. The standard recipe is a dedup key derived from the workflow execution plus an activity-local discriminator:

```java
String dedupKey = Activity.getWorkflowExecution().getWorkflowId()
    + "/" + Activity.getWorkflowExecution().getRunId()
    + "/" + Activity.getTask().getActivityId();
```

Use this as the idempotency key for any downstream API call (Stripe `Idempotency-Key`, database `INSERT ... ON CONFLICT`, etc.). The workflow ID is stable across the entire execution, the run ID changes only with continue-as-new or replay, and the activity ID is unique within a single workflow execution.

## Local activities

For short, in-process operations where the overhead of a normal activity (history events, polling, scheduling) dwarfs the work itself, use a local activity:

```java
private final ValidationActivities validate = Workflow.newLocalActivityStub(
    ValidationActivities.class,
    new LocalActivityOptions.Builder()
        .setStartToCloseTimeout(Duration.ofSeconds(2))
        .build());

ValidationResult result = validate.check(input);
```

Local activities execute on the same worker that's running the workflow's decision task and only record a single marker event into history. Trade-offs:

- They share the worker's resources and concurrency budget.
- They don't survive worker crashes between attempts — there is no separate activity task pulled by another worker.
- They aren't suitable for anything longer than a few hundred milliseconds.

Use them for input validation, format conversion, lookups against in-process caches, and similar fast, side-effect-light steps.

## Async completion

When an activity's outcome depends on an external event (human approval, callback from another system), don't tie up a worker thread waiting. Capture the task token, return without completing, and complete it later from the system that knows the answer.

```java
public class ApprovalActivitiesImpl implements ApprovalActivities {
    private final ActivityCompletionClient completionClient;

    public ApprovalActivitiesImpl(ActivityCompletionClient completionClient) {
        this.completionClient = completionClient;
    }

    @Override
    public Approval awaitApproval(Request request) {
        byte[] taskToken = Activity.getTaskToken();
        approvalQueue.publish(new ApprovalEnvelope(taskToken, request));
        Activity.doNotCompleteOnReturn();
        return null; // ignored
    }
}
```

When the approver returns:

```java
completionClient.complete(taskToken, decision);
// or completionClient.completeExceptionally(taskToken, new ApprovalRejectedException(...));
```

The `ActivityCompletionClient` is created from a `WorkflowClient` (`workflowClient.newActivityCompletionClient()`). Keep emitting heartbeats from outside the activity process if you want cancellation to flow through — the `complete*` methods throw `ActivityCompletionException` if the activity was cancelled or expired in the meantime.

## Errors and the retry policy

An activity that throws an exception:

1. Is wrapped by the SDK into `ActivityFailureException` on the workflow side; `Workflow.unwrap(e)` recovers the original cause.
2. Is consulted against the retry policy: if the exception class (or a supertype) matches `doNotRetry`, the activity fails immediately. Otherwise it is retried until `maximumAttempts` or `scheduleToCloseTimeout` is hit.

Application errors should be a small set of exception types you control. Define them once, list them in `doNotRetry` where they should short-circuit retries, and use exception fields to carry structured details across the activity-to-workflow boundary. See [`shared/error-reference.md`](../shared/error-reference.md) for the cross-SDK error model.

## Cancellation

If the workflow is cancelled (or the activity blows a timeout), heartbeating activities receive an `ActivityCancellationException` from the next `Activity.heartbeat(...)` call. Catch it for cleanup and then rethrow, or rethrow as `Activity.wrap(e)` from a non-checked method:

```java
try {
    for (int i = 0; i < items.size(); i++) {
        process(items.get(i));
        Activity.heartbeat(i + 1); // throws ActivityCancellationException on cancellation
    }
} catch (ActivityCancellationException e) {
    releaseResources();
    throw e;
}
```

Non-heartbeating activities only learn about cancellation when they return or fail — design long-running activities to heartbeat regularly so cancellation is responsive.

## Sources of truth

- `Activity` static helpers: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/activity/Activity.java`
- `@ActivityMethod` attributes: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/activity/ActivityMethod.java`
- `@MethodRetry` attributes: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/common/MethodRetry.java`
- `ActivityOptions` and `RetryOptions` builders: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/activity/ActivityOptions.java`, `src/main/java/com/uber/cadence/common/RetryOptions.java`
- `LocalActivityOptions`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/activity/LocalActivityOptions.java`
- `ActivityCompletionClient`: `cadence-workflow/cadence-java-client` → `src/main/java/com/uber/cadence/client/ActivityCompletionClient.java`
- Worked async-completion example: `cadence-workflow/cadence-java-samples` → `src/main/java/com/uber/cadence/samples/hello/HelloAsyncActivityCompletion.java`
