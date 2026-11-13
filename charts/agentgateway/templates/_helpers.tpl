{{- define "agentgateway.fullname" -}}
{{- default "agentgateway" .Values.nameOverride -}}
{{- end -}}

{{- define "agentgateway.name" -}}
{{- default "agentgateway" .Values.nameOverride -}}
{{- end -}}

{{- define "agentgateway.labels" -}}
app.kubernetes.io/name: {{ include "agentgateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
