# Production image promotion

The six files in `images/` are the production image-tag source of truth for
the containerized Sports Store workloads. `apps/sports-store-production.yaml`
passes every file to the parent Helm chart, after `values-eks.yaml`, so a tag
write-back changes the corresponding rendered Deployment.

Each file intentionally exposes the CI contract at `.image.tag` and aliases
that scalar into the chart's existing `services.<workload>.tag` value. The
write-back command is therefore both direct and idempotent:

```sh
IMAGE_TAG=1.0.0-deadbee yq -i \
  '.image.tag = strenv(IMAGE_TAG)' \
  environments/production/images/auth-service.yaml
```

Render the exact production input set with:

```sh
helm template sports-store helm/sports-store \
  --namespace sports-store \
  -f helm/sports-store/values-eks.yaml \
  -f environments/production/images/auth-service.yaml \
  -f environments/production/images/cart-service.yaml \
  -f environments/production/images/catalog-service.yaml \
  -f environments/production/images/order-service.yaml \
  -f environments/production/images/payment-service.yaml \
  -f environments/production/images/gateway.yaml
```

`tests/test_dep_250.py` validates the manifests, Argo CD value-file wiring,
Helm rendering, invalid/missing-tag failures, the application workflow paths,
and an actual `yq` update followed by an idempotent second update.

## GitHub App configuration

The upstream application workflows require:

- GitHub App slug: `sports-store-gitops-bot`
- installation owner: `Deploy-On-Friday2-0`
- repository access: `sports-store-deployments`
- repository permission: Contents, read and write
- protected-branch configuration allowing this App to push to `main`
- application repository secret `GITOPS_APP_ID`
- application repository secret `GITOPS_APP_PRIVATE_KEY`

The private key and generated installation token must remain secrets. The
workflows scope each short-lived token to this repository, validate the App
slug, and never print either credential.

## Frontend exception

`sports-store-frontend` is intentionally excluded from image-tag write-back.
Its approved production workflow builds static assets, uploads them to S3, and
invalidates CloudFront. It does not push an ECR image and therefore has no
honest image tag to promote. No `frontend.yaml` is present by design.

Containerizing the frontend is separate architecture work. It would require an
ECR repository, ECR-capable IAM permissions, a container workload and image
manifest, and a deliberate replacement or redesign of the existing
S3/CloudFront delivery path. Until that complete change is approved, the
static frontend workflow remains unchanged.
