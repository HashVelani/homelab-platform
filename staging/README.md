# staging/ — Applications not yet under the root app

Root syncs `platform/` with `directory.recurse: true`. Anything in **this**
directory is deliberately outside that path: the file exists, is reviewed, and is
render-checked by CI, but Argo does not know about it yet.

## Why this directory exists

Root's sync waves gate on child **health**, and root's `retry.limit` is `-1`, so a
wave that never goes Healthy parks root's operation forever. Argo will not start a
new sync while one is in flight — so a parked root means **no further commit to
`platform/` reaches the cluster at all**. That is not theoretical: root sat pinned
to one revision for ~30 minutes on 2026-09-12 while three merged PRs could not
land, until the operation was terminated by hand.

The subtlety is which children park it. A child with automation off still reports
**Healthy** if its target resources already exist and are healthy in-cluster — that
is why `argocd` and `cilium` do not block root despite being permanently
`OutOfSync` (both are already installed, inline). Only a child whose resources are
**Missing** blocks, and these two are exactly that:

- `cilium-lb` — the LB-IPAM pool and L2 policy do not exist until synced
- `istio-gateway` — its LoadBalancer Service cannot get an address until `cilium-lb`
  is live, so it is Missing until then too
- `kyverno-policies` — its GeneratingPolicy CRD does not exist until `kyverno`
  (wave 10, promoted) is Healthy.

`kyverno-policies` does not depend on waves 8–9 and can be promoted independently
of them; root orders only the children that exist.

## Promoting one

Advancing a wave stays a commit, never a `kubectl apply`:

```sh
git mv staging/cilium-lb.yaml platform/
git commit -m "feat(platform): promote cilium-lb to wave 8"
```

Root then creates the child and parks on it — expected, and now bounded by your
attention rather than indefinite. Read its diff (`argocd app diff cilium-lb`),
sync it from the Argo UI or `argocd app sync`, and root completes. Promote the
next one after that.

Keep the `sync-wave` annotations as they are; they stay correct on promotion.
