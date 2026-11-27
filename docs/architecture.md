# Architecture

## Repo layout

The repo has two halves, and only one of them is the pattern:

| Path      | What                                                                 |
| --------- | -------------------------------------------------------------------- |
| `gitops/` | **The pattern.** Everything Argo CD syncs: Argo CD's projects and Applications, platform governance, the observability stack, the apps. |
| `local/`  | **Laptop scaffolding.** The k3s clusters in Docker, what k3s applies before Argo CD can reach a cluster (CoreDNS overrides, Argo CD's login, Argo CD's installer), and cluster registration. A real platform replaces all of it with its own provisioning. |

Nothing in `gitops/` refers to files in `local/`. The few settings that only
exist because the clusters run in Docker (NodePorts, the `k3s-management`
endpoint, k3s's kubelet certificates, fixed logins) live in a
`values-local.yaml` next to each chart's `values.yaml`.

```
docker-compose.yaml          # entry point: includes local/compose.yaml
local/
  compose.yaml               # 4× k3s, lgtm, argocd-bootstrap
  register-clusters.sh       # registers the clusters (labelled Secrets), applies the root app
  k3s/workload/              # applied by k3s on internal/stg/prod
  k3s/management/            # applied by k3s on management (incl. the Argo CD installer)
  lgtm/                      # Grafana dashboard provider for the lgtm container
gitops/
  argocd/                    # Argo CD's own values, root app, AppProjects, Applications
  platform/governance/       # namespaces, quotas, limits, NetworkPolicies
  platform/observability/    # collector/SigNoz values, dashboards
  apps/                      # tenant workloads (queue-consumer)
```

## Clusters and bootstrap

Four single-node k3s clusters in Docker: **management** runs the platform
(Argo CD, plus the observability stack in [observability.md](observability.md)), and
**internal / stg / prod** run the workloads. Keeping Argo CD on its own
cluster means losing a workload cluster never takes down the thing that
manages it.

`docker compose up -d` does everything, with nothing to run by hand:

1. Each k3s container auto-applies its bind-mounted folder:
   `local/k3s/workload/` on internal/stg/prod (CoreDNS override, Argo CD's
   ServiceAccount and token), `local/k3s/management/` on management
   (CoreDNS override, Argo CD's installer).
2. k3s installs a bare Argo CD on management from
   `local/k3s/management/argocd-helmchart.yaml`.
3. `argocd-bootstrap` runs `local/register-clusters.sh`: it registers
   internal/stg/prod (and management itself) with Argo CD as labelled
   cluster Secrets, and applies `gitops/argocd/root-app.yaml`.
   From then on, Argo CD manages everything under `gitops/` from git.

Each file is applied by exactly one of the two: k3s applies `local/k3s/`,
Argo CD applies `gitops/`.

For IPs, ports, DNS and traffic flows, see [network.md](network.md).

There's no `kubectl` on the host. Each cluster ships its own:
`docker exec k3s-<cluster> kubectl …`.

## Namespaces

| Namespace        | Clusters            | Notes                                              |
| ---------------- | ------------------- | -------------------------------------------------- |
| `queue-consumer` | internal, stg, prod | The workload: 1 / 2 / 3 replicas                   |
| `otel-collectors`| internal, stg, prod | `otel-collector` (DaemonSet) + `otel-collector-cluster` (Deployment) |
| `otel-gateway`   | management          | OTel gateway                                       |
| `argocd`         | management          | Argo CD                                            |
| `signoz`         | management          | SigNoz + ClickHouse                                |

**One namespace per app, not per environment.** Each cluster is one
environment, so names have no stage suffix: queue-consumer lives in
`queue-consumer` on every cluster. Telemetry tells environments apart by
`deployment.environment.name`, which the otel-collector stamps. A per-env
namespace (`queue-consumer-prod`) only makes sense when several
environments share a cluster. For the reasoning and Google's guidance behind
this, see [namespaces.md](namespaces.md).

Each namespace gets its own ResourceQuota, LimitRange and NetworkPolicy,
sized per environment.

### Governance (`gitops/platform/governance/`)

| Path                      | What                                                       |
| ------------------------- | ---------------------------------------------------------- |
| `workload/base/<namespace>/` | One folder per namespace (`otel-collectors`, `queue-consumer`): `namespace.yaml`, `quota.yaml`, `limitrange.yaml`, `networkpolicy.yaml`. Shared by internal/stg/prod |
| `workload/overlays/<env>/`| Only what differs: the `platform.example.com/environment` label and the queue-consumer pod quota |
| `management/<namespace>/` | Same pattern for management's own namespaces (`argocd`, `otel-gateway`, `signoz`) |

All of it is plain Kustomize, synced by Argo CD only. How to add a namespace,
and why it's laid out this way: [namespaces.md](namespaces.md#10-how-the-namespaces-are-defined).
Check an overlay with
`kubectl kustomize gitops/platform/governance/workload/overlays/<env>`.

## Argo CD (`gitops/argocd/`)

| File                                       | What                                                     |
| ------------------------------------------ | -------------------------------------------------------- |
| `root-app.yaml`                            | App of apps: syncs everything else in `gitops/argocd/`   |
| `projects/`                                | AppProjects: `platform` (cluster-scoped), `queue-consumer` (own namespace only) |
| `applications/governance-appset.yaml`      | `platform/governance/workload/overlays/<environment>` (or `management/`) per cluster |
| `applications/otel-collectors-appset.yaml` | otel-collector + otel-collector-cluster per workload cluster           |
| `applications/otel-gateway.yaml`           | OTel gateway on management (2 replicas)                  |
| `applications/signoz.yaml`                 | SigNoz on management                                     |
| `applications/queue-consumer-appset.yaml`  | queue-consumer, one Application per workload cluster     |
| `applications/argocd.yaml`                 | Argo CD itself (self-managed)                            |
| `install/`                                 | Argo CD's Helm values: `values.yaml` + `values-local.yaml` |

**Argo CD manages itself**, as Argo CD's docs describe ("Argo CD is able to
manage itself since all settings are represented by Kubernetes manifests";
they suggest Kustomize on top of its base manifests, here it's the official
Helm chart, same idea). It can't install itself the first time, so k3s
installs a bare one from `local/k3s/management/argocd-helmchart.yaml`. That
file holds only what must match before the takeover: the chart version and
`fullnameOverride`. On its first sync, `applications/argocd.yaml` applies
everything else from `install/`. From then on, change Argo CD only there (and
the chart version in both files). On AKS, the bootstrap install belongs to the
cluster provisioning instead (e.g. Terraform's `helm_release`, ignoring later
changes). The Application has no resources-finalizer, so deleting it never
deletes Argo CD.

### Cluster labels

No file in `gitops/` lists the clusters. The ApplicationSets use Argo CD's
cluster generator, which reads the cluster Secrets Argo CD already has and
selects them by label:

| Label                              | Values                  | Used for |
| ---------------------------------- | ----------------------- | -------- |
| `platform.example.com/role`        | `workload`, `management` | Which ApplicationSets target the cluster: workload clusters get governance overlays, collectors and apps; management gets `governance/management/` |
| `platform.example.com/environment` | `internal`, `stg`, `prod`, `management` | Which overlay it gets (`overlays/<environment>`) |
| `platform.example.com/provider`    | `local` (k3s in Docker) | Which `values-<provider>.yaml` the collectors get. A provider without its own file just gets `values.yaml` |

Adding a cluster means registering one labelled Secret, with no change in
`gitops/`. Locally, `local/register-clusters.sh` creates them; on AKS the
cluster provisioning would. Management gets a Secret too, pointing at
`https://kubernetes.default.svc` with Argo CD's own service account, because
Argo CD's built-in in-cluster entry has no labels to select on.

The cluster name and the environment are separate on purpose: here every
cluster is its own environment, but two prod clusters would share
`environment=prod` (same overlay) and keep distinct names (distinct
Applications, distinct `k8s.cluster.name`).

The AppProjects don't list clusters either: `platform` may deploy to any
registered cluster, and `queue-consumer` to its own namespace on any
registered cluster except management (a `!` deny rule).

### Label scheme

Every label this repo defines uses one prefix, `platform.example.com/`, so it
can't clash with labels from Kubernetes, Helm charts or other tools. Apps use
the standard `app.kubernetes.io/*` labels.

| Label | On | Meaning |
| --- | --- | --- |
| `platform.example.com/role` | Cluster Secrets | `workload` or `management` |
| `platform.example.com/environment` | Cluster Secrets, namespaces, governance resources, Applications | `internal`, `stg`, `prod`, `management` |
| `platform.example.com/provider` | Cluster Secrets | `local` (k3s in Docker) |
| `platform.example.com/team` | Namespaces | Owning team: `platform`, `team-1`. Copied to telemetry as `com.example.team` |
| `platform.example.com/cost-center` | Namespaces | `cc-1000`, `cc-2000`. Copied to telemetry as `com.example.cost_center` |
| `platform.example.com/layer` | Applications | `bootstrap`, `governance`, `observability`, for filtering in the Argo CD UI |
| `app.kubernetes.io/name`, `component`, `part-of` | App workloads | Standard app labels. `part-of` is the tenant (its namespace) |

`platform.example.com` is a placeholder: use your organisation's domain.

## queue-consumer

[queue-consumer](https://github.com/glexposito/queue-consumer) is a Rust
background worker instrumented with the OpenTelemetry SDK. Each fake message
it processes is one consumer trace plus a `messages.processed` counter, and
it logs to stdout.

| Stage    | Replicas | Overlay                                |
| -------- | -------- | -------------------------------------- |
| internal | 1        | `gitops/apps/queue-consumer/overlays/internal` |
| stg      | 2        | `gitops/apps/queue-consumer/overlays/stg`      |
| prod     | 3        | `gitops/apps/queue-consumer/overlays/prod`     |

The base sets only standard `OTEL_*` env vars, identical on every stage. It
sends to the node-local otel-collector, which adds the environment. The image is
built and pushed to `ghcr.io/glexposito/queue-consumer` by that repo's
`publish` workflow. Each overlay pins it under `images:`.

## Sources

Argo CD:

- [Cluster generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/):
  selecting clusters by cluster Secret labels, `values` per generator, and
  why management needs its own Secret: "the default local cluster does not
  have a Secret."
- [Projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/):
  wildcard destinations and `!` deny rules (allowed only if an allow rule
  matches and no deny rule rejects it).
- [Helm](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/):
  `ignoreMissingValueFiles` for the `values-<provider>.yaml` files.
- [Declarative setup → Manage Argo CD using Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#manage-argo-cd-using-argo-cd):
  self-managed Argo CD.

k3s (`local/` only):

- [Auto-deploying manifests](https://docs.k3s.io/installation/packaged-components#auto-deploying-manifests-addons):
  "any file found in `/var/lib/rancher/k3s/server/manifests` will automatically
  be deployed", "both on startup and when the file is changed on disk".
  Deleting a file there doesn't delete its resources.
- [Helm](https://docs.k3s.io/add-ons/helm): the helm-controller and its
  `HelmChart` resource, used for Argo CD's bootstrap install.
