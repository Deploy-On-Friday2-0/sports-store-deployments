#!/usr/bin/env bash
set -eu

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v python3 >/dev/null 2>&1; then
  python3 "$repo_root/tests/dep-324.py"
elif command -v python >/dev/null 2>&1; then
  python "$repo_root/tests/dep-324.py"
else
  echo "FAIL: python or python3 not found" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "SKIP: rendered routing-table check skipped (helm not installed)" >&2
  exit 0
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

# Render exactly like the production-ingress Argo CD Application does, so the
# check covers the routing table that the ALB controller actually provisions.
helm template sports-store-ingress "$repo_root/helm/sports-store" \
  --namespace sports-store \
  --values "$repo_root/helm/sports-store/values-eks.yaml" \
  --set 'fullnameOverride=sports-store-gateway' \
  --set 'enabledServices[0]=__placeholder__' \
  --set 'ingressServices={auth,catalog,cart,order,payment}' \
  --set 'platform.externalSecret=false' \
  --set 'platform.mongodbInit=false' \
  --set 'platform.canaryAnalysis=false' \
  --set 'platform.createAnalysisTemplate=false' \
  --set 'mongodb.enabled=false' \
  --set 'redis.enabled=false' \
  >"$rendered"

rg --fixed-strings --quiet 'kind: Ingress' "$rendered" || fail "no Ingress rendered for the production-ingress release"
rg --fixed-strings --quiet 'ingressClassName: alb' "$rendered" || fail "rendered ingress class is not alb"
rg --fixed-strings --quiet 'name: sports-store-gateway' "$rendered" || fail "ingress is not named sports-store-gateway"

path_count="$(rg --count --fixed-strings 'path: /api/' "$rendered" || true)"
[[ "${path_count:-0}" == "5" ]] || fail "expected exactly 5 /api/* rules, found ${path_count:-0}"

for backend in auth catalog cart order payment; do
  rg --fixed-strings --quiet "name: $backend" "$rendered" || fail "rendered ingress has no backend for $backend"
done
for banned in gateway frontend; do
  if rg --fixed-strings --quiet "name: $banned" "$rendered"; then
    fail "rendered ingress routes to the $banned workload - the gateway must be bypassed"
  fi
done

rg --fixed-strings --quiet 'alb.ingress.kubernetes.io/actions.catalog' "$rendered" || fail "missing ALB actions.catalog annotation (Argo Rollouts canary weight)"
rg --fixed-strings --quiet 'alb.ingress.kubernetes.io/actions.order' "$rendered" || fail "missing ALB actions.order annotation (Argo Rollouts canary weight)"
rg --fixed-strings --quiet 'alb.ingress.kubernetes.io/healthcheck-path: /health' "$rendered" || fail "ALB healthcheck path is not /health"

printf 'DEP-324 rendered routing-table tests passed.\n'
