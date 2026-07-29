#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

chart_version="2.8.7"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_count() {
  local expected="$1" pattern="$2" file="$3" description="$4" actual
  actual="$(awk -v pattern="$pattern" '$0 ~ pattern { count++ } END { print count+0 }' "$file")"
  [[ "$actual" == "$expected" ]] || fail "$description: expected $expected, got $actual"
}

assert_contains() {
  local pattern="$1" file="$2" description="$3"
  grep -Eq "$pattern" "$file" || fail "missing $description"
}

assert_absent() {
  local pattern="$1" file="$2" description="$3"
  if grep -Eq "$pattern" "$file"; then
    fail "unexpected $description"
  fi
}

document_count() {
  local file="$1" kind="$2" name="$3"
  awk -v wanted_kind="$kind" -v wanted_name="$name" '
    BEGIN { RS="---" }
    {
      kind=""; name=""; in_metadata=0
      count=split($0, lines, "\n")
      for (i=1; i<=count; i++) {
        if (lines[i] ~ /^kind: /) kind=substr(lines[i], 7)
        if (lines[i] == "metadata:") { in_metadata=1; continue }
        if (in_metadata && lines[i] ~ /^[^ ]/) in_metadata=0
        if (in_metadata && lines[i] ~ /^  name: /) {
          name=substr(lines[i], 9)
          gsub(/^"|"$/, "", name)
          in_metadata=0
        }
      }
      if (kind == wanted_kind && name == wanted_name) matches++
    }
    END { print matches+0 }
  ' "$file"
}

assert_document_count() {
  local expected="$1" file="$2" kind="$3" name="$4" actual
  actual="$(document_count "$file" "$kind" "$name")"
  [[ "$actual" == "$expected" ]] || fail "$kind/$name count: expected $expected, got $actual"
}

extract_document() {
  local file="$1" kind="$2" name="$3" output="$4"
  awk -v wanted_kind="$kind" -v wanted_name="$name" '
    BEGIN { RS="---"; ORS="" }
    {
      kind=""; name=""; in_metadata=0
      count=split($0, lines, "\n")
      for (i=1; i<=count; i++) {
        if (lines[i] ~ /^kind: /) kind=substr(lines[i], 7)
        if (lines[i] == "metadata:") { in_metadata=1; continue }
        if (in_metadata && lines[i] ~ /^[^ ]/) in_metadata=0
        if (in_metadata && lines[i] ~ /^  name: /) {
          name=substr(lines[i], 9)
          gsub(/^"|"$/, "", name)
          in_metadata=0
        }
      }
      if (kind == wanted_kind && name == wanted_name) {
        matches++
        print $0
      }
    }
    END { if (matches != 1) exit 1 }
  ' "$file" > "$output" || fail "expected exactly one $kind/$name"
}

extract_container() {
  local workload="$1" container="$2" output="$3"
  awk -v wanted="$container" '
    function flush() {
      if (block ~ ("(^|\\n)          name: " wanted "(\\n|$)") ||
          block ~ ("(^|\\n)        - name: " wanted "(\\n|$)")) {
        matches++
        printf "%s", block
      }
      block=""
    }
    /^      containers:$/ { in_containers=1; next }
    in_containers && /^        - / { flush(); block=$0 "\n"; next }
    in_containers && /^      [^ ]/ { flush(); in_containers=0 }
    in_containers && block != "" { block=block $0 "\n" }
    END { flush(); if (matches != 1) exit 1 }
  ' "$workload" > "$output" || fail "expected exactly one container $container"
}

assert_resources() {
  local workload="$1" container="$2" request_cpu="$3" request_memory="$4"
  local limit_cpu="$5" limit_memory="$6" block="$work_dir/container-${container}.yaml"
  extract_container "$workload" "$container" "$block"
  assert_contains '^          resources:$' "$block" "$container resources"
  assert_resource_value "$block" "$container" limits cpu "$limit_cpu"
  assert_resource_value "$block" "$container" limits memory "$limit_memory"
  assert_resource_value "$block" "$container" requests cpu "$request_cpu"
  assert_resource_value "$block" "$container" requests memory "$request_memory"
}

assert_resource_value() {
  local block="$1" container="$2" section="$3" key="$4" expected="$5"
  awk -v section="$section" -v key="$key" -v expected="$expected" '
    $0 == "            " section ":" { in_section=1; next }
    in_section && $0 ~ /^            [^ ]/ { in_section=0 }
    in_section && $0 == "              " key ": " expected { found=1 }
    END { exit !found }
  ' "$block" || fail "$container $section.$key is not $expected"
}

application="apps/kubecost/kubecost.yaml"
asserted_version="$(awk '/^    targetRevision:/ { print $2; exit }' "$application")"
[[ "$asserted_version" == "$chart_version" ]] || \
  fail "test chart $chart_version does not match Application chart $asserted_version"

values_file="$work_dir/default-values.yaml"
awk '
  /^  source:$/ { in_source=1; next }
  in_source && /^    helm:$/ { in_helm=1; next }
  in_source && in_helm && /^      values: \|$/ { in_values=1; found=1; next }
  in_values && /^  [^ ]/ { exit }
  in_values {
    if ($0 != "" && $0 !~ /^        /) exit 2
    sub(/^        /, "")
    print
  }
  END { if (!found) exit 3 }
' "$application" > "$values_file" || fail "could not extract spec.source.helm.values"
[[ -s "$values_file" ]] || fail "extracted Helm values are empty"
for key in global kubecostProductConfigs persistentVolume service prometheus; do
  grep -Eq "^${key}:$" "$values_file" || fail "extracted Helm values are missing top-level key $key"
