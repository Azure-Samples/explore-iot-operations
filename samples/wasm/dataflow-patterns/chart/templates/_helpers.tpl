{{- define "patterns.name" -}}
{{- printf "%s-%s" (.Release.Name | trunc 29 | trimSuffix "-") (.Release.Name | sha256sum | trunc 8) -}}
{{- end -}}
{{- define "patterns.prefix" -}}
{{- default (printf "dataflow-patterns/%s" .Release.Name) .Values.topicPrefix -}}
{{- end -}}
{{- define "patterns.registry" -}}
{{- printf "%s-ghcr" (include "patterns.name" .) -}}
{{- end -}}
{{- define "patterns.profile" -}}
{{- if .Values.profile.create -}}
{{- include "patterns.name" . -}}
{{- else -}}
{{- $name := required "profileRef is required when profile.create=false" .Values.profileRef -}}
{{- $profile := lookup "connectivity.iotoperations.azure.com/v1" "DataflowProfile" .Release.Namespace $name -}}
{{- if not $profile -}}
{{- fail "Existing DataflowProfile must be readable in the target namespace; use Helm connected to the cluster (or --dry-run=server), not offline template" -}}
{{- end -}}
{{- if ne (toString $profile.spec.instanceCount) "1" -}}
{{- fail "Existing DataflowProfile spec.instanceCount must equal 1; the chart will not modify it" -}}
{{- end -}}
{{- $name -}}
{{- end -}}
{{- end -}}
