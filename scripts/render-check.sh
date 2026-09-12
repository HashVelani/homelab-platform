#!/usr/bin/env bash
# Renders every Helm-sourced Application in platform/ AND staging/ with
# `helm template`, using
# the exact chart, version and values the Application declares.
#
# Why: a values key the chart does not accept is not a sync failure — it is a
# ComparisonError, and Argo reports such an app as health Healthy with sync
# Unknown. With sync waves that is the worst possible shape: root sees Healthy
# and advances past an app that installed nothing. cert-manager shipped with a
# top-level `serviceMonitor:` key (belongs under `prometheus.servicemonitor`) and
# did exactly that on dc-c8a8 — wave 2 was skipped silently.
#
# Catching it here means a chart bump that moves or removes a value fails the PR.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

command -v helm >/dev/null || { echo "ERROR: helm not found" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# name<TAB>repoURL<TAB>chart<TAB>version<TAB>valuesfile, one line per helm app.
python3 - "$tmpdir" <<'PY' >"$tmpdir/apps.tsv"
from pathlib import Path
import sys
import yaml

out = Path(sys.argv[1])
rows = []
for f in sorted(Path("platform").glob("*.yaml")) + sorted(Path("staging").glob("*.yaml")):
    app = yaml.safe_load(f.read_text())
    if not app or app.get("kind") != "Application":
        continue
    src = app["spec"]["source"]
    if "chart" not in src:
        continue  # git-sourced app, nothing to render
    name = app["metadata"]["name"]
    values = (src.get("helm") or {}).get("values", "")
    vf = out / f"{name}.values.yaml"
    vf.write_text(values)
    rows.append("\t".join([name, src["repoURL"], src["chart"], src["targetRevision"], str(vf)]))
print("\n".join(rows))
PY

fail=0
while IFS=$'\t' read -r name repo chart version valuesfile; do
    [[ -n "${name:-}" ]] || continue
    printf 'rendering %-24s %s %s\n' "$name" "$chart" "$version"
    helm repo add "check-$name" "$repo" >/dev/null 2>&1 || true
    helm repo update "check-$name" >/dev/null 2>&1 || true
    if ! err="$(helm template "$name" "check-$name/$chart" \
                  --version "$version" \
                  --values "$valuesfile" \
                  --include-crds 2>&1 >/dev/null)"; then
        echo "ERROR: $name failed to render with its declared values:" >&2
        printf '%s\n' "$err" | head -20 >&2
        fail=1
    fi
done <"$tmpdir/apps.tsv"

if [[ $fail -ne 0 ]]; then
    echo "Chart render check FAILED — an Application would land as ComparisonError." >&2
    exit 1
fi
echo "Chart render check passed."
