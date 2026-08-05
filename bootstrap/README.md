# Controller bootstrap

This directory declares the namespaces required before the cluster's GitOps
applications are registered. Terraform owns installation and lifecycle of the
Argo CD Helm release; this repository must not install or uninstall that release.

| Application | Chart | Version | Namespace |
| --- | --- | --- | --- |
| Argo Rollouts | `argo-rollouts` | `2.41.1` | `argo-rollouts` |
| AWS Load Balancer Controller | `aws-load-balancer-controller` | `3.5.0` | `kube-system` |
| External Secrets Operator | `external-secrets` | `2.8.0` | `external-secrets` |

`00-namespaces.yaml` owns the controller and shared platform namespaces. The Application resources retain
`CreateNamespace=true` as a safe reconciliation fallback, but namespace
creation does not depend on an imperative Helm flag. Apply the namespace
manifest before registering the Applications with the cluster's bootstrap Argo
CD instance.

For a new or rebuilt cluster, Terraform must first install a healthy Argo CD
release named `argocd` in the `argocd` namespace. Then run
`scripts/bootstrap-gitops.ps1`. The script verifies that release and registers
the project, root Application, platform controllers, monitoring, and Kubecost
in dependency order. It deliberately contains no Argo CD Helm mutation.

Argo Rollouts is adopted by the root App-of-Apps at
`apps/argo-rollouts.yaml`, where automated sync and self-healing are enabled.
Argo CD is not self-managed from this repository. The Rollouts chart installs its cluster-scoped CRDs,
including the `AnalysisTemplate` and `ClusterAnalysisTemplate` APIs, and retains
them if the release is removed.

All enabled controller workloads have explicit CPU and memory requests and
limits. The values are conservative bootstrap defaults and should be adjusted
from observed utilization rather than removed.

## Local validation

With Helm, Ruby, and the official Argo chart repository available:

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
bash tests/dep-239.sh
```

The test parses the manifests, renders the pinned Rollouts chart with the
embedded values, verifies namespaces and workload resources, and confirms that
the Rollouts CRDs include `AnalysisTemplate` support. It does not connect to a
Kubernetes cluster.

See [`docs/gitops-bootstrap.md`](../docs/gitops-bootstrap.md) for bootstrap
order, project boundaries, controller adoption, access prerequisites, and Git
revert rollback procedures.
