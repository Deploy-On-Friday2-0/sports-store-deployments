# Sports Store Deployments

GitOps source of truth for deploying the Sports Store platform.

## Scope

- Raw Kubernetes manifests under `k8s/`
- Helm chart under `helm/sports-store/`
- Argo CD projects and applications
- Environment-specific image values
- Observability configuration

See `k8s/README.md` for the raw-manifest layout and apply order (Milestone 2),
`helm/sports-store/README.md` for the parent Helm chart (Milestone 3), and
`k8s/external-secrets/README.md` for the External Secrets Operator deployment.
Application source and cloud infrastructure do not belong in this repository.
