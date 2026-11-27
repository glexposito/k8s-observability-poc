# Namespaces: how to slice a cluster

Namespaces are the usual Kubernetes boundary for **logical** multi-tenancy:
they divide a shared cluster between groups that should not interfere with one
another. This guide distils the common GKE, EKS, and AKS guidance into a
decision model; links at the end provide the supporting detail.

## Start with the tenant

A tenant is the group that needs its own resource, access, and network
boundary. It can be a team, a business domain containing related workloads,
or one sensitive or independently operated workload.

| Building | Kubernetes |
| --- | --- |
| Building | Cluster |
| Landlord | Platform team |
| Apartment | Namespace |
| People in an apartment | Tenant |

Use this test: **who must not be able to consume, change, or observe whose
resources?** Each answer identifies a tenant.

| Tenant choice | Good fit | Example namespace |
| --- | --- | --- |
| Team | A team owns unrelated workloads as one unit | `payments-team` |
| Domain | Related services share ownership and lifecycle | `payments` |
| Workload | One app needs distinct limits, permissions, or sensitivity | `settlement-worker` |

Domain is often the most useful default. Split one workload into its own
namespace when its resource needs, permission model, or isolation needs
materially differ from the rest of the domain.

## The standard model

Give each tenant one namespace in a cluster. The platform team creates that
namespace and applies the baseline controls; the tenant deploys and operates
its workloads within the granted boundary.

Every tenant namespace should have:

- **RBAC:** access scoped to its namespace. Add a `Role` and `RoleBinding`
  before giving tenant users or CI direct Kubernetes API access.
- **ResourceQuota:** a ceiling so one tenant cannot exhaust shared capacity.
- **LimitRange:** sensible defaults and bounds when workloads omit resources.
- **NetworkPolicy:** deny cross-namespace traffic by default; open only the
  paths that a real dependency requires.

An Argo CD AppProject can limit where Argo CD deploys. It is not a substitute
for Kubernetes RBAC and does not control a user's direct API access.

Namespaces are a logical boundary, not a hard security boundary. Use separate
clusters for hostile, untrusted, or otherwise strongly isolated tenants.

## Environments and names

When environments use separate clusters, use the **same tenant namespace name
in each cluster**: `payments` in internal, staging, and production—not
`payments-prod`. The cluster or project identifies the environment; labels and
telemetry attributes identify it in tooling.

An environment suffix can be appropriate when several environments deliberately
share one cluster. It is not needed when a cluster already is the environment
boundary.

This produces a repeatable layout:

```
internal cluster          staging cluster           production cluster
├── payments              ├── payments              ├── payments
├── fulfilment            ├── fulfilment            ├── fulfilment
└── platform              └── platform              └── platform
```

Keep platform components in their own namespaces rather than mixing them with
tenant workloads.

## What the providers agree on

| Topic | Shared guidance |
| --- | --- |
| Tenant boundary | Give each team, domain, or workload its own namespace |
| Baseline controls | Namespace-scoped RBAC, quotas, and NetworkPolicies |
| Platform role | Platform administrators create and govern tenant namespaces |
| Strong isolation | Use physically separate clusters for untrusted tenants |

Their emphasis differs:

- **GKE** provides the most prescriptive enterprise model: separate
  environments by clusters or projects, standardise namespace names, and let
  the platform team supply the guardrails.
- **EKS** is most explicit that namespaces are “soft” multi-tenancy and that
  the cluster is the meaningful hard boundary.
- **AKS** recommends logical namespace isolation first and permits multiple
  workloads, teams, or environments in a cluster when that trade-off is
  acceptable.

These are compatible choices. A platform can adopt GKE's stricter
cluster-per-environment convention while still following the common advice on
namespace tenancy.

## Managing namespaces as code

| Approach | Use when | Trade-off |
| --- | --- | --- |
| Explicit folder per namespace | Few or moderately many tenants; clarity matters | Guardrail manifests are repeated |
| Namespace labels + policy engine | A policy engine such as Kyverno is already present and standard controls repeat often | Adds policy design and operational complexity |
| Multi-tenancy operator | Tenants need self-service namespaces with enforced limits | Adds a platform-specific API and controller |

The explicit approach keeps each namespace and its guardrails easy to review.
At larger scale, a policy engine can generate quotas, limit ranges,
NetworkPolicies, and RoleBindings from Namespace labels. Introduce that only
when it removes a real maintenance burden, not merely to reduce a few clear
YAML files.

## Takeaway

Choose the tenant first, then give it a namespace with RBAC, a quota, limits,
and default-deny networking. Separate environments with clusters when that is
the chosen boundary, retain namespace names across those clusters, and use a
different cluster when the tenant needs a hard isolation boundary.

## Sources

- [GKE enterprise multi-tenancy](https://docs.cloud.google.com/kubernetes-engine/docs/best-practices/enterprise-multitenancy) and [multi-tenancy overview](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/multitenancy-overview)
- [EKS tenant isolation](https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html) and [EKS Blueprints teams](https://awslabs.github.io/cdk-eks-blueprints/teams/teams/)
- [AKS cluster isolation](https://learn.microsoft.com/en-us/azure/aks/operator-best-practices-cluster-isolation) and [AKS multitenancy](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/service/aks)
- [Config Sync repository layouts](https://docs.cloud.google.com/kubernetes-engine/enterprise/config-sync/docs/concepts/hierarchical-repo), [Flux multi-tenancy example](https://github.com/fluxcd/flux2-multi-tenancy), and [Kyverno generated resources](https://kyverno.io/docs/policy-types/cluster-policy/generate/)
