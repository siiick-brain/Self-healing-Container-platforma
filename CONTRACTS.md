# Platform contracts

Namespaces are demo, monitoring, argocd, argo-rollouts, kyverno, storage, ops and chaos-mesh.

The app listens on port 8080. Its image is ghcr.io/siiick-brain/resilient-app and its UID is 10001.

| Method | Paths |
| --- | --- |
| GET | /healthz, /readyz, /metrics, /work |
| POST | /chaos/crash, /chaos/leak, /chaos/latency, /chaos/reset |

Metrics are `http_requests_total`, `http_request_duration_seconds` (histogram), `app_memory_bytes` and `app_chaos_active`.

Helm values use `image.repository`, `image.tag`, `service.port`, `replicaCount`, `resources.requests`, `resources.limits`, `livenessProbe`, `readinessProbe`, `podDisruptionBudget`, `autoscaling`, `topologySpreadConstraints`, `strategy`, `securityContext`, `networkPolicy.enabled`, `serviceMonitor.enabled` and `rollouts.enabled`. The memory limit is 128Mi and readiness timeoutSeconds is 1. <!-- target -->

Alert names are PodOOMKilled, HighBurnRate and SLOAvailabilityBreach. Over 30 days the targets are 99.5 percent availability and p95 under 300ms. <!-- target -->

Diagnostics go to the diagnostics bucket at minio.storage.svc:9000.

The MTTR JSON report requires every field below. Use UTC RFC 3339 timestamps and null when an event or duration could not be measured. A restart may be inapplicable to a latency experiment.

| Field | JSON type |
| --- | --- |
| scenario, config, run_id, injection_type | string |
| injected_at | string |
| detected_at, restarted_at, traffic_restored_at | string or null |
| detection_s, restart_s, mttr_s, dropped_requests_pct | number or null |

Measure each duration from injection to the named event. Report dropped requests as a percentage from 0 through 100. Use `app-level` for an app endpoint fallback and `chaos-mesh` for a Chaos Mesh experiment.
