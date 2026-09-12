#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
[[ -f "$REPO_ROOT/scripts/policy-lib.sh" ]] || { echo "ERROR: Missing required helper: scripts/policy-lib.sh" >&2; exit 1; }
source "$REPO_ROOT/scripts/policy-lib.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

echo "Running security policy checks..."

[[ -f bootstrap/root-app.yaml ]] || fail "bootstrap/root-app.yaml not found"
target_revision="$(python3 - <<'PY'
from pathlib import Path
import re
text = Path("bootstrap/root-app.yaml").read_text()
m = re.search(r'^\s*targetRevision:\s*["\']?([^"\']+)["\']?\s*$', text, re.M)
print(m.group(1) if m else "")
PY
)"
case "${target_revision:-}" in
  main|master|HEAD|"")
    fail "bootstrap/root-app.yaml must pin targetRevision to an immutable commit SHA or tag (found: ${target_revision:-<empty>})."
    ;;
esac

[[ -f bootstrap/argocd.yaml ]] || fail "bootstrap/argocd.yaml not found"
unpinned_images="$(find_unpinned_images bootstrap/argocd.yaml)"
if [[ -n "$unpinned_images" ]]; then
  printf '%s\n' "$unpinned_images" >&2
  fail "Found unpinned image tags in bootstrap/argocd.yaml (must include @sha256 digest)."
fi

python3 - <<'PY'
from pathlib import Path
import sys
import yaml

text = Path("bootstrap/argocd.yaml").read_text()
docs = [d for d in yaml.safe_load_all(text) if d]

policy = next(
    (d for d in docs if d.get("kind") == "NetworkPolicy" and d.get("metadata", {}).get("name") == "argocd-server-network-policy"),
    None,
)
if policy is None:
    print("ERROR: argocd-server-network-policy not found in bootstrap/argocd.yaml.", file=sys.stderr)
    sys.exit(1)
if {} in (((policy.get("spec") or {}).get("ingress")) or []):
    print("ERROR: argocd-server-network-policy still allows open ingress.", file=sys.stderr)
    sys.exit(1)

expected_repo_server_mtls = {
    "argocd-application-controller": (
        "StatefulSet",
        "argocd-application-controller",
        (
            "controller.repo.server.ca.cert.path",
            "controller.repo.server.client.cert.path",
            "controller.repo.server.client.cert.key.path",
        ),
    ),
    "argocd-applicationset-controller": (
        "Deployment",
        "argocd-applicationset-controller",
        (
            "applicationsetcontroller.repo.server.ca.cert.path",
            "applicationsetcontroller.repo.server.client.cert.path",
            "applicationsetcontroller.repo.server.client.cert.key.path",
        ),
    ),
    "argocd-notifications-controller": (
        "Deployment",
        "argocd-notifications-controller",
        (
            "notificationscontroller.repo.server.ca.cert.path",
            "notificationscontroller.repo.server.client.cert.path",
            "notificationscontroller.repo.server.client.cert.key.path",
        ),
    ),
    "argocd-repo-server": ("Deployment", "argocd-repo-server", ()),
    "argocd-server": (
        "Deployment",
        "argocd-server",
        (
            "server.repo.server.ca.cert.path",
            "server.repo.server.client.cert.path",
            "server.repo.server.client.cert.key.path",
        ),
    ),
}

