#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local value="$2"
  local description="$3"
  grep -Fq -- "$value" "$file" || fail "$description"
}

for step in \
  'bootstrap/00-namespaces.yaml' \
  'kubernetes/storageclasses/ebs-gp3-retain.yaml' \
  'helm upgrade --install argocd' \
  'projects/sports-store-project.yaml' \
  'bootstrap/argocd.yaml' \
  'apps/root-app.yaml' \
  'apps/platform-controllers.yaml' \
  'apps/kubecost/kubecost.yaml'; do
  assert_contains scripts/bootstrap-gitops.ps1 "$step" "bootstrap script is missing $step"
done

assert_contains apps/platform-controllers.yaml 'targetRevision: 3.5.0' \
  'AWS Load Balancer Controller chart version is not pinned'
assert_contains apps/platform-controllers.yaml 'name: aws-load-balancer-controller' \
  'AWS Load Balancer Controller ServiceAccount does not match Pod Identity'
assert_contains apps/platform-controllers.yaml 'targetRevision: 2.8.0' \
  'External Secrets chart version is not pinned'
assert_contains apps/platform-controllers.yaml 'name: external-secrets-sa' \
  'External Secrets ServiceAccount does not match Pod Identity'
assert_contains bootstrap/00-namespaces.yaml 'name: external-secrets' \
  'External Secrets namespace is not bootstrapped'

storage_class_count="$(grep -Fc -- 'storageClass: ebs-gp3-retain' apps/kubecost/kubecost.yaml)"
[[ "$storage_class_count" == "2" ]] || fail 'Kubecost and Prometheus must both use ebs-gp3-retain'

helm template aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.5.0 \
  --namespace kube-system \
  --set clusterName=sports-store-cluster \
  --set serviceAccount.name=aws-load-balancer-controller >/dev/null
helm template external-secrets external-secrets/external-secrets \
  --version 2.8.0 \
  --namespace external-secrets \
  --set serviceAccount.name=external-secrets-sa >/dev/null

printf 'GitOps runtime bootstrap acceptance tests passed.\n'
