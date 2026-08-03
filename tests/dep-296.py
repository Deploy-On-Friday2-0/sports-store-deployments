import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "load-testing" / "k6" / "high-concurrency.js"
DOCS = ROOT / "load-testing" / "k6" / "README.md"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, fragment: str, description: str) -> None:
    if fragment not in text:
        fail(f"missing {description}: {fragment}")


def main() -> None:
    if not SCRIPT.is_file() or not DOCS.is_file():
        fail("DEP-296 script or documentation is missing")

    script = SCRIPT.read_text(encoding="utf-8")
    docs = DOCS.read_text(encoding="utf-8")
    docs_flat = " ".join(docs.split())

    require(script, "requiredBaseUrl(__ENV.BASE_URL)", "required BASE_URL guard")
    require(script, "BASE_URL must not contain credentials", "credential-bearing URL rejection")
    require(script, "executor: 'ramping-vus'", "bounded ramping-vus scenario")
    for phase in ("warmup", "ramp_up", "sustained", "spike", "ramp_down"):
        require(script, f"traffic phase: {phase}", f"{phase} phase")
    for variable in (
        "WARMUP_VUS", "SUSTAINED_VUS", "SPIKE_VUS", "WARMUP_DURATION", "RAMP_UP_DURATION",
        "SUSTAINED_DURATION", "SPIKE_DURATION", "RAMP_DOWN_DURATION",
    ):
        require(script, f"'{variable}'", f"configurable {variable}")

    require(script, "maxVus: 500", "VU upper bound")
    require(script, "maxTotalDurationMs", "duration upper bound")
    require(script, "http_req_failed: ['rate<0.01']", "failed-request threshold")
    require(script, "'http_req_duration{route:catalog_list}'", "route latency threshold")
    require(script, "checks: ['rate>0.99']", "check threshold")
    require(script, "`${baseUrl}/api/products?limit=20&skip=0`", "verified catalog route")
    require(script, "res.status === 200", "deterministic status check")
    require(script, "Array.isArray(res.json())", "deterministic response check")
    require(script, "safety: 'read_only'", "read-only request tag")

    forbidden_routes = ("/api/catalog", "/gateway", "/api/gateway")
    for route in forbidden_routes:
        if route in script:
            fail(f"script targets an unverified route: {route}")

    url_literals = re.findall(r"https?://[^\s'\"`]+", script)
    if url_literals:
        fail(f"script contains a hard-coded URL: {url_literals[0]}")
    secret_assignment = re.search(
        r"(?i)(password|token|secret|cookie)\s*[:=]\s*['\"][^'\"]+['\"]", script
    )
    if secret_assignment:
        fail("script contains a secret-like hard-coded assignment")

    require(docs, "grafana/k6:0.54.0", "pinned Docker k6 version")
    require(docs, "DEP-321", "known Redis limitation")
    require(docs_flat, "does not use the internal `gateway` Service", "Ingress routing documentation")
    require(docs, "Ctrl+C", "safe stop instructions")
    require(docs, "DEP-297", "downstream runtime guidance")

    print("DEP-296 static k6 contract tests passed.")


if __name__ == "__main__":
    main()
