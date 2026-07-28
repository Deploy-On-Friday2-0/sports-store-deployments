# sports-store (parent Helm chart)

Milestone 3: a single Helm chart that renders all 7 first-party microservice
Deployments/Services plus an Ingress, and depends on the upstream Bitnami
MongoDB chart as a sub-chart. Supersedes-in-spirit but does not replace
`k8s/`'s raw manifests (Milestone 2) — both stay in the repo; this is the
newer, DRY path.

## Prerequisites

Same as Milestone 2: a running `sports-store` Minikube profile with the
`sports-store` namespace already created (`kubectl apply -f
../../k8s/00-namespace.yaml`) and all 7 `:v1.0.0` images built into that
profile's Docker daemon (see `../../k8s/README.md` "Local images"). This
chart does not build images or manage the namespace itself.

External Secrets Operator and `ClusterSecretStore/aws-secrets-manager` must be
ready before installation. The chart creates the application `ExternalSecret`;
it does not install ESO or create/populate the AWS secret.

## Install

```bash
helm dependency update .
helm install sports-store . --namespace sports-store
kubectl wait externalsecret/sports-store-app-secrets -n sports-store \
  --for=condition=Ready --timeout=120s
```

## Upgrade / rollback / uninstall

```bash
# after editing values.yaml (or with -f a values override / --set)
helm upgrade sports-store . --namespace sports-store

helm rollback sports-store <revision> --namespace sports-store

helm uninstall sports-store --namespace sports-store
```

All verified against a live cluster:

- **install**: fresh install seeds MongoDB (20 products, 1 admin user) exactly
  once.
- **upgrade**: changing a single service's config (e.g. `services.auth.env`)
  produces a surgical rolling update — only that Deployment gets a new
  ReplicaSet/pod; the other 6 services and MongoDB are untouched, and
  MongoDB's product count is unaffected (no reseed, no downtime observed
  through the Ingress during the rollout).
- **rollback**: `helm rollback` to a prior revision reverts the config
  change and leaves MongoDB's data untouched.
- **uninstall**: MongoDB's PVC survives — `mongodb.persistence.resourcePolicy:
  keep` (see values.yaml) makes Helm explicitly report `[PersistentVolumeClaim]
  ... kept due to the resource policy` on uninstall, rather than deleting it.
- **reinstall**: a fresh `helm install` after that uninstall reattaches to the
  same PVC (same PV, same age) — the seed script does not re-run (MongoDB
  only runs `/docker-entrypoint-initdb.d/*.js` against an empty data
  directory) and the product count is unchanged. This is what "zero data
  loss for persistent MongoDB volumes across lifecycles" means in practice
  here: install/upgrade/rollback/uninstall+reinstall all preserve it.

## Design notes

**Resource names stay unprefixed** (`auth`, `catalog`, `frontend`, ... —
not `sports-store-auth`). `sports-store-gateway`'s `nginx.conf` (baked into
its image, not templated by this chart) proxies to those exact short
hostnames, and `values.yaml`'s `CATALOG_URL`/`CART_URL`/`PAYMENT_URL` env
entries reference them the same way — same DNS constraint as the raw `k8s/`
manifests. `templates/_helpers.tpl`'s `sports-store.fullname` (the standard
release-prefixed convention) exists for governance and is used for the one
resource nothing else needs to resolve by a fixed name: the Ingress.

**Secrets come from AWS Secrets Manager.** `templates/external-secret.yaml`
synchronizes `sports-store/production/config` hourly. ESO owns the resulting
`sports-store-app-secrets` Kubernetes Secret. Explicit `secretKeyRef` entries give
auth `MONGO_URI` and `JWT_SECRET`, give cart/catalog/order/payment only `MONGO_URI`,
and give gateway/frontend no secrets. MongoDB selects only its
`mongodb-root-password` key. Auth and cart also declare optional references to the
future `sports-store-redis-secrets` Secret; no fake Redis credential is rendered
before the AWS `REDIS_PASSWORD` property and Redis workload exist.

**MongoDB's hostname is release-dependent.** As a subchart with alias
`mongodb` under a parent release named `sports-store`, Bitnami's chart
produces a Service named `sports-store-mongodb` (`<release>-<chart>`) —
not the plain `mongodb` you'd get installing the chart standalone with a
release name that equals the chart name (verified via `helm template`
before wiring it into the ExternalSecret template's `MONGO_URI`). If you
install this chart under a different release name, `MONGO_URI` adjusts
automatically (see `_helpers.tpl`'s `sports-store.mongoHost`).

**No separate seeding Job.** MongoDB's own container entrypoint already
runs any `*.js` file under `/docker-entrypoint-initdb.d/` exactly once,
against an empty data directory — idempotent by construction, and already
proven twice (Milestone 2 and above). `templates/mongodb-init-configmap.yaml`
mounts `seed/init-mongo.js` there via the subchart's
`extraVolumes`/`extraVolumeMounts` (see `values.yaml`'s `mongodb:` key). A
separate Job hitting that same path wouldn't do anything — that path only
has meaning to MongoDB's own entrypoint script.

**`gateway` is deployed but not in the Ingress.** All 7 microservices get a
Deployment/Service; the Ingress (`templates/ingress.yaml`) routes straight
to `frontend` and each backend by `ingressPath` (set per-service in
`values.yaml`) rather than through `gateway`, so Ingress paths can match
what the frontend actually calls (`/api/products`, `/api/auth`, ...) without
a second rebuild of the gateway image with different upstream names. Same
choice as the raw `k8s/04-ingress.yaml`, carried over here.

**Bitnami image substitution.** `values.yaml`'s `mongodb.image.repository`
points at `bitnamilegacy/mongodb` instead of `bitnami/mongodb` — Bitnami
stopped publishing pinned version tags to the free catalog, only `:latest`
remains there. `bitnamilegacy` is Bitnami's own mirror for this migration.
`helm install`/`upgrade` print a "SECURITY WARNING: Original containers have
been substituted" notice because of this — expected, not a chart bug.
