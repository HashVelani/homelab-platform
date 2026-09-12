# manifests/external-secrets/

Raw ESO custom resources. Sibling of `platform/` on purpose — the root app
recurses `platform/` only, so these are owned by a child Application
(`platform/external-secrets-config.yaml` when committed), never double-owned.

`clustersecretstore.yaml` needs the ESO CRDs established first. Every secret it
can read must live under the `dc-c8a8/` prefix — that is the IAM boundary of
role `dc-c8a8-external-secrets`, not a naming convention.

**No ExternalSecret committed yet.** The smoke test (design step 8) needs a
value in AWS Secrets Manager, which needs the `aws` CLI — not installed on the
GX10 yet.
