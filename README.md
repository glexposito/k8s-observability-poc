# k8s-observability-poc

A throwaway local **Kubernetes observability playground**. Four k3s clusters
run in Docker, with real workloads producing real signals. One vendor-neutral
**OpenTelemetry** pipeline collects metrics, logs and traces from every
environment and sends the same data to two backends side by side: **SigNoz**
and **Grafana LGTM**. KISS.

## Goals

- **Learn and compare Kubernetes observability** on something shaped like a
  real platform: a management cluster plus internal/stg/prod.
- **Standard OpenTelemetry only:** the upstream collector chart and k8s
  distribution, OTLP on every hop, semantic-convention attributes
  (`k8s.cluster.name`, `deployment.environment.name`). No vendor agents.
- **Backend-agnostic:** SigNoz and LGTM get identical data, so you can compare
  them fairly. Adding or swapping a backend means editing one file.
- **A real instrumented workload:** [queue-consumer](https://github.com/glexposito/queue-consumer),
  a Rust worker using the OTel SDK, runs in every environment (1 / 2 / 3 replicas).
- **Everything through GitOps:** Argo CD on management deploys all of it from
  this repo.

## TL;DR

```bash
docker compose up -d      # first start takes a few minutes (SigNoz the longest)
```

You only need Docker, with about 12-16 GiB of RAM for it.

| UI           | URL                         | Login           |
| ------------ | --------------------------- | --------------- |
| SigNoz       | http://localhost:3301       | `admin@playground.local` / `Playground123!` |
| Grafana (LGTM) | http://localhost:3000     | `admin` / `admin` |
| Argo CD      | https://localhost:9000      | `admin` / `123` |

## What runs where

```
 internal / stg / prod (each)                        management
 ┌─────────────────────────────────────┐            ┌─────────────────────────────┐
 │ queue-consumer                      │            │ Argo CD ── syncs everything │
 │ otel-agent      1 per node          │ ─ OTLP ──► │ otel-gateway (2 replicas) ──┼──► SigNoz (in-cluster)
 │ otel-k8s-state  1 per cluster       │            │                             │──► LGTM (Compose)
 └─────────────────────────────────────┘            └─────────────────────────────┘
   collection layer (agents)                          gateway layer
```

| Cluster    | API              | Runs                                          |
| ---------- | ---------------- | --------------------------------------------- |
| management | `localhost:6447` | Argo CD, otel-gateway, SigNoz                 |
| internal   | `localhost:6444` | queue-consumer (1 replica), OTel collectors   |
| stg        | `localhost:6446` | queue-consumer (2 replicas), OTel collectors  |
| prod       | `localhost:6445` | queue-consumer (3 replicas), OTel collectors  |

One namespace per app (`queue-consumer`, `observability`), the same on every
cluster. The cluster is the environment boundary, and telemetry carries it as
`deployment.environment.name`.

## Try it

queue-consumer emits a trace and a `messages.processed` count every 5 seconds
per replica, so prod should show about 3x internal's rate.

- **Dashboard "queue-consumer overview"**: Grafana loads it from git
  (Dashboards → k8s-observability-poc). For SigNoz, import
  `observability/dashboards/signoz/queue-consumer-overview.json` once per fresh
  stack (Dashboards → New dashboard → Import JSON)
- **SigNoz → Services → `queue-consumer`**: switch environments, compare throughput
- **Grafana → Explore → Tempo**: service `queue-consumer`, span `do_work`
- **Grafana → Explore → Prometheus**: `rate(messages_processed_total[1m])` (resource attributes like the environment sit on `target_info`)
- **Grafana → Explore → Loki**: `{k8s_namespace_name="queue-consumer"}` (stdout, shipped by the otel-agent)

```bash
docker exec k3s-prod kubectl -n queue-consumer get pods
docker exec k3s-prod kubectl -n queue-consumer scale deploy/queue-consumer --replicas=5   # Argo CD reverts it (selfHeal)
```

Send synthetic traces straight to the gateway:

```bash
docker run --rm --network host ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 20 --service telemetrygen
```

## Tear down

```bash
docker compose down       # keep state
docker compose down -v    # wipe everything
```

## Docs

- [observability.md](docs/observability.md): OpenTelemetry agents and gateway, SigNoz, LGTM
- [network.md](docs/network.md): Docker network, fixed IPs, ports, DNS overrides, traffic flows, NetworkPolicies
- [architecture.md](docs/architecture.md): clusters, namespaces, Argo CD, queue-consumer
- [kustomize-conventions.md](docs/kustomize-conventions.md): the Kustomize standard
- [namespaces.md](docs/namespaces.md): what gets its own namespace, per Google's GKE multi-tenancy guidance
