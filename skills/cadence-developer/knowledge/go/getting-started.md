# Getting started with the Cadence Go SDK

The fastest path from zero to a running Cadence Go application is to clone the upstream samples, run the `helloworld` recipe, and then adapt it. This file walks through that path, points out the parts of the code worth understanding, and explains how to swap in your own workflow.

## Prerequisites

- Go **1.21+** (matches the SDK's `go.mod`).
- A running Cadence cluster. For local development, run `docker-compose -f docker/docker-compose.yml up` from a checkout of [`cadence-workflow/cadence`](https://github.com/cadence-workflow/cadence), or build and run `cadence-server start` manually.
- The Cadence CLI on your `$PATH` (the `cadence` binary).
- A registered domain. From a fresh cluster:

  ```bash
  cadence --domain my-domain domain register
  ```

## Run the upstream hello world

Clone the samples repo and build it:

```bash
git clone https://github.com/cadence-workflow/cadence-samples
cd cadence-samples
make
```

In one terminal, start the worker that hosts the workflow and activity code:

```bash
./bin/helloworld -m worker
```

In a second terminal, trigger a workflow execution:

```bash
./bin/helloworld -m trigger
```

The worker logs "helloworld workflow started", invokes the activity, logs "helloworld activity started", and the workflow completes. You can also see the execution in Cadence Web (typically <http://localhost:8088>) or via the CLI:

```bash
cadence --domain samples-domain workflow list
```

## What the code does

The sample is two files: `helloworld_workflow.go` (workflow + activity) and `main.go` (worker bootstrap). The parts you need to understand:

### The workflow function

A workflow is a Go function whose first argument is `workflow.Context`. Activities are invoked through `workflow.ExecuteActivity`, which returns a `Future` you `Get` into a typed result:

```go
func helloWorldWorkflow(ctx workflow.Context, name string) error {
    ao := workflow.ActivityOptions{
        ScheduleToStartTimeout: time.Minute,
        StartToCloseTimeout:    time.Minute,
        HeartbeatTimeout:       time.Second * 20,
    }
    ctx = workflow.WithActivityOptions(ctx, ao)

    var result string
    if err := workflow.ExecuteActivity(ctx, helloWorldActivity, name).Get(ctx, &result); err != nil {
        return err
    }
    workflow.GetLogger(ctx).Info("Workflow completed.", zap.String("Result", result))
    return nil
}
```

Activity timeouts are mandatory — set them in `workflow.ActivityOptions` before calling `ExecuteActivity`. The three most common are `StartToCloseTimeout` (per-attempt activity duration), `ScheduleToStartTimeout` (how long the activity may wait in the task list), and `HeartbeatTimeout` (for long-running activities).

The workflow function itself must remain deterministic. See [`../shared/determinism.md`](../shared/determinism.md) before adding anything other than activity calls and SDK helpers.

### The activity function

An activity is a regular Go function whose first argument is `context.Context` (the standard library context, not `workflow.Context`). Activities can do anything — HTTP calls, database writes, file I/O — and Cadence handles their retries.

```go
func helloWorldActivity(ctx context.Context, name string) (string, error) {
    activity.GetLogger(ctx).Info("helloworld activity started")
    return "Hello " + name + "!", nil
}
```

Use `activity.GetLogger(ctx)` and `activity.GetInfo(ctx)` for activity-side observability.

### Registration

The worker needs to know which workflows and activities to host. Registration happens at startup:

```go
worker.RegisterWorkflowWithOptions(helloWorldWorkflow, workflow.RegisterOptions{Name: "helloWorldWorkflow"})
worker.RegisterActivity(helloWorldActivity)
```

The `Name` option is important — it is the workflow type recorded in history and used by clients when starting an execution. If you rename the Go function but keep the registered name, in-flight workflows continue to find their code on replay.

### Worker construction

The samples use a shared `common.SampleHelper` (`cmd/samples/common/sample_helper.go`) that handles YARPC dispatcher setup, config loading, and metrics. Underneath, it builds a `workflowserviceclient.Interface` and calls `worker.NewV2`:

```go
w, err := worker.NewV2(serviceClient, "my-domain", "my-task-list", worker.Options{
    Logger: logger,
})
if err != nil {
    return err
}
if err := w.Start(); err != nil {
    return err
}
```

`worker.New` (without the `V2` suffix) is deprecated — it panics on error. Use `worker.NewV2` in new code.

The first argument is a `workflowserviceclient.Interface`, typically wired through YARPC + gRPC against the Cadence frontend's gRPC port (7833 on the default development server). See [`workers.md`](workers.md) for the full canonical wiring (including the `compatibility.NewThrift2ProtoAdapter` step), the `worker.Options` reference, sticky cache tuning, and graceful shutdown.

### Starting a workflow from code

A client triggers a workflow execution by name, with `client.StartWorkflowOptions`:

```go
wf, err := cadenceClient.StartWorkflow(ctx, client.StartWorkflowOptions{
    ID:                              "helloworld_" + uuid.New(),
    TaskList:                        "my-task-list",
    ExecutionStartToCloseTimeout:    time.Minute,
    DecisionTaskStartToCloseTimeout: time.Minute,
}, "helloWorldWorkflow", "Cadence")
```

`ExecutionStartToCloseTimeout` bounds the whole workflow execution; `DecisionTaskStartToCloseTimeout` bounds an individual decision task. The workflow type passed as the third argument matches the name you registered.

## Adapt to your own workflow

The minimal substitution checklist:

1. Copy `helloworld_workflow.go` into your own module (or a new recipe folder).
2. Rename `helloWorldWorkflow` and `helloWorldActivity` to match your domain.
3. Pick your own task list name (replace `ApplicationName`).
4. Register your new workflow and activity in `registerWorkflowAndActivity`.
5. Update the registered workflow type and `StartWorkflow` call in `startWorkflow`.
6. Run the worker and trigger an execution.

Once your worker compiles and runs the hello path, swap in your real workflow logic. Resist the temptation to add anything non-deterministic to the workflow function — see [`../shared/determinism.md`](../shared/determinism.md).

## Useful CLI commands while you build

```bash
cadence --domain my-domain workflow list                       # recent executions
cadence --domain my-domain workflow showid <workflow-id>       # full event history
cadence --domain my-domain workflow describe -w <workflow-id>  # current status
cadence --domain my-domain workflow terminate -w <workflow-id> --reason "<reason>"
```

The history view is the single most useful debugging tool — most workflow bugs become obvious once you read the event log.

## Sources of truth

- Hello world recipe: <https://github.com/cadence-workflow/cadence-samples/tree/master/cmd/samples/recipes/helloworld>
- `SampleHelper` reference: <https://github.com/cadence-workflow/cadence-samples/blob/master/cmd/samples/common/sample_helper.go>
- Go SDK API docs: <https://pkg.go.dev/go.uber.org/cadence>
- `worker.NewV2`, `worker.Options`: `cadence-workflow/cadence-go-client` → `worker/worker.go`
- `workflow.ActivityOptions`, `workflow.ExecuteActivity`: `cadence-workflow/cadence-go-client` → `workflow/workflow.go`
