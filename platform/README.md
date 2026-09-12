# platform/

Every platform component is an ArgoCD `Application` in a directory here,
ordered with `argocd.argoproj.io/sync-wave` annotations (CRDs → controllers →
workloads). The root app (`bootstrap/root-app.yaml`) recurses this directory;
non-YAML files like this one are ignored by Argo's directory source.

**Still near-empty on purpose.** Bucket A proved the handoff (anonymous clone,
root Synced). Bucket B populates this tree — design lives in the private
homelab repo: [`docs/platform-design.md`](https://github.com/HashVelani/homelab/blob/main/docs/platform-design.md)
(private; 404 if you're not Hash). Do not dump secrets here. Ever.

## Layout (committed)

```
platform/                         # root app path
├── external-secrets.yaml         # wave 0  — operator
├── external-secrets-config.yaml  # wave 1  — path: manifests/external-secrets
├── cert-manager.yaml             # wave 2
├── istio-base.yaml               # wave 3  — sidecar CP, not ambient
├── istiod.yaml                   # wave 4
├── kube-prometheus-stack.yaml    # wave 5
├── argocd.yaml                   # wave 6  — self-manage (+ Application health Lua)
├── cilium.yaml                   # wave 7  — adopt inline Cilium + Istio/L2 deltas
├── cilium-lb.yaml                # wave 8  — path: manifests/cilium
├── istio-gateway.yaml            # wave 9  — needs the LB pool from wave 8
├── kyverno.yaml                  # wave 10 — chart; webhooks forced to Ignore
└── kyverno-policies.yaml         # wave 11 — path: manifests/kyverno

manifests/                        # NOT under root path
├── cilium/                       # CiliumLoadBalancerIPPool + L2AnnouncementPolicy
├── external-secrets/             # ClusterSecretStore aws, token Role, ExternalSecrets
├── kyverno/                      # GeneratingPolicy: PDB per multi-replica Deployment
└── argocd/                       # ExternalSecret → repo-creds (private git only)
```

## Sync waves

| Wave | App | Risk if it goes wrong |
|---|---|---|
| 0 | external-secrets | New namespace; nothing depends on it |
| 1 | external-secrets-config | Store invalid — proves the OIDC path, breaks nothing |
| 2 | cert-manager | New namespace |
| 3–4 | istio-base → istiod | New namespace; injection webhook matches no namespace yet |
| 5 | kube-prometheus-stack | New namespace |
| 6 | argocd | Argo interrupts itself mid-sync; recover by re-applying the seed |
| 7 | cilium | **Live CNI.** A bad diff drops node networking and takes kubectl with it |
| 8 | cilium-lb | LB-IPAM pool + L2 announcements |
| 9 | istio-gateway | Service stays Pending without wave 8 |
| 10 | kyverno | New namespace; webhooks Ignore and never see kube-system |
| 11 | kyverno-policies | Generates PDBs in kube-system — a wrong selector hangs drains |

**This order deviates from `platform-design.md` §4, deliberately.** The design
table (cilium at wave 0) describes a *fresh* build, where Cilium must exist
before anything else can run. This cluster is already up with Cilium inline and
healthy, so wave 0 buys nothing and spends the largest risk first. Reordered so
that everything additive proves itself before the live dataplane is touched, and
so the ESO → AWS acceptance test — the one that validates the whole OIDC design
— lands before anything can break `kubectl`.

Waves gate on health, which means **order is enforced, not advisory**: with the
Application health Lua in `argocd-cm`, root will not create wave N+1 until every
wave-N child reports Healthy.

## How a wave is advanced

Nothing here is applied by hand. `kubectl` is for reading state; every change to
the cluster arrives as a commit.

- **Waves 0–5 carry `syncPolicy.automated`** (prune + selfHeal). Argo reconciles
  them from `main` with no operator action, and drift is corrected rather than
  accumulated.
- **Waves 6–7 deliberately do not.** `argocd` and `cilium` sit permanently
  `OutOfSync`, synced by hand from the **Argo UI or `argocd app sync`** after
  reading the diff.
- **Waves 8–11 are not in this directory at all** — see [`../staging/`](../staging/).

### What actually blocks a wave (learned the hard way)

Root waits for child **health**, not sync status. A child with automation off
still reports **Healthy** when its target resources already exist and are healthy
in-cluster — which is why `argocd` and `cilium` do *not* park root despite never
being synced: both are already installed inline by Talos. Only a child whose
resources are **Missing** blocks.

That matters because root's `retry.limit` is `-1` and Argo starts no new sync
while one is in flight: a parked root means **no commit to `platform/` reaches
the cluster**. Root sat pinned to one revision for ~30 minutes on 2026-09-12
while three merged PRs could not land. `root-app.yaml` is create-only via Talos
`extraManifests`, so root's retry posture cannot be fixed from git — the fix is
to keep Missing-resource apps out of `platform/` until you are ready to work
them. Hence `staging/`.

Do not mistake the gate for a safety mechanism: it is a wait-for-health, not a
guard against applying. What keeps Cilium safe is automation being off, nothing
else.

### A failed root sync does not retry itself

Argo will not re-attempt an **automated** sync for the same commit once a sync of
that commit has failed — deliberate anti-sync-loop behaviour. Root keeps
reconciling (`status.reconciledAt` advances) but starts no new operation, so it
sits `Failed / OutOfSync` indefinitely.

This is easy to walk into, because terminating a parked operation *is* a failure:
root then shows `Operation terminated`, and nothing further happens on its own.
Observed on dc-c8a8 on 2026-09-12: after the terminate, waves 0–2 had been
applied with their new specs and waves 3–5 had not, and root stayed put.

Two ways forward, and the first is preferred:

1. **Land any commit on `main`.** A new revision re-arms automated sync, and root
   applies the current tree. No imperative action, nothing outside git.
2. `argocd app sync root` once, from the UI or CLI — a human operational action,
   not a state change.

Corollary worth remembering: a terminate is not free. It ends the block, but it
also disarms root until the next commit.

Do not patch an Application's `operation` field with `kubectl` to force a sync.
It works, but it applies sync options that git never declared — that is how
`CreateNamespace=true` got silently skipped during the wave-0 bringup.

Public repo ⇒ Argo needs **no** GitHub PAT for this tree. Private Layer 2
repos get credentials later via ESO → Secrets Manager → Argo `repo-creds`
(see the private design doc §2 / §6).

Porting source for several values: the old `homelab-cluster-config` repo.
arm64 (GX10) tolerations come with the node, not before. Longhorn / GitLab
stay out of the first platform pass.
