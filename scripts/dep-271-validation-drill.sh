#!/usr/bin/env bash
#
# DEP-271 (Sub-PRD 7 2.3.2) - Validation Drill.
#
# Proves that a breaking container image tag which aborts an Argo Rollout
# triggers a K8sGPT root-cause analysis to Slack (#k8s-ai-diagnostics) within
# 3 minutes of the abort.
#
# The drill:
#   1. pauses Argo CD auto-sync on the workload's per-service Application (so
#      self-heal doesn't fight us),
#   2. arms a deterministic abort by shortening the Rollout's
#      progressDeadlineSeconds and enabling progressDeadlineAbort,
#   3. sets a non-existent image tag on the Rollout (-> ImagePullBackOff), which
#      then deterministically aborts once the (shortened) progress deadline trips,
#   4. once the abort is DETECTED, starts a fresh 3-minute SLA timer and waits
#      for a K8sGPT Result about the failing workload (the same event posted to
#      Slack),
#   5. always rolls back: restores the Rollout settings + image, undoes the
#      Rollout, and re-enables auto-sync.
#
# It is intentionally reversible and safe to re-run. It must be run by an
# operator with kubectl access to the production EKS cluster.
#
# Usage:
#   ./scripts/dep-271-validation-drill.sh [--service catalog] [--namespace sports-store] \
#       [--app production-catalog-service] [--progress-deadline 60]
#
set -euo pipefail

SERVICE="catalog"
NAMESPACE="sports-store"
ARGOCD_APP=""                 # defaults to production-<service>-service (see below)
ARGOCD_NS="argocd"
K8SGPT_NS="k8sgpt-operator"
BREAKING_TAG="9.9.9-dep271-drill-broken"
ABORT_TIMEOUT=240             # max wait for the Rollout to abort after injection
SLA_SECONDS=180               # 3-minute K8sGPT SLA, measured FROM abort detection
DRILL_PROGRESS_DEADLINE=60    # shortened so the stuck canary aborts deterministically
SLACK_CHANNEL="#k8s-ai-diagnostics"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --app) ARGOCD_APP="$2"; shift 2 ;;
    --tag) BREAKING_TAG="$2"; shift 2 ;;
    --progress-deadline) DRILL_PROGRESS_DEADLINE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# DEP-248 splits production into one Argo CD Application per workload, so the
# catalog Rollout is owned by 'production-catalog-service', not a single
# 'sports-store-production' app. Derive that unless the caller overrides it.
[[ -n "$ARGOCD_APP" ]] || ARGOCD_APP="production-${SERVICE}-service"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; }

ORIGINAL_IMAGE=""
SYNC_PAUSED="false"
ROLLOUT_PATCHED="false"
ORIGINAL_PROGRESS_DEADLINE=""
ORIGINAL_PROGRESS_ABORT=""

restore() {
  log "Teardown: restoring a healthy state"
  if [[ "$ROLLOUT_PATCHED" == "true" ]]; then
    kubectl -n "$NAMESPACE" patch rollout "$SERVICE" --type merge \
      -p "{\"spec\":{\"progressDeadlineSeconds\":${ORIGINAL_PROGRESS_DEADLINE:-600},\"progressDeadlineAbort\":${ORIGINAL_PROGRESS_ABORT:-false}}}" || true
  fi
  if [[ -n "$ORIGINAL_IMAGE" ]]; then
    kubectl argo rollouts set image "$SERVICE" "$SERVICE=$ORIGINAL_IMAGE" -n "$NAMESPACE" || true
    kubectl argo rollouts undo "$SERVICE" -n "$NAMESPACE" || true
  fi
  if [[ "$SYNC_PAUSED" == "true" ]]; then
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
kubectl -n "$ARGOCD_NS" get application "$ARGOCD_APP" >/dev/null 2>&1 \
  || { fail "Argo CD Application '$ARGOCD_APP' not found. Production is per-service; pass --app for the right one."; exit 1; }
kubectl get k8sgpt -n "$K8SGPT_NS" >/dev/null 2>&1 || { fail "K8sGPT CRs not found in $K8SGPT_NS"; exit 1; }
if ! kubectl get k8sgpt -n "$K8SGPT_NS" -o jsonpath='{.items[*].spec.targetNamespace}' | tr ' ' '\n' | grep -qx "$NAMESPACE"; then
  fail "No K8sGPT instance targets namespace '$NAMESPACE' - the drill cannot pass. Apply k8sgpt-sports-store."
  exit 1
fi
ok "cluster reachable; Rollout + Argo app '$ARGOCD_APP' present; K8sGPT analyses '$NAMESPACE'"

ORIGINAL_IMAGE="$(kubectl get rollout "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='$SERVICE')].image}")"
ORIGINAL_PROGRESS_DEADLINE="$(kubectl get rollout "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.progressDeadlineSeconds}' 2>/dev/null || true)"
ORIGINAL_PROGRESS_ABORT="$(kubectl get rollout "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.progressDeadlineAbort}' 2>/dev/null || true)"
BREAKING_IMAGE="${ORIGINAL_IMAGE%:*}:$BREAKING_TAG"
ok "current image: $ORIGINAL_IMAGE"

