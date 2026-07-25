# platform/

Every platform component is an ArgoCD `Application` in a directory here,
ordered with `argocd.argoproj.io/sync-wave` annotations (CRDs → controllers →
workloads). The root app (`bootstrap/root-app.yaml`) recurses this directory;
non-YAML files like this one are ignored by Argo's directory source.

Deliberately near-empty for Bucket A — what bootstrap proves is the handoff
mechanism, not a full platform (homelab repo: docs/bootstrap-plan.md §9).

Landing order (Bucket B+): `external-secrets/` (closes the loop to AWS OIDC),
`cert-manager/`, `longhorn/`, `monitoring/`, `argocd/` (self-management),
`cilium/` (adopts the inline-manifest install). Porting source for several of
these: the old `homelab-cluster-config` repo. arm64 (GX10) tolerations come
with the node, not before.
