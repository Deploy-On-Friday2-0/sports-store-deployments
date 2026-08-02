#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap_dir="$repo_root/bootstrap"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract_values() {
  local application="$1"
  local output="$2"
  ruby -ryaml -e '
    application = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    File.write(ARGV.fetch(1), application.dig("spec", "source", "helm", "values"))
  ' "$application" "$output"
}

assert_application() {
  local application="$1"
  local name="$2"
  local chart="$3"
  local version="$4"
  local namespace="$5"
  ruby -ryaml -e '
    app = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    expected = {
      "metadata.name" => ARGV.fetch(1),
      "spec.source.repoURL" => "https://argoproj.github.io/argo-helm",
      "spec.source.chart" => ARGV.fetch(2),
      "spec.source.targetRevision" => ARGV.fetch(3),
      "spec.destination.namespace" => ARGV.fetch(4)
    }
    expected.each do |path, value|
      actual = path.split(".").reduce(app) { |node, key| node.fetch(key) }
      abort "#{path}: expected #{value.inspect}, got #{actual.inspect}" unless actual.to_s == value
    end
    abort "automated sync must remain out of DEP-239" if app.dig("spec", "syncPolicy", "automated")
  ' "$application" "$name" "$chart" "$version" "$namespace"
}

assert_namespaces() {
  ruby -ryaml -e '
    documents = YAML.load_stream(File.read(ARGV.fetch(0)))
    namespaces = documents.filter_map { |doc| doc.dig("metadata", "name") if doc["kind"] == "Namespace" }
    expected = %w[argocd argo-rollouts]
    abort "expected namespaces #{expected.inspect}, got #{namespaces.inspect}" unless namespaces.sort == expected.sort
  ' "$bootstrap_dir/00-namespaces.yaml"
}

assert_workload_resources() {
  local rendered="$1"
  ruby -ryaml -e '
    documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    workloads = documents.select { |doc| %w[Deployment StatefulSet DaemonSet].include?(doc["kind"]) }
    abort "no controller workloads rendered" if workloads.empty?
    workloads.each do |workload|
      pod_spec = workload.dig("spec", "template", "spec")
      containers = pod_spec.fetch("containers", []) + pod_spec.fetch("initContainers", [])
      containers.each do |container|
        resources = container.fetch("resources", {})
        %w[requests limits].each do |bound|
          %w[cpu memory].each do |resource|
            abort "#{workload.dig("metadata", "name")}/#{container["name"]} lacks #{bound}.#{resource}" unless resources.dig(bound, resource)
          end
        end
      end
    end
  ' "$rendered"
}

assert_namespaces
assert_application "$bootstrap_dir/argocd.yaml" argocd argo-cd 10.2.2 argocd
assert_application "$bootstrap_dir/argo-rollouts.yaml" argo-rollouts argo-rollouts 2.41.1 argo-rollouts

extract_values "$bootstrap_dir/argocd.yaml" "$temp_dir/argocd-values.yaml"
extract_values "$bootstrap_dir/argo-rollouts.yaml" "$temp_dir/argo-rollouts-values.yaml"

helm template argocd argo/argo-cd --version 10.2.2 --namespace argocd \
  --values "$temp_dir/argocd-values.yaml" --include-crds >"$temp_dir/argocd-rendered.yaml"
helm template argo-rollouts argo/argo-rollouts --version 2.41.1 --namespace argo-rollouts \
  --values "$temp_dir/argo-rollouts-values.yaml" --include-crds >"$temp_dir/argo-rollouts-rendered.yaml"

assert_workload_resources "$temp_dir/argocd-rendered.yaml"
assert_workload_resources "$temp_dir/argo-rollouts-rendered.yaml"

ruby -ryaml -e '
  documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  crd_kinds = documents.filter_map do |doc|
    doc.dig("spec", "names", "kind") if doc["kind"] == "CustomResourceDefinition"
  end
  expected = %w[Rollout AnalysisTemplate ClusterAnalysisTemplate]
  missing = expected - crd_kinds
  abort "missing Rollouts CRDs: #{missing.join(", ")}" unless missing.empty?
' "$temp_dir/argo-rollouts-rendered.yaml"

printf 'DEP-239 acceptance tests passed.\n'
