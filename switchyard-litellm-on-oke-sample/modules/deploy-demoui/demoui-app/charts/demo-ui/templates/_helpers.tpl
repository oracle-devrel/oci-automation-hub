# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

{{- define "demo-ui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "demo-ui.fullname" -}}
{{- default (printf "%s-%s" .Release.Name (include "demo-ui.name" .)) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "demo-ui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-ui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "demo-ui.loadbalancerFullname" -}}
{{- printf "%s-lb" (include "demo-ui.fullname" . | trunc 60 | trimSuffix "-") -}}
{{- end -}}
{{- define "demo-ui.labels" -}}
{{ include "demo-ui.selectorLabels" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "demo-ui.image" -}}
{{- $repo := required "Set image.repository to your built demo-ui image repository." .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{ printf "%s@%s" $repo .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" $repo (required "Set image.tag or image.digest." .Values.image.tag) }}
{{- end -}}
{{- end -}}
