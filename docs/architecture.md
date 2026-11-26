# Architecture

## Clusters and bootstrap

Four single-node k3s clusters in Docker: **management** runs the platform
(Argo CD, plus the observability stack in [observability.md](observability.md)), and
**internal / stg / prod** run the workloads. Keeping Argo CD on its own
cluster means losing a workload cluster never takes down the thing that
manages it.

`docker compose up -d` does everything, with no scripts:

1. Each k3s container auto-applies its `manifests/<cluster>/`, which is
   bind-mounted in.
2. k3s installs Argo CD on management from `argocd/helmchart.yaml`.
3. `argocd-bootstrap` registers internal/stg/prod with Argo CD and applies
   `argocd/root-app.yaml`. From then on, Argo CD manages everything from git.

For IPs, ports, DNS and traffic flows, see [network.md](network.md).

There's no `kubectl` on the host. Each cluster ships its own:
`docker exec k3s-<cluster> kubectl …`.

## Namespaces

| Namespace        | Clusters            | Notes                                              |
| ---------------- | ------------------- | -------------------------------------------------- |
| `queue-consumer` | internal, stg, prod | The workload: 1 / 2 / 3 replicas                   |
| `observability`  | all four            | OTel agents (workload clusters), OTel gateway (management) |
| `argocd`         | management          | Argo CD                                            |
| `signoz`         | management          | SigNoz + ClickHouse                                |

**One namespace per app, not per environment.** Each cluster is one
environment, so names have no stage suffix: queue-consumer lives in
`queue-consumer` on every cluster. Telemetry tells environments apart by
`deployment.environment.name`, which the otel-agent stamps. A per-env
namespace (`queue-consumer-prod`) only makes sense when several
environments share a cluster.

Each namespace gets its own ResourceQuota, LimitRange and NetworkPolicy
(`manifests/<cluster>/`), sized per environment.

## Argo CD (`argocd/`)

| File                          | What                                                     |
| ----------------------------- | -------------------------------------------------------- |
| `helmchart.yaml`              | Argo CD itself, installed by k3s                         |
| `root-app.yaml`               | App of apps: syncs everything else in `argocd/`          |
| `clusters-appset.yaml`        | `manifests/<cluster>/` per cluster                       |
| `otel-collectors-appset.yaml` | otel-agent + otel-k8s-state per workload cluster         |
| `otel-gateway.yaml`           | OTel gateway on management (2 replicas)                  |
| `signoz.yaml`                 | SigNoz on management                                     |
| `queue-consumer-appset.yaml`  | queue-consumer, one Application per stage                |
| `projects/`                   | AppProjects: `platform` (cluster-scoped), `queue-consumer` (own namespace only) |

## queue-consumer

[queue-consumer](https://github.com/glexposito/queue-consumer) is a Rust
background worker instrumented with the OpenTelemetry SDK. Each fake message
it processes is one consumer trace plus a `messages.processed` counter, and
it logs to stdout.

| Stage    | Replicas | Overlay                                |
| -------- | -------- | -------------------------------------- |
| internal | 1        | `apps/queue-consumer/overlays/internal` |
| stg      | 2        | `apps/queue-consumer/overlays/stg`      |
| prod     | 3        | `apps/queue-consumer/overlays/prod`     |

The base sets only standard `OTEL_*` env vars, identical on every stage. It
sends to the node-local otel-agent, which adds the environment. The image is
built and pushed to `ghcr.io/glexposito/queue-consumer` by that repo's
`publish` workflow. Each overlay pins it under `images:`.
