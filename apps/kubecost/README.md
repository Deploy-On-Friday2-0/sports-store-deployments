# Kubecost allocation (DEP-267)

[`kubecost.yaml`](kubecost.yaml) defines the `kubecost` Argo CD Application for
Linear issue DEP-267. It deploys the official Kubecost `cost-analyzer` Helm
chart version `2.8.7` into the `kubecost` namespace with the cluster identity
`sports-store-cluster`.

## Architecture decisions

- Kubecost uses the chart's bundled Prometheus because this repository does not
  currently define kube-prometheus-stack, Prometheus, Thanos, VictoriaMetrics,
  or another compatible metrics endpoint. This keeps DEP-267 self-contained
  without guessing a future service name. If a shared Prometheus is introduced,
  disable `global.prometheus.enabled` and configure its verified in-cluster FQDN.
- Bundled Grafana is disabled to avoid creating a second visualization stack.
- The Kubecost service is an internal `ClusterIP`; no Ingress or public load
  balancer is created.
- Kubecost and bundled Prometheus persistence are disabled. The deployment uses
  ephemeral storage to avoid adding PVCs to this learning environment. Allocation
  history is lost if the relevant pods are recreated. The existing
  `ebs-gp3-retain` StorageClass is therefore not consumed or modified.
- AWS EKS node pricing is discovered from Kubernetes node provider metadata and
  Kubecost's AWS public pricing model. No AWS credentials, CUR, Athena, S3, IAM,
  IRSA, or Pod Identity configuration is required or included. Actual AWS bill
  reconciliation remains outside DEP-267.
- Idle allocation is enabled by default. The `kube-system` and `kubecost`
  namespaces are identified as shared costs, and tenancy costs are shared. The
  Allocation view/API can aggregate the collected Kubernetes metrics by
  namespace, service, deployment, controller, pod, or other workload dimensions.

## Deployment verification

After an authorized operator syncs the Application, verify Argo CD and the
generated resources:

```sh
kubectl -n argocd get application kubecost
kubectl -n kubecost get pods
kubectl -n kubecost get services
kubectl -n kubecost get deployments
kubectl -n kubecost logs deployment/kubecost-cost-analyzer -c cost-model
```

Access the internal UI temporarily:

```sh
kubectl -n kubecost port-forward service/kubecost-cost-analyzer 9090:9090
```

Then open `http://localhost:9090`. In **Allocations**, select a time window and:

1. Aggregate by **Namespace** to verify per-namespace costs.
2. Aggregate by **Service**, **Deployment**, or **Controller** to verify service
   or workload costs.
3. Include or inspect **Idle** to verify unallocated cluster capacity cost.
4. Inspect shared-cost distribution for `kube-system` and `kubecost`.

Prometheus must first scrape enough samples and Kubecost must complete its ETL
windows, so meaningful allocation data can take several minutes to accumulate.
Static YAML validation and local Helm rendering do not prove runtime health or
real allocation data. Real AWS billing reconciliation requires a separately
approved cloud-cost integration and is not configured by this change.
