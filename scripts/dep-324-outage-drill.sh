#!/usr/bin/env bash
#
# DEP-324 (PRD Step 3) - Direct ALB Ingress Routing & Outage SPOF Isolation Drill.
#
# Proves two things about the production cluster:
#   1. Direct ALB routing: dynamic /api/* traffic reaches the EKS backend pods
#      straight from the AWS ALB - no gateway workload exists in the path.
#   2. Outage SPOF isolation: taking one service (payment) down does not
#      disrupt any of the other services; only payment's own endpoints fail.
#
# The drill:
#   1. resolves the ALB DNS name from the Ingress status,
#   2. asserts the gateway workload is absent (no Deployment/Service/pods) and
#      that every backend answers through the ALB (FastAPI 2xx/4xx JSON, never
#      ALB 502/503/504), proving direct pod delivery,
#   3. pauses Argo CD auto-sync on production-payment-service (so self-heal
#      doesn't fight us), drops the payment HPA minReplicas to 0, scales the
#      payment Deployment to 0, and waits for every payment pod to disappear,
#   4. re-verifies the other four services still answer through the ALB and
#      that /api/payments now fails (contained blast radius),
#   5. always restores: payment replicas + HPA minReplicas and auto-sync, then
#      waits until payment is healthy again.
#
# It is intentionally reversible and safe to re-run. It must be run by an
# operator with kubectl + AWS CLI access to the production EKS cluster.
#
# Usage:
#   ./scripts/dep-324-outage-drill.sh [--namespace sports-store] \
#       [--app production-payment-service] [--target payment]
#
set -euo pipefail

NAMESPACE="sports-store"
ARGOCD_NS="argocd"
INGRESS_NAME="sports-store-gateway"   # historical name (fullnameOverride), ALB is adopted under it
ALB_NAME="alb-sports-store"
TARGET="payment"
ARGOCD_APP="production-${TARGET}-service"
DOWN_TIMEOUT=180
RECOVERY_TIMEOUT=300
CURL_TIMEOUT=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --app) ARGOCD_APP="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

ORIGINAL_MIN_REPLICAS=""
DEPLOYMENT_SCALED="false"
SYNC_PAUSED="false"
HPA_DELETED="false"
TARGET_PODS=""
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

restore() {
  log "Teardown: restoring a healthy state"
  if [[ "$SYNC_PAUSED" == "true" ]]; then
    kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' || true
    ok "auto-sync restored on $ARGOCD_APP"
  fi
  if [[ "$DEPLOYMENT_SCALED" == "true" ]]; then
    kubectl -n "$NAMESPACE" scale deployment "$TARGET" --replicas="${ORIGINAL_MIN_REPLICAS:-2}" || true
    ok "deployment/$TARGET scaled back to ${ORIGINAL_MIN_REPLICAS:-2} replicas"
  fi
  if [[ "$HPA_DELETED" == "true" ]]; then
    # The HPA was deleted for the outage window; Argo CD recreates it from Git
    # once auto-sync runs again (the last step below).
    :
  fi
}
trap restore EXIT

# --- 0. Preconditions ---------------------------------------------------------
log "Preconditions"
command -v kubectl >/dev/null || { fail "kubectl not found"; exit 1; }
command -v aws >/dev/null || { fail "aws CLI not found"; exit 1; }
command -v curl >/dev/null || { fail "curl not found"; exit 1; }
kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" >/dev/null 2>&1 \
  || { fail "Ingress '$INGRESS_NAME' not found in $NAMESPACE"; exit 1; }
kubectl -n "$ARGOCD_NS" get application "$ARGOCD_APP" >/dev/null 2>&1 \
  || { fail "Argo CD Application '$ARGOCD_APP' not found"; exit 1; }
kubectl -n "$NAMESPACE" get hpa "$TARGET" >/dev/null 2>&1 \
  || { fail "HPA '$TARGET' not found in $NAMESPACE"; exit 1; }
ok "cluster reachable; ingress + Argo app + HPA present"

# --- 1. Resolve the ALB and prove gateway absence -----------------------------
log "Resolving the ALB DNS name"
ALB_DNS="$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [[ -z "$ALB_DNS" ]]; then
  ALB_DNS="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)"
