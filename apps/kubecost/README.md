# Kubecost allocation (DEP-267) + core Prometheus integration (DEP-319)

[`kubecost.yaml`](kubecost.yaml) defines a reusable, production-like baseline
for an Argo CD-managed Kubecost deployment. It pins the official `cost-analyzer`
chart at `2.8.7`, deploys to the `kubecost` namespace, and identifies metrics as
coming from `sports-store-cluster`. This is a safe baseline, not a claim that the
configuration is production-sized or validated against the live cluster.

## Architecture and defaults

- **DEP-319: Kubecost uses the core kube-prometheus-stack**, not a bundled
  Prometheus. `global.prometheus.enabled: false` and `global.prometheus.fqdn`
  points at `http://prometheus-stack-kube-prom-prometheus.monitoring.svc:9090`
  — the Prometheus Service created by
  [`apps/monitoring/prometheus-stack.yaml`](../monitoring/prometheus-stack.yaml)
  (chart `kube-prometheus-stack`, release `prometheus-stack`, namespace
  `monitoring`). This avoids running a second, duplicate Prometheus in the
  cluster.
- The reverse direction is also wired: `serviceMonitor.enabled: true` and
  `prometheusRule.enabled: true`, both labelled `release: prometheus-stack` so
  the core Prometheus Operator selects them (its default
  `serviceMonitorSelectorNilUsesHelmValues` only matches that release label).
  Kubecost's cost-model `/metrics` are then scraped by the core Prometheus and
  its recording rules are loaded there.
- Kubecost persistence is enabled with a `10Gi` request. The bundled Prometheus
  and its separate persistence/retention are no longer part of this Application.
- No `storageClass` is set. Kubernetes therefore uses the cluster's default
  StorageClass. To select a verified class explicitly, set
  `persistentVolume.storageClass`. Do not set it to an empty value; omit it to
  retain default-class behavior.
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
| Bundled Prometheus | `global.prometheus.enabled` | `false` |
| Core Prometheus endpoint | `global.prometheus.fqdn` | `http://prometheus-stack-kube-prom-prometheus.monitoring.svc:9090` |
| Scrape Kubecost from core Prometheus | `serviceMonitor.enabled` | `true` |
| Kubecost recording rules in core Prometheus | `prometheusRule.enabled` | `true` |
| Operator selector label | `serviceMonitor.additionalLabels.release` / `prometheusRule.additionalLabels.release` | `prometheus-stack` |
| Kubecost persistence | `persistentVolume.enabled` | `true` |
| Kubecost volume size | `persistentVolume.size` | `10Gi` |
| Kubecost StorageClass | `persistentVolume.storageClass` | omitted |

The core Prometheus supplies the scrape targets Kubecost needs (kube-state-metrics,
node-exporter, and cadvisor) — all shipped by `kube-prometheus-stack`. If the
monitoring release name or namespace ever changes, update `global.prometheus.fqdn`
and the two `release` labels to match; never put credentials in this file.

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
and has an acceptable reclaim policy. Confirm the core Prometheus is running and
reachable at `global.prometheus.fqdn` before syncing Kubecost:

```sh
kubectl -n monitoring get svc prometheus-stack-kube-prom-prometheus
kubectl -n argocd get application prometheus-stack
```

Also confirm the cluster permits the chart's cluster-scoped read RBAC and that
namespace Pod Security controls accept the rendered security contexts.

## Resource sizing

The values are conservative starting points for this small learning cluster:

| Component | Request | Limit |
| --- | --- | --- |
| frontend | `25m`, `64Mi` | `250m`, `256Mi` |
| cost-model | `200m`, `256Mi` | `750m`, `1Gi` |
| aggregator | `100m`, `256Mi` | `500m`, `1Gi` |
| cloud-cost | `50m`, `128Mi` | `250m`, `512Mi` |

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

Confirm the core Prometheus discovered Kubecost's ServiceMonitor (DEP-319):

```sh
kubectl -n kubecost get servicemonitor kubecost-cost-analyzer \
  -o jsonpath='{.metadata.labels.release}{"\n"}'   # must print prometheus-stack
# In the Prometheus UI (Status > Targets), the kubecost cost-model target is Up.
```

Open `http://localhost:9090` during the port-forward. Verify Allocation views by
namespace, service, deployment, and controller, including Idle and shared costs
for `kube-system` and `kubecost`. Prometheus needs time to collect samples and
Kubecost needs time to complete ETL windows. AWS bill reconciliation, CUR,
Athena, S3, IAM, IRSA, Pod Identity, TLS, authentication, network policy, backup,
and multi-cluster/federated storage are outside this change and require separate
runtime design and validation.
