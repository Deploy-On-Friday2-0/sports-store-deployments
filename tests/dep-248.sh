#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ruby -ryaml -e '
  root = YAML.safe_load_file(ARGV[0], aliases: true)
  repo = "https://github.com/Deploy-On-Friday2-0/sports-store-deployments.git"
  abort "wrong root project" unless root.dig("spec", "project") == "sports-store-project"
  abort "wrong root source" unless root.dig("spec", "source").slice("repoURL", "targetRevision", "path") == {"repoURL" => repo, "targetRevision" => "main", "path" => "apps"}
  abort "root must exclude itself" unless root.dig("spec", "source", "directory", "exclude") == "root-app.yaml"
  abort "root automation missing" unless root.dig("spec", "syncPolicy", "automated") == {"prune" => true, "selfHeal" => true}

  apps = YAML.load_stream(File.read(ARGV[1])).compact
  names = apps.map { |app| app.dig("metadata", "name") }
  expected = %w[production-mongodb production-redis-sentinel production-auth-service production-cart-service production-catalog-service production-order-service production-payment-service production-gateway]
  abort "unexpected Applications: #{names.inspect}" unless names.sort == expected.sort
  workload_apps = apps
  workload_apps.each do |app|
    abort "non-Application document" unless app["kind"] == "Application"
    abort "wrong project" unless app.dig("spec", "project") == "sports-store-project"
    abort "wrong repository" unless app.dig("spec", "source", "repoURL") == repo
    abort "wrong revision/path" unless app.dig("spec", "source", "targetRevision") == "main" && app.dig("spec", "source", "path") == "helm/sports-store"
    abort "wrong destination" unless app.dig("spec", "destination") == {"server" => "https://kubernetes.default.svc", "namespace" => "sports-store"}
    abort "automation missing" unless app.dig("spec", "syncPolicy", "automated") == {"prune" => true, "selfHeal" => true}
    abort "safe namespace creation missing" unless app.dig("spec", "syncPolicy", "syncOptions")&.include?("CreateNamespace=true")
  end
  expected_releases = {
    "production-mongodb" => "sports-store-mongodb",
    "production-redis-sentinel" => "sports-store-redis-sentinel",
    "production-auth-service" => "sports-store-auth",
    "production-cart-service" => "sports-store-cart",
    "production-catalog-service" => "sports-store-catalog",
    "production-order-service" => "sports-store-order",
    "production-payment-service" => "sports-store-payment",
    "production-gateway" => "sports-store-gateway"
  }
  actual_releases = workload_apps.to_h { |app| [app.dig("metadata", "name"), app.dig("spec", "source", "helm", "releaseName")] }
  abort "release-name mapping drift: #{actual_releases.inspect}" unless actual_releases == expected_releases
  all_releases = workload_apps.map { |app| app.dig("spec", "source", "helm", "releaseName") }
  abort "missing Helm release name" if all_releases.any?(&:nil?)
  abort "duplicate Helm release name" unless all_releases.uniq.length == all_releases.length
  waves = apps.to_h { |app| [app.dig("metadata", "name"), Integer(app.dig("metadata", "annotations", "argocd.argoproj.io/sync-wave"))] }
  abort "databases must precede services" unless waves["production-mongodb"] < waves["production-auth-service"] && waves["production-redis-sentinel"] < waves["production-auth-service"]
  creators = apps.select { |app| app.dig("spec", "syncPolicy", "syncOptions")&.include?("CreateNamespace=true") }
  abort "namespace creation drift" unless creators.map { |app| app.dig("metadata", "name") }.sort == names.sort

  controller = YAML.safe_load_file(ARGV[2], aliases: true)
  abort "controller source drift" unless controller.dig("spec", "source").slice("repoURL", "chart", "targetRevision") == {"repoURL" => "https://argoproj.github.io/argo-helm", "chart" => "argo-rollouts", "targetRevision" => "2.41.1"}
  controller_wave = Integer(controller.dig("metadata", "annotations", "argocd.argoproj.io/sync-wave"))
  abort "controller must precede databases" unless controller_wave < waves["production-mongodb"]
' "$repo_root/apps/root-app.yaml" "$repo_root/apps/sports-store-production.yaml" "$repo_root/apps/argo-rollouts.yaml"

ruby -ryaml -e '
  project = YAML.safe_load_file(ARGV[0], aliases: true)
  namespaces = project.dig("spec", "destinations").map { |destination| destination["namespace"] }
  expected = %w[default apps monitoring logging sports-store argocd argo-rollouts]
  abort "AppProject destination drift" unless namespaces.sort == expected.sort
  abort "wildcard project permission" if File.read(ARGV[0]).include?("kind: \"*\"") || namespaces.include?("*")
' "$repo_root/projects/sports-store-project.yaml"

ruby -ryaml -e '
  values = YAML.safe_load_file(ARGV[0], aliases: true)
  eks = YAML.safe_load_file(ARGV[1], aliases: true)
  retain = {"enabled" => true, "whenScaled" => "Retain", "whenDeleted" => "Retain"}
  abort "MongoDB PVCs are not retained" unless values.dig("mongodb", "persistentVolumeClaimRetentionPolicy") == retain
  abort "Redis Sentinel PVCs are not retained" unless values.dig("redis", "sentinel", "persistentVolumeClaimRetentionPolicy") == retain
  abort "MongoDB is not on retain storage" unless eks.dig("mongodb", "persistence", "storageClass") == "ebs-gp3-retain"
  abort "Redis is not on retain storage" unless eks.dig("redis", "sentinel", "persistence", "storageClass") == "ebs-gp3-retain"
' "$repo_root/helm/sports-store/values.yaml" "$repo_root/helm/sports-store/values-eks.yaml"

printf 'DEP-248 manifest tests passed.\n'
