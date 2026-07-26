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
source ../scripts/policy-lib.sh

ARGOCD_VERSION="${ARGOCD_VERSION:?set ARGOCD_VERSION, e.g. ARGOCD_VERSION=v3.2.0 (check releases page)}"
export ARGOCD_IMAGE="quay.io/argoproj/argocd:v3.4.5@sha256:224e454cfd8c1818fec3ed17b72b2034c9a3915fa819e1dcccafc753776d446a"
export DEX_IMAGE="ghcr.io/dexidp/dex:v2.45.0@sha256:b8469881d3cb3a73001506f0d3aaefecb9c45d2311c1e0f405d8ac538316c59d"
export REDIS_IMAGE="public.ecr.aws/docker/library/redis:8.2.3-alpine@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba"

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

python3 - <<'PY'
from pathlib import Path
import os
import re

p = Path("argocd.yaml")
text = p.read_text()

required_env = ("ARGOCD_IMAGE", "DEX_IMAGE", "REDIS_IMAGE")
missing = [k for k in required_env if not os.environ.get(k)]
if missing:
    raise SystemExit(f"missing required image pins: {', '.join(missing)}")

replacements = {
    os.environ["ARGOCD_IMAGE"].split("@", 1)[0]: os.environ["ARGOCD_IMAGE"],
    os.environ["DEX_IMAGE"].split("@", 1)[0]: os.environ["DEX_IMAGE"],
    os.environ["REDIS_IMAGE"].split("@", 1)[0]: os.environ["REDIS_IMAGE"],
}

for old, new in replacements.items():
    before = text.count(old)
    if before == 0:
        raise SystemExit(f"expected image reference not found in manifest: {old}")
    text = text.replace(old, new)
    after = text.count(new)
    if after < before:
        raise SystemExit(f"failed to replace all image references for: {old}")

pattern = (
    r"(name:\s*argocd-server-network-policy[\s\S]*?ingress:\s*\n)"
    r"\s*-\s*\{\}\s*\n"
)
replacement = (
    r"\1"
    r"  - from:\n"
    r"    - namespaceSelector:\n"
    r"        matchLabels:\n"
    r"          kubernetes.io/metadata.name: argocd\n"
    r"    ports:\n"
    r"    - port: 8080\n"
    r"      protocol: TCP\n"
    r"    - port: 8083\n"
    r"      protocol: TCP\n"
)
text, network_policy_replacements = re.subn(pattern, replacement, text, flags=re.M)
if network_policy_replacements == 0:
    raise SystemExit("failed to update argocd-server-network-policy ingress rules")

p.write_text(text)
PY

if grep -qE '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82}|-----BEGIN (RSA|EC|OPENSSH|DSA|PGP|PRIVATE) KEY-----|AIza[0-9A-Za-z\-_]{35})' argocd.yaml; then
    echo "ERROR: possible credential-like material detected in argocd.yaml" >&2
    exit 1
fi

if [[ -n "$(find_unpinned_images argocd.yaml)" ]]; then
    echo "ERROR: unpinned image tag found in argocd.yaml (must include @sha256 digest)" >&2
    exit 1
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
