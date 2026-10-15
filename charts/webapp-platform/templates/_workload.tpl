{{/*
=============================================================================
Shared Deployment / Service renderers for the stateless components.

Usage:
  include "webapp.deployment" (dict
    "root" $                      # chart root context
    "component" "frontend"        # values key
    "checksum" "<sha>"            # optional: config checksum to roll pods
    "env" "<yaml list string>"    # optional: chart-managed env vars
    "volumeMounts" "<yaml>"       # optional
    "volumes" "<yaml>"            # optional
    "extraContainers" "<yaml>"    # optional: sidecars
    "extraPodLabels" (dict)       # optional
    "extraPodAnnotations" (dict)  # optional
    "ports" "<yaml>"              # optional: extra container ports
  )
=============================================================================
*/}}
{{- define "webapp.deployment" -}}
{{- $root := .root }}
{{- $component := .component }}
{{- $v := index $root.Values $component }}
{{- $slug := include "webapp.componentSlug" $component }}
{{- $ctx := dict "root" $root "component" $component }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "webapp.componentName" $ctx }}
  labels:
    {{- include "webapp.componentLabels" $ctx | nindent 4 }}
  {{- with $root.Values.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if not (include "webapp.hpaEnabled" $ctx) }}
  replicas: {{ $v.replicaCount }}
  {{- end }}
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      {{- include "webapp.componentSelectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "webapp.componentLabels" $ctx | nindent 8 }}
        {{- with .extraPodLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        kubectl.kubernetes.io/default-container: {{ $slug }}
        {{- with .checksum }}
        checksum/config: {{ . }}
        {{- end }}
        {{- with .extraPodAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- with $v.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      serviceAccountName: {{ include "webapp.serviceAccountName" $root }}
      automountServiceAccountToken: {{ $root.Values.serviceAccount.automountServiceAccountToken }}
      {{- with (include "webapp.imagePullSecrets" $root | trim) }}
      {{- . | nindent 6 }}
      {{- end }}
      securityContext:
        {{- toYaml $root.Values.podSecurityContext | nindent 8 }}
      terminationGracePeriodSeconds: 30
      containers:
        - name: {{ $slug }}
          image: {{ include "webapp.image" (dict "root" $root "image" $v.image) | quote }}
          imagePullPolicy: {{ $v.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ $v.containerPort }}
              protocol: TCP
            {{- with .ports }}
            {{- . | nindent 12 }}
            {{- end }}
          {{- if or .env $v.env }}
          env:
            {{- with .env }}
            {{- . | nindent 12 }}
            {{- end }}
            {{- with $v.env }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          {{- end }}
          {{- with (include "webapp.probe" (dict "name" "startupProbe" "probe" $v.probes.startup) | trim) }}
          {{- . | nindent 10 }}
          {{- end }}
          {{- with (include "webapp.probe" (dict "name" "readinessProbe" "probe" $v.probes.readiness) | trim) }}
          {{- . | nindent 10 }}
          {{- end }}
          {{- with (include "webapp.probe" (dict "name" "livenessProbe" "probe" $v.probes.liveness) | trim) }}
          {{- . | nindent 10 }}
          {{- end }}
          resources:
            {{- toYaml $v.resources | nindent 12 }}
          securityContext:
            {{- toYaml $root.Values.containerSecurityContext | nindent 12 }}
          {{- with .volumeMounts }}
          volumeMounts:
            {{- . | nindent 12 }}
          {{- end }}
        {{- with .extraContainers }}
        {{- . | nindent 8 }}
        {{- end }}
      {{- with .volumes }}
      volumes:
        {{- . | nindent 8 }}
      {{- end }}
      {{- with $v.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      affinity:
        {{- if $v.affinity }}
        {{- toYaml $v.affinity | nindent 8 }}
        {{- else }}
        # Default: spread replicas across nodes when possible.
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    {{- include "webapp.componentSelectorLabels" $ctx | nindent 20 }}
        {{- end }}
      {{- with $v.topologySpreadConstraints }}
      topologySpreadConstraints:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}

{{/*
Service for a stateless component.
Usage: include "webapp.service" (dict "root" $ "component" "frontend" "ports" "<yaml>")
*/}}
{{- define "webapp.service" -}}
{{- $root := .root }}
{{- $v := index $root.Values .component }}
{{- $ctx := dict "root" $root "component" .component }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "webapp.componentName" $ctx }}
  labels:
    {{- include "webapp.componentLabels" $ctx | nindent 4 }}
spec:
  type: {{ $v.service.type }}
  selector:
    {{- include "webapp.componentSelectorLabels" $ctx | nindent 4 }}
  ports:
    - name: http
      port: {{ $v.service.port }}
      targetPort: http
      protocol: TCP
    {{- with .ports }}
    {{- . | nindent 4 }}
    {{- end }}
{{- end }}

{{/* Small writable emptyDir volumes for read-only root filesystems. */}}
{{- define "webapp.tmpVolume" -}}
- name: tmp
  emptyDir:
    sizeLimit: 64Mi
{{- end }}
