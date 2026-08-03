# Sports Store Deployments

GitOps source of truth for deploying the Sports Store platform.

## Scope

- Raw Kubernetes manifests under `k8s/`
- Helm chart under `helm/sports-store/`
- Argo CD projects and applications
- Environment-specific image values
- Observability configuration
- Controller bootstrap under `bootstrap/`

See `k8s/README.md` for the raw-manifest layout and apply order (Milestone 2),
`helm/sports-store/README.md` for the parent Helm chart (Milestone 3), and
`k8s/external-secrets/README.md` for the External Secrets Operator deployment.
The pinned Argo CD and Argo Rollouts controller definitions are documented in
[`bootstrap/README.md`](bootstrap/README.md).
`apps/root-app.yaml` is the production App-of-Apps entry point. Its child
manifest declares Argo Rollouts, MongoDB, Redis Sentinel, every first-party
backend, and the gateway. Workload children deploy to the existing `sports-store` namespace under
`sports-store-project`. The project documents `sports-store` and `argocd` as
narrow additions to the PRD namespaces (`default`, `apps`, `monitoring`, and
`logging`); `argo-rollouts` is the controller-specific exception. Argo Rollouts
is synchronized in wave -3, MongoDB creates the workload namespace in wave -2, Redis
Sentinel follows in wave -1, and dependent services start at wave 0.

MongoDB and Redis Sentinel both retain StatefulSet claims on deletion and
scale-down and use the infrastructure-managed `ebs-gp3-retain` StorageClass in
production, protecting persistent data if Argo CD prunes a StatefulSet.

The AppProject boundary, root App-of-Apps, safe controller adoption, sync, and
rollback workflow are documented in
[`docs/gitops-bootstrap.md`](docs/gitops-bootstrap.md).
Application source and cloud infrastructure do not belong in this repository.

Production image promotion, the GitHub App requirements, and the justified
static-frontend exception are documented in
[`environments/production/README.md`](environments/production/README.md).

## PR Diff Review Runner

The provider-independent pipeline and trusted post-CI GitHub Actions integration are documented in [`review_runner/README.md`](review_runner/README.md). The trusted workflow runs only after branch-name and Helm chart validation succeed; local use accepts a supplied unified patch and uses the mock provider.