fi
[[ -n "$ALB_DNS" ]] || { fail "could not resolve the ALB DNS name"; exit 1; }
ok "ALB: $ALB_DNS"

log "Asserting the gateway workload is absent from the cluster"
if kubectl get deployment gateway -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "gateway Deployment still exists in $NAMESPACE - routing is NOT direct"
fi
if kubectl get service gateway -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "gateway Service still exists in $NAMESPACE - routing is NOT direct"
fi
gateway_pods="$(kubectl get pods -n "$NAMESPACE" -l app=gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "$gateway_pods" == "0" ]] || fail "found $gateway_pods gateway pods still running"
ok "no gateway workload present - the ALB is the only entry point"

# --- 2. Direct routing: every backend answers through the ALB -----------------
# Every backend answers with FastAPI JSON: catalog 200 (public list), the
# auth-gated services 401/404 with {"detail": ...}. ALB 502/503/504 (no healthy
# targets) is the failure signature we assert against.
log "Verifying direct ALB -> backend pod routing for all five services"
expect_alive() {
  local path="$1" label="$2"
  local code
  code="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
    --max-time "$CURL_TIMEOUT" "http://$ALB_DNS$path" 2>/dev/null || true)"
  if [[ "$code" =~ ^(502|503|504)$ ]] || [[ -z "$code" ]]; then
    fail "$label: ALB returned $code (no healthy backend target) - routing is broken"
  fi
  if ! head -c 1 "$BODY_FILE" 2>/dev/null | grep -q '[{[]'; then
    fail "$label: expected a FastAPI JSON response, got HTTP $code"
  fi
  ok "$label: HTTP $code with JSON body (served by a backend pod)"
}

# ALB target-group health checks lag pod readiness, so after a restore wait for
# the endpoint to come back through the ALB itself (up to --alive-timeout).
wait_alive() {
  local path="$1" label="$2" timeout="${3:-120}"
  local deadline=$(( $(date +%s) + timeout ))
  local code
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    code="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
      --max-time "$CURL_TIMEOUT" "http://$ALB_DNS$path" 2>/dev/null || true)"
    [[ "$code" =~ ^(502|503|504)$ ]] || [[ -z "$code" ]] || break
    sleep 5
  done
  expect_alive "$path" "$label"
}
expect_alive "/api/products" "catalog (GET /api/products)"
expect_alive "/api/auth/me"  "auth (GET /api/auth/me)"
expect_alive "/api/cart"     "cart (GET /api/cart)"
expect_alive "/api/orders"   "order (GET /api/orders)"
expect_alive "/api/payments" "payment (GET /api/payments)"

# --- 3. Take payment down -----------------------------------------------------
log "Pausing auto-sync on $ARGOCD_APP (so self-heal doesn't revert the drill)"
kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
SYNC_PAUSED="true"
ok "auto-sync paused"

ORIGINAL_MIN_REPLICAS="$(kubectl -n "$NAMESPACE" get hpa "$TARGET" \
  -o jsonpath='{.spec.minReplicas}')"
ok "current hpa/$TARGET minReplicas: $ORIGINAL_MIN_REPLICAS"

# Kubernetes validation rejects minReplicas: 0 for a CPU-only HPA, so the HPA
# is deleted for the outage window instead. Argo CD (once auto-sync is resumed)
# recreates it from Git with minReplicas 2 - the HPA is a Helm-rendered,
# Git-committed resource, so GitOps restores it exactly.
log "Deleting hpa/$TARGET (minReplicas 0 is invalid) and scaling deployment/$TARGET to 0"
kubectl -n "$NAMESPACE" delete hpa "$TARGET" --wait=true
HPA_DELETED="true"
kubectl -n "$NAMESPACE" scale deployment "$TARGET" --replicas=0
DEPLOYMENT_SCALED="true"
ok "$TARGET scaled to zero"

