# Observability

All of this is vendor-neutral OpenTelemetry: the upstream
`opentelemetry-collector` Helm chart, the official `otel/opentelemetry-collector-k8s`
distribution, OTLP on every hop, and semantic-convention attributes. SigNoz and
LGTM are just two OTLP endpoints at the end.

```
 COLLECTION LAYER (agents)                               GATEWAY LAYER
 internal / stg / prod, each:                            management:
 ┌───────────────────────────────────────┐             ┌────────────────────────────┐
 │ apps ─OTLP─► otel-agent               │             │ otel-gateway (2 replicas)  │──► SigNoz (signoz ns)
 │              DaemonSet, 1 per node    │  OTLP gRPC  │  NodePort 30317 / 30318    │
 │              kubelet stats, pod logs  │ ──────────► │  receives from every       │
 │ otel-k8s-state                        │             │  cluster, fans out to all  │──► LGTM (Compose, lgtm:4318)
 │   Deployment, 1 per cluster           │             │  backends, own queue each  │
 │   k8s object state, events (k8s API)  │             └────────────────────────────┘
 └───────────────────────────────────────┘
```

**Terminology** (from the OpenTelemetry Collector deployment docs):

- **Agent:** a collector next to the workload (here a DaemonSet, one per
  node). `otel-k8s-state` belongs to the same per-cluster collection layer.
  It's a single replica because Kubernetes object state and events must be
  read from the API exactly once per cluster.
- **Gateway:** standalone collector replicas behind one endpoint. They
  receive from agents and do central processing (fan-out, sampling, routing).
  That's `otel-gateway`.
- **Collector fleet:** all of the above together.

| Layer | Where | Does | Config |
| --- | --- | --- | --- |
| `otel-agent` | each workload cluster, DaemonSet | App OTLP, kubelet stats, pod logs, `k8sattributes` | `observability/otel-agent/values.yaml` |
| `otel-k8s-state` | each workload cluster, 1 replica | Kubernetes object state (`k8s_cluster`: replicas, pod phases, restarts, node conditions) and events, from the API, exactly once per cluster | `observability/otel-k8s-state/values.yaml` |
| `otel-gateway` | management, 2 replicas | Only layer that knows the backends; fans out to all of them | `observability/otel-gateway/values.yaml` |
| SigNoz | management, `signoz` ns | Backend (ClickHouse) | `observability/signoz/values.yaml` |
| LGTM | Compose `lgtm` | Backend (Grafana, Loki, Tempo, Prometheus) | `docker-compose.yaml` |

**Why per-cluster collectors plus a central gateway:** kubelet stats, pod
logs and `k8sattributes` only work from inside the cluster. Backends,
credentials, sampling and fan-out belong in one place, so changing a backend
is a single file (`otel-gateway/values.yaml`), not three clusters.

**Environment identity:** each collector stamps `k8s.cluster.name` and
`deployment.environment.name` (`internal`/`stg`/`prod`) from the
ApplicationSet. Filter on those in either UI. Apps don't set them.

**Instrumenting an app:** use the OpenTelemetry SDK and the standard env vars
(see `apps/queue-consumer/base/deployment.yaml`):
`OTEL_EXPORTER_OTLP_ENDPOINT=http://$(NODE_IP):4318`, `OTEL_SERVICE_NAME`,
`OTEL_RESOURCE_ATTRIBUTES` (add `k8s.pod.uid` from the downward API so the agent can match the pod reliably).
Keep the environment out of `service.name`: one `queue-consumer` service,
filtered by `deployment.environment.name`.

Send **cumulative** metrics (OTel's default). Prometheus in LGTM drops delta
sums. SigNoz accepts both.

**Try it from the host:** the gateway is also published on `localhost:4317`/`4318`:

```bash
docker run --rm --network host ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 20 --service telemetrygen
```

Then look for `telemetrygen` in SigNoz (http://localhost:3301) and in Grafana →
Explore → Tempo (http://localhost:3000).

**Footprint:** SigNoz (ClickHouse + ZooKeeper) plus LGTM add several GiB on
top of the four k3s nodes. Give Docker 12-16 GiB.
