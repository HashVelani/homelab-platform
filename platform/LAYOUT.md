# platform/ + manifests/ layout

Wave index of the live Applications under `platform/` (synced by root) and the
one still staged under `staging/`. The design intent lives in the private doc
[`docs/platform-design.md`](https://github.com/HashVelani/homelab/blob/main/docs/platform-design.md);
where this file and the committed YAML disagree, the YAML is what the cluster
runs.

```
wave 0  platform/external-secrets.yaml
wave 1  platform/external-secrets-config.yaml   → manifests/external-secrets/*
wave 2  platform/cert-manager.yaml
wave 3  platform/istio-base.yaml
wave 4  platform/istiod.yaml
wave 5  platform/kube-prometheus-stack.yaml
wave 6  platform/argocd.yaml
wave 6  platform/monitoring-config.yaml   → manifests/monitoring/*
wave 7  platform/cilium.yaml
wave 8  platform/cilium-lb.yaml   → manifests/cilium/*
wave 9  staging/istio-gateway.yaml (NOT under root)
wave 10 platform/kyverno.yaml
wave 11 platform/kyverno-policies.yaml   → manifests/kyverno/*
```

Order rationale and risk table: [`README.md`](./README.md). This is a live
cluster, so Cilium adoption is deliberately last — not wave 0 as in the design
doc, which describes a fresh build.

When adding real Applications: prefer automated sync off (or a
`argocd.argoproj.io/compare-options: IgnoreExtraneous` / manual sync) for the
Cilium adoption commit until `argocd app diff` looks safe.
