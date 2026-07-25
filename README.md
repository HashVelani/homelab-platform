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
