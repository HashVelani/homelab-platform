# platform/

Every platform component is an ArgoCD `Application` in a directory here,
ordered with `argocd.argoproj.io/sync-wave` annotations (CRDs → controllers →
workloads). The root app (`bootstrap/root-app.yaml`) recurses this directory;
non-YAML files like this one are ignored by Argo's directory source.

**Still near-empty on purpose.** Bucket A proved the handoff (anonymous clone,
root Synced). Bucket B populates this tree — design lives in the private
homelab repo: [`docs/platform-design.md`](https://github.com/HashVelani/homelab/blob/main/docs/platform-design.md)
(private; 404 if you're not Hash). Do not dump secrets here. Ever.

## Intended layout (commit when ready)

Plain `Application` CRs only under `platform/` — **not** ApplicationSets.
Raw CRs (ClusterSecretStore, LB pools, ExternalSecrets) live in a sibling
`manifests/` tree so the root app does not double-own them.

```
platform/                         # root app path
├── argocd.yaml                   # wave 0  — self-manage (+ Application health Lua)
├── cilium.yaml                   # wave 0  — adopt inline Cilium + Istio/L2 deltas
├── external-secrets.yaml         # wave 1
├── cilium-lb.yaml                # wave 1  — path: manifests/cilium
├── cert-manager.yaml             # wave 2
├── istio-base.yaml               # wave 3  — sidecar CP, not ambient
├── istiod.yaml                   # wave 4
├── istio-gateway.yaml            # wave 5
└── kube-prometheus-stack.yaml    # wave 6

manifests/                        # NOT under root path
├── cilium/                       # CiliumLoadBalancerIPPool + L2AnnouncementPolicy
├── external-secrets/             # ClusterSecretStore aws, smoke ExternalSecrets
└── argocd/                       # ExternalSecret → repo-creds (private git only)
```

## Sync waves (summary)

| Wave | Apps |
|---|---|
| 0 | argocd self-manage, cilium adopt |
| 1 | external-secrets, cilium-lb |
| 2 | cert-manager |
| 3–5 | istio-base → istiod → istio-gateway |
| 6 | kube-prometheus-stack |

Public repo ⇒ Argo needs **no** GitHub PAT for this tree. Private Layer 2
repos get credentials later via ESO → Secrets Manager → Argo `repo-creds`
(see the private design doc §2 / §6).

Porting source for several values: the old `homelab-cluster-config` repo.
arm64 (GX10) tolerations come with the node, not before. Longhorn / GitLab
stay out of the first platform pass.