# --- 1. Pause auto-sync on the per-service Application -------------------------
log "Pausing Argo CD auto-sync on $ARGOCD_APP (so self-heal doesn't revert the drill)"
kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
SYNC_PAUSED="true"
ok "auto-sync paused"

# --- 2. Arm the deterministic abort -------------------------------------------
log "Shortening progressDeadlineSeconds to ${DRILL_PROGRESS_DEADLINE}s and enabling progressDeadlineAbort"
kubectl -n "$NAMESPACE" patch rollout "$SERVICE" --type merge \
  -p "{\"spec\":{\"progressDeadlineSeconds\":${DRILL_PROGRESS_DEADLINE},\"progressDeadlineAbort\":true}}"
ROLLOUT_PATCHED="true"
ok "abort armed"

# --- 3. Inject the breaking image ---------------------------------------------
log "Injecting breaking image: $BREAKING_IMAGE"
kubectl argo rollouts set image "$SERVICE" "$SERVICE=$BREAKING_IMAGE" -n "$NAMESPACE"

# --- 4. Wait for the Rollout to abort (its own timeout) -----------------------
log "Waiting up to ${ABORT_TIMEOUT}s for the Rollout to abort/degrade"
abort_deadline=$(( $(date +%s) + ABORT_TIMEOUT ))
abort_at=""
while [[ "$(date +%s)" -lt "$abort_deadline" ]]; do
  phase="$(kubectl argo rollouts status "$SERVICE" -n "$NAMESPACE" --timeout 5s 2>/dev/null || true)"
  status="$(kubectl get rollout "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if echo "$phase $status" | grep -qiE 'Degraded|Aborted|Error'; then
    abort_at="$(date +%s)"; ok "Rollout aborted/degraded"; break
  fi
  sleep 5
done
[[ -n "$abort_at" ]] || { fail "Rollout did not abort within ${ABORT_TIMEOUT}s"; exit 1; }

# --- 5. K8sGPT SLA - starts NOW, at abort detection ---------------------------
log "Abort detected; waiting up to ${SLA_SECONDS}s for a K8sGPT Result about $NAMESPACE"
sla_deadline=$(( abort_at + SLA_SECONDS ))
found="false"
while [[ "$(date +%s)" -lt "$sla_deadline" ]]; do
  if kubectl get results.core.k8sgpt.ai -n "$K8SGPT_NS" \
      -o jsonpath='{range .items[*]}{.spec.name}{"\n"}{end}' 2>/dev/null \
      | grep -qiE "(^|/)${NAMESPACE}/|${SERVICE}"; then
    found="true"; break
  fi
  sleep 10
done
elapsed=$(( $(date +%s) - abort_at ))

if [[ "$found" == "true" ]]; then
  ok "K8sGPT Result found ${elapsed}s after the abort (SLA ${SLA_SECONDS}s)"
  echo
  kubectl get results.core.k8sgpt.ai -n "$K8SGPT_NS" -o wide || true
  echo
  ok "DRILL PASSED - verify the root-cause message posted to $SLACK_CHANNEL and screenshot it for the DEP-271 evidence."
else
  fail "No K8sGPT Result for $NAMESPACE within ${SLA_SECONDS}s of the abort - DRILL FAILED."
  echo "Debug: kubectl logs -n $K8SGPT_NS deploy/k8sgpt-operator-controller-manager"
  exit 1
fi
