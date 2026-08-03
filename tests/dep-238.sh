#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ruby -ryaml -e '
  project = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
  abort "wrong AppProject identity" unless project["kind"] == "AppProject" && project.dig("metadata", "name") == "sports-store-project" && project.dig("metadata", "namespace") == "argocd"

  expected_sources = [
    "https://github.com/Deploy-On-Friday2-0/sports-store-deployments.git",
    "https://argoproj.github.io/argo-helm"
  ]
  sources = project.dig("spec", "sourceRepos")
  abort "AppProject sources are not least-privilege" unless sources.sort == expected_sources.sort

  expected_namespaces = %w[default apps monitoring logging sports-store argocd argo-rollouts]
  destinations = project.dig("spec", "destinations")
  abort "wildcard destination found" if destinations.any? { |destination| destination.value?("*") }
  abort "non-local destination found" unless destinations.all? { |destination| destination["server"] == "https://kubernetes.default.svc" }
  actual_namespaces = destinations.map { |destination| destination["namespace"] }
  abort "unexpected destination set: #{actual_namespaces.inspect}" unless actual_namespaces.sort == expected_namespaces.sort

  cluster_kinds = project.dig("spec", "clusterResourceWhitelist").map { |resource| [resource["group"], resource["kind"]] }
  abort "cluster-admin wildcard found" if cluster_kinds.include?(["*", "*"])
  %w[Namespace CustomResourceDefinition ClusterRole ClusterRoleBinding].each do |kind|
    abort "missing cluster permission for #{kind}" unless cluster_kinds.any? { |resource| resource.last == kind }
  end
' "$repo_root/projects/sports-store-project.yaml"

ruby -ryaml -e '
  root = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
  abort "root Application uses the wrong project" unless root.dig("spec", "project") == "sports-store-project"
  abort "root Application uses the wrong repository" unless root.dig("spec", "source", "repoURL") == "https://github.com/Deploy-On-Friday2-0/sports-store-deployments.git"
  abort "root Application must track main" unless root.dig("spec", "source", "targetRevision") == "main"
  abort "root Application must track apps" unless root.dig("spec", "source", "path") == "apps"
  abort "root Application recursion must be disabled" unless root.dig("spec", "source", "directory", "recurse") == false
  abort "root Application does not exclude itself" unless root.dig("spec", "source", "directory", "exclude") == "root-app.yaml"
  automated = root.dig("spec", "syncPolicy", "automated")
  abort "root prune/self-heal is disabled" unless automated == {"prune" => true, "selfHeal" => true}
' "$repo_root/apps/root-app.yaml"

for application in \
  "$repo_root/apps/argo-rollouts.yaml" \
  "$repo_root/apps/sports-store-production.yaml"; do
  ruby -ryaml -e '
    app = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    abort "#{ARGV.fetch(0)} uses the wrong project" unless app.dig("spec", "project") == "sports-store-project"
    automated = app.dig("spec", "syncPolicy", "automated")
    abort "#{ARGV.fetch(0)} lacks prune/self-heal" unless automated == {"prune" => true, "selfHeal" => true}
  ' "$application"
done

if rg --quiet --glob '*.{yaml,yml}' \
  'arn:aws:iam::[0-9]{12}|BEGIN (RSA |EC )?PRIVATE KEY|github_pat_|ghp_' "$repo_root"; then
  printf 'FAIL: credential or invented AWS identity material found.\n' >&2
  exit 1
fi

printf 'DEP-238 GitOps boundary tests passed.\n'