for workload_name, (workload_kind, container_name, required_keys) in expected_repo_server_mtls.items():
    deployment = next(
        (d for d in docs if d.get("kind") == workload_kind and d.get("metadata", {}).get("name") == workload_name),
        None,
    )
    if deployment is None:
        print(f"ERROR: {workload_kind} {workload_name} not found in bootstrap/argocd.yaml.", file=sys.stderr)
        sys.exit(1)

    pod_spec = ((((deployment.get("spec") or {}).get("template") or {}).get("spec")) or {})
    containers = pod_spec.get("containers") or []
    container = next((c for c in containers if c.get("name") == container_name), None)
    if container is None:
        print(f"ERROR: {workload_name} missing expected container {container_name}.", file=sys.stderr)
        sys.exit(1)

    mounts = container.get("volumeMounts") or []
    if not any(m.get("mountPath") == "/home/argocd/params" and m.get("name") == "argocd-cmd-params-cm" for m in mounts):
        print(f"ERROR: {workload_name} missing /home/argocd/params volumeMount.", file=sys.stderr)
        sys.exit(1)

    if not any(m.get("mountPath") == "/app/config/reposerver/mtls" and m.get("name") == "argocd-repo-server-mtls" for m in mounts):
        print(f"ERROR: {workload_name} missing repo-server mTLS volumeMount.", file=sys.stderr)
        sys.exit(1)

    volumes = pod_spec.get("volumes") or []
    if not any(
        v.get("name") == "argocd-cmd-params-cm"
        and (v.get("configMap") or {}).get("name") == "argocd-cmd-params-cm"
        and (v.get("configMap") or {}).get("optional") is True
        for v in volumes
    ):
        print(f"ERROR: {workload_name} missing argocd-cmd-params-cm volume.", file=sys.stderr)
        sys.exit(1)

    if not any(v.get("name") == "argocd-repo-server-mtls" for v in volumes):
        print(f"ERROR: {workload_name} missing argocd-repo-server-mtls volume.", file=sys.stderr)
        sys.exit(1)

    env = container.get("env") or []
    for key in required_keys:
        if not any(
            ((item.get("valueFrom") or {}).get("configMapKeyRef") or {}).get("key") == key
            and ((item.get("valueFrom") or {}).get("configMapKeyRef") or {}).get("name") == "argocd-cmd-params-cm"
            for item in env
        ):
            print(
                f"ERROR: {workload_name} cmd param is not wired via "
                f"configMapKeyRef/name argocd-cmd-params-cm for key: {key}",
                file=sys.stderr,
            )
            sys.exit(1)
PY

# ESO must not hold cluster-wide TokenRequest rights.
#
# Chart external-secrets defaults rbac.serviceAccountTokenCreate=true, which puts
# `create` on `serviceaccounts/token` — no resourceNames — into the CLUSTER role
# external-secrets-controller. ESO picks its IAM role from a ServiceAccount
# annotation, so minting a token for any SA in any namespace is a path to
# assuming any role those SAs point at. We set it false and grant a namespaced
# Role scoped to the external-secrets SA instead.
#
# This check exists because the failure is silent: a chart bump or a dropped
# value re-opens it with no error anywhere.
if [[ -f platform/external-secrets.yaml ]]; then
  python3 - <<'PY'
from pathlib import Path
import sys
import yaml

app = yaml.safe_load(Path("platform/external-secrets.yaml").read_text())
values = yaml.safe_load(app["spec"]["source"]["helm"]["values"]) or {}
setting = (values.get("rbac") or {}).get("serviceAccountTokenCreate")

if setting is not False:
    print(
        "ERROR: platform/external-secrets.yaml must set rbac.serviceAccountTokenCreate: false "
        f"(found: {setting!r}). The chart default grants the ESO ClusterRole create on "
        "serviceaccounts/token cluster-wide.",
        file=sys.stderr,
    )
    sys.exit(1)

role = Path("manifests/external-secrets/serviceaccount-token-rbac.yaml")
if not role.is_file():
    print(
        "ERROR: rbac.serviceAccountTokenCreate is false but "
        "manifests/external-secrets/serviceaccount-token-rbac.yaml is missing — "
        "ESO cannot mint its own token and the AWS store will never authenticate.",
        file=sys.stderr,
    )
    sys.exit(1)

for doc in yaml.safe_load_all(role.read_text()):
    if not doc or doc.get("kind") != "Role":
        continue
    for rule in doc.get("rules", []):
        if "serviceaccounts/token" in (rule.get("resources") or []):
            if not rule.get("resourceNames"):
                print(
                    "ERROR: the serviceaccounts/token rule must carry resourceNames. "
                    "TokenRequest is a subresource, so the parent name is in the request "
                    "path and resourceNames IS enforced; without it the Role mints tokens "
                    "for every ServiceAccount in the namespace.",
                    file=sys.stderr,
                )
                sys.exit(1)
print("ok: ESO token-minting is scoped, not cluster-wide")
PY
fi

# High-signal secret patterns (kept strict to reduce false positives).
secret_matches_file="$(mktemp)"
trap 'rm -f "$secret_matches_file"' EXIT
find_secret_pattern_matches --exclude-dir=.git . >"$secret_matches_file"
if [[ -s "$secret_matches_file" ]]; then
  cat "$secret_matches_file" >&2
  fail "Potential secret material detected."
fi

echo "Security policy checks passed."
