# Observability

All of this is vendor-neutral OpenTelemetry: the upstream
`opentelemetry-collector` Helm chart, the official `otel/opentelemetry-collector-k8s`
distribution, OTLP on every hop, and semantic-convention attributes. SigNoz and
LGTM are just two OTLP endpoints at the end.

```
 COLLECTION LAYER                                        GATEWAY LAYER
 internal / stg / prod, each:                            management:
 ┌───────────────────────────────────────┐             ┌────────────────────────────┐
 │ apps ─OTLP─► otel-collector           │             │ otel-gateway (2 replicas)  │──► SigNoz (signoz ns)
 │              DaemonSet, 1 per node    │  OTLP gRPC  │  NodePort 30317 / 30318    │
 │              kubelet stats, pod logs  │ ──────────► │  receives from every       │
 │ otel-collector-cluster                │             │  cluster, fans out to all  │──► LGTM (Compose, lgtm:4318)
 │   Deployment, 1 per cluster           │             │  backends, own queue each  │
 │   k8s object state, events (k8s API)  │             └────────────────────────────┘
 └───────────────────────────────────────┘
```

**The three collectors.** All three are the same software (the
OpenTelemetry Collector). The two per-cluster ones are named and set up
exactly as in OpenTelemetry's
[Kubernetes getting-started guide](https://opentelemetry.io/docs/platforms/kubernetes/getting-started/),
which installs "two installations of the collector, one as a Daemonset and
one as a Deployment": `otel-collector` and `otel-collector-cluster`.

| Name | Runs | Looks at |
| --- | --- | --- |
| `otel-collector` | One per node of each workload cluster (DaemonSet; the chart names its pods `otel-collector-agent-…`) | Its own node: the apps' traces, metrics and logs, plus CPU/memory (kubelet stats) and pod logs |
| `otel-collector-cluster` | One per workload cluster (Deployment, 1 replica) | The Kubernetes API: replicas, restarts, pod phases, node conditions, events. Like kube-state-metrics does for Prometheus. One replica, because a second would report everything twice |
| `otel-gateway` | On management (2 replicas) | Nothing itself: it receives from every collector in every cluster and forwards to SigNoz and LGTM |

Why two per cluster: node data (kubelet stats, pod log files, app OTLP) only
exists on each node, so it needs a collector per node; cluster data (the
Kubernetes API) is the same everywhere, so it must be read exactly once - in
the guide's words, "a deployment with exactly one replica ensures that we
don't produce duplicate data".

The gateway is not in the guide; it's OpenTelemetry's optional
[gateway pattern](https://opentelemetry.io/docs/collector/deploy/gateway/)
(standalone replicas behind one endpoint, doing central processing). It
costs one more component to run, and this repo uses it so that SigNoz and
LGTM get identical data and backends are configured in one file. In the
docs' terms, `otel-collector` is an
[agent](https://opentelemetry.io/docs/collector/deploy/agent/): a collector
next to the workload.

**When the gateway earns its place, and when it doesn't.** Keep it when any
of these holds:

- **More than one backend**, or one you might swap: one place fans out, so
  every backend gets identical data (the reason here).
- **Backends you don't want every cluster to reach:** without a gateway,
  every cluster needs network access and credentials (API keys) for every
  backend. With it, only the gateway does.
- **Central processing:** tail sampling, redacting sensitive data, dropping
  noisy telemetry. These need one place that sees whole traces from all
  collectors ("For use cases where telemetry data must be processed in a
  specific Collector, use a two-tiered setup", OpenTelemetry's gateway page).

Drop it when there's a single backend, reachable from each cluster with simple
auth, and no central processing: then it's only an extra hop that can fail.
The collectors export straight to the backend, and the gateway can come back
when a second backend or sampling does.

| Layer | Where | Does | Config |
| --- | --- | --- | --- |
| `otel-collector` | each workload cluster, DaemonSet | App OTLP, kubelet stats, pod logs, `k8sattributes` | `gitops/platform/observability/otel-collector/` |
| `otel-collector-cluster` | each workload cluster, 1 replica | Kubernetes object state (`k8s_cluster`: replicas, pod phases, restarts, node conditions) and events, from the API, exactly once per cluster | `gitops/platform/observability/otel-collector-cluster/` |
| `otel-gateway` | management, 2 replicas | Only layer that knows the backends; fans out to all of them | `gitops/platform/observability/otel-gateway/` |
| SigNoz | management, `signoz` ns | Backend (ClickHouse) | `gitops/platform/observability/signoz/` |
| LGTM | Compose `lgtm` | Backend (Grafana, Loki, Tempo, Prometheus) | `local/compose.yaml` |

**Why per-cluster collectors plus a central gateway:** kubelet stats, pod
logs and `k8sattributes` only work from inside the cluster. Backends,
credentials, sampling and fan-out belong in one place, so changing a backend
is a single file (`otel-gateway/values.yaml`), not three clusters.

**Environment identity:** each collector stamps `k8s.cluster.name` (the
cluster's name) and `deployment.environment.name` (its
`platform.example.com/environment` label: `internal`/`stg`/`prod`), both from
the cluster's Argo CD cluster Secret via the ApplicationSet. They're separate
on purpose: two prod clusters share the environment, not the name. Filter on
those in either UI. Apps don't set them.

**Ownership:** the otel-collector also copies the namespace's
`platform.example.com/team` and `platform.example.com/cost-center` labels onto
every signal from that namespace, as `com.example.team` and
`com.example.cost_center` (custom attributes get a reverse-domain prefix, per
the OpenTelemetry spec). In Prometheus they show up as `com_example_team` and
`com_example_cost_center` on `target_info`.

**Instrumenting an app:** use the OpenTelemetry SDK and the standard env vars
(see `gitops/apps/queue-consumer/base/deployment.yaml`):
`OTEL_EXPORTER_OTLP_ENDPOINT=http://$(NODE_IP):4318`, `OTEL_SERVICE_NAME`,
`OTEL_RESOURCE_ATTRIBUTES` (add `k8s.pod.uid` from the downward API so the agent can match the pod reliably).
Keep the environment out of `service.name`: one `queue-consumer` service,
filtered by `deployment.environment.name`.

Send **cumulative** metrics (OTel's default). Prometheus in LGTM drops delta
sums. SigNoz accepts both.

**Try it from the host:** the gateway is also published on `127.0.0.1:4317`/`4318`:

```bash
docker run --rm --network host ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-insecure --otlp-endpoint 127.0.0.1:4317 --traces 20 --service telemetrygen
```

Then look for `telemetrygen` in SigNoz (http://127.0.0.1:3301) and in Grafana →
Explore → Tempo (http://127.0.0.1:3000).

**Span metrics:** the otel-collector's `span_metrics` connector turns every span
into the standard `traces.span.metrics.calls` / `.duration` series (Prometheus:
`traces_span_metrics_calls_total`, `traces_span_metrics_duration_milliseconds_*`).
Both backends get the same rate, error and duration series, split by
environment. It runs in the agent, not the gateway: a pod's spans always reach
its own node's agent, so each series has a single producer.

## Dashboards

`gitops/platform/observability/dashboards/` holds a **queue-consumer overview** dashboard for
each backend. Same panels, same `environment` variable:

| Row | Panels |
| --- | --- |
| Rate, errors, duration | messages/s, `do_work` error ratio, p50/p95/p99 duration |
| Workload health | replicas available vs desired, CPU and memory per pod vs limits, restarts, pod phase |
| What's happening | queue-consumer logs, Kubernetes warning events, recent `do_work` traces |

| Backend | Files | How it loads |
| --- | --- | --- |
| Grafana | `dashboards/grafana/` | Bind-mounted into the `lgtm` container as a provisioning provider. Rescanned every 30 s, so a JSON edit shows up with no restart. |
| SigNoz | `dashboards/signoz/` | **Imported by hand** (Dashboards → New dashboard → Import JSON). SigNoz has no file provisioning: its built-in dashboards are compiled into the binary, and everything else goes through its API. Steps in `dashboards/signoz/README.md`. |

Git is the source of truth for both. Grafana enforces it (`allowUiUpdates:
false`); for SigNoz, export the JSON after editing in the UI and commit it.
The two use different query languages over the same data: PromQL/LogQL/TraceQL
in Grafana, where Prometheus rewrites names (`messages.processed` →
`messages_processed_total`), and SigNoz's query builder, which keeps the
OpenTelemetry names.

SigNoz's admin (`admin@playground.local`, from `signoz_user_root_*` in
`gitops/platform/observability/signoz/values-local.yaml`) only exists on a fresh SigNoz database. If
SigNoz was set up through its sign-up page first, reset with
`docker compose down -v`.

**Footprint:** SigNoz (ClickHouse + ZooKeeper) plus LGTM add several GiB on
top of the four k3s nodes. Give Docker 12-16 GiB.

## Sources

OpenTelemetry:

- [Getting started with Kubernetes](https://opentelemetry.io/docs/platforms/kubernetes/getting-started/):
  the two collectors and their names. "we'll need two installations of the
  collector, one as a Daemonset and one as a Deployment"; "A deployment with
  exactly one replica ensures that we don't produce duplicate data."
- [Collector deployment: agent](https://opentelemetry.io/docs/collector/deploy/agent/):
  "a Collector instance that runs alongside the application or on the same
  host, such as a sidecar or DaemonSet."
- [Collector deployment: gateway](https://opentelemetry.io/docs/collector/deploy/gateway/):
  the optional central tier, and its cost: "It's one more thing to maintain
  and that can fail (complexity)."
- [opentelemetry-collector Helm chart README](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/main/charts/opentelemetry-collector/README.md):
  the presets used here. Pod logs need the DaemonSet ("It needs agent
  collector to be deployed"); cluster metrics need "A single active instance",
  with leader election when there are more replicas.
- [k8sattributes processor README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/k8sattributesprocessor/README.md):
  extracting namespace labels (`extract.labels` with `from: namespace`), used
  for `com.example.team` / `com.example.cost_center`.
- [Semantic conventions → Naming](https://opentelemetry.io/docs/specs/semconv/general/naming/):
  custom attribute names get a prefix, "your company's reverse domain name",
  hence `com.example.*`.
