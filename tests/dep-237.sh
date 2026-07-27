#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart_dir="$repo_root/helm/sports-store"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

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
done

raw_ref_count="$(rg --count 'name: sports-store-app-secrets' "$repo_root/k8s/03-deployments.yaml")"
[[ "$raw_ref_count" == "6" ]] || fail "Raw Deployments must contain exactly six application Secret references"

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

rendered_ref_count="$(rg --count 'name: sports-store-app-secrets' "$rendered")"
[[ "$rendered_ref_count" -ge 9 ]] || fail "Rendered workloads do not consistently reference the generated Secret"
assert_contains "$rendered" 'kind: ExternalSecret' "Helm did not render the ExternalSecret"
assert_contains "$rendered" 'MONGO_URI: "mongodb://root:\{\{ .mongoRootPassword \| urlquery \}\}@sports-store-mongodb' \
  "Rendered MongoDB URI does not encode the synchronized password"

printf 'DEP-237 acceptance tests passed.\n'
