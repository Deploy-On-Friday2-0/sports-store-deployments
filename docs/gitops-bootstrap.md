# Sports Store GitOps bootstrap

## Architecture

The bootstrap has three layers, applied in this order:

1. `bootstrap/00-namespaces.yaml` declares `argocd`, `argo-rollouts`,
   `external-secrets`, `apps`, `monitoring`, and `logging`. The pre-existing
   `sports-store` namespace remains owned by `k8s/00-namespace.yaml`; `default`
   is Kubernetes-managed.
2. `projects/sports-store-project.yaml` establishes the local-cluster source,
   destination, and resource boundary.
3. `apps/root-app.yaml` reconciles the top-level downstream Application files
   in `apps/`. It excludes itself and does not recurse into auxiliary
   application directories, preventing a duplicate root Application.

The root manages `sports-store-production` and `argo-rollouts`. Kubecost remains
independently managed under `apps/kubecost/` because it belongs to the separate
observability scope. Argo CD remains a bootstrap Application rather than a root
child so a bad root sync cannot remove the controller that performs recovery.

Run `pwsh scripts/bootstrap-gitops.ps1` from an approved operator network when
bootstrapping a new or rebuilt cluster. The EKS API must only be opened to that
operator's `/32` for the duration of the bootstrap and closed again after Argo
CD has reconciled the in-cluster controllers and workloads.

## DEP-239 controller adoption

The DEP-239 Argo Rollouts Application moved from `bootstrap/argo-rollouts.yaml`
to `apps/argo-rollouts.yaml`; its Application name, Helm release name,
namespace, chart version, CRD retention, and resource settings did not change.
Argo CD can therefore adopt the existing Helm release without creating a
second controller. The Application now uses `sports-store-project` and enables
prune and self-heal. CRDs retain `keepCRDs: true` and are not intended to be
deleted during prune or chart removal.

The Argo CD bootstrap Application also uses `sports-store-project`, but does not
enable automated self-sync. This deliberate recovery safeguard avoids a
circular dependency in which an erroneous self-management change removes or
locks out the controller needed to repair itself.

## Namespace and project boundaries

The approved Sub-PRD requires `default`, `apps`, `monitoring`, and `logging`.
Three additional narrow destinations are necessary: `sports-store` preserves
the existing workload namespace, while `argocd` and `argo-rollouts` allow the
root and controller Applications to belong to this AppProject. There are no
wildcard destinations or remote cluster endpoints. Only the deployment and
official Argo Helm repositories are permitted.

## Internal Argo CD access (DEP-240)

Argo CD remains private by default: its service is explicitly `ClusterIP` and
chart-managed ingress is disabled. Do not enable the internal ALB until all of
the following verified inputs exist:

- an internal DNS hostname;
- an ACM certificate covering that hostname;
- the approved authentication mechanism and access policy;
- confirmation that AWS Load Balancer Controller and its external IRSA role are
  active.

Those values must come from Terraform outputs or approved environment
configuration. Never invent an ARN, hostname, AWS account ID, or credential in
Git. Enabling an unauthenticated or HTTP-only ingress is not an acceptable
partial implementation.

## Repository governance (DEP-241)

GitHub repository and organization settings are external to this repository.
The required end state is protection on `main` with at least one approving
review for human changes, plus a repository-scoped `sports-store-gitops-bot`
whose short-lived installation tokens have only the necessary contents write
access. Store the App's client ID as the GitHub organization variable
`GITOPS_CLIENT_ID` and its private key as the organization secret
`GITOPS_APP_PRIVATE_KEY`, with access limited to the application repositories.
The client ID comes from the `sports-store-gitops-bot` App settings; no private
key or other secret value belongs here.

## Sync, health, and rollback

After an authorized operator registers the project and root Application, use
Argo CD—not manual Kubernetes edits—to inspect and reconcile state:

```sh
argocd app get sports-store-root
argocd app get sports-store-production
argocd app get argo-rollouts
argocd app sync sports-store-root
```

Rollback is a Git operation: revert the faulty manifest or image-tag commit via
an approved pull request. Argo CD then reconciles the prior desired state.
Avoid manual `kubectl edit`, imperative Helm upgrades, and direct cluster
changes; they create drift and will be reverted by self-heal.

Local validation does not prove EKS reachability or runtime health:

```sh
bash tests/dep-238.sh
bash tests/dep-239.sh
```
