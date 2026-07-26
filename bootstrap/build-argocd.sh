#!/usr/bin/env bash
# Builds bootstrap/argocd.yaml: the argocd Namespace + the pinned upstream
# ArgoCD install manifest. COMMITTED here (public) — it contains no secrets;
# the admin password is generated in-cluster on first start.
#
# Upstream manifests/install.yaml intentionally omits metadata.namespace so
# `kubectl apply -n argocd -f …` can target any namespace. Talos extraManifests
# applies with no -n context, so namespaced resources without metadata.namespace
# land in `default`. We must:
#   1. Prepend the Namespace (upstream does not create it).
#   2. Inject `namespace: argocd` on every namespaced object via kustomize.
#
# VERIFY current stable tag before running: https://github.com/argoproj/argo-cd/releases
set -euo pipefail
cd "$(dirname "$0")"

ARGOCD_VERSION="${ARGOCD_VERSION:?set ARGOCD_VERSION, e.g. ARGOCD_VERSION=v3.2.0 (check releases page)}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    >"${tmpdir}/install.yaml"

cat >"${tmpdir}/namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
YAML

cat >"${tmpdir}/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - namespace.yaml
  - install.yaml
YAML

# kubectl's bundled kustomize; avoids requiring a separate kustomize binary.
kubectl kustomize "$tmpdir" >argocd.yaml

if grep -qE 'kind: Secret' argocd.yaml && grep -qE '^\s+(password|token|key)\s*:' argocd.yaml; then
    echo "WARNING: possible secret material in argocd.yaml — inspect before committing" >&2
fi

# Sanity: every namespaced kind must carry metadata.namespace: argocd
python3 - <<'PY'
import re, sys
from pathlib import Path
text = Path("argocd.yaml").read_text()
docs = [d for d in text.split("---") if d.strip()]
cluster = {
    "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition",
    "Namespace", "PriorityClass", "MutatingWebhookConfiguration",
    "ValidatingWebhookConfiguration",
}
missing = []
for d in docs:
    kind_m = re.search(r"^kind:\s*(.+)$", d, re.M)
    name_m = re.search(r"^  name:\s*(.+)$", d, re.M)
    ns_m = re.search(r"^  namespace:\s*(.+)$", d, re.M)
    k = kind_m.group(1).strip() if kind_m else "?"
    if k in cluster:
        continue
    if not ns_m or ns_m.group(1).strip() != "argocd":
        missing.append((k, name_m.group(1).strip() if name_m else "?"))
if missing:
    print("ERROR: namespaced resources missing namespace: argocd:", file=sys.stderr)
    for item in missing[:20]:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
print(f"ok: {sum(1 for d in docs if re.search(r'^kind:', d, re.M))} docs, all namespaced resources in argocd")
PY

echo "built bootstrap/argocd.yaml (ArgoCD ${ARGOCD_VERSION}, $(wc -l < argocd.yaml) lines)"
