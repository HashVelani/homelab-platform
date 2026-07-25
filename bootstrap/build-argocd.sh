#!/usr/bin/env bash
# Builds bootstrap/argocd.yaml: the argocd Namespace + the pinned upstream
# ArgoCD install manifest. COMMITTED here (public) — it contains no secrets;
# the admin password is generated in-cluster on first start.
#
# The Namespace must be prepended: the upstream install.yaml does not create
# it, and Talos extraManifests won't apply namespaced resources into a
# namespace that doesn't exist.
#
# VERIFY current stable tag before running: https://github.com/argoproj/argo-cd/releases
set -euo pipefail
cd "$(dirname "$0")"

ARGOCD_VERSION="${ARGOCD_VERSION:?set ARGOCD_VERSION, e.g. ARGOCD_VERSION=v3.2.0 (check releases page)}"

{
    cat <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
YAML
    curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
} > argocd.yaml

if grep -qE 'kind: Secret' argocd.yaml && grep -qE '^\s+(password|token|key)\s*:' argocd.yaml; then
    echo "WARNING: possible secret material in argocd.yaml — inspect before committing" >&2
fi
echo "built bootstrap/argocd.yaml (ArgoCD ${ARGOCD_VERSION}, $(wc -l < argocd.yaml) lines)"
