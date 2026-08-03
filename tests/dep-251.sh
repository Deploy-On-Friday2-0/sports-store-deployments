#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ruby -ryaml -e '
  applications = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  abort "no production Applications found" if applications.empty?

  applications.each_with_index do |application, index|
    name = application.dig("metadata", "name") || "document #{index + 1}"
    abort "#{name}: expected an Argo CD Application" unless application["kind"] == "Application"
    abort "#{name}: expected a production Application" unless name.start_with?("production-")

    automated = application.dig("spec", "syncPolicy", "automated")
    abort "#{name}: automated.prune must be true" unless automated&.fetch("prune", nil) == true
    abort "#{name}: automated.selfHeal must be true" unless automated&.fetch("selfHeal", nil) == true

    sync_options = application.dig("spec", "syncPolicy", "syncOptions") || []
    %w[CreateNamespace=true ApplyOutOfSyncOnly=true].each do |required_option|
      abort "#{name}: missing sync option #{required_option}" unless sync_options.include?(required_option)
    end
  end
' "$repo_root/apps/sports-store-production.yaml"

printf 'DEP-251 sync-policy tests passed.\n'
