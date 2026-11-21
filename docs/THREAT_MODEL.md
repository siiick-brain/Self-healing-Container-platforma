# Threat model

| Boundary | Abuse | Control |
| --- | --- | --- |
| Client to ingress | Attempts to reach fault controls | Route only the work endpoint |
| Namespace to app | Direct unauthorized traffic | Default-deny policy with explicit allows |
| Git to cluster | Unreviewed configuration | Restrict write access, require checks and review changes |
| Receiver to Kubernetes | Excessive API access | Scope access to workload diagnostics and required cleanup |
| Receiver to MinIO | Archive tampering or credential exposure | Use a scoped bucket identity and encrypted credentials |

Use test data for diagnostic archives. Treat workload logs and heap profiles as potentially sensitive before publishing evidence.
