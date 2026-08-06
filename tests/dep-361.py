import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CR_FILE = ROOT / "apps" / "k8sgpt" / "k8sgpt-cr.yaml"

EXPECTED_CRS = (
    "k8sgpt-default",
    "k8sgpt-apps",
    "k8sgpt-monitoring",
    "k8sgpt-logging",
    "k8sgpt-sports-store",
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if not CR_FILE.is_file():
        fail(f"missing manifest: {CR_FILE}")

    text = CR_FILE.read_text(encoding="utf-8")

    if "gemini-2.5-flash" in text:
        fail("manifest still references gemini-2.5-flash (shutdown Oct 16, 2026, intermittent empty responses)")

    blocks = re.split(r"^---\s*$", text, flags=re.MULTILINE)
    k8sgpt_blocks = [b for b in blocks if "kind: K8sGPT" in b]

    if len(k8sgpt_blocks) != len(EXPECTED_CRS):
        fail(f"expected {len(EXPECTED_CRS)} K8sGPT CRs, found {len(k8sgpt_blocks)}")

    for block in k8sgpt_blocks:
        name_match = re.search(r"^\s*name:\s*(\S+)\s*$", block, flags=re.MULTILINE)
        name = name_match.group(1) if name_match else "unknown"
        if name not in EXPECTED_CRS:
            fail(f"unexpected CR name: {name}")
        if not re.search(r"^\s*model:\s*gemini-3\.5-flash\s*$", block, flags=re.MULTILINE):
            fail(f"{name}: model is not gemini-3.5-flash")
        if not re.search(r"^\s*backend:\s*google\s*$", block, flags=re.MULTILINE):
            fail(f"{name}: backend is not google")
        if not re.search(r"^\s*version:\s*v0\.4\.36\s*$", block, flags=re.MULTILINE):
            fail(f"{name}: version is not v0.4.36")

    print("DEP-361 k8sgpt model contract tests passed.")


if __name__ == "__main__":
    main()
