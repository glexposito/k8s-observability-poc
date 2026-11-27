#!/bin/sh
# Run once by the argocd-bootstrap Compose service (local/compose.yaml):
# waits for Argo CD on management, registers internal/stg/prod (and
# management itself) as labelled clusters, then applies the root Application.
# From then on Argo CD manages everything under gitops/ from git.
#
# Laptop-only: each workload cluster's argocd-manager token
# (local/k3s/workload/argocd-manager.yaml) becomes an Argo CD cluster Secret.
# A real platform registers clusters from its provisioning tooling instead.
set -e

management() { kubectl --kubeconfig=/kubeconfigs/management/k3s.yaml --server=https://k3s-management:6443 "$@"; }

echo "Waiting for Argo CD..."
for workload in deployment/argocd-server deployment/argocd-repo-server \
  deployment/argocd-applicationset-controller statefulset/argocd-application-controller; do
  management -n argocd wait --for=create "$workload" --timeout=600s
  management -n argocd rollout status "$workload" --timeout=300s
done

# Cluster Secrets carry the labels the ApplicationSets select on
# (docs/architecture.md, "Cluster labels"):
#   platform.example.com/role         workload | management
#   platform.example.com/environment  which overlay a cluster gets
#   platform.example.com/provider     which values-<provider>.yaml it gets
# Here every cluster is its own environment; several clusters can share one.
register() { # name server environment role config
  management apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $1-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    platform.example.com/role: $4
    platform.example.com/environment: $3
    platform.example.com/provider: local
type: Opaque
stringData:
  name: $1
  server: $2
  config: |
    $5
EOF
}

echo "Registering internal, stg, and prod as managed clusters..."
for cluster in internal stg prod; do
  remote() { kubectl --kubeconfig=/kubeconfigs/$cluster/k3s.yaml --server=https://k3s-$cluster:6443 "$@"; }
  remote -n kube-system wait --for=create secret/argocd-manager-token --timeout=120s
  remote -n kube-system wait --for=jsonpath='{.data.token}' secret/argocd-manager-token --timeout=120s
  token=$(remote -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
  register "$cluster" "https://k3s-$cluster:6443" "$cluster" workload \
    "{\"bearerToken\":\"$token\",\"tlsClientConfig\":{\"insecure\":true}}"
done

# Management itself: Argo CD's built-in in-cluster entry has no Secret, so the
# cluster generator can't select it by label. Declaring one (Argo CD's own
# service account, no token) makes it a labelled cluster like the others.
echo "Registering management (in-cluster)..."
register management https://kubernetes.default.svc management management \
  '{"tlsClientConfig":{"insecure":false}}'

echo "Applying the root Application..."
management apply -n argocd -f /gitops/root-app.yaml

# The root app creates the self-managed Argo CD Application. That application
# replaces the bare bootstrap installation's server pod, briefly resetting the
# NodePort while it rolls out. Do not report bootstrap as finished until the
# replacement is healthy and the UI is ready to serve requests.
echo "Waiting for self-managed Argo CD to roll out..."
management -n argocd wait --for=create application/argocd --timeout=300s
management -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/argocd --timeout=300s
management -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/argocd --timeout=300s
management -n argocd rollout status deployment/argocd-server --timeout=300s

echo "Managed clusters: internal, stg, prod, management. Argo CD UI: https://127.0.0.1:9000 (admin/123)"
