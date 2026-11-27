# Architecture

## At a glance

This playground runs four single-node k3s clusters in Docker. The management
cluster runs Argo CD and the observability backend; `internal`, `stg`, and
`prod` run the workload. Keeping Argo CD on management means a failed workload
cluster does not take down its controller.

```
management: Argo CD, OTel gateway, SigNoz
       │
       ├── internal: queue-consumer + OTel collectors
       ├── stg:      queue-consumer + OTel collectors
       └── prod:     queue-consumer + OTel collectors
```

For the fixed addresses, ports, DNS and allowed traffic, see
[network.md](network.md). For telemetry flow, see
[observability.md](observability.md).

## Repo layout

| Path | Purpose |
| --- | --- |
| `gitops/` | **The reusable pattern.** Argo CD projects and Applications, governance, observability, and workloads. |
| `local/` | **Laptop scaffolding.** Docker/k3s provisioning, first Argo CD install, cluster registration, and playground dashboards. Replace this in a real platform. |

`gitops/` never refers to `local/`. Settings needed only for this Docker
playground live in a chart's adjacent `values-local.yaml`.

```
gitops/
  argocd/                 # root app, projects, Applications/ApplicationSets
  platform/argocd/        # self-managed Argo CD values
  platform/governance/    # namespaces, quotas, limits, NetworkPolicies
  platform/observability/ # collectors, gateway, SigNoz
  apps/                   # tenant workloads
local/                    # Docker and first-boot scaffolding
```

`apps/` holds tenant workloads; `argocd/applications/` holds Argo CD
`Application` objects. They are different uses of “application”.

## Bootstrap and GitOps ownership

`docker compose up -d` performs the local bootstrap:

1. k3s applies its bind-mounted `local/k3s/` manifests.
2. The management cluster installs a minimal Argo CD from
   `local/k3s/management/argocd-helmchart.yaml`.
3. `argocd-bootstrap` registers all four clusters as labelled Argo CD cluster
   Secrets, applies `gitops/argocd/root-app.yaml`, then waits for the
   self-managed Argo CD to be healthy.

After that hand-off, Argo CD owns configuration beneath `gitops/`. The
bootstrap chart only has the version and `fullnameOverride` that must match
before Argo CD takes over. Change Argo CD under `gitops/platform/argocd/` and
keep the bootstrap chart version in sync. The root Argo CD Application has no
resources finalizer, so deleting it cannot delete Argo CD itself.

There is no host `kubectl`; use `docker exec k3s-<cluster> kubectl …`.

## Namespace and workload model

Each workload cluster represents an environment, so tenant namespaces use the
same name in every cluster. `queue-consumer` therefore runs in
`queue-consumer` on `internal`, `stg`, and `prod`; telemetry distinguishes the
environments with `deployment.environment.name`.

| Namespace | Cluster(s) | Purpose |
| --- | --- | --- |
| `queue-consumer` | internal, stg, prod | Workload; 1 / 2 / 3 replicas |
| `otel-collectors` | internal, stg, prod | Node and cluster collectors |
| `otel-gateway` | management | Central telemetry gateway |
| `argocd` | management | GitOps controller |
| `signoz` | management | SigNoz and ClickHouse |

All except `signoz` receive a ResourceQuota, LimitRange, and ingress
NetworkPolicy. SigNoz is chart-owned and needs unrestricted ingress. The
governance layout has a base per workload namespace, small environment
overlays, and a separate management directory. See [namespaces.md](namespaces.md)
for the policy and extension path.

`queue-consumer` is a Rust worker that emits traces, metrics, and stdout logs.
Its base uses stage-neutral `OTEL_*` variables; each overlay pins its image and
replica count.

## Deployment targeting

ApplicationSets select Argo CD cluster Secrets rather than a hand-maintained
cluster list. Register a labelled Secret to add a cluster.

| Label | Values | Used for |
| --- | --- | --- |
| `platform.example.com/role` | `workload`, `management` | Which Applications target it |
| `platform.example.com/environment` | `internal`, `stg`, `prod`, `management` | Governance/app overlay and telemetry environment |
| `platform.example.com/provider` | `local` | Optional `values-<provider>.yaml` |

The cluster name and environment are intentionally separate: multiple prod
clusters share `environment=prod` but receive distinct Argo CD Applications
and `k8s.cluster.name` values. The management cluster has a labelled Secret
for the in-cluster API because Argo CD's built-in local entry has no labels.

The `platform` project can deploy to registered clusters. The
`queue-consumer` project is limited to its namespace and denies management.

Use `platform.example.com/` for platform-specific labels and
`app.kubernetes.io/*` for workload labels. Replace `platform.example.com` with
your organisation's domain.

## Sources

- [Flux repository structure](https://fluxcd.io/flux/guides/repository-structure/)
- [Argo CD cluster generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/), [projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/), and [self-management](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#manage-argo-cd-using-argo-cd)
- [k3s manifest auto-deployment](https://docs.k3s.io/installation/packaged-components#auto-deploying-manifests-addons) and [HelmChart](https://docs.k3s.io/add-ons/helm)
