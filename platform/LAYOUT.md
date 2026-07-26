# platform/ + manifests/ layout (stub)

Design-only reminder. **Do not treat this file as authority** — the private
doc [`docs/platform-design.md`](https://github.com/HashVelani/homelab/blob/main/docs/platform-design.md)
is. Application YAML is committed in a later session; until then this tree
stays empty of syncable CRs so root remains a clean Synced handoff proof.

```
wave 0  platform/argocd.yaml
wave 0  platform/cilium.yaml
wave 1  platform/external-secrets.yaml
wave 1  platform/cilium-lb.yaml          → manifests/cilium/*
wave 2  platform/cert-manager.yaml
wave 3  platform/istio-base.yaml
wave 4  platform/istiod.yaml
wave 5  platform/istio-gateway.yaml
wave 6  platform/kube-prometheus-stack.yaml
```

When adding real Applications: prefer automated sync off (or a
`argocd.argoproj.io/compare-options: IgnoreExtraneous` / manual sync) for the
Cilium adoption commit until `argocd app diff` looks safe.
