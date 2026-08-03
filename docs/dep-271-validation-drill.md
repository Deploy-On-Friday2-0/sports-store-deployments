# DEP-271 — Validation Drill (Sub-PRD 7 §2.3.2)

## Acceptance criterion
> Deploying a breaking container image tag that causes an Argo Rollouts abort
> (Sub-PRD 6) must trigger a K8sGPT root-cause analysis posted to
> `#k8s-ai-diagnostics` **within 3 minutes**.

## What the drill proves
The end-to-end failure-diagnosis path:

```
breaking image tag ─▶ Argo Rollout canary fails ─▶ Rollout aborts (Degraded)
                                                        │
                        K8sGPT (targetNamespace: sports-store) detects the
                        failing Pod/Events ─▶ Gemini root-cause analysis
                                                        │
                                             Slack sink ─▶ #k8s-ai-diagnostics
```

## Prerequisites (must already be deployed & synced)
| Component | Source |
|---|---|
| Argo Rollouts + the `catalog` Rollout in `sports-store` | `apps/argo-rollouts.yaml`, `helm/sports-store` |
| kube-prometheus-stack (canary analysis metrics) | DEP-262 `apps/monitoring/prometheus-stack.yaml` |
| K8sGPT operator + a CR targeting **`sports-store`** | `apps/k8sgpt` (incl. the `k8sgpt-sports-store` CR added by this PR) |
| `k8sgpt-secrets` (`google-api-key`, `slack-webhook-url` → `#k8s-ai-diagnostics`) | `apps/k8sgpt/k8sgpt-cr.yaml` (ESO) |
| `kubectl` + the `kubectl-argo-rollouts` plugin, context on the prod EKS cluster | operator workstation |

> **Note:** the four original K8sGPT CRs target `default`, `apps`, `monitoring`,
> `logging` — **not** `sports-store`, where the Rollouts run. This PR adds the
> `k8sgpt-sports-store` CR so the drill can pass. Merge & sync it first.

## Run it
```bash
./scripts/dep-271-validation-drill.sh --service catalog --namespace sports-store
```

The script is reversible and self-cleaning (it always restores the original
image and re-enables Argo CD auto-sync on exit). It:
1. pauses auto-sync on `sports-store-production` (so self-heal doesn't fight the drill),
2. sets a non-existent tag (`…:9.9.9-dep271-drill-broken`) → `ImagePullBackOff`,
3. waits for the Rollout to go `Degraded`/`Aborted`,
4. asserts a `results.core.k8sgpt.ai` object for `sports-store`/`catalog` appears within 180s,
5. undoes the Rollout and restores auto-sync.

## Pass criteria & evidence
- ✅ Rollout reaches `Degraded`/`Aborted`.
- ✅ A K8sGPT `Result` for the failing workload appears **< 3 min** (script asserts this).
- ✅ A root-cause message is posted to **`#k8s-ai-diagnostics`** — **screenshot it** (timestamp visible) and attach to DEP-271. This is the human-verified half; kubectl can confirm the `Result`, not the Slack delivery.

## Manual / GitOps variant (optional, fully end-to-end)
Instead of patching the Rollout, commit the breaking tag through GitOps:
1. Set `image.tag` in `environments/production/images/catalog-service.yaml` to `9.9.9-dep271-drill-broken`, commit, push.
2. Argo CD syncs → Rollout aborts → K8sGPT posts to Slack.
3. Revert the commit to restore. (Slower; pollutes prod history — prefer the script for routine drills.)

## Rollback / safety
- The script's `EXIT` trap always restores the last-good image and auto-sync.
- If it is killed uncleanly, manually run:
  ```bash
  kubectl argo rollouts undo catalog -n sports-store
  kubectl -n argocd patch application sports-store-production --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  ```
