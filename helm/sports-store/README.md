# sports-store (parent Helm chart)

Milestone 3: a single Helm chart that renders all 7 first-party microservice
Deployments/Services plus an Ingress, and depends on the upstream Bitnami
MongoDB chart as a sub-chart. Supersedes-in-spirit but does not replace
`k8s/`'s raw manifests (Milestone 2) — both stay in the repo; this is the
newer, DRY path.

## Prerequisites

A Kubernetes cluster with the `sports-store` namespace already created
(`kubectl apply -f ../../k8s/00-namespace.yaml`) is required. MongoDB uses
preferred hostname anti-affinity and preferred zone spreading. Production
clusters should provide at least three schedulable workers across multiple
zones, while smaller development clusters remain schedulable. The 7
`:v1.0.0` application images must also be available (see
`../../k8s/README.md` "Local images"). This chart does not build images or
manage the namespace itself.

On EKS, the platform must install the AWS EBS CSI Driver and provide the
`ebs-gp3-retain` StorageClass before this chart is deployed. Both are
infrastructure-managed and are intentionally not rendered by this chart.
Verify the prerequisite:

```bash
kubectl get csidriver ebs.csi.aws.com
kubectl get pods --namespace kube-system \
  -l app.kubernetes.io/name=aws-ebs-csi-driver
kubectl get storageclass ebs-gp3-retain -o yaml
```

The StorageClass contract is `ebs.csi.aws.com`, gp3, encrypted, `Retain`,
`WaitForFirstConsumer`, and expansion enabled. Do not deploy the EKS values
until the CSI controller and node components are healthy.

Create `app-secrets` before installing. This Secret is managed outside Helm
so credentials never appear in committed values or rendered manifests. The
ReplicaSet key must be shared by all members, and `MONGO_URI` must identify
the ReplicaSet. The following example generates credentials in the current
shell; use the platform secret manager in shared environments:

```bash
MONGODB_ROOT_PASSWORD="$(openssl rand -hex 24)"
MONGODB_REPLICA_SET_KEY="$(openssl rand -hex 64)"
JWT_SECRET="$(openssl rand -hex 32)"
MONGO_URI="mongodb://root:${MONGODB_ROOT_PASSWORD}@sports-store-mongodb-headless:27017/?authSource=admin&replicaSet=rs0"

kubectl create secret generic app-secrets \
  --namespace sports-store \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=MONGO_URI="$MONGO_URI" \
  --from-literal=mongodb-root-password="$MONGODB_ROOT_PASSWORD" \
  --from-literal=mongodb-replica-set-key="$MONGODB_REPLICA_SET_KEY"
unset MONGODB_ROOT_PASSWORD MONGODB_REPLICA_SET_KEY JWT_SECRET MONGO_URI
```

If the release name is not `sports-store`, replace the URI host with
`<release>-mongodb-headless`. The headless Service is a discovery seed; the
MongoDB driver discovers each member's stable StatefulSet DNS identity and
the current Primary.

## Install

```bash
helm dependency build .
# Local cluster
helm install sports-store . --namespace sports-store

# EKS
helm install sports-store . --namespace sports-store -f values-eks.yaml
```

## Upgrade / rollback / uninstall

```bash
# after editing values.yaml (or with -f a values override / --set)
helm upgrade sports-store . --namespace sports-store

# EKS upgrades must continue supplying the environment override
helm upgrade sports-store . --namespace sports-store -f values-eks.yaml

helm rollback sports-store <revision> --namespace sports-store

helm uninstall sports-store --namespace sports-store
```

The MongoDB StatefulSet retains its per-member claims when scaled or deleted.
Each member has a separate `ReadWriteOnce` volume; MongoDB replicates writes
through its oplog. On EKS, the StorageClass's `Retain` reclaim policy also
keeps the PV and EBS volume if a PVC is manually deleted. Helm rollback does
not reverse a database or storage migration.

