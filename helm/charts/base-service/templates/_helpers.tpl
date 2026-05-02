{{/*
Expand the name of the chart.
*/}}
{{- define "base-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "base-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "base-service.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Standard Kubernetes recommended labels (https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/).
These are applied to every resource so Prometheus, Argo CD, and kubectl can
consistently filter and identify resources.
*/}}
{{- define "base-service.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "base-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: swms
{{- end -}}

{{/*
Selector labels — used by Deployment selectors and Service selectors.
Must be a STRICT subset of .labels and must NEVER change after first deploy
(changing selector labels forces pod recreation).
*/}}
{{- define "base-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "base-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
ServiceAccount name helper.
*/}}
{{- define "base-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
  {{- include "base-service.fullname" . -}}
{{- else -}}
  default
{{- end -}}
{{- end -}}
