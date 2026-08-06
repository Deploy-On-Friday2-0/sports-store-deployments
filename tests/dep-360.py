import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CR = ROOT / "apps" / "k8sgpt" / "k8sgpt-cr.yaml"
PLACEHOLDER = "placeholder-dep-360"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, fragment: str, description: str) -> None:
    if fragment not in text:
        fail(f"missing {description}: {fragment}")


def main() -> None:
    if not CR.is_file():
        fail("DEP-360 K8sGPT CR manifest is missing")

    text = CR.read_text(encoding="utf-8")
    docs = [d for d in text.split("---") if re.search(r"kind:\s*K8sGPT", d)]
    if len(docs) != 5:
        fail(f"expected 5 K8sGPT CRs, found {len(docs)}")

    for doc in docs:
        name_match = re.search(r"name:\s*(k8sgpt-\S+)", doc)
        name = name_match.group(1) if name_match else "?"

        require(doc, "type: slack", f"{name} sink type")

        webhook_match = re.search(r"webhook:\s*(\S+)", doc)
        if not webhook_match or webhook_match.group(1) != PLACEHOLDER:
            fail(f"{name} sink.webhook must be the DEP-360 dedup marker {PLACEHOLDER!r}")

        if text.count(f"webhook: {PLACEHOLDER}") != 5:
            fail("sink.webhook dedup marker must appear exactly once per K8sGPT CR")

        require(doc, "key: slack-webhook-url", f"{name} sink secret key")
        require(doc, "name: k8sgpt-secrets", f"{name} sink secret name")

        if re.search(r"^\s*- Event\s*$", doc, re.M):
            fail(f"{name} still enables the Event filter (perpetual result churn)")

        for expected in ("Pod", "Ingress", "Service", "Deployment"):
            if not re.search(rf"^\s*- {expected}\s*$", doc, re.M):
                fail(f"{name} missing {expected} filter")

        interval_match = re.search(r"interval:\s*(\S+)", doc)
        if not interval_match or interval_match.group(1) != "5m":
            fail(f"{name} analysis interval must be 5m, found {interval_match.group(1) if interval_match else 'none'}")

    if "hooks.slack.com" in text:
        fail("real Slack webhook URL committed to the repository")

    if re.search(r"^\s*webhook:\s*https?://", text, re.M):
        fail("sink.webhook must not contain a real URL (keep the secret-managed setup)")

    print("DEP-360 static k8sgpt dedup contract tests passed.")


if __name__ == "__main__":
    main()
