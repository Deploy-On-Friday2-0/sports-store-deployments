# External Secrets Operator

External Secrets Operator (ESO) connects the EKS cluster to AWS Secrets Manager.
The controller uses EKS Pod Identity through the `external-secrets-sa` ServiceAccount;
no AWS credentials or IAM role annotation belong in these manifests.

The infrastructure repository provisions the Pod Identity Agent and associates
`external-secrets/external-secrets-sa` with an IAM role that can read
`sports-store/*` secrets in AWS Secrets Manager.

## Install

The official ESO Helm chart is pinned to version `2.8.0`.

```bash
kubectl apply -f k8s/external-secrets/00-namespace.yaml

helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version 2.8.0 \
  --namespace external-secrets \
  --values k8s/external-secrets/values.yaml \
  --wait

kubectl apply -f k8s/external-secrets/cluster-secret-store.yaml
```

The chart installs the ESO CRDs, so apply the `ClusterSecretStore` only after the
Helm release is ready.

## Verify

```bash
kubectl rollout status deployment/external-secrets -n external-secrets
kubectl get pods -n external-secrets
kubectl get serviceaccount external-secrets-sa -n external-secrets
kubectl get deployment external-secrets -n external-secrets \
  -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
kubectl wait clustersecretstore/aws-secrets-manager \
  --for=condition=Ready \
  --timeout=120s
kubectl describe clustersecretstore aws-secrets-manager
```

The ServiceAccount command must print `external-secrets-sa`, and the store must
report `Ready=True`. If the store is not ready, inspect the ESO controller logs and
confirm the EKS Pod Identity association and IAM permissions in the infrastructure
repository.

The application chart and raw manifests each include an `ExternalSecret` in the
`sports-store` namespace. Use only the deployment path selected for the application;
both synchronize `sports-store/production/config` into the same Kubernetes Secret,
`sports-store-app-secrets`, every hour.

## Verify application synchronization

These checks display resource state and key names, never secret values:

```bash
kubectl wait externalsecret/sports-store-app-secrets \
  --namespace sports-store \
  --for=condition=Ready \
  --timeout=120s

kubectl get externalsecret sports-store-app-secrets -n sports-store
kubectl get secret sports-store-app-secrets -n sports-store \
  -o go-template='{{range $key, $_ := .data}}{{$key}}{{"\n"}}{{end}}'
kubectl get secret sports-store-app-secrets -n sports-store \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}'
```

The key list (Helm deployment path) must contain `MONGO_URI`, `JWT_SECRET`,
`mongodb-root-password`, `mongodb-replica-set-key`, and `redis-password`. The AWS
property names are intentionally not copied into the generated Secret as duplicate
keys. The owner must be `ExternalSecret/sports-store-app-secrets`.

## Required AWS Secrets Manager properties

The `ExternalSecret` only *references* AWS Secrets Manager — every property below
must already exist in the `sports-store/production/config` secret, or ESO fails to
sync the whole `sports-store-app-secrets` Secret (which then blocks MongoDB and
every service that reads `MONGO_URI`). No values live in Git.

| AWS property (`sports-store/production/config`) | Generated Secret key | Consumer |
| --- | --- | --- |
| `MONGO_INITDB_ROOT_PASSWORD` | `mongodb-root-password`, `MONGO_URI` | all services + MongoDB root |
| `MONGODB_REPLICA_SET_KEY` | `mongodb-replica-set-key` | MongoDB ReplicaSet internal auth (keyfile) |
| `JWT_SECRET_KEY` | `JWT_SECRET` | auth service |
| `REDIS_PASSWORD` | `redis-password` | auth, cart, Redis |

### DEP-320 — `MONGODB_REPLICA_SET_KEY` missing

After the MongoDB Deployment→StatefulSet ReplicaSet conversion (DEP-290/291), the
ReplicaSet members authenticate to each other with a shared keyfile taken from
`mongodb-replica-set-key`. If `MONGODB_REPLICA_SET_KEY` is absent from AWS Secrets
Manager, the `ExternalSecret` reports a `SecretSyncedError` and the ReplicaSet
never forms. Add it once, out-of-band, as an authorized operator (never commit the
value, never print it):

```bash
# Generate a keyfile value (base64 charset, 6-1024 chars per MongoDB).
KEY="$(openssl rand -base64 32)"

# Merge it into the existing secret JSON without echoing the value.
aws secretsmanager get-secret-value \
  --secret-id sports-store/production/config \
  --query SecretString --output text > cfg.json
jq --arg k "$KEY" '. + {MONGODB_REPLICA_SET_KEY: $k}' cfg.json > cfg.new.json
aws secretsmanager put-secret-value \
  --secret-id sports-store/production/config \
  --secret-string file://cfg.new.json
shred -u cfg.json cfg.new.json 2>/dev/null || rm -f cfg.json cfg.new.json
```

Then force an immediate resync (see below) and confirm the ReplicaSet forms:

```bash
kubectl get externalsecret sports-store-app-secrets -n sports-store   # Ready=True
kubectl get secret sports-store-app-secrets -n sports-store \
  -o go-template='{{range $k,$_ := .data}}{{$k}}{{"\n"}}{{end}}' | grep mongodb-replica-set-key
kubectl -n sports-store rollout status statefulset/sports-store-mongodb
```

> Redis (`REDIS_PASSWORD` / `redis-password`) is tracked separately; see DEP-283/321
> for its enablement. It is listed here only to keep this the single source of truth
> for the `sports-store/production/config` properties.

After an authorized operator updates the AWS secret, request an immediate refresh
and confirm the Kubernetes Secret's resource version changes. Do not print or decode
the Secret during this check:

```bash
kubectl get secret sports-store-app-secrets -n sports-store \
  -o jsonpath='{.metadata.resourceVersion}{"\n"}'
kubectl annotate externalsecret sports-store-app-secrets -n sports-store \
  force-sync="$(date +%s)" --overwrite
kubectl wait externalsecret/sports-store-app-secrets -n sports-store \
  --for=condition=Ready --timeout=120s
kubectl get secret sports-store-app-secrets -n sports-store \
  -o jsonpath='{.metadata.resourceVersion}{"\n"}'
```

To validate owner cleanup in a disposable environment, delete the `ExternalSecret`
and confirm its generated Secret disappears. Reapply the raw manifest or run a Helm
upgrade immediately afterward to restore it:

```bash
kubectl delete externalsecret sports-store-app-secrets -n sports-store
kubectl wait --for=delete secret/sports-store-app-secrets -n sports-store --timeout=60s
```
