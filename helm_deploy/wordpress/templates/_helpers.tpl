{{/*
Expand the name of the chart..
*/}}
{{- define "wordpress.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "wordpress.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "wordpress.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "wordpress.labels" -}}
helm.sh/chart: {{ include "wordpress.chart" . }}
{{ include "wordpress.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "wordpress.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wordpress.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "wordpress.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "wordpress.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "wp.replicaCount" -}}
{{- if eq .Values.configmap.envtype "staging" -}}
  {{ .Values.replicaCount.staging }}
{{- else if eq .Values.configmap.envtype "dev" -}}
  {{ .Values.replicaCount.dev }}
{{- else if eq .Values.configmap.envtype "demo" -}}
  {{ .Values.replicaCount.demo }}
{{- else -}}
  {{ .Values.replicaCount.prod }}
{{- end -}}
{{- end }}

{{- define "replicaSettings" -}}
{{- if eq .Values.configmap.envtype "prod" -}}
  minReplicas: 4
  maxReplicas: 5
{{- else if eq .Values.configmap.envtype "staging" -}}
  minReplicas: 2
  maxReplicas: 3
{{- else if eq .Values.configmap.envtype "demo" -}}
  minReplicas: 2
  maxReplicas: 3
{{- else -}}
  minReplicas: 1
  maxReplicas: 1
{{- end -}}
{{- end }}