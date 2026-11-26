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

**Span metrics:** the otel-agent's `span_metrics` connector turns every span
into the standard `traces.span.metrics.calls` / `.duration` series (Prometheus:
`traces_span_metrics_calls_total`, `traces_span_metrics_duration_milliseconds_*`).
Both backends get the same rate, error and duration series, split by
environment. It runs in the agent, not the gateway: a pod's spans always reach
its own node's agent, so each series has a single producer.

## Dashboards

`observability/dashboards/` holds a **queue-consumer overview** dashboard for
each backend. Same panels, same `environment` variable:

| Row | Panels |
| --- | --- |
| Rate, errors, duration | messages/s, `do_work` error ratio, p50/p95/p99 duration |
| Workload health | replicas available vs desired, CPU and memory per pod vs limits, restarts, pod phase |
| What's happening | queue-consumer logs, Kubernetes warning events, recent `do_work` traces |

| Backend | Files | How it loads |
| --- | --- | --- |
| Grafana | `dashboards/grafana/` | Bind-mounted into the `lgtm` container as a provisioning provider. Rescanned every 30 s, so a JSON edit shows up with no restart. |
| SigNoz | `dashboards/signoz/` | SigNoz has no file provisioning. The `signoz-dashboards` Argo CD app turns the JSON into a ConfigMap, and a PostSync Job imports it through the v2 API as the config-defined admin (`signoz_user_root_*` in `observability/signoz/values.yaml`). Re-runs on every git change. |

Both are **read-only in the UI** (Grafana `allowUiUpdates: false`, SigNoz
dashboards locked by the import). To change one, edit the JSON and commit.
The two use different query languages over the same data: PromQL/LogQL/TraceQL
in Grafana, where Prometheus rewrites names (`messages.processed` →
`messages_processed_total`), and SigNoz's query builder, which keeps the
OpenTelemetry names.

The SigNoz admin only exists on a fresh SigNoz database. If SigNoz was set up
through its sign-up page first, reset with `docker compose down -v`.

**Footprint:** SigNoz (ClickHouse + ZooKeeper) plus LGTM add several GiB on
top of the four k3s nodes. Give Docker 12-16 GiB.
