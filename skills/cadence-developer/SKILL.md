---
name: cadence-developer
description: Build, debug, and operate Cadence workflows, activities, and workers across supported SDKs (Go, Java, and Python — the Python SDK itself is alpha so coverage calls out gaps explicitly). Use when the user is writing Cadence SDK code; troubleshooting non-determinism, stuck workflows, or activity retries; using the `cadence` CLI or running `cadence-server`; or working with durable execution concepts such as signals, queries, child workflows, continue-as-new, saga, domains, or task lists.
version: 0.6.2
---

# Cadence Developer

## Overview

[Cadence](https://cadenceworkflow.io) is a fault-tolerant, stateful orchestration engine that runs long-lived business logic as workflows backed by a complete event history. This skill helps an agent build, debug, and operate Cadence applications. The Go, Java, and Python SDK directories use the same six-file topic layout so agents know where to look; coverage depth follows the upstream SDK surfaces. The Python SDK (`cadence-python-client`) is alpha, so its files document the surface that exists today and call out the gaps relative to Go and Java explicitly (see [`README.md`](../../README.md)).

## Core concepts

- **Cadence Server / Cadence Cluster** — the backend. Composed of the frontend, history, matching, and worker services plus a persistence store (Cassandra, MySQL, PostgreSQL, or SQLite). Runs as a single binary (`cadence-server`) for development or as a distributed deployment for production.
- **Domain** — the tenancy boundary. Workflows and task lists live within a domain; a domain must be registered before any workflow can run in it.
- **Worker** — a long-running process you operate. It polls a task list for workflow tasks and activity tasks and executes the corresponding code. The same binary commonly hosts both workflow and activity workers.
- **Workflow** — a durable, deterministic function that orchestrates work. Its state survives process restarts because Cadence reconstructs it from the event history. Workflow code must avoid non-determinism and external side effects.
- **Activity** — a non-deterministic operation (HTTP call, database write, file I/O) invoked by a workflow. Activities are retried by Cadence according to a configurable policy.
- **Task list** — the queue that connects workers to the cluster. Workers poll a task list for tasks and the cluster dispatches work to whichever worker is available.

## Why workflows must be deterministic

Cadence durability comes from **history replay**. When a worker resumes a workflow — after a crash, a sticky-cache eviction, or a long-sleeping timer firing — it re-executes the workflow code from the beginning, replacing each external operation with the result already recorded in the event history. If the replayed code diverges from history, the worker returns a non-determinism error and the workflow gets stuck.

Practical rules for workflow code:

- No wall-clock reads, random numbers, file I/O, or network calls directly in a workflow. Use the SDK's deterministic equivalents where they exist (for example `workflow.Now` and `workflow.Sleep` in Go) and wrap one-off non-deterministic reads in `workflow.SideEffect` so the result is recorded in history and replayed deterministically.
- No raw goroutines, threads, or channels. Use the SDK-provided concurrency primitives instead (`workflow.Go`, `workflow.NewChannel`, etc. in Go).
- Any operation that needs real-world side effects — HTTP calls, database writes, file I/O — belongs inside an activity.

## Getting started

1. Install the Cadence CLI (the `cadence` binary) and start a local Cadence server (`cadence-server start`, or run the project's Docker Compose stack). Verify the CLI with `cadence --version`.
2. Register a domain: `cadence --domain my-domain domain register`.
3. Add the SDK to your project:
    - Go: `go get go.uber.org/cadence`.
    - Java: `com.uber.cadence:cadence-client` via Gradle or Maven; pin a version compatible with the API line you use (see [`knowledge/java/getting-started.md`](knowledge/java/getting-started.md)).
    - Python (alpha): `pip install cadence-python-client` — pin to a specific version (see [`knowledge/python/getting-started.md`](knowledge/python/getting-started.md)).
4. Implement a workflow, an activity, and a worker that registers both, then run the worker pointed at your local server. Known-good starting points: [`cadence-samples`](https://github.com/cadence-workflow/cadence-samples) for Go, [`cadence-java-samples`](https://github.com/cadence-workflow/cadence-java-samples) for Java, and `cadence/sample/client_example.py` inside [`cadence-python-client`](https://github.com/cadence-workflow/cadence-python-client) for Python.

## Knowledge map

Deeper guidance is split across language-agnostic concepts (`knowledge/shared/`) and per-SDK directories (`knowledge/go/`, `knowledge/java/`, `knowledge/python/`). Read the file that matches the task in front of you.

### Concepts (`knowledge/shared/`)

- [`architecture.md`](knowledge/shared/architecture.md) — Cadence Server services, deployment topologies, persistence and visibility options.
- [`determinism.md`](knowledge/shared/determinism.md) — history replay, sources of non-determinism, the non-determinism worker policy, and the Workflow Shadower.
- [`patterns.md`](knowledge/shared/patterns.md) — signals, queries, child workflows, continue-as-new, saga, polling, fan-out, and workflow-as-state-machine.
- [`versioning.md`](knowledge/shared/versioning.md) — `workflow.GetVersion`, new workflow types, bad-binary reset, and a compatibility cheat sheet.
- [`pitfalls.md`](knowledge/shared/pitfalls.md) — anti-patterns, timeout misconfigurations, history-size limits, and identity traps.
- [`troubleshooting.md`](knowledge/shared/troubleshooting.md) — symptom-driven diagnosis with the CLI cheat sheet and recovery procedures.
- [`error-reference.md`](knowledge/shared/error-reference.md) — workflow-observable error types, the `Reason` convention, retry policy interaction, and client/server-side error types.

### Go SDK (`knowledge/go/`)

- [`getting-started.md`](knowledge/go/getting-started.md) — minimal Go worker + workflow + activity, anchored on the upstream samples.
- [`workflows.md`](knowledge/go/workflows.md) — full workflow API surface: context, activities, timers, signals, queries, child workflows, continue-as-new, versioning, side effects, cancellation, errors.
- [`activities.md`](knowledge/go/activities.md) — activity functions, retry policy, heartbeats, idempotency, local activities, async completion.
- [`workers.md`](knowledge/go/workers.md) — building the service client, `worker.Options` reference, pollers, sticky cache, topology patterns, graceful shutdown.
- [`testing.md`](knowledge/go/testing.md) — `testsuite` unit tests, replay tests, and the Workflow Shadower with CI integration patterns.
- [`observability.md`](knowledge/go/observability.md) — logging, metrics, tracing, context propagation, and the canonical `cadence-*` SDK metric catalogue.

### Java SDK (`knowledge/java/`)

- [`getting-started.md`](knowledge/java/getting-started.md) — minimal Java worker + workflow + activity using the annotation-based API (`@WorkflowMethod`, `@ActivityMethod`), `WorkflowClient`, and `WorkerFactory`, anchored on the upstream samples.
- [`workflows.md`](knowledge/java/workflows.md) — workflow API surface: `@WorkflowMethod` attributes, activity stubs, async via `Promise` and `Async`, signals, queries, child workflows, continue-as-new, versioning, side effects, cancellation scopes.
- [`activities.md`](knowledge/java/activities.md) — activity interfaces and implementations, `@ActivityMethod` and `@MethodRetry` attributes, `Activity.*` execution context, heartbeats, idempotency, local activities, async completion via `ActivityCompletionClient`.
- [`workers.md`](knowledge/java/workers.md) — `WorkflowClient`, `WorkerFactory`, `Worker`, the three layers of options (`WorkflowClientOptions`, `WorkerFactoryOptions`, `WorkerOptions`), pollers, sticky cache, topology patterns, graceful shutdown.
- [`testing.md`](knowledge/java/testing.md) — `TestWorkflowEnvironment` with virtual time and Mockito-friendly activity mocks, `TestActivityEnvironment` for activity-only unit tests, `WorkflowReplayer` for history replay tests, `WorkflowShadower` for production replay.
- [`observability.md`](knowledge/java/observability.md) — replay-safe SLF4J logging via `Workflow.getLogger`, the canonical `cadence-*` Tally metric catalog, OpenTracing via `WorkerOptions.setTracer`, `ContextPropagator` for request-scoped values, and worker identity for fleet correlation.

### Python SDK (`knowledge/python/`)

The Python SDK (`cadence-python-client`) is **alpha**; coverage in this skill reflects that and pins to the canonical repository.

- [`getting-started.md`](knowledge/python/getting-started.md) — minimal Python worker + workflow + activity, anchored on `cadence/sample/client_example.py`. Decorator-driven API (`@registry.workflow`, `@workflow.run`, `@registry.activity`) and async-first `Client` / `Worker`.
- [`workflows.md`](knowledge/python/workflows.md) — workflow class shape, `@workflow.run`, `workflow.execute_activity` with `ActivityOptions` and `RetryPolicy`, `workflow.sleep`, `workflow.wait_condition`, `@workflow.signal`, `@workflow.query`, `workflow.continue_as_new`, determinism rules, and an honest list of capabilities not yet in the alpha SDK (child workflows, side effects, versioning).
- [`activities.md`](knowledge/python/activities.md) — three registration idioms (`@registry.activity`, `@activity.defn` + `register_activity`, `@activity.method` + `register_activities`), sync vs async activities, `activity.info` / `activity.client` / `activity.heartbeat` / `activity.heartbeat_details`, idempotency, retries by reason string. Calls out the alpha gaps: no async completion, no cancellation-via-heartbeat, no local activities.
- [`workers.md`](knowledge/python/workers.md) — `Client`, `Registry`, and `Worker` as the three process-level objects; `ClientOptions` and `WorkerOptions` reference; async-context-managed lifecycle with `asyncio.Event` shutdown; topology patterns (single, split workflow/activity via `disable_*_worker`, multi-task-list, domain-per-tenant); starting workflows via `Client.start_workflow`. Flags absent capabilities (sticky cache tuning, worker factory, suspend/resume, health probe).
- [`testing.md`](knowledge/python/testing.md) — practical patterns given the alpha SDK ships no `TestWorkflowEnvironment` / `WorkflowReplayer` / `WorkflowShadower`: activity unit tests as plain Python functions, workflow integration tests via `pytest-docker` with per-test task-list isolation, history capture for assertions, two activity-mocking shapes, and the cluster-based determinism workflow.
- [`observability.md`](knowledge/python/observability.md) — standard `logging` for both worker and application code (with the alpha gap that workflow-side logs duplicate on replay), the `MetricsEmitter` protocol and built-in `PrometheusMetrics`, the canonical `cadence-*` metric catalog, gRPC interceptors for transport-level tracing, and worker identity for fleet correlation. Flags absent features (replay-aware logger and metrics scope, `is_replaying`, `ContextPropagator`, first-class tracer).

If the user mentions non-determinism, debugging stuck workflows, or workflow-code changes, jump to the relevant `shared/` file. For SDK-specific code, pick the directory that matches the language they are writing.

## Sources of truth

When this skill conflicts with an upstream source, the upstream source wins. Primary sources:

- Docs: <https://cadenceworkflow.io>
- Server: <https://github.com/cadence-workflow/cadence>
- Go SDK: <https://github.com/cadence-workflow/cadence-go-client>
- Go API reference: <https://pkg.go.dev/go.uber.org/cadence>
- Go samples: <https://github.com/cadence-workflow/cadence-samples>
- Java SDK: <https://github.com/cadence-workflow/cadence-java-client>
- Java samples: <https://github.com/cadence-workflow/cadence-java-samples>
- Python SDK: <https://github.com/cadence-workflow/cadence-python-client>
