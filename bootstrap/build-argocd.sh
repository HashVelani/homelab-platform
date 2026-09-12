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

# Verify ArgoCD tags on https://github.com/argoproj/argo-cd/releases and resolve digests with:
# docker buildx imagetools inspect <image:tag>
export ARGOCD_IMAGE="quay.io/argoproj/argocd:v3.5.2@sha256:e2aadfae709d904e87f46ba4aa49601d827b3022db22cd4d03aae816a2e7097b"
export DEX_IMAGE="ghcr.io/dexidp/dex:v2.45.1@sha256:8499afd690c437f52301efd2b05b2455da5bd2dfc20332cd697dc9937f808462"
export REDIS_IMAGE="public.ecr.aws/docker/library/redis:8.2.3-alpine@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba"
# Derive ARGOCD_VERSION from the pinned ARGOCD_IMAGE tag (single source of truth).
_argocd_image_no_digest="${ARGOCD_IMAGE%%@*}"
ARGOCD_VERSION="${_argocd_image_no_digest##*:}"
unset _argocd_image_no_digest
[[ "$ARGOCD_VERSION" =~ ^v[0-9] ]] || {
  echo "ERROR: ARGOCD_IMAGE must include a version tag (e.g. :v3.4.5) before the digest; got '${ARGOCD_VERSION}'" >&2
  exit 1
}

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
bad_format = [k for k in required_env if "@sha256:" not in os.environ[k]]
if bad_format:
    raise SystemExit(f"image pins must include @sha256 digest: {', '.join(bad_format)}")

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

docs = text.split("---")
notif_matches = [
    i for i, d in enumerate(docs)
    if re.search(r"^kind:\s*Deployment\s*$", d, re.M)
    and re.search(r"^  name:\s*argocd-notifications-controller\s*$", d, re.M)
]
if len(notif_matches) != 1:
    raise SystemExit(f"expected exactly 1 notifications deployment, found {len(notif_matches)}")

notif_doc = docs[notif_matches[0]]
lines = notif_doc.splitlines()

if "        - mountPath: /home/argocd/params" not in lines:
    try:
        working_dir_idx = lines.index("        workingDir: /app")
    except ValueError as exc:
        raise SystemExit("failed to locate notifications controller workingDir for params mount insertion") from exc
    lines[working_dir_idx:working_dir_idx] = [
        "        - mountPath: /home/argocd/params",
        "          name: argocd-cmd-params-cm",
    ]

notif_doc = "\n".join(lines) + "\n"
if not re.search(
    r"(?ms)^      volumes:\s*$.*?"
    r"^      - configMap:\s*$\n"
    r"(?:^          .*$\n)*?"
    r"^          name:\s*argocd-cmd-params-cm\s*$\n"
    r"(?:^          .*$\n)*?"
    r"^        name:\s*argocd-cmd-params-cm\s*$",
    notif_doc,
):
    try:
        volumes_idx = lines.index("      volumes:")
    except ValueError as exc:
        raise SystemExit("failed to locate notifications controller volumes section") from exc

    insert_idx = len(lines)
    for i in range(volumes_idx + 1, len(lines)):
        if lines[i] and not lines[i].startswith("      "):
            insert_idx = i
            break

    lines[insert_idx:insert_idx] = [
        "      - configMap:",
        "          name: argocd-cmd-params-cm",
        "          optional: true",
        "        name: argocd-cmd-params-cm",
    ]

docs[notif_matches[0]] = "\n".join(lines) + "\n"
text = "---".join(docs)

p.write_text(text)
PY

# Restore the Application CRD health check. ArgoCD dropped the built-in one in
# v1.8 and it is still gone at v3.5.2: without it every child Application reads
# Healthy the instant it appears, so sync waves do not wait and app-of-apps
# ordering is decorative. Baking it into the seed means a rebuilt cluster is
# correct from minute zero, and a self-manage sync of bootstrap/argocd.yaml
# cannot revert it out of the live ConfigMap.
# Docs: https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#argocd-app
python3 - <<'PY'
from pathlib import Path
import re
import sys

KEY = "resource.customizations.health.argoproj.io_Application"
LUA = """    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil then
      if obj.status.health ~= nil then
        hs.status = obj.status.health.status
        if obj.status.health.message ~= nil then
          hs.message = obj.status.health.message
        end
      end
    end
    return hs
"""

path = Path("argocd.yaml")
text = path.read_text()
docs = text.split("---")

targets = [
    i for i, d in enumerate(docs)
    if re.search(r"^kind:\s*ConfigMap\s*$", d, re.M)
    and re.search(r"^  name:\s*argocd-cm\s*$", d, re.M)
]
if len(targets) != 1:
    print(f"ERROR: expected exactly 1 argocd-cm ConfigMap, found {len(targets)}", file=sys.stderr)
    sys.exit(1)

i = targets[0]
doc = docs[i]
if KEY in doc:
    print("ok: health customization already in argocd-cm")
    sys.exit(0)

entry = f"  {KEY}: |\n{LUA}"
if re.search(r"^data:\s*$", doc, re.M):
    doc = re.sub(r"^data:\s*$", "data:\n" + entry.rstrip("\n"), doc, count=1, flags=re.M)
else:
    doc = doc.rstrip("\n") + "\ndata:\n" + entry

docs[i] = doc
path.write_text("---".join(docs))

check = path.read_text()
if check.count(KEY) != 1:
    print(f"ERROR: expected 1 occurrence of {KEY}, got {check.count(KEY)}", file=sys.stderr)
    sys.exit(1)
print(f"ok: injected {KEY} into argocd-cm")
PY

if [[ -n "$(find_secret_pattern_matches argocd.yaml)" ]]; then
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
