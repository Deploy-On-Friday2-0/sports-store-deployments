import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALUES_EKS = ROOT / "helm" / "sports-store" / "values-eks.yaml"
VALUES = ROOT / "helm" / "sports-store" / "values.yaml"
INGRESS_TPL = ROOT / "helm" / "sports-store" / "templates" / "ingress.yaml"
APPS_FILE = ROOT / "apps" / "sports-store-production.yaml"

BACKENDS = ("auth", "catalog", "cart", "order", "payment")


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    for path in (VALUES_EKS, VALUES, INGRESS_TPL, APPS_FILE):
        if not path.is_file():
            fail(f"missing file: {path}")

    eks = VALUES_EKS.read_text(encoding="utf-8")
    values = VALUES.read_text(encoding="utf-8")
    template = INGRESS_TPL.read_text(encoding="utf-8")
    apps = APPS_FILE.read_text(encoding="utf-8")

    # --- values-eks.yaml: the ALB ingress contract ---------------------------
    eks_required = (
        (r"ingress:\n\s+className:\s*alb", "production ingress class must be alb"),
        (r"alb\.ingress\.kubernetes\.io/scheme:\s*internet-facing", "ALB must be internet-facing"),
        (r"alb\.ingress\.kubernetes\.io/target-type:\s*ip", "ALB targets must be pod IPs (ip, not instance)"),
        (r"alb\.ingress\.kubernetes\.io/load-balancer-name:\s*[\"']?alb-sports-store[\"']?", "ALB must be named alb-sports-store"),
        (r"alb\.ingress\.kubernetes\.io/healthcheck-path:\s*/health", "ALB health checks must hit /health"),
    )
    for pattern, description in eks_required:
        if not re.search(pattern, eks, flags=re.MULTILINE):
            fail(f"values-eks.yaml is missing {description}")

    for workload in ("gateway", "frontend"):
        if not re.search(rf"^\s+{workload}:\n\s+enabled: false", eks, flags=re.MULTILINE):
            fail(f"values-eks.yaml must disable the {workload} workload (no gateway/frontend in the routing path)")

    # --- values.yaml: gateway must never be routable --------------------------
    gateway_block = re.search(r"^\s{2}gateway:\n(?:.+\n)*?(?=^\S|\Z)", values, flags=re.MULTILINE)
    if gateway_block and re.search(r"ingressPath:", gateway_block.group(0)):
        fail("values.yaml gives the gateway an ingressPath - it could enter the ALB routing table")

    # --- ingress template: routing is whitelist-gated -------------------------
    if "ingressServices" not in template:
        fail("ingress template does not gate rules on .Values.ingressServices")
    if "has $name $.Values.ingressServices" not in template:
        fail("ingress template does not require each backend to be whitelisted in ingressServices")
    if "service:" not in template or "name: {{ $name }}" not in template:
        fail("ingress template no longer routes directly to the backend Services")

    # --- apps/sports-store-production.yaml: Application contract --------------
    blocks = re.split(r"^---\s*$", apps, flags=re.MULTILINE)
    application_blocks = [b for b in blocks if "kind: Application" in b]
    if len(application_blocks) != 8:
        fail(f"expected 8 Applications in apps/sports-store-production.yaml, found {len(application_blocks)}")

    ingress_app = None
    for block in application_blocks:
        if re.search(r"name:\s*production-ingress", block):
            ingress_app = block
            break
    if ingress_app is None:
        fail("production-ingress Application not found in apps/sports-store-production.yaml")

    if not re.search(r"releaseName:\s*sports-store-ingress", ingress_app):
        fail("production-ingress must use releaseName sports-store-ingress")
    if not re.search(r"fullnameOverride:\s*sports-store-gateway", ingress_app):
        fail("production-ingress must pin fullnameOverride sports-store-gateway (adopt the existing ALB)")
    if not re.search(r"valueFiles:\s*\[values-eks\.yaml\]", ingress_app):
        fail("production-ingress must render with values-eks.yaml (the ALB values file)")
    if not re.search(r"ingressServices:\s*\[auth, catalog, cart, order, payment\]", ingress_app):
        fail("production-ingress must whitelist exactly the five backend services in ingressServices")

    for banned in ("enabledServices: [gateway]", "enabledServices: [frontend]"):
        if banned in ingress_app:
            fail(f"production-ingress must not deploy a workload ({banned})")

    if re.search(r"gateway", apps) and "fullnameOverride: sports-store-gateway" not in apps:
        fail("unexpected gateway reference in production Applications")

    for workload in ("gateway", "frontend"):
        for pattern in (rf"enabledServices:\s*\[.*{workload}", rf"releaseName:\s*sports-store-{workload}"):
            if re.search(pattern, apps):
                fail(f"no production Application may deploy the {workload} workload (found {pattern})")

    # The five backends each need a dedicated per-service Application.
    for backend in BACKENDS:
        if not re.search(rf"name:\s*production-{backend}-service", apps):
            fail(f"missing production-{backend}-service Application")

    print("DEP-324 direct ALB routing contract tests passed.")


if __name__ == "__main__":
    main()