done

if [[ -n "${KUBECOST_CHART_ARCHIVE:-}" ]]; then
  chart_archive="$KUBECOST_CHART_ARCHIVE"
  [[ -f "$chart_archive" && -r "$chart_archive" ]] || \
    fail "KUBECOST_CHART_ARCHIVE is not a readable file: $chart_archive"
else
  chart_archive="$work_dir/cost-analyzer-${chart_version}.tgz"
  chart_url="https://kubecost.github.io/cost-analyzer/cost-analyzer-${chart_version}.tgz"
  curl --fail --location --silent --show-error --retry 3 \
    "$chart_url" --output "$chart_archive" || fail "could not download $chart_url"
fi

tar -tzf "$chart_archive" >/dev/null || fail "invalid chart archive: $chart_archive"
tar -xzf "$chart_archive" -C "$work_dir" || fail "could not extract chart archive"
chart="$work_dir/cost-analyzer"
[[ -f "$chart/Chart.yaml" ]] || fail "extracted chart is missing cost-analyzer/Chart.yaml"
archive_version="$(awk '/^version:/ { print $2; exit }' "$chart/Chart.yaml")"
[[ "$archive_version" == "$chart_version" ]] || \
  fail "chart archive version $archive_version does not match $chart_version"

render() {
  local output="$1"
  shift
  helm template kubecost "$chart" --namespace kubecost \
    -f "$values_file" "$@" > "$output"
  [[ -s "$output" ]] || fail "Helm produced an empty render: $output"
}

assert_pvc() {
  local render_file="$1" name="$2" size="$3" storage_class="${4:-}"
  local pvc="$work_dir/pvc-${name}.yaml"
  extract_document "$render_file" PersistentVolumeClaim "$name" "$pvc"
  assert_contains "^[[:space:]]+storage: \"?${size}\"?$" "$pvc" "$name storage request $size"
  if [[ -n "$storage_class" ]]; then
    assert_contains "^  storageClassName: \"?${storage_class}\"?$" "$pvc" "$name StorageClass"
  else
    assert_absent '^  storageClassName:' "$pvc" "$name storageClassName"
  fi
}

helm lint "$chart" -f "$values_file"

default_render="$work_dir/default.yaml"
render "$default_render"
assert_count 2 '^kind: PersistentVolumeClaim$' "$default_render" 'default PVC count'
assert_pvc "$default_render" kubecost-cost-analyzer 10Gi
assert_pvc "$default_render" kubecost-prometheus-server 20Gi
assert_document_count 1 "$default_render" Deployment kubecost-prometheus-server
assert_document_count 1 "$default_render" Service kubecost-prometheus-server
assert_count 0 '^kind: Ingress$' "$default_render" 'Ingress count'
assert_absent '^[[:space:]]*type: "?LoadBalancer"?$' "$default_render" 'LoadBalancer Service'
assert_count 0 '^kind: Secret$' "$default_render" 'rendered Secret count'

cost_analyzer="$work_dir/deployment-kubecost-cost-analyzer.yaml"
prometheus="$work_dir/deployment-kubecost-prometheus-server.yaml"
extract_document "$default_render" Deployment kubecost-cost-analyzer "$cost_analyzer"
extract_document "$default_render" Deployment kubecost-prometheus-server "$prometheus"
assert_resources "$cost_analyzer" cost-analyzer-frontend 25m 64Mi 250m 256Mi
assert_resources "$cost_analyzer" cost-model 200m 256Mi 750m 1Gi
assert_resources "$cost_analyzer" aggregator 100m 256Mi 500m 1Gi
assert_resources "$cost_analyzer" cloud-cost 50m 128Mi 250m 512Mi
assert_resources "$prometheus" prometheus-server 100m 256Mi 500m 1Gi

explicit_render="$work_dir/explicit-storage-class.yaml"
render "$explicit_render" \
  --set persistentVolume.storageClass=validated-storage-class \
  --set prometheus.server.persistentVolume.storageClass=validated-storage-class \
  --set persistentVolume.size=11Gi \
  --set prometheus.server.persistentVolume.size=21Gi
assert_count 2 '^kind: PersistentVolumeClaim$' "$explicit_render" 'explicit-StorageClass PVC count'
assert_pvc "$explicit_render" kubecost-cost-analyzer 11Gi validated-storage-class
assert_pvc "$explicit_render" kubecost-prometheus-server 21Gi validated-storage-class

external_render="$work_dir/external-prometheus.yaml"
render "$external_render" \
  --set global.prometheus.enabled=false \
  --set-string global.prometheus.fqdn=http://prometheus.example.invalid
assert_count 1 '^kind: PersistentVolumeClaim$' "$external_render" 'external-Prometheus PVC count'
assert_pvc "$external_render" kubecost-cost-analyzer 10Gi
assert_document_count 0 "$external_render" PersistentVolumeClaim kubecost-prometheus-server
assert_document_count 0 "$external_render" Deployment kubecost-prometheus-server
assert_document_count 0 "$external_render" Service kubecost-prometheus-server

ephemeral_render="$work_dir/ephemeral.yaml"
render "$ephemeral_render" \
  --set persistentVolume.enabled=false \
  --set prometheus.server.persistentVolume.enabled=false
assert_count 0 '^kind: PersistentVolumeClaim$' "$ephemeral_render" 'disabled-persistence PVC count'
assert_document_count 0 "$ephemeral_render" PersistentVolumeClaim kubecost-cost-analyzer
assert_document_count 0 "$ephemeral_render" PersistentVolumeClaim kubecost-prometheus-server

echo 'Kubecost render validation passed.'
