import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APPS_FILE = ROOT / "apps" / "sports-store-production.yaml"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if not APPS_FILE.is_file():
        fail(f"missing file: {APPS_FILE}")

    text = APPS_FILE.read_text(encoding="utf-8")

    blocks = re.split(r"^---\s*$", text, flags=re.MULTILINE)
    ingress_app = None
    for block in blocks:
        if "kind: Application" in block and re.search(r"name:\s*production-ingress", block):
            ingress_app = block
            break

    if ingress_app is None:
        fail("production-ingress Application not found in apps/sports-store-production.yaml")

    required = (
        (r"ignoreDifferences:", "ignoreDifferences block"),
        (r"group:\s*networking\.k8s\.io", "ignoreDifferences group"),
        (r"kind:\s*Ingress", "ignoreDifferences kind"),
        (r"managedFieldsManagers:", "managedFieldsManagers list"),
        (r"-\s*argoproj\.io/rollouts", "rollouts manager entry"),
    )
    for pattern, description in required:
        if not re.search(pattern, ingress_app, flags=re.MULTILINE):
            fail(f"production-ingress is missing {description}")

    if len(re.findall(r"ignoreDifferences:", text)) != 1:
        fail("ignoreDifferences must appear exactly once (only on production-ingress)")

    print("DEP-336 argo ingress ignoreDifferences contract tests passed.")


if __name__ == "__main__":
    main()
