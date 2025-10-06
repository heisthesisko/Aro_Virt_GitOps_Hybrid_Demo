#!/usr/bin/env bash
set -e
echo "🧹 Cleaning up demo resources..."
NS_GITOPS="gitops-demo"
NS_VIRT="virt-demo"

# Best-effort deletes
kubectl -n "$NS_VIRT" delete svc fedora-nginx-svc --ignore-not-found || true
kubectl -n "$NS_VIRT" delete virtualmachine kubevirt.io/fedora-nginx --ignore-not-found || true
oc delete project "$NS_VIRT" --ignore-not-found || true

kubectl -n "$NS_GITOPS" delete kustomization.kustomize.toolkit.fluxcd.io/podinfo-kustomize --ignore-not-found || true
kubectl -n "$NS_GITOPS" delete gitrepository.source.toolkit.fluxcd.io/podinfo-source --ignore-not-found || true
oc delete project "$NS_GITOPS" --ignore-not-found || true

echo "✅ Cleanup complete."

