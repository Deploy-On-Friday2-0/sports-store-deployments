# DEP-324 — Validation Drill (PRD Step 3)

## Acceptance criteria
> 1. Dynamic API traffic routes **directly** from the AWS ALB to the EKS backend
>    pods, bypassing the gateway.
> 2. An outage in one service does not disrupt the others (no SPOF).

## What the drill proves
The end-to-end direct-routing + isolation path:

```
Shopper / CloudFront ─▶ ALB (internet-facing, target-type ip, /health checks)
                          │
          ┌───────────────┼──────────────────┬──────────────────┐
          │               │                  │                  │
       /api/auth      /api/products      /api/cart        /api/orders
          │               │                  │                  │
      auth pod         catalog pod       cart pod          order pod
          │               │                  │                  │
   payment outage ──▶ /api/payments fails; everything else stays up
```

The legacy NGINX gateway workload is **not deployed** on EKS
(`gateway.enabled: false` in `helm/sports-store/values-eks.yaml`; the workload
was removed in commit `a7243a9`). The ALB Ingress (`sports-store-gateway`,
rendered by the `production-ingress` Argo CD Application) is the only entry
point, and each `/api/*` prefix maps straight to its backend Service.

## Prerequisites (must already be deployed & synced)
| Component | Source |
|---|---|
| `production-ingress` ALB Ingress in `sports-store` | `apps/sports-store-production.yaml` |
| Five backend workloads + HPAs (min 2 / max 6) | `helm/sports-store`, `values-eks.yaml` |
| AWS Load Balancer Controller + ALB `alb-sports-store` | `apps/platform-controllers.yaml` |
| `kubectl` + `aws` CLI + `curl`, context on the prod EKS cluster | operator workstation |

## Run it
```bash
./scripts/dep-324-outage-drill.sh
```

The script is reversible and self-cleaning. It:
1. resolves the ALB DNS name from the Ingress status,
2. asserts no `gateway` Deployment/Service/pod exists, then verifies every
   backend answers through the ALB with FastAPI JSON (catalog `200`; the
   auth-gated services `401/404`) — never an ALB `502/503/504`, which would
   mean no healthy direct target,
3. pauses auto-sync on `production-payment-service`, **deletes** `hpa/payment`
   (Kubernetes rejects `minReplicas: 0` for a CPU-only HPA), scales
   `deployment/payment` to `0`, and waits for all payment pods to disappear
   (both controllers would otherwise fight the drill),
4. re-verifies **auth / catalog / cart / order** still answer through the ALB
   while payment is down, and that `/api/payments` now returns `502/503/504`
   (blast radius contained),
5. restores payment replicas, resumes auto-sync — Argo CD recreates
   `hpa/payment` from Git with `minReplicas 2` — waits for
   `readyReplicas >= 2` **and** for the endpoint to come back through the ALB
   (target-group health checks lag pod readiness), then confirms
   `/api/payments` recovers.

## Pass criteria & evidence
- ✅ No `gateway` workload exists in the cluster; the ALB is the only entry point.
- ✅ All five `/api/*` paths answer through the ALB with FastAPI JSON
  (direct pod delivery — target-type `ip`).
- ✅ With `payment` at 0 replicas, auth/catalog/cart/order remain healthy
  through the ALB while `/api/payments` fails.
- ✅ After restore, payment recovers through the ALB.
- 📸 Screenshot the drill output (timestamp visible — terminal shows the ALB
  DNS, per-service HTTP codes, and the outage/restore steps) and attach to
  DEP-324.

## CI companion
`tests/dep-324.py` + `tests/dep-324.sh` (wired into `.github/workflows/helm.yml`)
keep the manifest contract honest on every PR: ALB class/annotations,
gateway/frontend disabled, `ingressServices` whitelist exactly the five
backends, no gateway backend in the rendered routing table.

## Rollback / safety
- The script's `EXIT` trap always restores the Deployment replicas and Argo CD
  auto-sync. The HPA is a Git-committed, Helm-rendered resource, so resuming
  auto-sync makes Argo CD recreate it exactly (with `minReplicas 2`).
- If it is killed uncleanly, manually run:
  ```bash
  kubectl -n sports-store scale deployment payment --replicas=2
  kubectl -n argocd patch application production-payment-service --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  kubectl -n sports-store rollout status deployment/payment
  kubectl -n sports-store get hpa payment   # Argo CD recreates it within ~60s
  ```
- **Cluster access:** the EKS public endpoint is CIDR-restricted
  (`publicAccessCidrs`); the operator's egress IP must be in the list before
  `kubectl` works (`aws eks update-cluster-config ... --public-access-cidrs ...`),
  and the IAM principal needs a cluster-admin access entry
  (`aws eks create-access-entry` + `AmazonEKSClusterAdminPolicy`).
