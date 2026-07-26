#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/policy-lib.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

echo "Running security policy checks..."

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

unpinned_images="$(find_unpinned_images bootstrap/argocd.yaml)"
if [[ -n "$unpinned_images" ]]; then
  printf '%s\n' "$unpinned_images" >&2
  fail "Found unpinned image tags in bootstrap/argocd.yaml (must include @sha256 digest)."
fi

python3 - <<'PY'
from pathlib import Path
import re
import sys

text = Path("bootstrap/argocd.yaml").read_text()
m = re.search(
    r"name:\s*argocd-server-network-policy\s*\n\s*namespace:\s*argocd\s*\n\s*spec:\s*\n\s*ingress:\s*\n\s*-\s*\{\}",
    text,
    re.M,
)
if m:
    print("ERROR: argocd-server-network-policy still allows open ingress.", file=sys.stderr)
    sys.exit(1)
PY

# High-signal secret patterns (kept strict to reduce false positives).
secret_matches_file="$(mktemp)"
trap 'rm -f "$secret_matches_file"' EXIT
if grep -RInE \
  '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82}|-----BEGIN (RSA|EC|OPENSSH|DSA|PGP|PRIVATE) KEY-----|AIza[0-9A-Za-z\-_]{35})' \
  --exclude-dir=.git \
  . >"$secret_matches_file"; then
  cat "$secret_matches_file" >&2
  fail "Potential secret material detected."
fi

echo "Security policy checks passed."
