{{/* Names. One release == one site, and the release name must equal the namespace. */}}
{{- define "gf.name" -}}{{ .Release.Name }}{{- end -}}

{{- define "gf.labels" -}}
app.kubernetes.io/name: gemfire
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
gemfire/application: {{ .Values.application.name }}
gemfire/environment: {{ .Values.application.environment }}
gemfire/site: {{ .Values.site.role }}
{{- end -}}

{{- define "gf.selector" -}}
app.kubernetes.io/name: gemfire
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Comma-separated locator list for THIS site, one entry per locator pod. */}}
{{- define "gf.locators" -}}
{{- $r := .Release.Name -}}{{- $ns := .Release.Namespace -}}{{- $d := .Values.site.clusterDomain -}}{{- $p := int .Values.ports.locator -}}
{{- range $i := until (int .Values.gemfire.cluster.locatorCount) }}{{ if $i }},{{ end }}{{ $r }}-locator-{{ $i }}.{{ $r }}-locator-hl.{{ $ns }}.svc.{{ $d }}[{{ $p }}]{{ end -}}
{{- end -}}

{{/* Digest is preferred and is what the pipeline always uses. A non-"latest" tag is accepted
     only for local demos (kind) where there is no registry to produce a digest. */}}
{{- define "gf.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest -}}{{ $repo }}@{{ .Values.image.digest }}
{{- else if and .Values.image.tag (ne .Values.image.tag "latest") -}}{{ $repo }}:{{ .Values.image.tag }}
{{- else }}{{ fail "set image.digest (sha256:...) or, for local demos only, a non-latest image.tag" }}{{ end -}}
{{- end -}}

{{/* Fail early on identity/config mismatches. Called from configmap.yaml. */}}
{{- define "gf.validate" -}}
{{- $want := printf "%s-%s-%s" .Values.application.name .Values.application.environment .Values.site.role -}}
{{- if ne .Release.Name $want }}{{ fail (printf "release name %q must be %q (application-environment-site)" .Release.Name $want) }}{{ end -}}
{{- if ne .Release.Namespace .Release.Name }}{{ fail (printf "namespace %q must equal the release name %q" .Release.Namespace .Release.Name) }}{{ end -}}
{{- if ne .Values.site.name .Release.Name }}{{ fail "site.name must equal the release name" }}{{ end -}}
{{- if and .Values.wan.enabled (not .Values.site.partner) }}{{ fail "wan.enabled requires site.partner (generated site identity)" }}{{ end -}}
{{- if lt (int .Values.gemfire.cluster.memberCount) 1 }}{{ fail "memberCount must be >= 1" }}{{ end -}}
{{- range .Values.gemfire.regions }}
{{- if gt (int .redundantCopies) (sub (int $.Values.gemfire.cluster.memberCount) 1) }}{{ fail (printf "region %s: redundantCopies %d exceeds memberCount-1" .name (int .redundantCopies)) }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "gf.securityContext" -}}
runAsNonRoot: true
runAsUser: {{ .Values.runAsUser }}
runAsGroup: {{ .Values.runAsUser }}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: { drop: ["ALL"] }
seccompProfile: { type: RuntimeDefault }
{{- end -}}

{{/* Anti-affinity + spread for a component. */}}
{{- define "gf.scheduling" -}}
affinity:
  podAntiAffinity:
{{- if eq .root.Values.scheduling.antiAffinity "hard" }}
    requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: {{ .root.Values.scheduling.topologyKey }}
      labelSelector:
        matchLabels: {{ include "gf.selector" . | nindent 10 }}
{{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: {{ .root.Values.scheduling.topologyKey }}
        labelSelector:
          matchLabels: {{ include "gf.selector" . | nindent 12 }}
{{- end }}
{{- if .root.Values.scheduling.zoneSpread }}
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels: {{ include "gf.selector" . | nindent 6 }}
{{- end }}
{{- end -}}
