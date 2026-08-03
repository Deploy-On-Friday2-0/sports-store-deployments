import os
import sys
import yaml

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    file_path = os.path.join(repo_root, "apps", "infrastructure.yaml")

    if not os.path.exists(file_path):
        fail("apps/infrastructure.yaml does not exist")

    with open(file_path, "r", encoding="utf-8") as f:
        try:
            docs = list(yaml.safe_load_all(f))
        except Exception as e:
            fail(f"Failed to parse YAML: {e}")

    docs = [d for d in docs if d is not None]
    if len(docs) < 2:
        fail("Expected at least 2 documents in infrastructure.yaml")

    loki = next((d for d in docs if d.get("metadata", {}).get("name") == "loki"), None)
    alloy = next((d for d in docs if d.get("metadata", {}).get("name") == "alloy"), None)

    if not loki:
        fail("Loki application not found")
    if not alloy:
        fail("Alloy application not found")

    # Assert Loki
    if loki.get("spec", {}).get("project") != "default":
        fail(f"Loki project should be 'default', got {loki.get('spec', {}).get('project')}")
    if loki.get("spec", {}).get("source", {}).get("repoURL") != "https://grafana.github.io/helm-charts":
        fail("Loki repoURL is incorrect")
    if loki.get("spec", {}).get("source", {}).get("chart") != "loki":
        fail("Loki chart name is incorrect")
    if loki.get("spec", {}).get("destination", {}).get("namespace") != "logging":
        fail("Loki destination namespace should be 'logging'")

    loki_values = yaml.safe_load(loki.get("spec", {}).get("source", {}).get("helm", {}).get("values", "")) or {}
    # The grafana/loki chart reads singleBinary.persistence.storageClass;
    # storageClassName is silently ignored, so assert the key the chart uses.
    persistence = loki_values.get("singleBinary", {}).get("persistence", {})
    storage_class = persistence.get("storageClass")
    if storage_class != "ebs-gp3-retain":
        fail(f"Loki singleBinary.persistence.storageClass should be 'ebs-gp3-retain', got {storage_class}")

    if loki_values.get("deploymentMode") != "SingleBinary":
        fail("Loki deploymentMode should be 'SingleBinary' (otherwise the chart aborts on mixed replicas)")
    if not loki_values.get("loki", {}).get("schemaConfig", {}).get("configs"):
        fail("Loki is missing loki.schemaConfig.configs (chart aborts without a schema_config)")

    # Assert Alloy
    if alloy.get("spec", {}).get("project") != "default":
        fail(f"Alloy project should be 'default', got {alloy.get('spec', {}).get('project')}")
    if alloy.get("spec", {}).get("source", {}).get("repoURL") != "https://grafana.github.io/helm-charts":
        fail("Alloy repoURL is incorrect")
    if alloy.get("spec", {}).get("source", {}).get("chart") != "alloy":
        fail("Alloy chart name is incorrect")
    if alloy.get("spec", {}).get("destination", {}).get("namespace") != "logging":
        fail("Alloy destination namespace should be 'logging'")

    alloy_values = yaml.safe_load(alloy.get("spec", {}).get("source", {}).get("helm", {}).get("values", "")) or {}
    stability_level = alloy_values.get("alloy", {}).get("stabilityLevel")
    if stability_level != "experimental":
        fail(f"Alloy stabilityLevel should be 'experimental', got {stability_level}")

    content = alloy_values.get("alloy", {}).get("configMap", {}).get("content", "")
    if not content or not content.strip():
        fail("Alloy configMap content is empty")

    if "stage.json" not in content or 'level = "level"' not in content or 'service = "service"' not in content or 'trace_id = "trace_id"' not in content:
        fail("Alloy missing json parsing stages for level, service, or trace_id")

    if "loki.secretfilter" not in content:
        fail("Alloy missing loki.secretfilter for secret sanitization")

    print("DEP-264 manifest tests passed.")

if __name__ == "__main__":
    main()
