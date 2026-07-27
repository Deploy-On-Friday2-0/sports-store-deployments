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

The key list must include `MONGO_INITDB_ROOT_PASSWORD` and `JWT_SECRET_KEY`.
The owner must be `ExternalSecret/sports-store-app-secrets`.

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
