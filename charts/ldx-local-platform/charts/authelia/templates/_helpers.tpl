{{- define "authelia.fullname" -}}
{{- default "authelia" .Values.nameOverride -}}
{{- end -}}

{{- define "authelia.name" -}}
{{- default "authelia" .Values.nameOverride -}}
{{- end -}}

{{- define "authelia.labels" -}}
app.kubernetes.io/name: {{ include "authelia.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "authelia.selectorLabels" -}}
app.kubernetes.io/name: {{ include "authelia.name" . }}
{{- end -}}

{{/*
The umbrella release lives in the platform namespace; Authelia keeps its own.
namespaceOverride wins, then the release namespace.
*/}}
{{- define "authelia.namespace" -}}
{{- .Values.namespaceOverride | default .Release.Namespace -}}
{{- end -}}
