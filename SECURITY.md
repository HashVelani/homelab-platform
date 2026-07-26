# Security policy

This repository is public and must remain secret-free.

## Credential handling

- Never commit credentials, API keys, tokens, kubeconfigs, private keys, or passwords.
- Store credentials only in AWS Secrets Manager.
- Sync runtime secrets into the cluster through External Secrets.
- Do not commit Kubernetes `Secret` manifests with inline `data` or `stringData` values.

## Supply chain and dependency cadence

- Weekly reminder automation opens a supply-chain review issue.
- Review ArgoCD, Dex, and Redis image versions, digests, and CVEs.
- Regenerate and re-pin `bootstrap/argocd.yaml` when updates are required.
