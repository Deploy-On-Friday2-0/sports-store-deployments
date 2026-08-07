# CloudCart — Project Architecture & Documentation

CloudCart ("Sports Store") is a cloud-native e-commerce platform: five FastAPI
microservices behind an NGINX gateway and a React storefront, shipped to Amazon
EKS through a fully automated, GitOps-driven delivery pipeline with progressive
(canary) rollouts, end-to-end observability, cost tracking, and AI-assisted
incident diagnostics.

This document is the engineer-facing map of the **whole system** across all ten
repositories in the [`Deploy-On-Friday2-0`](https://github.com/orgs/Deploy-On-Friday2-0/repositories)
GitHub organization. For a non-technical walkthrough, see the companion
presentation script.

---

## Table of contents

1. [System at a glance](#1-system-at-a-glance)
2. [Repository map (10 repos)](#2-repository-map-10-repos)
3. [Application architecture](#3-application-architecture)
4. [Request flow (end-to-end)](#4-request-flow-end-to-end)
5. [Data & databases](#5-data--databases)
6. [Local development](#6-local-development)
7. [Cloud infrastructure (Terraform)](#7-cloud-infrastructure-terraform)
8. [Containers & image strategy](#8-containers--image-strategy)
9. [CI/CD pipeline](#9-cicd-pipeline)
10. [GitOps delivery (Argo CD)](#10-gitops-delivery-argo-cd)
11. [Progressive delivery (Argo Rollouts)](#11-progressive-delivery-argo-rollouts)
12. [Observability & cost](#12-observability--cost)
13. [Security & secrets](#13-security--secrets)
14. [Runbooks](#14-runbooks)
15. [Glossary](#15-glossary)

---

## 1. System at a glance

| Plane | What it is | Key technology |
| --- | --- | --- |
| **Experience** | The storefront and the single public entry point | React + Vite frontend, NGINX gateway, CloudFront + ACM |
| **Application** | Five independent business services, one database each | Python / FastAPI, MongoDB |
| **Platform** | The cluster and cloud that run the services | AWS EKS (Kubernetes), ECR, VPC, Terraform Cloud |
| **Delivery** | How code becomes a running release | GitHub Actions (OIDC), Argo CD (GitOps), Helm, Argo Rollouts |
| **Operations** | Seeing, costing, and diagnosing the system | kube-prometheus-stack, Loki + Alloy, Kubecost, K8sGPT |
| **Security** | Keyless access and no secrets in Git | AWS Secrets Manager + External Secrets, EKS Pod Identity, GitHub OIDC |

**Design principles**

- **Polyrepo, one service per repo** — each service scales, ships, and fails independently.
- **Database-per-service** — no service reads another's data; they cooperate via HTTP.
- **Everything as code** — application, cluster, and cloud are all declarative and version-controlled.
- **GitOps** — the live cluster is continuously reconciled to Git; rollback is a `git revert`.
- **Progressive, self-healing releases** — canary traffic shifting with a Prometheus metric-gate (`AnalysisTemplate`) that auto-aborts a rollout whose success rate drops below 99.5% or p95 latency exceeds 250 ms (see §11).
- **Zero static credentials** — OIDC and Pod Identity everywhere; secrets live in AWS Secrets Manager, never in Git.

---

## 2. Repository map (10 repos)

All under `github.com/Deploy-On-Friday2-0`.

| Repo | Role | Highlights |
| --- | --- | --- |
| [`sports-store-auth-service`](https://github.com/Deploy-On-Friday2-0/sports-store-auth-service) | Auth service | Registration, login, JWT, roles, bcrypt hashing · port `8001` · `auth_db` |
| [`sports-store-catalog-service`](https://github.com/Deploy-On-Friday2-0/sports-store-catalog-service) | Catalog service | Products, variants, filtering, inventory & stock · port `8002` · `catalog_db` |
| [`sports-store-cart-service`](https://github.com/Deploy-On-Friday2-0/sports-store-cart-service) | Cart service | Per-user carts, product snapshots, subtotals · port `8003` · `cart_db` |
| [`sports-store-order-service`](https://github.com/Deploy-On-Friday2-0/sports-store-order-service) | Order service | Checkout orchestration, history, shipping, stock updates · port `8004` · `order_db` |
| [`sports-store-payment-service`](https://github.com/Deploy-On-Friday2-0/sports-store-payment-service) | Payment service | Mock provider, idempotent charges, deterministic declines · port `8005` · `payment_db` |
| [`sports-store-frontend`](https://github.com/Deploy-On-Friday2-0/sports-store-frontend) | Storefront | React 18, React Router, Vite 5; talks to `/api` via the gateway |
| [`sports-store-gateway`](https://github.com/Deploy-On-Friday2-0/sports-store-gateway) | Edge gateway | NGINX single public entry point; reverse-proxies `/api/*` to services |
| [`sports-store-deployments`](https://github.com/Deploy-On-Friday2-0/sports-store-deployments) | **GitOps hub** | Helm parent chart, Argo CD apps, rollouts, observability, this doc |
| [`sports-store-infrastructure`](https://github.com/Deploy-On-Friday2-0/sports-store-infrastructure) | Cloud IaC | Terraform for VPC, EKS, ECR, IAM/OIDC, ACM, CloudFront, Secrets Manager (Terraform Cloud) |
| [`sports-store-local`](https://github.com/Deploy-On-Friday2-0/sports-store-local) | Local dev | Docker Compose for the whole stack + MongoDB seed |

---

## 3. Application architecture

Each service is a small FastAPI app (FastAPI `0.140`, Uvicorn, async MongoDB via
**Motor**, Pydantic v2). Every service exposes:

- `GET /health` — liveness/readiness probe.
- `GET /metrics` — Prometheus metrics via `prometheus-fastapi-instrumentator`
  (high-cardinality labels such as `user_id`/`order_id`/`cart_id` are excluded).

| Service | Port | Database | Responsibility | Depends on |
| --- | --- | --- | --- | --- |
| auth | 8001 | `auth_db` | Accounts, login, JWT issuance, roles | — |
| catalog | 8002 | `catalog_db` | Products, filtering, inventory & stock | — |
| cart | 8003 | `cart_db` | Baskets, quantities, subtotals | catalog |
| order | 8004 | `order_db` | Checkout orchestration, order history | cart, catalog, payment |
| payment | 8005 | `payment_db` | Idempotent charges, mock decline logic | — |

**Gateway routing** (`sports-store-gateway/nginx.conf`) — the single entry point:

| Path | Upstream |
| --- | --- |
| `/` | `frontend:80` |
| `/api/auth/` | `auth:8001` |
| `/api/products`, `/api/internal/` | `catalog:8002` |
| `/api/cart` | `cart:8003` |
| `/api/orders` | `order:8004` |
| `/api/payments` | `payment:8005` |

> **EKS topology note.** The frontend is served from S3 + CloudFront, and the ALB
> `Ingress` routes `/api/*` directly to the backend Services (`ingressServices:
> [auth, catalog, cart, order, payment]`). The legacy gateway nginx workload was
> removed when the frontend left the cluster; the `production-ingress` Argo CD
> Application owns only the shared Ingress. CloudFront's `/api/*` origin targets
> the ALB that this Ingress provisions.

---

## 4. Request flow (end-to-end)

The diagram below shows the **Docker Compose topology**, where the NGINX gateway is
the single entry point and every `/api/*` request is proxied through it. On **EKS the
request path differs**: the ALB `Ingress` routes each `/api/*` prefix directly to the
matching backend Service and does not pass through the gateway (see the EKS topology
note in §3).

```mermaid
flowchart LR
  U[Shopper] --> GW[NGINX Gateway<br/>single entry point<br/>Compose only]
  GW -->|/api/auth| A[Auth :8001]
  GW -->|/api/products| C[Catalog :8002]
  GW -->|/api/cart| K[Cart :8003]
  GW -->|/api/orders| O[Order :8004]
  GW -->|/api/payments| P[Payment :8005]
  K -.stock check.-> C
  O -.confirm cart.-> K
  O -.charge.-> P
  O -.decrement stock.-> C
  A --> ADB[(auth_db)]
  C --> CDB[(catalog_db)]
  K --> KDB[(cart_db)]
  O --> ODB[(order_db)]
  P --> PDB[(payment_db)]
```

**Checkout, step by step**

1. The shopper hits the site. Under Compose every request passes through the gateway;
   on EKS the ALB Ingress routes each `/api/*` prefix straight to the backend Service.
2. Browsing calls the **catalog**; adding to basket calls the **cart**, which
   verifies stock against the catalog.
3. At checkout the **order** service orchestrates: confirm the cart → ask
   **payment** to charge → tell **catalog** to decrement stock → record the order.
4. Each service reads and writes only its **own** database.

---

## 5. Data & databases

- **Database-per-service** — five logical MongoDB databases (`auth_db`,
  `catalog_db`, `cart_db`, `order_db`, `payment_db`). Services never share a
  database; cross-service reads happen over HTTP.
- **Local:** a single `mongo:7.0.39` container hosts all databases (see §6).
- **Production:** a **Bitnami MongoDB ReplicaSet** (3 members, `architecture:
  replicaset`, `replicaSetName: rs0`), deployed as a StatefulSet with
  independent, retained gp3 PVCs per member. Members are designed to authenticate
  to each other with a shared keyfile (`mongodb-replica-set-key`) sourced from AWS
  Secrets Manager via External Secrets. **Pending:** the backing
  `MONGODB_REPLICA_SET_KEY` value is not yet written by Terraform on infrastructure
  `main` (DEP-320, PR #18 still open) — see §13.
- Seed data: `sports-store-local/seed/init-mongo.js`.

---

## 6. Local development

`sports-store-local/docker-compose.yml` runs the entire platform on one Docker
network:

- `mongo` (`mongo:7.0.39`) — single instance, per-service databases.
- `auth`, `catalog`, `cart`, `order`, `payment` — built from each service repo.
- `frontend` — React/Vite build.
- `gateway` — NGINX, the only service with published host ports.

```bash
# from the folder containing all the cloned repos
cd sports-store-local
docker compose up --build
# app reachable through the gateway; MongoDB seeded from seed/init-mongo.js
```

Each service can also be run on its own for development (`uvicorn main:app` on its
port) — see the individual repo READMEs.

---

## 7. Cloud infrastructure (Terraform)

`sports-store-infrastructure` is a Terraform root module driven by **Terraform
Cloud** (VCS-driven runs, remote state; workspace `sports-store-infrastructure`).
Terraform `>= 1.11`, AWS provider `~> 5`. Built on public modules, not
hand-rolled resources.

| File | Provisions |
| --- | --- |
| `vpc.tf` | VPC across 3 AZs, public/private subnets, NAT, ELB discovery tags (`terraform-aws-modules/vpc`) |
| `eks.tf` | EKS control plane + managed node group (AL2023); addons: `coredns`, `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver`, `eks-pod-identity-agent` (`terraform-aws-modules/eks`) |
| `ecr.tf` | One ECR repository per deployable component, `scan_on_push` |
| `iam.tf` | Cluster/node roles; **EKS Pod Identity** roles for EBS CSI, External Secrets, AWS Load Balancer Controller, and Argo Rollouts; GitHub Actions **OIDC** provider + ECR/frontend deploy roles |
| `secrets.tf` | AWS Secrets Manager secret `sports-store/production/config`. Write-only payload on infrastructure `main` today: **`MONGO_INITDB_ROOT_PASSWORD`, `JWT_SECRET_KEY`** only. `MONGODB_REPLICA_SET_KEY` is pending in DEP-320 (infra PR #18 — open, changes requested, not yet merged) and `REDIS_PASSWORD` is not yet provisioned by any merged change — see the pending-secrets note in §13. |
| `acm.tf` | Regional + `us-east-1` ACM certificates (DNS-validated) |
| `frontend.tf` | S3 bucket + CloudFront distribution serving the static frontend |
| `security.tf`, `variables.tf`, `outputs.tf` | Security groups, inputs, outputs |
| `bootstrap/oidc/` | Standalone bootstrap module |
| `kubernetes/storageclasses/ebs-gp3-retain.yaml` | gp3 StorageClass: `WaitForFirstConsumer`, `Retain`, encrypted |

CI (`terraform-ci.yml`): branch-name check, `terraform fmt`, `terraform validate`
(`-backend=false`), Checkov scan, and static acceptance tests under `tests/`.

---

## 8. Containers & image strategy

- **Multi-stage Docker** on `python:3.11-slim` (pinned by digest). Each image
  `EXPOSE`s its service port, ships a container `HEALTHCHECK` hitting `/health`,
  and runs `uvicorn main:app`.
- Images are pushed to **ECR**, tagged `‹semver›-‹7-char-sha›` (never `latest`).
- The frontend is built and published to **S3/CloudFront** rather than an ECR image.

---

## 9. CI/CD pipeline

Every service repo carries the same workflows:

| Workflow | Trigger | Does |
| --- | --- | --- |
| `ci.yml` | Pull request | Lint, test, build (no push) |
| `publish.yml` | Merge to `main` | Version, build, push image to ECR via **OIDC** (no static keys), then **write the new image tag back** to `sports-store-deployments/environments/production/images/‹service›.yaml` using `yq`, committed with a GitHub App installation token |
| `ai-review-after-ci.yml` + `reusable-ai-review.yml` | After CI | **AI-powered PR reviewer** (OpenRouter) posts findings on the PR |

```mermaid
flowchart LR
  PR[Pull request] --> CI[ci.yml: lint/test/build]
  CI --> AIR[AI PR review]
  M[Merge to main] --> PUB[publish.yml]
  PUB -->|OIDC, no static keys| ECR[(ECR image<br/>semver-sha)]
  PUB -->|yq write-back<br/>GitHub App token| IMG[deployments/environments/<br/>production/images/*.yaml]
  IMG --> ARGO[Argo CD reconciles]
```

This is the GitOps handoff: **CI never touches the cluster.** It only updates an
image-tag file in Git; Argo CD does the actual deploy (§10).

---

## 10. GitOps delivery (Argo CD)

`sports-store-deployments` is the single source of truth for the cluster.

- **App-of-apps:** `apps/root-app.yaml` reconciles every downstream Argo CD
  Application in `apps/`.
- **AppProject:** `projects/sports-store-project.yaml` restricts sources and
  destination namespaces (`default`, `apps`, `monitoring`, `logging`, plus narrow
  `sports-store`/`argocd`/`argo-rollouts` exceptions). Third-party charts
  (Kubecost, kube-prometheus-stack, K8sGPT) run in the built-in `default` project.
- **Applications (`apps/`):** `sports-store-production.yaml` (the app Helm
  chart), `argo-rollouts.yaml`, `monitoring/prometheus-stack.yaml`,
  `observability.yaml` (Loki + Alloy), `observability-secrets.yaml`,
  `kubecost/kubecost.yaml`, `k8sgpt-operator.yaml` + `k8sgpt-resources.yaml`,
  `infrastructure.yaml`.
- **Helm chart:** `helm/sports-store` — a parent chart that `range`s over the
  services (`_helpers.tpl`), with the vendored **Bitnami MongoDB** subchart, an
  `ExternalSecret`, an ALB `Ingress`, `ServiceMonitor`s, and the canary
  `AnalysisTemplate`. `values-eks.yaml` carries EKS overrides.
- **Reconciliation:** every Application enables `automated.prune` and
  `automated.selfHeal` — manual cluster drift is reverted automatically.
- **Rollback** is a Git operation: revert the offending image-tag or manifest
  commit and Argo CD restores the previous desired state.

Direct pushes to `main` are blocked; changes arrive via approved PRs or the CI
GitHub App. See [`docs/gitops-bootstrap.md`](gitops-bootstrap.md) for bootstrap
order and boundaries.

---

## 11. Progressive delivery (Argo Rollouts)

`catalog-service` and `order-service` are deployed as Argo **Rollout** CRDs (not
plain Deployments) for progressive canary delivery, integrated with the AWS Load
Balancer Controller for ALB **target-group weighting**.

**Traffic steps** (`helm/sports-store/templates/deployment.yaml`):
`10% (pause 2m) → 25% (pause 2m) → 50% (pause 2m) → 75% (pause 2m) → 100%`.

**Metric analysis (wired in).** An `AnalysisTemplate`
(`sports-store-canary-analysis`, in `helm/sports-store/templates/canary-analysis.yaml`,
created by the `production-catalog-service` release via `platform.createAnalysisTemplate`
and referenced by the catalog/order Rollouts as a **background analysis**,
`startingStep: 1`) queries Prometheus in the `monitoring` namespace for:

- **Success rate ≥ 99.5%** — checked every 30s over a 1-minute (`[1m]`) window
  (`2xx/3xx ÷ all` on `http_requests_total`, scoped to `namespace="sports-store"`
  and `job="<service>-canary"` — the canary Service is scraped under its own
  job name, so the gate evaluates **only the new version's traffic**;
  `prometheus-fastapi-instrumentator` emits grouped `2xx/3xx/4xx/5xx` status
  buckets).
- **p95 latency < 250 ms** — checked every 30s over a 1-minute (`[1m]`) window
  (`http_request_duration_seconds_bucket`).

The analysis starts once the canary reaches its first pause (10% weight) and
runs continuously through every step. If either SLO is breached
(`failureLimit: 1`) the Rollout is **aborted automatically** — no manual
intervention or time-based promotion past a failing canary. The 2-minute pauses
give each step four 30s-interval Prometheus checks before advancing. The
`production-order-service` release references the shared template but does not
own it (`createAnalysisTemplate: false`), avoiding a Helm resource-ownership
conflict.

The Argo Rollouts controller receives its AWS permissions for target-group
weighting via **EKS Pod Identity** (`argo-rollouts/argo-rollouts` service
account) — provisioned in `sports-store-infrastructure/iam.tf`.

---

## 12. Observability & cost

Deployed declaratively as Argo CD Applications and owned by the observability
scope:

| Capability | Component | Namespace | Notes |
| --- | --- | --- | --- |
| Metrics, dashboards, alerts | **kube-prometheus-stack** (release `prometheus-stack`) | `monitoring` | Grafana sidecar dashboard discovery; Prometheus 15d on gp3; Alertmanager → Slack |
| App scraping | **ServiceMonitor** (`sports-store-servicemonitors.yaml`) | `sports-store` | Scrapes `app.kubernetes.io/part-of: sports-store` every 15s |
| Dashboards | `sports-store-overview.json` | — | CPU/RAM, RPS, 5xx %, p95/p99 latency |
| Alert rules | `observability/alerts/prometheus-rules.yaml` | `monitoring` | ServiceDown, PodCrashLooping, HighHTTPErrorRate, ReplicasUnavailable |
| Logs | **Loki + Grafana Alloy** | `logging` | Alloy collects stdout/stderr, parses JSON (`level`, `service`, `trace_id`), redacts secrets |
| Cost | **Kubecost** (`cost-analyzer`) | `kubecost` | Per-namespace/service + idle cost; queries the **core** Prometheus (`http://prometheus-operated.monitoring.svc.cluster.local:9090`) instead of a bundled one |
| AI diagnostics | **K8sGPT Operator** | `k8sgpt-operator` | `autoAnalysis`; intercepts RolloutDegraded / PodCrashLooping / ImagePullBackOff; Slack sink → `#k8s-ai-diagnostics` |

---

## 13. Security & secrets

- **No secrets in Git.** All application/observability secrets live in **AWS
  Secrets Manager** and are synced into Kubernetes by the **External Secrets
  Operator (ESO)** through a `ClusterSecretStore` (`aws-secrets-manager`).
  - App secret `sports-store/production/config` → K8s `sports-store-app-secrets`.
    The Helm `ExternalSecret` maps `MONGO_URI`, `JWT_SECRET`, `mongodb-root-password`,
    `mongodb-replica-set-key`, and `redis-password`.
  - Observability secret `sports-store/production/observability` → `grafana-admin`,
    `alertmanager-slack`.

> **Pending secret provisioning (known gap).** On infrastructure `main`, Terraform
> (`sports-store-infrastructure/secrets.tf`) currently writes only
> `MONGO_INITDB_ROOT_PASSWORD` and `JWT_SECRET_KEY` into `sports-store/production/config`.
> The `mongodb-replica-set-key` and `redis-password` properties the `ExternalSecret`
> above expects are **not yet present** in AWS Secrets Manager: `MONGODB_REPLICA_SET_KEY`
> is pending in DEP-320 (infra PR #18 — open, changes requested, Terraform Cloud check
> failing) and no merged change supplies `REDIS_PASSWORD`. Until those land, the ESO
> sync for those two keys fails with a missing-property error. An `ExternalSecret`
> declaring a property is not evidence that Secrets Manager contains it.
- **Keyless access (no static credentials).**
  - In-cluster controllers (ESO, AWS LB Controller, EBS CSI, Argo Rollouts) use
    **EKS Pod Identity** associations bound to their service accounts.
  - GitHub Actions authenticates to AWS via **OIDC** — no long-lived AWS keys.
- **Branch protection** on `sports-store-deployments` `main`; only approved PRs or
  the scoped CI GitHub App can write.

---

## 14. Runbooks

**Deploy a new version of a service**
1. Merge the service PR to `main`. `publish.yml` builds, pushes to ECR, and writes
   the new tag to `deployments/environments/production/images/‹service›.yaml`.
2. Argo CD detects the change and syncs. For `catalog`/`order`, the Rollout shifts
   traffic through the canary steps (10→25→50→75→100%, 2m soaks each) while the
   background analysis verifies success rate ≥ 99.5% and p95 latency < 250 ms —
   a breached SLO aborts the rollout automatically before promoting.

**Roll back**
- Revert the image-tag (or manifest) commit in `sports-store-deployments` via PR.
  Argo CD reconciles back to the previous state. (For an in-flight canary, abort it
  manually with `kubectl argo rollouts abort <name>`; automated metric-gated rollback
  is not yet wired in — see §11.)

**Rotate / add an app secret**
- Update the value in AWS Secrets Manager (or add the property in
  `infrastructure/secrets.tf` and bump `production_config_version`). Force an ESO
  resync; confirm `kubectl get externalsecret sports-store-app-secrets -n
  sports-store` is `Ready=True`. Never commit secret values.

**Add a new microservice**
- New repo with the standard `ci.yml`/`publish.yml`; add an ECR repo and (if
  needed) an OIDC `sub` in `infrastructure/iam.tf`; add the service to the Helm
  `values`, an image-tag file, and the gateway routes.

**Recreate the observability secret (if deleted)**
- As of `sports-store-infrastructure` PR #45, `sports-store/production/observability`
  is mostly **Terraform-managed** (`aws_secretsmanager_secret.production_observability`
  + `_version` in `secrets.tf`): Terraform sets `GRAFANA_ADMIN_USER = "admin"` and
  generates `GRAFANA_ADMIN_PASSWORD` itself (`random_password`, no human input
  needed). Only `SLACK_WEBHOOK_URL` stays human-supplied, via the same
  `slack_webhook_url` Terraform Cloud variable already used for
  `sports-store/production/config`'s K8sGPT sink — Terraform can't invent a
  real external credential. Symptom if it's ever deleted:
  `grafana-admin`/`alertmanager-slack` `ExternalSecret`s in `monitoring` show
  `STATUS=SecretDeleted` (both have `deletionPolicy: Delete`, so ESO removes
  the K8s Secret too), Grafana's pod sits in `CreateContainerConfigError`, and
  Alertmanager's init container hangs in `PodInitializing`.
- **Preferred recovery: re-run Terraform.** Queue a `terraform apply` on the
  `sports-store-infrastructure` Terraform Cloud workspace (`slack_webhook_url`
  is already set there, shared with the config secret). This recreates the
  secret with a fresh Grafana password and the existing webhook — no manual
  AWS CLI needed.
  - **One-time gotcha:** if the secret already exists in AWS Secrets Manager
    but isn't yet in Terraform state — e.g. right after adopting the
    observability-secret PR (sports-store-infrastructure #47, DEP-331), or
    after the emergency fallback below was used mid-incident — `terraform
    apply` fails on a name collision. Import it first:
    ```sh
    terraform import aws_secretsmanager_secret.production_observability arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:sports-store/production/observability-<SUFFIX>
    ```
    Import by **ARN** (not just the secret name), run in the
    `sports-store-infrastructure` Terraform Cloud workspace (org
    `deploy-on-friday`) before applying. Then re-run `terraform apply`; it
    overwrites the secret's contents with the Terraform-generated password
    plus the current `slack_webhook_url`.
  - **Rotate the Grafana password:** `secret_string_wo` is write-only, so
    unrelated applies never change it. To rotate, bump the
    `production_observability_version` Terraform Cloud variable (org
    `deploy-on-friday`, `sports-store-infrastructure` workspace) and re-run
    `terraform apply`.
- **Emergency fallback (no Terraform Cloud access mid-incident):** recreate it
  by hand, then reconcile Terraform afterward.
  ```sh
  aws secretsmanager create-secret \
    --name sports-store/production/observability \
    --kms-key-id alias/aws/secretsmanager \
    --secret-string '{"GRAFANA_ADMIN_USER":"admin","GRAFANA_ADMIN_PASSWORD":"<generate a new strong password>","SLACK_WEBHOOK_URL":"<Slack incoming webhook URL>"}' \
    --region us-east-1
  ```
  - `SLACK_WEBHOOK_URL` is a real external credential; don't invent one. Reuse
    the same webhook already used by `k8sgpt-secrets` (property
    `SLACK_WEBHOOK_URL` on `sports-store/production/config`), or ask whoever
    owns the `#k8s-ai-diagnostics`/alerts Slack workspace for a fresh one.
  - Afterward, run the `terraform import` step above before the next
    `terraform apply`, or it fails on the name collision you just created.
- Either way, force an immediate ESO resync rather than waiting for the 1h
  `refreshInterval`:
  ```sh
  kubectl annotate externalsecret grafana-admin -n monitoring force-sync="$(date +%s)" --overwrite
  kubectl annotate externalsecret alertmanager-slack -n monitoring force-sync="$(date +%s)" --overwrite
  ```
- Confirm `kubectl get externalsecret -n monitoring` shows both
  `SecretSynced`/`Ready=True`, then `kubectl get pods -n monitoring` shows
  Grafana `3/3 Running` and the Alertmanager pod `2/2 Running`. No pod restart
  is needed — kubelet retries `CreateContainerConfigError`/`PodInitializing`
  pods automatically once the referenced Secret exists.

---

## 15. Glossary

| Term | Plain meaning |
| --- | --- |
| **Microservice** | A small program that does one job and owns its own data. |
| **Gateway** | The single front door that routes requests to the right service. |
| **Container / ECR** | A sealed, identical package of a service; ECR stores those packages. |
| **Kubernetes / EKS** | The system that runs containers and restarts/scales them automatically. |
| **Terraform** | The cloud, described as code, so it's rebuildable and reviewable. |
| **GitOps / Argo CD** | The cluster is continuously reconciled to match Git; deploys = commits. |
| **Argo Rollouts** | Controller for gradual canary releases; supports metric-gated automatic rollback (metric gate defined but not yet wired in here — see §11). |
| **Prometheus / Grafana** | Metrics storage and dashboards. |
| **Loki / Alloy** | Log storage and the agent that ships logs to it. |
| **Kubecost** | Shows what each part of the cluster costs. |
| **K8sGPT** | AI that reads cluster problems and posts plain-English diagnoses to Slack. |
| **External Secrets / Pod Identity** | Pull secrets from AWS Secrets Manager with no static keys. |
| **OIDC** | Short-lived, badge-in cloud access for CI instead of stored keys. |
