# Kubecost allocation (DEP-267)

[`kubecost.yaml`](kubecost.yaml) defines a reusable, production-like baseline
for an Argo CD-managed Kubecost deployment. It pins the official `cost-analyzer`
chart at `2.8.7`, deploys to the `kubecost` namespace, and identifies metrics as
coming from `sports-store-cluster`. This is a safe baseline, not a claim that the
configuration is production-sized or validated against the live cluster.

## Architecture and defaults

- Bundled Prometheus is enabled (`global.prometheus.enabled: true`). No
  kube-prometheus-stack, Prometheus, Thanos, VictoriaMetrics, Amazon Managed
  Service for Prometheus, or compatible endpoint is defined elsewhere in this
  repository. Cluster discovery was not possible locally, so this must be
  checked before deployment to avoid duplicate monitoring.
- Kubecost persistence is enabled with a `10Gi` request. Bundled Prometheus
  persistence is enabled with a `20Gi` request and `97h` retention. The chart's
  default `49`-hour Kubecost hourly ETL window remains below Prometheus
  retention, as required by chart 2.8.7.
- No `storageClass` is set. Kubernetes therefore uses the cluster's default
  StorageClass. To select a verified class explicitly, set the same class at
  `persistentVolume.storageClass` and
  `prometheus.server.persistentVolume.storageClass`. Do not set either key to an
  empty value; omit it to retain default-class behavior.
- The aggregator uses the chart's `singlepod` deployment method and the main
  Kubecost persistent volume. The separate aggregator StatefulSet storage
  settings do not apply to this deployment model.
- Bundled Grafana and forecasting are disabled. The Kubecost service is an
  internal `ClusterIP`; neither Ingress nor a public load balancer is enabled.
- Argo CD creates the namespace and prunes chart resources. Removing the
  Application or disabling persistence can delete PVC objects and may make
  historical data unavailable. A StorageClass reclaim policy controls whether
  the underlying volume survives PVC deletion. Changing a StorageClass does not
  migrate existing data, and PVC sizes generally cannot be reduced.

## Configuring Prometheus and storage

All deployment inputs are Helm values in `kubecost.yaml`:

| Decision | Value path | Default |
| --- | --- | --- |
| Bundled Prometheus | `global.prometheus.enabled` | `true` |
| External endpoint | `global.prometheus.fqdn` | unset for external use |
| Kubecost persistence | `persistentVolume.enabled` | `true` |
| Kubecost volume size | `persistentVolume.size` | `10Gi` |
| Kubecost StorageClass | `persistentVolume.storageClass` | omitted |
| Prometheus persistence | `prometheus.server.persistentVolume.enabled` | `true` |
| Prometheus volume size | `prometheus.server.persistentVolume.size` | `20Gi` |
| Prometheus StorageClass | `prometheus.server.persistentVolume.storageClass` | omitted |
| Prometheus retention | `prometheus.server.retention` | `97h` |

For an existing Prometheus, first verify that it meets Kubecost's scrape and
recording-rule requirements. Then set `global.prometheus.enabled: false` and
set `global.prometheus.fqdn` to the verified endpoint. Do not guess its scheme,
namespace, service, port, TLS, or authentication settings. When bundled
Prometheus is disabled, its persistence values remain harmlessly unused.
Authentication should reference a pre-existing Kubernetes Secret through the
chart's supported secret-name values; never put credentials in this file.

## Pre-deployment checks

Run these against the intended cluster before the first Argo CD sync:

```sh
kubectl get storageclass
kubectl get pods -A
kubectl get svc -A
kubectl get helmreleases -A  # only when Flux HelmRelease CRDs are installed
helm list -A
```

Confirm exactly one default StorageClass exists, supports dynamic provisioning,
and has an acceptable reclaim policy. Confirm there is no existing compatible
Prometheus before retaining the bundled default. If one exists, establish its
Kubecost compatibility and endpoint/authentication contract before switching to
external mode. Also confirm the cluster permits the chart's cluster-scoped read
RBAC and that namespace Pod Security controls accept the rendered security
contexts.

## Resource sizing

The values are conservative starting points for this small learning cluster:

| Component | Request | Limit |
| --- | --- | --- |
| frontend | `25m`, `64Mi` | `250m`, `256Mi` |
| cost-model | `200m`, `256Mi` | `750m`, `1Gi` |
| aggregator | `100m`, `256Mi` | `500m`, `1Gi` |
| cloud-cost | `50m`, `128Mi` | `250m`, `512Mi` |
| Prometheus | `100m`, `256Mi` | `500m`, `1Gi` |

The `1Gi` limits are retained as burst ceilings for query/ETL and time-series
workloads; their requests remain `256Mi`, so the scheduler does not reserve
`1Gi` per component. These figures are not production sizing evidence. Tune
requests, limits, storage, and retention using real node, pod, and series counts,
scrape interval, retention target, query concurrency, and observed CPU, memory,
and disk growth. An OOM at these limits requires measured adjustment rather than
blindly removing limits.

## Local validation

The Helm validation workflow parses the Argo CD Application YAML and verifies
its basic structure:

```sh
ruby -e 'require "yaml"; YAML.safe_load_file("apps/kubecost/kubecost.yaml", aliases: true)'
```

This structural validation does not render or inspect the Kubecost Helm chart.

## Runtime verification and access

After an authorized operator syncs the Application:

```sh
kubectl -n argocd get application kubecost
kubectl -n kubecost get pods,deployments,statefulsets,services,pvc
kubectl -n kubecost describe pvc
kubectl -n kubecost logs deployment/kubecost-cost-analyzer -c cost-model
kubectl -n kubecost port-forward service/kubecost-cost-analyzer 9090:9090
```

Open `http://localhost:9090` during the port-forward. Verify Allocation views by
namespace, service, deployment, and controller, including Idle and shared costs
for `kube-system` and `kubecost`. Prometheus needs time to collect samples and
Kubecost needs time to complete ETL windows. AWS bill reconciliation, CUR,
Athena, S3, IAM, IRSA, Pod Identity, TLS, authentication, network policy, backup,
and multi-cluster/federated storage are outside this change and require separate
runtime design and validation.
