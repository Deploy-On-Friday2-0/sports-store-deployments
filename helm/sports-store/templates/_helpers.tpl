{{/*
Standard Helm naming convention (release-prefixed unless the release name
already contains the chart name). Provided for governance/convention, and
used for resources nothing else needs to resolve by a fixed DNS name (e.g.
the Ingress). Deployment/Service names for the 7 microservices deliberately
do NOT use this — they stay unprefixed (e.g. "auth", not
"sports-store-auth") because sports-store-gateway/nginx.conf proxies to
those exact short hostnames, and services/order-service + cart-service's
CATALOG_URL/CART_URL/PAYMENT_URL env vars (set in values.yaml) reference
them the same way. Same constraint the raw k8s/ manifests document.
*/}}
{{- define "sports-store.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sports-store.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Standard labels applied to every resource this chart renders directly
(the mongodb subchart applies its own, per Bitnami's own conventions).
*/}}
{{- define "sports-store.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/*
Selector label for a single microservice, keyed by its short name (the map
key under .Values.services — "auth", "catalog", etc). Used identically on
the Deployment's pod template and its Service's selector so they match.
*/}}
{{- define "sports-store.selectorLabels" -}}
app: {{ . }}
{{- end -}}

{{/* MongoDB ReplicaSet headless Service used as the driver discovery seed. */}}
{{- define "sports-store.mongoHost" -}}
{{- printf "%s-mongodb-headless" .Release.Name -}}
{{- end -}}
