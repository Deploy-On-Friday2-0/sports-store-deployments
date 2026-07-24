# Sports Store Deployments

GitOps source of truth for deploying the Sports Store platform.

## Scope

- Raw Kubernetes manifests under `k8s/`
- Helm chart
- Argo CD projects and applications
- Environment-specific image values
- Observability configuration

See `k8s/README.md` for the current manifest layout and apply order. Application source and cloud infrastructure do not belong in this repository.
