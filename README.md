# homelab-platform — Layer 1 (PUBLIC)

> Staged inside the private repo until pushed. To publish:
>
> ```sh
> cd homelab-platform-seed
> bootstrap/build-argocd.sh          # renders bootstrap/argocd.yaml (committed here)
> git init -b main && git add -A && git commit -m "feat: seed + empty platform"
> gh repo create HashVelani/homelab-platform --public --source . --push
> git rev-parse HEAD                 # → the <SHA> for talos/clusters/<uid>/cluster.yaml
> ```

This repo is what ArgoCD watches, cloned **anonymously** — that is the design
(homelab repo, `docs/bootstrap-plan.md` §9): no credential exists at seed time,
so the repo must need none.

**THE RULE: nothing secret ever lands here.** Not a token, not a rendered chart
with a generated CA, not "just temporarily". History is forever on a public
repo. Secrets come from External Secrets → AWS after bootstrap.

- `bootstrap/` — seed part 2: `argocd.yaml` (pinned ArgoCD install, no secrets)
  and `root-app.yaml` (the handoff artifact). Fetched by Talos `extraManifests`,
  pinned by commit SHA.
- `platform/` — every platform component as an Argo Application, ordered by
  sync-wave annotations. Near-empty for Bucket A; `external-secrets/` lands
  first in Bucket B.

## Security controls (public repo hardening)

- `bootstrap/root-app.yaml` is pinned to an immutable revision (not `main`).
- `bootstrap/argocd.yaml` uses image digests (`@sha256`) for ArgoCD, Dex, and Redis.
- `argocd-server-network-policy` is restricted to traffic from the `argocd` namespace on expected ports.
- CI enforces security guardrails on every PR/push:
  - `.github/workflows/security-gates.yml`
  - `scripts/security-policy-check.sh`
- Secrets policy: this repo stays credential-free. Put credentials only in AWS Secrets Manager and consume through External Secrets.

### Required GitHub repository settings (manual, one-time)

Enforce these on `main` in GitHub settings:

1. Branch protection enabled for `main`
2. Require pull request reviews before merging
3. Require status checks to pass (include `Security Gates`)
4. Require signed commits
