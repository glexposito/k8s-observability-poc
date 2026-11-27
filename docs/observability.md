# Observability

The platform uses OpenTelemetry end-to-end. Every workload cluster collects
telemetry locally and sends it by OTLP to a gateway on management; the gateway
fans it out to SigNoz and the local LGTM stack.

```
internal / stg / prod                         management
apps ─► node collector ────────────────┐
cluster collector ─────────────────────┼──► OTel gateway ─► SigNoz
                                       │                  └► LGTM
```

| Component | Runs | Responsibility | Configuration |
| --- | --- | --- | --- |
| `otel-collector` | DaemonSet, workload clusters | App OTLP, kubelet metrics, pod logs, namespace attributes | `platform/observability/otel-collector/` |
| `otel-collector-cluster` | One replica, workload clusters | Kubernetes object state and events from the API | `platform/observability/otel-collector-cluster/` |
| `otel-gateway` | Two replicas, management | Central fan-out and backend configuration | `platform/observability/otel-gateway/` |
| SigNoz | management, `signoz` | Production-like OTLP backend | `platform/observability/signoz/` |
| LGTM | Docker Compose | Grafana, Loki, Tempo, Prometheus playground backend | `local/compose.yaml` |

The node collector must run on every node because logs, kubelet metrics, and
node-local app traffic are local. The cluster collector must have one active
replica because every replica would report the same Kubernetes API state.

## Why the gateway exists

The gateway is the only component configured with backend endpoints. This
keeps credentials, backend changes, fan-out, and future central processing in
one place while ensuring both backends receive the same data.

Keep it when there are multiple backends, backends should not be reachable
from every cluster, or central processing such as sampling/redaction is
needed. With one simply reachable backend and no central processing, remove
the gateway and export from the collectors directly.

## Resource identity and app instrumentation

ApplicationSets pass the cluster name and environment label to collectors.
They stamp every signal with:

- `k8s.cluster.name`: the individual cluster;
- `deployment.environment.name`: `internal`, `stg`, or `prod`;
- `com.example.team` and `com.example.cost_center`: copied from namespace
  ownership labels.

Keep the environment out of `service.name`; one logical service should be
filtered by its environment attribute. In Prometheus, the custom attributes
appear with underscores on `target_info`.

Apps use the standard SDK variables. The queue consumer is the reference
deployment:

```text
OTEL_EXPORTER_OTLP_ENDPOINT=http://$(NODE_IP):4318
OTEL_SERVICE_NAME=<service>
OTEL_RESOURCE_ATTRIBUTES=...k8s.pod.uid=...
```

Use cumulative metrics (the OpenTelemetry default): Prometheus in LGTM drops
delta sums, while SigNoz accepts both. The node collector produces span
metrics so each pod's series has one producer.

To send a quick host-side test trace:

```bash
docker run --rm --network host ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-insecure --otlp-endpoint 127.0.0.1:4317 --traces 20 --service telemetrygen
```

Find it in SigNoz at <http://127.0.0.1:3301> or Grafana Tempo at
<http://127.0.0.1:3000>.

## Dashboards and local operations

Both backends have a queue-consumer overview dashboard for rate, errors and
duration; workload health; and recent logs, warning events, and traces.

| Backend | Dashboard source | Loading |
| --- | --- | --- |
| Grafana | `local/lgtm/dashboards/` | Provisioned from the bind mount and rescanned every 30 seconds |
| SigNoz | `local/signoz/dashboards/` | Imported manually; see its `README.md` |

Git is the source of truth: Grafana disallows UI updates, while SigNoz edits
must be exported and committed. They live in `local/` because neither is
currently Argo CD-managed. A real platform should sync dashboard resources
from `gitops/`.

SigNoz's supplied admin account works only on a fresh database. If first-use
sign-up was completed instead, reset the playground with `docker compose down
-v`. SigNoz plus LGTM needs roughly 12–16 GiB of Docker memory in addition to
the k3s nodes.

## Sources

- [OpenTelemetry on Kubernetes](https://opentelemetry.io/docs/platforms/kubernetes/getting-started/)
- [Agent deployment](https://opentelemetry.io/docs/collector/deploy/agent/) and [gateway deployment](https://opentelemetry.io/docs/collector/deploy/gateway/)
- [Collector Helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector), [k8sattributes processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor), and [semantic-convention naming](https://opentelemetry.io/docs/specs/semconv/general/naming/)
