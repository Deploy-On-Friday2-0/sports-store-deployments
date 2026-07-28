#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart_dir="$repo_root/helm/sports-store"
rendered="$(mktemp)"
rendered_deployments="$(mktemp)"
trap 'rm -f "$rendered" "$rendered_deployments"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  rg --quiet "$pattern" "$file" || fail "$message"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  rg --quiet "$pattern" "$file" && fail "$message"
  return 0
}

assert_count() {
  local file="$1"
  local pattern="$2"
  local expected="$3"
  local message="$4"
  local actual
  actual="$(rg --count "$pattern" "$file" || true)"
  [[ "${actual:-0}" == "$expected" ]] || fail "$message (expected $expected, found ${actual:-0})"
}

for manifest in \
  "$repo_root/k8s/01-external-secret.yaml" \
  "$chart_dir/templates/external-secret.yaml"; do
  assert_contains "$manifest" 'refreshInterval: 1h' "Hourly refresh is missing from $manifest"
  assert_contains "$manifest" 'name: aws-secrets-manager' "ClusterSecretStore reference is missing from $manifest"
  assert_contains "$manifest" 'creationPolicy: Owner' "Owner creation policy is missing from $manifest"
  assert_contains "$manifest" 'deletionPolicy: Delete' "Delete policy is missing from $manifest"
  assert_contains "$manifest" 'key: sports-store/production/config' "AWS secret path is missing from $manifest"
  assert_contains "$manifest" 'property: MONGO_INITDB_ROOT_PASSWORD' "MongoDB property mapping is missing from $manifest"
  assert_contains "$manifest" 'property: JWT_SECRET_KEY' "JWT property mapping is missing from $manifest"
  assert_not_contains "$manifest" '^[[:space:]]+MONGO_INITDB_ROOT_PASSWORD:' "Raw MongoDB property is exposed in $manifest"
  assert_not_contains "$manifest" '^[[:space:]]+JWT_SECRET_KEY:' "Raw JWT property is exposed in $manifest"
done

for deployments in \
  "$repo_root/k8s/03-deployments.yaml" \
  "$chart_dir/values.yaml"; do
  assert_not_contains "$deployments" 'envFrom:' "Whole-Secret envFrom import found in $deployments"
  assert_count "$deployments" 'key: MONGO_URI' 5 "MongoDB URI access does not match the workload matrix in $deployments"
  assert_count "$deployments" 'key: JWT_SECRET' 1 "JWT access must be limited to auth in $deployments"
  assert_count "$deployments" 'key: redis-password' 2 "Redis placeholder access must be limited to auth and cart in $deployments"
  assert_count "$deployments" 'optional: true' 2 "Redis placeholder references must remain optional in $deployments"
done

assert_not_contains "$chart_dir/templates/deployment.yaml" 'envFrom:' "Helm template supports unsafe whole-Secret imports"
assert_not_contains "$chart_dir/values.yaml" 'appSecrets:' "Generic application Secret access remains enabled"

if rg --quiet --glob '*.{yaml,yml,tpl}' \
  'dev-secret-change-me|dev-mongo-pw-change-me|ZGV2LXNlY3JldA|ZGV2LW1vbmdv' "$repo_root"; then
  fail "Static credential material was found"
fi

if rg --quiet --glob '*.{yaml,yml,tpl}' '^kind: Secret$' "$repo_root"; then
  fail "A statically managed Kubernetes Secret was found"
fi

if [[ ! -d "$chart_dir/charts/mongodb" ]]; then
  helm dependency build "$chart_dir" >/dev/null
  archive="$(printf '%s\n' "$chart_dir"/charts/mongodb-*.tgz)"
  tar -xzf "$archive" -C "$chart_dir/charts"
fi

helm lint "$chart_dir"
helm template sports-store "$chart_dir" --namespace sports-store >"$rendered"
helm template sports-store "$chart_dir" --namespace sports-store \
  --show-only templates/deployment.yaml >"$rendered_deployments"

assert_contains "$rendered" 'kind: ExternalSecret' "Helm did not render the ExternalSecret"
assert_contains "$rendered" 'MONGO_URI: "mongodb://root:\{\{ .mongoRootPassword \| urlquery \}\}@sports-store-mongodb' \
  "Rendered MongoDB URI does not encode the synchronized password"
assert_not_contains "$rendered_deployments" 'envFrom:' "Rendered workloads contain a whole-Secret import"
assert_count "$rendered_deployments" 'key: MONGO_URI' 5 "Rendered MongoDB URI access does not match the workload matrix"
assert_count "$rendered_deployments" 'key: JWT_SECRET' 1 "Rendered JWT access is not limited to auth"
assert_count "$rendered_deployments" 'key: redis-password' 2 "Rendered Redis placeholder access is not limited to auth and cart"
assert_count "$rendered_deployments" 'optional: true' 2 "Rendered Redis placeholder references are not optional"

printf 'DEP-237 acceptance tests passed.\n'