## Automated validation

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest.git --version 1.0.3
helm lint .
helm lint . -f values-eks.yaml
helm unittest --strict .
```

The test renders the chart and verifies the three-member StatefulSet,
ReplicaSet authentication Secret reference, absence of an arbiter, headless
Service, independent PVC template, distribution constraints, PDB, and
application Secret references. The EKS suite also verifies three replicas use
the `ebs-gp3-retain` claim template with `ReadWriteOnce`, `8Gi`, and retained
PVCs. Infrastructure tests own assertions for the external StorageClass's CSI
provisioner, gp3 type, encryption, reclaim policy, delayed binding, and
expansion settings.

## ReplicaSet verification and failover

```bash
kubectl get statefulset --namespace sports-store
kubectl get pods --namespace sports-store -l app.kubernetes.io/name=mongodb -o wide
kubectl get pvc --namespace sports-store

MONGODB_ROOT_PASSWORD="$(kubectl get secret app-secrets --namespace sports-store \
  -o jsonpath='{.data.mongodb-root-password}' | base64 --decode)"
kubectl exec --namespace sports-store sports-store-mongodb-0 -- \
  mongosh --quiet --username root --password "$MONGODB_ROOT_PASSWORD" \
  --authenticationDatabase admin --eval 'rs.status()'
```

`rs.status()` must report exactly one healthy `PRIMARY` and two healthy
`SECONDARY` members. To verify automatic election and data durability:

1. Write a test document through the application and confirm it can be read.
2. Identify the member whose `stateStr` is `PRIMARY` in `rs.status()`.
3. Delete that Pod with `kubectl delete pod <primary> -n sports-store`.
4. Re-run `rs.status()` through either remaining Pod until a new Primary is elected.
5. Confirm application reads and writes recover without changing `MONGO_URI`.
6. Wait for the deleted Pod to become Ready and verify it rejoins as a Secondary.
7. Confirm the original test document remains available and all three PVCs remain Bound.

The PDB preserves two available members during voluntary disruptions. It
cannot protect against simultaneous involuntary node failures.

## EKS storage verification

Delayed binding means a claim can remain Pending until its MongoDB Pod is
scheduled. After rollout, verify all three ordinal claims are Bound to
different PVs:

```bash
kubectl get storageclass ebs-gp3-retain
kubectl get pvc --namespace sports-store -o wide
kubectl get pv
kubectl get pods --namespace sports-store \
  -l app.kubernetes.io/name=mongodb -o wide
```

Expected claims are `datadir-sports-store-mongodb-0`, `-1`, and `-2`. Each
must use `ebs-gp3-retain`, have access mode `RWO`, and reference a distinct PV.
For each PV, verify the CSI driver, retained lifecycle, EBS handle, and zonal
node affinity:

```bash
kubectl get pv <pv-name> \
  -o jsonpath='{.spec.csi.driver}{"\n"}{.spec.csi.volumeHandle}{"\n"}{.spec.persistentVolumeReclaimPolicy}{"\n"}{.spec.nodeAffinity}{"\n"}'

aws ec2 describe-volumes --volume-ids <volume-id> \
  --query 'Volumes[].{Id:VolumeId,Type:VolumeType,Encrypted:Encrypted,AZ:AvailabilityZone,Attachments:Attachments}'
