{{/*
=============================================================================
Naming
=============================================================================
*/}}

{{/* Chart name, overridable with nameOverride. */}}
{{- define "webapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. If the release name already contains the chart
name it is not repeated. Truncated to 63 chars (DNS-1123 label limit).
*/}}
{{- define "webapp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Chart label value. */}}
{{- define "webapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Kebab-case name of a component from its values key.
  authProxy -> auth-proxy
*/}}
{{- define "webapp.componentSlug" -}}
{{- . | kebabcase }}
{{- end }}

{{/*
Resource name of a component.
Usage: include "webapp.componentName" (dict "root" $ "component" "backend")
*/}}
{{- define "webapp.componentName" -}}
{{- $slug := include "webapp.componentSlug" .component }}
{{- printf "%s-%s" (include "webapp.fullname" .root | trunc (int (sub 62 (len $slug)))) $slug | trimSuffix "-" }}
{{- end }}

{{/*
=============================================================================
Labels
=============================================================================
*/}}

{{/* Selector labels shared by every object of the release (immutable). */}}
{{- define "webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "webapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Common labels. */}}
{{- define "webapp.labels" -}}
helm.sh/chart: {{ include "webapp.chart" . }}
{{ include "webapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "webapp.name" . }}
app.example.org/environment: {{ .Values.global.environment | quote }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Component selector labels (immutable once a Deployment exists).
Usage: include "webapp.componentSelectorLabels" (dict "root" $ "component" "frontend")
*/}}
{{- define "webapp.componentSelectorLabels" -}}
{{ include "webapp.selectorLabels" .root }}
app.kubernetes.io/component: {{ include "webapp.componentSlug" .component }}
{{- end }}

{{/* Component labels = common labels + component. */}}
{{- define "webapp.componentLabels" -}}
{{ include "webapp.labels" .root }}
app.kubernetes.io/component: {{ include "webapp.componentSlug" .component }}
{{- end }}

{{/*
=============================================================================
Misc
=============================================================================
*/}}

{{- define "webapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "webapp.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Full image reference.
Usage: include "webapp.image" (dict "root" $ "image" .Values.frontend.image)
*/}}
{{- define "webapp.image" -}}
{{- $registry := .root.Values.global.imageRegistry | default "" }}
{{- $tag := .image.tag | default .root.Chart.AppVersion | toString }}
{{- if $registry }}
{{- printf "%s/%s:%s" (trimSuffix "/" $registry) .image.repository $tag }}
{{- else }}
{{- printf "%s:%s" .image.repository $tag }}
{{- end }}
{{- end }}

{{- define "webapp.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Render a probe block from values, dropping the "enabled" toggle.
Usage: include "webapp.probe" (dict "name" "readinessProbe" "probe" .probes.readiness)
*/}}
{{- define "webapp.probe" -}}
{{- if and .probe .probe.enabled }}
{{ .name }}:
{{- omit .probe "enabled" | toYaml | nindent 2 }}
{{- end }}
{{- end }}

{{/* True when HPA manages this component's replica count. */}}
{{- define "webapp.hpaEnabled" -}}
{{- $cfg := index .root.Values.scalability.hpa.components .component | default dict }}
{{- if and .root.Values.scalability.enabled $cfg }}true{{- end }}
{{- end }}

{{/* In-cluster URL of the backend service. */}}
{{- define "webapp.backendUrl" -}}
{{- printf "http://%s:%v" (include "webapp.componentName" (dict "root" . "component" "backend")) .Values.backend.service.port }}
{{- end }}

{{/* In-cluster URL of the frontend service. */}}
{{- define "webapp.frontendUrl" -}}
{{- printf "http://%s:%v" (include "webapp.componentName" (dict "root" . "component" "frontend")) .Values.frontend.service.port }}
{{- end }}

{{/* Partner API URL seen by the backend. */}}
{{- define "webapp.partnerApiUrl" -}}
{{- if .Values.istio.enabled }}
{{- /* Plain HTTP: the sidecar + egress gateway originate mTLS and tunnel via the proxy. */}}
{{- printf "http://%s" .Values.istio.partner.host }}
{{- else }}
{{- .Values.backend.partnerApi.url }}
{{- end }}
{{- end }}

{{/*
=============================================================================
Render-time guard rails
=============================================================================
*/}}
{{- define "webapp.validate" -}}
{{- $exposure := list "route" "ingress" "none" }}
{{- if not (has .Values.exposure.type $exposure) }}
{{- fail (printf "exposure.type must be one of %v, got %q" $exposure .Values.exposure.type) }}
{{- end }}
{{- $providers := list "existingSecret" "externalSecret" "vaultStaticSecret" }}
{{- if not (has .Values.secrets.provider $providers) }}
{{- fail (printf "secrets.provider must be one of %v, got %q" $providers .Values.secrets.provider) }}
{{- end }}
{{- if .Values.mongodb.enabled }}
{{- $_ := required "mongodb.auth.secretName is required (no default credentials are generated)" .Values.mongodb.auth.secretName }}
{{- end }}
{{- range $c := list "frontend" "authProxy" "backend" }}
{{- range (index $.Values $c "env") }}
{{- if and (eq .name "NODE_TLS_REJECT_UNAUTHORIZED") (eq (toString .value) "0") }}
{{- fail (printf "%s.env: NODE_TLS_REJECT_UNAUTHORIZED=0 disables TLS verification and is not allowed. Trust the CA instead (NODE_EXTRA_CA_CERTS)." $c) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.istio.enabled (not .Values.backend.enabled) }}
{{- fail "istio.enabled=true requires backend.enabled=true (the egress pattern targets the backend)" }}
{{- end }}
{{- end }}
