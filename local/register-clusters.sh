#!/bin/sh
# Run once by the argocd-bootstrap Compose service (local/compose.yaml):
# waits for Argo CD on management, registers internal/stg/prod as managed
# clusters, then applies the root Application. From then on Argo CD manages
# everything under gitops/ from git.
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

echo "Registering internal, stg, and prod as managed clusters..."
for cluster in internal stg prod; do
  remote() { kubectl --kubeconfig=/kubeconfigs/$cluster/k3s.yaml --server=https://k3s-$cluster:6443 "$@"; }
  remote -n kube-system wait --for=create secret/argocd-manager-token --timeout=120s
  remote -n kube-system wait --for=jsonpath='{.data.token}' secret/argocd-manager-token --timeout=120s
  token=$(remote -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
  management apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster}-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster}
  server: https://k3s-${cluster}:6443
  config: |
    {"bearerToken":"${token}","tlsClientConfig":{"insecure":true}}
EOF
done

echo "Applying the root Application..."
management apply -n argocd -f /gitops/root-app.yaml
echo "Managed clusters: internal, stg, prod. Argo CD UI: https://127.0.0.1:9000 (admin/123)"