```

Every volume must be gp3 and encrypted. Its Availability Zone must match the
scheduled worker and the PV node affinity. Three MongoDB members must have
three different EBS volume IDs; EBS volumes are never shared between members.

## Retention test and recovery

Perform this only in a non-production environment:

1. Deploy with `values-eks.yaml`, write test data, and verify ReplicaSet health.
2. Record all three PVC names, PV names, and `.spec.csi.volumeHandle` values.
3. Run `helm uninstall sports-store --namespace sports-store`.
4. Confirm the PVCs remain and each EBS volume still exists.
5. Confirm any deliberately deleted PVC leaves its PV in `Released` with reclaim policy `Retain`.
6. Reinstall with the same release name to reuse retained ordinal PVCs, then verify the data.

A `Released` retained PV is not automatically reusable. Recovery requires an
operator to validate the EBS volume, clear or recreate the PV claim binding as
appropriate, and bind a replacement PVC with matching size, StorageClass,
access mode, and Availability Zone. Cleanup is also manual: verify backups and
the rollback window before deleting retained PVs and EBS volumes, which
continue to incur AWS charges.

## Existing storage migration

Changing `mongodb.persistence.storageClass` does not migrate an existing PVC,
and changing a deployed StatefulSet claim template can be rejected as
immutable. The previous standalone Deployment PVC and existing `standard`
StatefulSet claims are not automatically adopted as gp3 claims. For an
existing installation:

1. Stop application writes and create a verified logical backup with `mongodump`.
2. Retain the standalone PVC for rollback; do not delete it.
3. Deploy a new gp3-backed ReplicaSet/PVC set; do not delete or mutate the old claims automatically.
4. Restore with `mongorestore` through the Primary or headless discovery URI.
5. Compare collection counts and indexes, then run application read/write and failover checks.
6. Remove the old PVC only after the rollback window has closed.

EBS is Availability Zone-specific. Moving data to another zone requires a
logical restore or EBS snapshot/restore workflow; an existing EBS volume
cannot simply attach in a different zone. PVC expansion is supported by the
StorageClass, but shrinking is not supported.

## Design notes

**Resource names stay unprefixed** (`auth`, `catalog`, `frontend`, ... —
not `sports-store-auth`). `sports-store-gateway`'s `nginx.conf` (baked into
its image, not templated by this chart) proxies to those exact short
hostnames, and `values.yaml`'s `CATALOG_URL`/`CART_URL`/`PAYMENT_URL` env
entries reference them the same way — same DNS constraint as the raw `k8s/`
manifests. `templates/_helpers.tpl`'s `sports-store.fullname` (the standard
release-prefixed convention) exists for governance and is used for the one
resource nothing else needs to resolve by a fixed name: the Ingress.

**MongoDB's hostname is release-dependent.** ReplicaSet mode creates the
headless Service `<release>-mongodb-headless`. Pods advertise stable names
such as `<release>-mongodb-0.<release>-mongodb-headless`; the external
`app-secrets` Secret must use the matching Service name in `MONGO_URI`.

**No separate seeding Job.** MongoDB's own container entrypoint already
runs any `*.js` file under `/docker-entrypoint-initdb.d/` exactly once,
against an empty data directory — idempotent by construction, and already
proven twice (Milestone 2 and above). `templates/mongodb-init-configmap.yaml`
mounts `seed/init-mongo.js` there via the subchart's
`extraVolumes`/`extraVolumeMounts` (see `values.yaml`'s `mongodb:` key). A
separate Job hitting that same path wouldn't do anything — that path only
has meaning to MongoDB's own entrypoint script.

**`gateway` is deployed but not in the Ingress.** All 7 microservices get a
Deployment/Service; the Ingress (`templates/ingress.yaml`) routes straight
to `frontend` and each backend by `ingressPath` (set per-service in
`values.yaml`) rather than through `gateway`, so Ingress paths can match
what the frontend actually calls (`/api/products`, `/api/auth`, ...) without
a second rebuild of the gateway image with different upstream names. Same
choice as the raw `k8s/04-ingress.yaml`, carried over here.

**Bitnami image substitution.** `values.yaml`'s `mongodb.image.repository`
points at `bitnamilegacy/mongodb` instead of `bitnami/mongodb` — Bitnami
stopped publishing pinned version tags to the free catalog, only `:latest`
remains there. `bitnamilegacy` is Bitnami's own mirror for this migration.
`helm install`/`upgrade` print a "SECURITY WARNING: Original containers have
been substituted" notice because of this — expected, not a chart bug.