log "Waiting up to ${DOWN_TIMEOUT}s for every $TARGET pod to disappear"
down_deadline=$(( $(date +%s) + DOWN_TIMEOUT ))
while [[ "$(date +%s)" -lt "$down_deadline" ]]; do
  TARGET_PODS="$(kubectl get pods -n "$NAMESPACE" -l app="$TARGET" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${TARGET_PODS:-0}" == "0" ]]; then ok "all $TARGET pods gone"; break; fi
  sleep 5
done
[[ "${TARGET_PODS:-1}" == "0" ]] || { fail "$TARGET pods still running after ${DOWN_TIMEOUT}s"; exit 1; }

# --- 4. SPOF isolation: only payment is affected ------------------------------
log "Verifying outage isolation - every other service must stay up"
expect_alive "/api/products" "catalog (still up during payment outage)"
expect_alive "/api/auth/me"  "auth (still up during payment outage)"
expect_alive "/api/cart"     "cart (still up during payment outage)"
expect_alive "/api/orders"   "order (still up during payment outage)"

log "Verifying the blast radius is contained - payment itself must now fail"
code="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
  --max-time "$CURL_TIMEOUT" "http://$ALB_DNS/api/payments" 2>/dev/null || true)"
if [[ "$code" =~ ^(502|503|504)$ ]]; then
  ok "payment down: ALB returned $code (expected - outage contained to payment)"
else
  fail "payment outage not observed: /api/payments returned $code"
fi

# --- 5. Restore and verify recovery -------------------------------------------
log "Restoring $TARGET"
kubectl -n "$NAMESPACE" scale deployment "$TARGET" --replicas="${ORIGINAL_MIN_REPLICAS:-2}"
kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
SYNC_PAUSED="false"
DEPLOYMENT_SCALED="false"
ok "$TARGET scaled back to ${ORIGINAL_MIN_REPLICAS:-2}; auto-sync resumed (Argo CD recreates hpa/$TARGET from Git)"

log "Waiting for Argo CD to recreate hpa/$TARGET (GitOps restore)"
hpa_deadline=$(( $(date +%s) + 180 ))
while [[ "$(date +%s)" -lt "$hpa_deadline" ]]; do
  if kubectl -n "$NAMESPACE" get hpa "$TARGET" >/dev/null 2>&1; then
    HPA_DELETED="false"
    ok "hpa/$TARGET recreated"
    break
  fi
  sleep 5
done
if kubectl -n "$NAMESPACE" get hpa "$TARGET" >/dev/null 2>&1; then
  min_replicas="$(kubectl -n "$NAMESPACE" get hpa "$TARGET" -o jsonpath='{.spec.minReplicas}')"
  [[ "${min_replicas:-0}" == "${ORIGINAL_MIN_REPLICAS:-2}" ]] \
    || { fail "hpa/$TARGET recreated with minReplicas=$min_replicas, expected ${ORIGINAL_MIN_REPLICAS:-2}"; exit 1; }
else
  fail "hpa/$TARGET was not recreated within 180s of resuming auto-sync"
  exit 1
fi

log "Waiting up to ${RECOVERY_TIMEOUT}s for payment to become ready again"
kubectl -n "$NAMESPACE" rollout status deployment/"$TARGET" --timeout="${RECOVERY_TIMEOUT}s" >/dev/null
recovery_deadline=$(( $(date +%s) + 120 ))
while [[ "$(date +%s)" -lt "$recovery_deadline" ]]; do
  ready="$(kubectl get deployment "$TARGET" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ "${ready:-0}" -ge "${ORIGINAL_MIN_REPLICAS:-2}" ]] && break
  sleep 5
done
[[ "${ready:-0}" -ge "${ORIGINAL_MIN_REPLICAS:-2}" ]] \
  || { fail "payment did not reach ${ORIGINAL_MIN_REPLICAS:-2} ready replicas"; exit 1; }
ok "payment healthy again"
wait_alive "/api/payments" "payment (recovered)" 120

echo
ok "DRILL PASSED - ALB routes /api/* directly to backend pods (gateway bypassed)"
ok "DRILL PASSED - payment outage left auth/catalog/cart/order unaffected (no SPOF)"
ok "Capture screenshots with timestamps for the DEP-324 evidence."
