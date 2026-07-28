# Sports Store — Kubernetes manifests

Kubernetes manifests for Stage 3 — Local Kubernetes Deployment, applied against a
Minikube profile named `sports-store`. Namespace used throughout the rest of this
course is **`sports-store`** — later stages (Helm chart, EKS deploy, CI/CD, Argo CD,
observability) all assume that name, so don't rename it.

## Layout

```text
k8s/
├── 00-namespace.yaml           # Namespace sports-store, PSA baseline enforcement
├── 01-external-secret.yaml     # AWS Secrets Manager synchronization
├── 01-mongodb-init-configmap.yaml   # generated from seed/init-mongo.js, verbatim
├── mongodb-values.yaml         # Bitnami MongoDB Helm chart values
├── 02-services.yaml            # ClusterIP Services for all 7 microservices
├── 03-deployments.yaml         # Deployments for all 7 microservices
└── 04-ingress.yaml             # Ingress routing / -> frontend, /api/* -> backends
```

## Internal service DNS

`sports-store-gateway`'s `nginx.conf` (same file completed in Stage 2) still proxies
by the short Compose-style hostnames (`auth`, `catalog`, `cart`, `order`, `payment`,
`frontend`) — `02-services.yaml` names every Service to match exactly, and
`03-deployments.yaml`'s `CATALOG_URL`/`CART_URL`/`PAYMENT_URL` env vars use those same
names. If you rename a Service here, update the matching `proxy_pass` line in
`sports-store-gateway/nginx.conf` too and rebuild the gateway image.

`04-ingress.yaml` bypasses `gateway` entirely and routes straight to `frontend` and
each backend Service — `gateway` is still deployed (per the "all 7 microservices"
Deployment requirement) but nothing in the Ingress routing table points at it. Both
are acceptable per this stage's brief; direct-to-backend was chosen so the Ingress
paths can match what the frontend actually calls without needing a second rebuild of
the gateway image with different upstream names.

Ingress paths mirror the frontend's actual calls (`src/*.jsx`) and
`gateway/nginx.conf`'s existing routes — `/api/products`, `/api/auth`, `/api/cart`,
`/api/orders`, `/api/payments` — not a `/api/v1/*` scheme, which nothing in this
codebase calls or serves.

## Local images

All 7 images are built directly into the `sports-store` Minikube profile's Docker
daemon (`eval $(minikube -p sports-store docker-env)` before `docker build`), tagged
`:v1.0.0` — not pushed to any registry:

- `sports-store-frontend:v1.0.0`
- `sports-store-gateway:v1.0.0`
- `sports-store-auth-service:v1.0.0`
- `sports-store-catalog-service:v1.0.0`
- `sports-store-cart-service:v1.0.0`
- `sports-store-order-service:v1.0.0`
- `sports-store-payment-service:v1.0.0`

Because these never reach a registry, every Deployment's container sets
`imagePullPolicy: IfNotPresent` (the default, `Always`, will try to pull from
Docker Hub and fail with `ImagePullBackOff` even though the image already exists
on the node).

## MongoDB: seeding and persistence

`01-mongodb-init-configmap.yaml` holds `seed/init-mongo.js` (from
`sports-store-local`) verbatim, mounted by `mongodb-values.yaml`'s `extraVolumes` /
`extraVolumeMounts` as a single file (via `subPath`) at
`/docker-entrypoint-initdb.d/init-mongo.js`. `persistence.storageClass: standard` /
`persistence.size: 8Gi` back it with a PVC, so data survives pod restarts and the
init script — which the Bitnami image only runs against an empty data directory —
only ever runs once. Verified by deleting the mongo pod and confirming against the
same PVC that neither the seed log line nor the product count reappear/change.

`mongodb-values.yaml` also overrides `image.repository` to
`bitnamilegacy/mongodb`: Bitnami stopped publishing pinned version tags (e.g.
`7.0.14-debian-12-r3`, what chart 15.6.26 expects) to the free
`docker.io/bitnami/mongodb` catalog — only `:latest` remains there. The exact tag
this chart version expects is still published under `docker.io/bitnamilegacy/mongodb`,
Bitnami's own mirror for this migration.

## Security

Every container in `03-deployments.yaml` sets `securityContext.runAsNonRoot: true`,
`runAsUser: 10001`, and `allowPrivilegeEscalation: false` — this is enforcing what's
already true of every image (each Dockerfile already `USER 10001`s), not fighting
them. `00-namespace.yaml` additionally labels the namespace
`pod-security.kubernetes.io/enforce: baseline`, so the cluster itself would reject a
pod that tried to run privileged regardless of what any Deployment spec says.

`01-external-secret.yaml` synchronizes the production application configuration
from AWS Secrets Manager through `ClusterSecretStore/aws-secrets-manager`. ESO owns
the generated `sports-store-app-secrets` Secret. Workloads use explicit
`secretKeyRef` entries: auth receives `MONGO_URI` and `JWT_SECRET`; cart, catalog,
order, and payment receive only `MONGO_URI`; gateway and frontend receive none.
MongoDB selects only the `mongodb-root-password` key required by the Bitnami chart.
Auth and cart have optional references to the future `sports-store-redis-secrets`
Secret, so no placeholder credential is stored in Git and the pods can start until
the AWS `REDIS_PASSWORD` property and Redis workload are introduced.

## MongoDB readiness

MongoDB should come up first and be healthy before the app Deployments start
successfully connecting — there's no `initContainer` gating that here. Each
service's MongoDB client already retries lazily per request (see
`services/*/database.py`), the same retry-friendly behavior already verified in
Stage 2's `docker-compose.yml`: a request that arrives before Mongo is reachable
fails and self-heals on the next one, without needing the pod to restart.

## Apply order

```bash
kubectl apply -f k8s/00-namespace.yaml

# ESO and ClusterSecretStore installation must already be complete.
kubectl apply -n sports-store -f k8s/01-external-secret.yaml
kubectl wait externalsecret/sports-store-app-secrets -n sports-store \
  --for=condition=Ready --timeout=120s
kubectl apply -n sports-store -f k8s/01-mongodb-init-configmap.yaml

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm upgrade --install mongodb bitnami/mongodb \
  --version 15.6.26 \
  --namespace sports-store \
  --values k8s/mongodb-values.yaml

kubectl apply -n sports-store -f k8s/02-services.yaml
kubectl apply -n sports-store -f k8s/03-deployments.yaml
kubectl apply -n sports-store -f k8s/04-ingress.yaml

kubectl rollout status deployment/gateway -n sports-store
kubectl rollout status deployment/auth -n sports-store
kubectl rollout status deployment/catalog -n sports-store
kubectl rollout status deployment/cart -n sports-store
kubectl rollout status deployment/order -n sports-store
kubectl rollout status deployment/payment -n sports-store
```
