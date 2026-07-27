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

Application-level `ExternalSecret` resources and injecting generated Kubernetes
Secrets into workloads are intentionally deferred to DEP-237.
