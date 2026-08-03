#!/usr/bin/env bash
#
# DEP-271 (Sub-PRD 7 2.3.2) - Validation Drill.
#
# Proves that a breaking container image tag which aborts an Argo Rollout
# triggers a K8sGPT root-cause analysis to Slack (#k8s-ai-diagnostics) within
# 3 minutes.
#
# The drill:
#   1. pauses Argo CD auto-sync on the app (so self-heal doesn't fight us),
#   2. sets a non-existent image tag on the Rollout (-> ImagePullBackOff),
#   3. waits for the Rollout to go Degraded/Aborted,
#   4. waits for a K8sGPT Result about the failing workload (the same event that
#      is posted to Slack) to appear within the 3-minute SLA,
#   5. always rolls back: undoes the Rollout and restores auto-sync.
#
# It is intentionally reversible and safe to re-run. It must be run by an
# operator with kubectl access to the production EKS cluster.
#
# Usage:
#   ./scripts/dep-271-validation-drill.sh [--service catalog] [--namespace sports-store]
#
set -euo pipefail

SERVICE="catalog"
NAMESPACE="sports-store"
ARGOCD_APP="sports-store-production"
ARGOCD_NS="argocd"
K8SGPT_NS="k8sgpt-operator"
BREAKING_TAG="9.9.9-dep271-drill-broken"
SLA_SECONDS=180   # 3-minute acceptance-criteria window
SLACK_CHANNEL="#k8s-ai-diagnostics"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --app) ARGOCD_APP="$2"; shift 2 ;;
    --tag) BREAKING_TAG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; }

ORIGINAL_IMAGE=""
SYNC_PAUSED="false"

restore() {
  log "Teardown: restoring a healthy state"
  if [[ -n "$ORIGINAL_IMAGE" ]]; then
    kubectl argo rollouts set image "$SERVICE" "$SERVICE=$ORIGINAL_IMAGE" -n "$NAMESPACE" || true
    kubectl argo rollouts undo "$SERVICE" -n "$NAMESPACE" || true
  fi
  if [[ "$SYNC_PAUSED" == "true" ]]; then
    # Re-enable automated prune + self-heal on the Argo CD Application.
    kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' || true
    ok "auto-sync restored on $ARGOCD_APP"
  fi
}
trap restore EXIT

# --- 0. Preconditions ---------------------------------------------------------
log "Preconditions"
command -v kubectl >/dev/null || { fail "kubectl not found"; exit 1; }
kubectl argo rollouts version >/dev/null 2>&1 || { fail "kubectl-argo-rollouts plugin not found"; exit 1; }
kubectl get rollout "$SERVICE" -n "$NAMESPACE" >/dev/null || { fail "Rollout $SERVICE/$NAMESPACE not found"; exit 1; }
kubectl get k8sgpt -n "$K8SGPT_NS" >/dev/null 2>&1 || { fail "K8sGPT CRs not found in $K8SGPT_NS"; exit 1; }
if ! kubectl get k8sgpt -n "$K8SGPT_NS" -o jsonpath='{.items[*].spec.targetNamespace}' | tr ' ' '\n' | grep -qx "$NAMESPACE"; then
  fail "No K8sGPT instance targets namespace '$NAMESPACE' — the drill cannot pass. Apply k8sgpt-sports-store."
  exit 1
fi
ok "cluster reachable, Rollout present, K8sGPT analyses '$NAMESPACE'"

ORIGINAL_IMAGE="$(kubectl get rollout "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='$SERVICE')].image}")"
BREAKING_IMAGE="${ORIGINAL_IMAGE%:*}:$BREAKING_TAG"
ok "current image: $ORIGINAL_IMAGE"

# --- 1. Pause auto-sync -------------------------------------------------------
log "Pausing Argo CD auto-sync on $ARGOCD_APP (so self-heal doesn't revert the drill)"
kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
SYNC_PAUSED="true"
ok "auto-sync paused"

# --- 2. Inject the breaking image ---------------------------------------------
log "Injecting breaking image: $BREAKING_IMAGE"
kubectl argo rollouts set image "$SERVICE" "$SERVICE=$BREAKING_IMAGE" -n "$NAMESPACE"
DRILL_START="$(date +%s)"

# --- 3. Wait for the Rollout to abort/degrade ---------------------------------
log "Waiting for Rollout to abort/degrade"
deadline=$(( DRILL_START + SLA_SECONDS ))
rollout_bad="false"
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  phase="$(kubectl argo rollouts status "$SERVICE" -n "$NAMESPACE" --timeout 5s 2>/dev/null || true)"
  status="$(kubectl get rollout "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if echo "$phase $status" | grep -qiE 'Degraded|Aborted|Error'; then
    rollout_bad="true"; ok "Rollout is unhealthy (Degraded/Aborted)"; break
  fi
  sleep 5
done
[[ "$rollout_bad" == "true" ]] || { fail "Rollout did not abort within the window"; exit 1; }

# --- 4. Assert K8sGPT produced an analysis within the SLA ---------------------
log "Waiting for a K8sGPT Result about $NAMESPACE within the 3-minute SLA"
found="false"
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  if kubectl get results.core.k8sgpt.ai -n "$K8SGPT_NS" \
      -o jsonpath='{range .items[*]}{.spec.name}{"\n"}{end}' 2>/dev/null \
      | grep -qiE "(^|/)${NAMESPACE}/|${SERVICE}"; then
    found="true"; break
  fi
  sleep 10
done
elapsed=$(( $(date +%s) - DRILL_START ))

if [[ "$found" == "true" ]]; then
  ok "K8sGPT Result found after ${elapsed}s (SLA ${SLA_SECONDS}s)"
  echo
  kubectl get results.core.k8sgpt.ai -n "$K8SGPT_NS" -o wide || true
  echo
  ok "DRILL PASSED — verify the root-cause message posted to $SLACK_CHANNEL and screenshot it for the DEP-271 evidence."
else
  fail "No K8sGPT Result for $NAMESPACE within ${SLA_SECONDS}s — DRILL FAILED."
  echo "Debug: kubectl logs -n $K8SGPT_NS deploy/k8sgpt-operator-controller-manager"
  exit 1
fi
