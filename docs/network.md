# Network topology

Everything shares one Docker bridge network, `k8s-management` (`172.28.0.0/24`).
Every long-running service has a **fixed IP**, so DNS overrides and endpoints
are plain YAML in git with nothing to discover at runtime.

```
 host (127.0.0.1)
  │ published ports
  ▼
 ┌────────────────────── Docker bridge: k8s-management 172.28.0.0/24 ──────────────────────┐
 │                                                                                         │
 │  k3s-internal   .101 ┐                                                                  │
 │  k3s-stg        .102 ├─ :6443 API ◄──────────────── Argo CD (on management)             │
 │  k3s-prod       .103 ┘                                                                  │
 │        │  queue-consumer ─► otel-agent (same node, hostPort 4318)                       │
 │        │                                                                                │
 │        │ OTLP gRPC → k3s-management:30317                                               │
 │        ▼                                                                                │
 │  k3s-management .104   :6443 API   :30090 Argo CD                                       │
 │                        :30317/:30318 otel-gateway                                       │
 │                        :30301 SigNoz UI                                                 │
 │        │                                                                                │
 │        │ OTLP HTTP → lgtm:4318                                                          │
 │        ▼                                                                                │
 │  lgtm           .105   :3000 Grafana, :4317/:4318 OTLP (not published)                  │
 │                                                                                         │
 │  argocd-bootstrap: Docker-assigned IP (one-shot client)                                 │
 └─────────────────────────────────────────────────────────────────────────────────────────┘
```

## Addresses

| Container          | IP             | Role                                            |
| ------------------ | -------------- | ----------------------------------------------- |
| `k3s-internal`     | `172.28.0.101` | Workload cluster                                |
| `k3s-stg`          | `172.28.0.102` | Workload cluster                                |
| `k3s-prod`         | `172.28.0.103` | Workload cluster                                |
| `k3s-management`   | `172.28.0.104` | Platform cluster: Argo CD, otel-gateway, SigNoz |
| `lgtm`             | `172.28.0.105` | Grafana LGTM backend                            |
| `argocd-bootstrap` | dynamic        | One-shot cluster registration, outbound only    |

`.100` is free (it used to be azurite).

Inside every cluster, k3s uses its default CIDRs: pods `10.42.0.0/16`, Services
`10.43.0.0/16`. All four clusters use the **same** ranges. That's fine
because cross-cluster traffic never uses pod or Service IPs. It always goes
to a node IP (`172.28.0.x`) on an API port or a NodePort, and flannel
masquerades pod egress behind the node's address.

## Published ports (host → container)

| Host port                | Target                        | What                          |
| ------------------------ | ----------------------------- | ----------------------------- |
| `3301`                   | management `:30301`           | SigNoz UI                     |
| `3000`                   | lgtm `:3000`                  | Grafana                       |
| `9000`                   | management `:30090`           | Argo CD UI/API (HTTPS)        |
| `4317` / `4318`          | management `:30317/:30318`    | otel-gateway OTLP gRPC / HTTP |
| `6447`                   | management `:6443`            | management API server         |
| `6444` / `6446` / `6445` | internal / stg / prod `:6443` | workload API servers          |

LGTM's own OTLP ports aren't published, because the host's 4317/4318 belong
to the gateway. Everything goes through the gateway.

## DNS: why the CoreDNS overrides exist

Containers resolve each other through Docker's embedded DNS, but pods don't:
a pod's network namespace uses the cluster's CoreDNS, which knows nothing
about Docker. So each cluster gets a `coredns-custom` ConfigMap that maps
hostnames to the fixed IPs above:

| Cluster               | File                                       | Resolves                                                   |
| --------------------- | ------------------------------------------ | ---------------------------------------------------------- |
| management            | `local/k3s/management/cluster-dns.yaml` | `k3s-internal`, `k3s-stg`, `k3s-prod` (Argo CD), `lgtm` (gateway) |
| internal / stg / prod | `local/k3s/workload/cluster-dns.yaml`     | `k3s-management` (OTel collectors → gateway)               |

`argocd-bootstrap` runs as a container on the bridge, so it doesn't need any
of this: Docker's DNS already resolves `k3s-<cluster>` for it.

## Traffic flows

| From                         | To                                        | Port            | Purpose                                 |
| ---------------------------- | ----------------------------------------- | --------------- | --------------------------------------- |
| Argo CD (management)         | `k3s-<cluster>`                           | 6443            | Sync workload clusters (bearer token from `argocd-bootstrap`) |
| Argo CD repo-server          | GitHub, Helm repos                        | 443 (out)       | This repo, Argo CD, OTel and SigNoz charts |
| workload kubelets            | `ghcr.io`                                 | 443 (out)       | Pull `glexposito/queue-consumer`        |
| `argocd-bootstrap`           | all four API servers                      | 6443            | One-shot cluster registration           |
| queue-consumer pods          | `otel-agent` on their node (`$(NODE_IP)`) | 4318 (hostPort) | Traces + metrics (OTel SDK)             |
| `otel-agent` (filelog)       | `/var/log/pods` on its node               | (local)         | queue-consumer stdout as logs           |
| `otel-agent`, `otel-k8s-state` | `k3s-management`                        | 30317           | OTLP gRPC to the gateway                |
| `otel-gateway`               | `signoz-otel-collector.signoz.svc`        | 4317            | Fan-out to SigNoz (in-cluster)          |
| `otel-gateway`               | `lgtm`                                    | 4318            | Fan-out to LGTM                         |

## NetworkPolicies (ingress)

k3s enforces NetworkPolicies through its embedded kube-router. Every
governed namespace is default-deny-except-same-namespace, with explicit
holes only where traffic must come from outside:

| Namespace        | Cluster(s)          | Extra ingress allowed       | Why                                       |
| ---------------- | ------------------- | --------------------------- | ----------------------------------------- |
| `queue-consumer` | internal, stg, prod | none                        | Worker: outbound connections only         |
| `otel-collectors` | internal, stg, prod | TCP 4317/4318 from anywhere | Apps in every namespace push to the agent |
| `otel-gateway`   | management          | TCP 4317/4318 from anywhere | Collectors from other clusters hit the NodePort. kube-proxy masquerades them, so peers can't be pinned by IP |
| `argocd`         | management          | none                        | UI reached through NodePort 30090         |
| `signoz`         | management          | no policy                   | Gateway (other namespace) and UI NodePort must reach it |

All policies are ingress-only. Egress is unrestricted everywhere.
