# Network topology

All long-running containers share Docker bridge `k8s-management`
(`172.28.0.0/24`) and have fixed addresses. Cross-cluster traffic always uses
a node address and an API port or NodePort; no cluster relies on another
cluster's pod or Service CIDR.

| Container | IP | Role |
| --- | --- | --- |
| `k3s-internal` | `172.28.0.101` | Workload cluster |
| `k3s-stg` | `172.28.0.102` | Workload cluster |
| `k3s-prod` | `172.28.0.103` | Workload cluster |
| `k3s-management` | `172.28.0.104` | Argo CD, gateway, SigNoz |
| `lgtm` | `172.28.0.105` | Grafana/Loki/Tempo/Prometheus |
| `argocd-bootstrap` | dynamic | One-shot registration client |

k3s uses its default pod (`10.42.0.0/16`) and Service (`10.43.0.0/16`)
CIDRs in every cluster. Overlap is safe because flannel masquerades pod egress
behind the node address and cross-cluster traffic does not use those CIDRs.

## Host access

| Host port | Target | Purpose |
| --- | --- | --- |
| `3301` | management `:30301` | SigNoz UI |
| `3000` | lgtm `:3000` | Grafana |
| `9000` | management `:30090` | Argo CD UI/API (HTTPS) |
| `4317`, `4318` | management `:30317`, `:30318` | Gateway OTLP gRPC / HTTP |
| `6447` | management `:6443` | Management Kubernetes API |
| `6444`, `6446`, `6445` | internal, stg, prod `:6443` | Workload Kubernetes APIs |

LGTM's OTLP ports remain private; host traffic uses the gateway.

## DNS

Docker containers can resolve each other through Docker DNS, but pods use
CoreDNS. The `coredns-custom` manifests bridge that difference:

| Cluster | File | Names resolved |
| --- | --- | --- |
| management | `local/k3s/management/cluster-dns.yaml` | workload k3s hosts and `lgtm` |
| internal, stg, prod | `local/k3s/workload/cluster-dns.yaml` | `k3s-management` |

`argocd-bootstrap` is itself on the Docker bridge and needs no override.

## Required flows

| From | To | Port | Reason |
| --- | --- | --- | --- |
| Argo CD / bootstrap | cluster APIs | 6443 | Register and sync clusters |
| Argo CD repo-server; kubelets | GitHub, Helm repositories, GHCR | 443 out | Fetch charts, manifests, and image |
| queue-consumer | node-local collector | 4318 | App traces and metrics |
| collectors | management gateway | 30317 | OTLP gRPC |
| gateway | SigNoz / LGTM | 4317 / 4318 | OTLP fan-out |
| node collector | `/var/log/pods` | local | Pod logs |

## NetworkPolicies

Policies are ingress-only; egress is unrestricted. Every governed namespace
is default-deny except same-namespace traffic and these explicit needs:

| Namespace | Extra ingress | Reason |
| --- | --- | --- |
| `queue-consumer` | none | Worker makes outbound calls only |
| `otel-collectors` | TCP 4317/4318 from all sources | Apps send to node collectors |
| `otel-gateway` | TCP 4317/4318 from all sources | Cross-cluster NodePort traffic is masqueraded |
| `argocd` | none | UI arrives through its NodePort |
| `signoz` | no policy | Gateway and UI require ingress |

k3s enforces these policies through its embedded kube-router.
