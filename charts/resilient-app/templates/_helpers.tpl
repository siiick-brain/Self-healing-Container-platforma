{{- define "resilient-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "resilient-app.podTemplate" -}}
metadata:
  labels:
    {{- include "resilient-app.selectorLabels" . | nindent 4 }}
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: {{ .Values.securityContext.runAsNonRoot }}
    {{- if .Values.diagnostics.enabled }}
    fsGroup: {{ .Values.securityContext.runAsGroup }}
  {{- end }}
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- range . }}
    - {{- toYaml (omit . "labelSelector") | nindent 6 }}
      labelSelector:
        matchLabels:
          {{- include "resilient-app.selectorLabels" $ | nindent 10 }}
    {{- end }}
  {{- end }}
  containers:
    - name: app
      {{- if .Values.image.digest }}
      image: {{ printf "%s@%s" .Values.image.repository .Values.image.digest | quote }}
      {{- else }}
      image: {{ printf "%s:%s" .Values.image.repository .Values.image.tag | quote }}
      {{- end }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: 8080
      env:
        - name: CHAOS_ENABLED
          value: {{ .Values.chaosEnabled | quote }}
        - name: MEMORY_LIMIT_BYTES
          valueFrom:
            resourceFieldRef:
              resource: limits.memory
              divisor: "1"
        {{- if .Values.diagnostics.enabled }}
        - name: HEAP_PROFILE_PATH
          value: {{ printf "%s/heap.pprof" (trimSuffix "/" .Values.diagnostics.mountPath) | quote }}
        {{- end }}
        {{- with .Values.env }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      {{- if .Values.livenessProbe.enabled }}
      livenessProbe:
        {{- toYaml (omit .Values.livenessProbe "enabled") | nindent 8 }}
      {{- end }}
      {{- if .Values.readinessProbe.enabled }}
      readinessProbe:
        {{- toYaml (omit .Values.readinessProbe "enabled") | nindent 8 }}
      {{- end }}
      {{- if .Values.diagnostics.enabled }}
      volumeMounts:
        - name: diagnostics
          mountPath: {{ .Values.diagnostics.mountPath | quote }}
      {{- end }}
  {{- if .Values.diagnostics.enabled }}
  volumes:
    - name: diagnostics
      emptyDir:
        sizeLimit: {{ .Values.diagnostics.sizeLimit | quote }}
  {{- end }}
{{- end }}
