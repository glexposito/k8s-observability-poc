# Namespaces: how to slice a cluster

How to decide what gets its own namespace, based on what Google (GKE), AWS
(EKS) and Azure (AKS) recommend. Quotes are verbatim from these pages.

## Sources

**Google (GKE)**, sections 1-8:

- [Best practices for enterprise multi-tenancy](https://docs.cloud.google.com/kubernetes-engine/docs/best-practices/enterprise-multitenancy)
  ("the enterprise guide"): the practical setup, with an example company.
- [Multi-tenancy overview](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/multitenancy-overview)
  ("the overview"): the concepts.

**AWS (EKS)**, section 9:

- [EKS Best Practices Guide → Tenant Isolation](https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html)
- [EKS Blueprints → Teams](https://awslabs.github.io/cdk-eks-blueprints/teams/teams/)

**Azure (AKS)**, section 9:

- [Cluster isolation best practices for AKS](https://learn.microsoft.com/en-us/azure/aks/operator-best-practices-cluster-isolation)
- [Use AKS in a multitenant solution](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/service/aks)

## 1. What a tenant is

A **tenant** is a group that shares a cluster with other groups but must be
kept apart from them. Think of an apartment building:

| Building        | Kubernetes                           |
| --------------- | ------------------------------------ |
| the building    | the cluster                          |
| the landlord    | the platform team, which runs it     |
| an apartment    | a namespace                          |
| a tenant        | whoever lives in that namespace      |

The overview:

> "A multi-tenant cluster is shared by multiple users and/or workloads which are referred to as" *tenants*.

Who counts as a tenant is your choice. The enterprise guide gives three
options:

> "a *tenant* can be defined as any of the following:"
> - "A team responsible for developing and operating one or more workloads."
> - "A set of related workloads, whether operated by one or more teams."
> - "A single workload, such as a Deployment."

| Google's option         | Example namespace | In plain words     |
| ----------------------- | ----------------- | ------------------ |
| a team                  | `payments-team`   | per team           |
| a set of related workloads | `payments`     | **per domain**     |
| a single workload       | `queue-consumer`  | per app            |

**The test:** ask *"who must not be able to break, see or use up the
resources of whom?"* That "who" is your tenant.

## 2. One namespace per tenant

The overview:

> "In an enterprise environment, the tenants of a cluster are distinct teams within the organization."
>
> "Typically, each tenant has a corresponding namespace."
>
> "Alternative models of multi-tenancy with a tenant per cluster, or a tenant per Google Cloud project, are harder to manage."

The enterprise guide:

> "To provide a logical isolation between tenants that are on the same cluster, implement namespaces."

So: pick your tenant (team, domain or app), then give each one a namespace.

## 3. Don't put the environment in the namespace name

The enterprise guide, under "Standardize namespace naming":

> "avoid tying the environment name (development, staging, and production) to the namespace name"

Environments are separated by **clusters** (or Google Cloud projects), not
namespaces:

> "projects can be used to segregate environments (for example, production vs. staging) and teams from each other."
>
> "A folder dedicated for the platform team to manage clusters per environment."

So `payments` exists in the dev, staging and prod clusters under the same
name. `payments-prod` is the anti-pattern.

## 4. Google's example company

The enterprise guide walks through one company:

- Three top-level folders: **Network Team**, **Cluster Team**, **Tenants**.
- Three environments: development, staging, production, with separate
  clusters for each.
- Tenants called "Tenant A" and "Tenant B". Tenant A's namespace is
  `tenant-a`.
- Its starting assumption:

  > "Each tenant is a single team developing a single workload."

Who does what:

> "The platform team owns the clusters and defines the amount of resources each tenant team can use;"
>
> "Each tenant team should be able to deploy their application through the Kubernetes API"
>
> "Each tenant should not be able to affect other tenants in the shared cluster, except via explicit design decisions"

Drawn out:

```
dev cluster          staging cluster        prod cluster
├── tenant-a         ├── tenant-a           ├── tenant-a      ← same name everywhere
├── tenant-b         ├── tenant-b           ├── tenant-b
└── (platform)       └── (platform)         └── (platform)
```

## 5. Who creates namespaces

Not the tenants. The enterprise guide:

> "As part of the Kubernetes RBAC process, the cluster admin creates namespaces for each tenant group."
>
> "The Tenant admin manages users (tenant developers) within their respective tenant namespace."

The overview says the same thing: cluster administrators

> "can create namespaces and assign them to namespace administrators."

## 6. What every tenant namespace gets

The enterprise guide's example gives `tenant-a` three things:

**Access rights:** a `RoleBinding` so only Tenant A's group can manage it:

> "Grants access to list and watch deployments in their namespace."

**A NetworkPolicy** that blocks other namespaces:

> "block traffic between namespaces that host different tenants' applications."

```yaml
# From the enterprise guide
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: tenant-a
spec:
  podSelector:
    matchLabels:
  ingress:
  - from:
    - podSelector: {}
```

The overview explains why this is needed:

> "Network traffic within a namespace is unrestricted. Network traffic between namespaces must be explicitly allowed."

**A ResourceQuota** so one tenant can't starve the rest:

> "Create a resource quota for each namespace based on the number of Pods deployed by each tenant"

In the example, Pods in the `tenant-a` namespace can request up to 16 CPU and
64 GB of memory. The overview:

> "Resource quotas let you ensure that no tenant uses more than its assigned share of cluster resources."

Neither page mentions LimitRange. This repo adds one anyway, so containers
without explicit sizes still get defaults that fit inside the quota.

## 7. How this repo maps to it

| Google                                      | This repo                                                  |
| ------------------------------------------- | ---------------------------------------------------------- |
| Clusters per environment                    | `internal` / `stg` / `prod` clusters                       |
| Same namespace name in every environment    | `queue-consumer` on all three, no `-prod` suffix           |
| Platform team creates namespaces            | `manifests/` + Argo CD (GitOps), not the app               |
| RoleBinding per tenant namespace            | Argo CD project `queue-consumer` can only deploy there     |
| NetworkPolicy blocking other namespaces     | `manifests/base/queue-consumer-policies.yaml`              |
| ResourceQuota per tenant namespace          | same file, pod count per cluster in `manifests/overlays/`  |
| Platform namespaces kept separate           | `observability`, `argocd`, `signoz`                        |

The tenant here is **a single workload** (Google's third option), because the
playground has one app.

## 8. Applying it to domains

With business domains (`domain-1`, `domain-2`, … `domain-x`), the tenant is
**"a set of related workloads"** (Google's second option): one namespace per
domain, the same in every cluster.

```
prod cluster (same layout in internal and stg)
├── domain-1        ← domain-1 apps    domain=domain-1
├── domain-2        ← domain-2 apps    domain=domain-2
├── domain-x        ← domain-x apps    domain=domain-x
└── observability   ← platform
```

Each domain namespace gets the starter kit from section 6: access rights for
the owning team, a NetworkPolicy blocking the other domains (open specific
paths, like domain-2 → domain-1, on purpose), and a quota sized for the domain.

**When to split an app out of its domain namespace:** when it needs
different limits or permissions from the rest of the domain, for example a
heavy batch job or a service holding sensitive data. That's Google's third
option ("a single workload") applied to just that app.

When a namespace holds several apps, filter telemetry by app as well
(`service.name`, `k8s.deployment.name`), not by `k8s.namespace.name` alone.

## 9. What AWS (EKS) and Azure (AKS) say

All three agree on the basics: **isolate each tenant in its own namespace**,
with access rights, a quota and network policies. They differ on how much
they trust namespaces and on environments.

### AWS: [EKS Best Practices Guide → Tenant Isolation](https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html)

Tenant = a team or department:

> "Each tenant will typically align to an administrative division such as a department or team."

Namespaces are the basic tool ("soft multi-tenancy"):

> "Namespaces are fundamental to implementing soft multi-tenancy."
>
> "you should plan to impose quotas on namespaces in a multi-tenant environment."

AWS is the bluntest about the limits. The cluster is "the only construct that
provides a strong security boundary"; for strong isolation it says:

> "Hard multi-tenancy can be implemented by provisioning separate clusters for each tenant."

It doesn't cover environments (dev/stg/prod).

AWS's open-source [EKS Blueprints](https://awslabs.github.io/cdk-eks-blueprints/teams/teams/)
automate this: an `ApplicationTeam` gets its own namespace and quotas created
for it, the same "platform team provisions the starter kit" pattern as
Google's.

### Azure: [Cluster isolation best practices for AKS](https://learn.microsoft.com/en-us/azure/aks/operator-best-practices-cluster-isolation)

Default to namespaces, not more clusters:

> "Separate teams and projects using logical isolation."
>
> "Minimize the number of physical AKS clusters you deploy to isolate teams or applications."
>
> "Kubernetes Namespaces form the logical isolation boundary for workloads and resources."

Separate clusters only for untrusted tenants:

> "For these types of hostile multi-tenant workloads, you should use physically isolated clusters."

On environments, Azure is looser than Google and allows sharing a cluster:

> "With logical isolation, you can use a single AKS cluster for multiple workloads, teams, or environments."

### Azure: [Use AKS in a multitenant solution](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/service/aks)

> "As a best practice, separate each tenant and its Kubernetes resources into dedicated namespaces."
>
> "Separate teams within an organization can use namespaces to isolate their projects"

What each namespace carries:

> "RBAC roles and role bindings are namespace-scoped resources"
>
> "Resource quotas for CPU and memory are namespaced objects."
>
> "By default, all pods in an AKS cluster can send and receive traffic without restrictions"

### Side by side

| | Google (GKE) | AWS (EKS) | Azure (AKS) |
| --- | --- | --- | --- |
| Tenant is | team, set of related workloads, or one workload | team / department | team or project |
| Tenant gets | a namespace | a namespace | a namespace |
| In each namespace | RBAC, NetworkPolicy, quota | RBAC, NetworkPolicy, quota | RBAC, NetworkPolicy, quota |
| Separate clusters for | environments | untrusted tenants ("hard" tenancy) | untrusted tenants |
| Environments | separate clusters, no env in namespace names | not covered | may share a cluster |
| LimitRange | not mentioned | not mentioned | not mentioned |

### Same guidance, different tone

All three give the **same core guidance**:

| Point | Google | AWS | Azure |
| --- | --- | --- | --- |
| Each tenant gets its own namespace | "Typically, each tenant has a corresponding namespace." | "Namespaces are fundamental to implementing soft multi-tenancy." | "separate each tenant and its Kubernetes resources into dedicated namespaces." |
| A tenant is usually a team | "the tenants of a cluster are distinct teams within the organization." | "align to an administrative division such as a department or team." | "Separate teams and projects using logical isolation." |
| Each namespace gets a quota | "Create a resource quota for each namespace" | "you should plan to impose quotas on namespaces" | "Resource quotas for CPU and memory are namespaced objects." |
| Block traffic between namespaces | "block traffic between namespaces that host different tenants' applications." | (network policies are part of soft multi-tenancy) | "By default, all pods in an AKS cluster can send and receive traffic without restrictions" |
| Untrusted tenants need separate clusters | "Kubernetes cannot guarantee perfectly secure isolation between tenants" | "provisioning separate clusters for each tenant." | "you should use physically isolated clusters." |

They differ in **tone**:

- **AWS is the most cautious.** Namespaces give only "the semblance of
  multi-tenancy"; the cluster is "the only construct that provides a strong
  security boundary". It lays out soft (namespaces) and hard (clusters)
  tenancy without picking a default.
- **Azure is the most positive.** Namespaces first: "Minimize the number of
  physical AKS clusters you deploy to isolate teams or applications."
- **Google sits in between.** Namespaces per tenant, plus the most detailed
  setup (folders, projects, example YAML).

They only really **disagree on environments**:

| | Google | AWS | Azure |
| --- | --- | --- | --- |
| dev / stg / prod | separate clusters, and "avoid tying the environment name … to the namespace name" | not covered | "you can use a single AKS cluster for multiple workloads, teams, or environments." |

Azure says environments **can** share a cluster, not that they must. So
Google's rule (a cluster per environment) doesn't conflict with Azure's
guidance, and AWS is silent.

**Takeaway:** namespace per tenant (team, domain or app) with RBAC, a quota
and network policies is the guidance all three share. This repo follows it,
plus Google's stricter rule on environments: a cluster per environment and
the same namespace names in every cluster. That setup fits all three
vendors.
