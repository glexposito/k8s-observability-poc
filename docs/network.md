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

## Local playground versus production

The Docker port mappings and explicit NodePorts are local scaffolding, not the
normal public interface of a production workload.

| Concept | This playground | Production expectation |
| --- | --- | --- |
| `ClusterIP` Service | A virtual `10.43.0.0/16` address, reachable only inside its k3s cluster | Same: use it for application-to-application traffic |
| Pod IP | A `10.42.0.0/16` address, reachable only inside its k3s cluster | Same: clients never target Pods directly |
| NodePort | Fixed ports such as gateway `30317`, reached at `k3s-management:30317` | May be an implementation detail of a load balancer; clients should not depend on node IPs or ports |
| Docker port publishing | `127.0.0.1:4317` maps to the management node's NodePort `30317` | Does not exist; k3s nodes are not Docker containers on an operator's laptop |
| `hostPort` | The node-local collector listens on `4318` for apps on that node | Use only when a node-local agent needs it; it is not a general service exposure mechanism |

**NodePort example — Argo CD.** A browser calls
`https://127.0.0.1:9000`. Docker maps that laptop port to
`k3s-management:30090`; NodePort `30090` then sends the request through the
Argo CD Service to an Argo CD server Pod. The first mapping is Docker-only;
the middle hop is Kubernetes NodePort.

```text
browser :9000 → Docker → management node :30090 → Argo CD Service → server Pod
```

For a public HTTP application, the usual production path is:

```
https://app.example.com
  → public load balancer
  → Gateway controller
  → application ClusterIP Service
  → ready application Pod
```

The Gateway owns TLS, host/path routing, and load balancing. The application
keeps a normal `ClusterIP` Service; it does not get a public NodePort. Use a
`LoadBalancer` Service for a directly exposed service when that is the
platform standard. For non-HTTP protocols, choose the platform's
load-balancer or gateway pattern rather than exposing node ports directly.
Kubernetes recommends Gateway API for new HTTP routing; Ingress remains
supported but is frozen. See [Services](https://kubernetes.io/docs/concepts/services-networking/service/),
[Gateway API](https://gateway-api.sigs.k8s.io/), and
[Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/).

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
