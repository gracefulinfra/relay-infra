{{- define "relay-api.labels" -}}
app.kubernetes.io/part-of: relay
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "relay-api.selector" -}}
app.kubernetes.io/name: relay-api
app.kubernetes.io/component: {{ . }}
{{- end }}

{{- define "relay-api.image" -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" .Values.image.digest) -}}
{{- fail "image.digest must be set to a sha256 digest (relay-api CI on main prints it); tags are never deployed" -}}
{{- end -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end }}

{{/* Pod settings shared by the API, the worker, and the migration Job. */}}
{{- define "relay-api.podSpec" -}}
automountServiceAccountToken: false
{{- with .Values.imagePullSecrets }}
imagePullSecrets: {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  seccompProfile: {type: RuntimeDefault}
{{- end }}

{{- define "relay-api.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: {drop: [ALL]}
{{- end }}

{{- define "relay-api.env" -}}
envFrom:
  - configMapRef: {name: relay-api-config}
  - secretRef: {name: relay-api-db}
{{- end }}

{{/* GOMEMLIMIT at 90% of the container memory limit, so the Go GC works before the OOM killer does. */}}
{{- define "relay-api.gomemlimit" -}}
{{- $mi := trimSuffix "Mi" .limits.memory | int -}}
- {name: GOMEMLIMIT, value: {{ printf "%dMiB" (div (mul $mi 9) 10) | quote }}}
{{- end }}

{{- define "relay-api.opsProbes" -}}
startupProbe:
  httpGet: {path: /healthz, port: ops}
  periodSeconds: 2
  failureThreshold: 30
livenessProbe:
  httpGet: {path: /healthz, port: ops}
  periodSeconds: 10
readinessProbe:
  httpGet: {path: /readyz, port: ops}
  periodSeconds: 5
  timeoutSeconds: 3
{{- end }}

{{- define "relay-api.scrape" -}}
prometheus.io/scrape: "true"
prometheus.io/port: "9090"
prometheus.io/path: /metrics
{{- end }}
