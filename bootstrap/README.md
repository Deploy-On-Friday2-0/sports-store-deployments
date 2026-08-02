# Controller bootstrap

This directory declaratively provisions the cluster's GitOps controllers with
the official Argo Helm charts:

| Application | Chart | Version | Namespace |
| --- | --- | --- | --- |
| Argo CD | `argo-cd` | `10.2.2` | `argocd` |
| Argo Rollouts | `argo-rollouts` | `2.41.1` | `argo-rollouts` |

`00-namespaces.yaml` owns both namespaces. The Application resources retain
`CreateNamespace=true` as a safe reconciliation fallback, but namespace
creation does not depend on an imperative Helm flag. Apply the namespace
manifest before registering the Applications with the cluster's bootstrap Argo
CD instance.

Automated sync and self-healing are intentionally not configured here. Those
policies belong to DEP-251. The Rollouts chart installs its cluster-scoped CRDs,
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

The test parses the manifests, renders both pinned upstream charts with the
embedded values, verifies namespaces and workload resources, and confirms that
the Rollouts CRDs include `AnalysisTemplate` support. It does not connect to a
Kubernetes cluster.
