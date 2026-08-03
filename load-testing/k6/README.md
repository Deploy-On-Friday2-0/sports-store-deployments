# DEP-296 high-concurrency workload

This directory contains the reusable, bounded k6 workload for DEP-297 to use
when validating EKS autoscaling, resource behavior, dashboards, and alerts.
It does not itself prove that an HPA scaled or that an alert fired.

## Target contract

The rendered EKS Ingress sends traffic directly to backend Services; it does
not use the internal `gateway` Service. The baseline therefore calls only the
catalog service's public, read-only route:

- `GET /api/products?limit=20&skip=0` (expected: HTTP 200 and a JSON array)

The path and response contract were verified against the Helm Ingress and the
catalog service source. Authenticated and state-changing flows are deliberately
excluded. This also keeps the baseline independent of the DEP-321 Redis secret
bug affecting Redis-dependent auth/cart execution.

## Prerequisites and execution

Install k6 locally, or use the pinned Docker image `grafana/k6:0.54.0`. Always
use an explicitly authorized environment. `BASE_URL` is mandatory, must be an
absolute HTTP(S) URL, and has no production default.

```bash
BASE_URL=https://load-test.example.invalid k6 inspect load-testing/k6/high-concurrency.js
BASE_URL=https://load-test.example.invalid k6 run load-testing/k6/high-concurrency.js

docker run --rm -i \
  -e BASE_URL=https://load-test.example.invalid \
  -v "$PWD/load-testing/k6:/scripts:ro" \
  grafana/k6:0.54.0 run /scripts/high-concurrency.js
```

The `.invalid` hostname is a placeholder; do not run the example unchanged.
Do not point this workload at production without explicit authorization.

## Configuration and guardrails

| Variable | Default | Constraint |
| --- | ---: | --- |
| `BASE_URL` | none | Required HTTP(S) origin; credentials, query, and fragment rejected |
| `WARMUP_VUS` | `10` | Positive integer, no greater than sustained VUs |
| `SUSTAINED_VUS` | `50` | Positive integer between warm-up and spike VUs |
| `SPIKE_VUS` | `100` | Positive integer, hard maximum `500` |
| `WARMUP_DURATION` | `30s` | Positive k6 duration |
| `RAMP_UP_DURATION` | `30s` | Positive k6 duration |
| `SUSTAINED_DURATION` | `3m` | Positive k6 duration |
| `SPIKE_DURATION` | `30s` | Positive k6 duration |
| `RAMP_DOWN_DURATION` | `1m` | Positive k6 duration |
| `THINK_TIME_SECONDS` | `0.5` | Between `0` and `10` seconds |
| `ABORT_ON_CHECK_FAILURE` | unset | Set exactly `true` to abort an iteration on a failed contract check |

Combined phase duration is capped at two hours. VUs must remain monotonic from
warm-up through spike. Defaults produce a 5.5-minute bounded profile: gradual
warm-up and ramp-up, three minutes of sustained 50-VU traffic, a 100-VU spike,
then controlled ramp-down.

Thresholds fail the k6 run when request failures reach 1%, catalog p95 latency
reaches 750 ms, catalog p99 reaches 1500 ms, or successful checks fall to 99%.
Requests carry `route`, `method`, `safety`, `profile`, and `workload` tags for
result analysis; the scenario's four ordered stages identify the traffic phase.

## DEP-297 EKS runtime validation

DEP-297 should obtain the ALB address from the authorized environment and pass
it through `BASE_URL`; never commit it. During the run, operators can monitor:

```bash
kubectl get hpa --namespace sports-store --watch
kubectl top pods --namespace sports-store
kubectl get pods --namespace sports-store --watch
```

In Grafana, use **Sports Store Overview** to watch request rate, 5xx rate,
p95/p99 latency, CPU, and memory. In Prometheus/Alertmanager, inspect the
`sports-store` targets and the `ServiceDown`, `PodCrashLooping`,
`ReplicasUnavailable`, and `HighHTTPErrorRate` rules. Normal read traffic is
not intended to force failure alerts; record what actually happens rather than
claiming expected scaling or alert evidence in advance.

Stop safely with `Ctrl+C`; k6 performs a graceful ramp-down where possible.
For a planned stop, reduce VUs or durations and rerun. The workload creates no
application data, so no cleanup is required.

## Static validation

`python tests/dep-296.py` validates the route, phases, thresholds, configuration
guards, and absence of committed endpoints or secret-like values without
contacting any service. CI runs this check. If k6 is available, also run
`k6 inspect` with a placeholder/local URL and a minimal execution only against
a local mock server; ordinary CI must never contact EKS.
