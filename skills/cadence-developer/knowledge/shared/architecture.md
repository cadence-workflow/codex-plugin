# Cadence Server architecture

A Cadence cluster is a small set of cooperating services backed by one (or two) data stores. You can run all of them in a single process for development, or scale each independently in production.

## Core services

Cadence Server runs four logical services. Each can run in its own process or all of them can be hosted in one process; service names are fixed.

- **`cadence-frontend`** — the API gateway. All SDK clients and the CLI talk to the frontend. It handles authentication, request validation, rate limiting, and routes work to the right backend service. Externally exposed.
- **`cadence-history`** — owns durable workflow state. Stores and serves the event history of every workflow execution. Sharded by workflow ID across history hosts.
- **`cadence-matching`** — owns task list state. Holds the in-memory queue of workflow tasks (decision tasks) and activity tasks waiting to be picked up by workers. Workers poll matching, not the frontend.
- **`cadence-worker`** — the *system* worker. Runs Cadence's internal workflows (cross-cluster replication, archival, system maintenance). Distinct from the worker processes you operate as a Cadence user.

A newer optional service is **`cadence-shard-distributor`**, which manages shard ownership and leader election across the history and matching hosts. Most existing deployments still rely on the legacy hash-ring approach inside each service.

## Default ports

| Endpoint | Default port |
| --- | --- |
| Frontend TChannel | 7933 |
| Frontend gRPC | 7833 |
| History service membership | 7934 |
| Matching service membership | 7935 |
| Shard distributor RPC (if enabled) | 7941 |
| Shard distributor pprof (if enabled) | 7942 |
| Shard distributor gRPC (if enabled) | 7943 |

Bootstrap hosts in development configs typically list `127.0.0.1:7933,7934,7935`. SDKs connect to the frontend port; the YARPC service name is `cadence-frontend`.

## Persistence

Cadence stores its durable state in a single relational/columnar database. Supported backends (each enabled via a plugin compiled into `cadence-server`):

- **Cassandra** — the original and most battle-tested backend; the default in many production deployments.
- **MySQL** — supported via the SQL plugin.
- **PostgreSQL** — supported via the SQL plugin.
- **SQLite** — supported for local development and small single-node deployments.

Conceptually, the persistence layer keeps:

- **Execution store** — current state of every workflow execution: status, last event, in-flight activities, timers.
- **History store** — append-only event history per workflow, the canonical log used during replay.
- **Task store** — pending workflow and activity tasks that matching has not yet handed to a worker.
- **Shard store** — ownership and consistency metadata for the cluster's shards.
- **Domain store** — registered domains and their configuration.

Schema migrations are managed via the `cadence-cassandra-tool` and `cadence-sql-tool` binaries shipped in the cadence repo's `tools/` directory.

## Visibility

Listing and searching workflow executions (`cadence ... workflow list`, the Cadence Web search UI) is served from a separate **visibility** store. Three deployment shapes are common:

- **Basic visibility** — uses the same persistence backend as core state. Adequate for small deployments; limited query support.
- **Elasticsearch / OpenSearch** — an indexed visibility store that supports the full search-attribute query language. The most common production choice.
- **Pinot** — used by some larger deployments for analytic-style queries over visibility data.

Search attributes (custom typed fields you tag on workflows) require an advanced visibility store. Without one, you can still list workflows by ID, type, and status, but custom search attributes are unavailable.

## Deployment topologies

**Single-process development.** All four services run in one `cadence-server start` process backed by SQLite or a single Cassandra/MySQL/PostgreSQL instance. The repo's `docker/docker-compose.yml` brings this up alongside Cadence Web and a database container.

**Multi-host production.** Each service is deployed as its own group of pods/containers. Frontend hosts sit behind a load balancer; history and matching hosts form hash rings keyed by shard ID; the system worker runs a small fleet. Persistence and visibility are each pointed at managed clusters (Cassandra, RDS, OpenSearch, etc.).

**Multi-cluster (cross-DC replication).** Two or more Cadence clusters run in different regions, each with its own persistence. Domains can be configured as **active-passive** (one cluster owns writes, others mirror) or **active-active** (all clusters accept writes for the domain). Replication is driven by the `cadence-worker` system service. The `development_xdc_cluster*.yaml` configs in the cadence repo illustrate a three-cluster topology.

## Archival

Completed workflow histories can be **archived** to long-term storage to keep the active history store small. Two archival sinks ship in the server: filestore and Google Cloud Storage; community plugins exist for S3. Archival is enabled per domain and can be configured independently for history and visibility. When archived workflows are queried, Cadence transparently reads from the archival store.

## How an SDK call flows

A worker polling for work touches the cluster like this:

1. The worker opens a long poll against the frontend's gRPC or TChannel port.
2. Frontend forwards the poll to the matching service that owns the task list.
3. When a task becomes available (because some other process started a workflow or completed an activity), matching returns it to the frontend, which returns it to the worker.
4. The worker executes the workflow or activity code.
5. The worker reports the result back through the frontend; frontend routes the response to the history service, which appends the resulting events to the workflow's history.

The frontend is the only service an end-user SDK or CLI ever directly addresses.

## Sources of truth

- Service names: `cadence-workflow/cadence` → `common/service/name.go`
- Default ports and topology: `cadence-workflow/cadence` → `config/development.yaml`
- Persistence plugin registration: `cadence-workflow/cadence` → `cmd/server/main.go`
- Visibility deployment examples: `cadence-workflow/cadence` → `config/development_es_*.yaml`, `config/development_pinot.yaml`
- XDC configuration: `cadence-workflow/cadence` → `config/development_xdc_cluster*.yaml`
- Operator setup guide: <https://cadenceworkflow.io/docs/operation-guide/setup>
