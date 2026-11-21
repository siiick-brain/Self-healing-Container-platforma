# OpenShift comparison

A live OpenShift run was unavailable for this comparison. The table describes expected differences.

| Area | Local k3d | OpenShift to validate |
| --- | --- | --- |
| Pod admission | Kubernetes pod security and Kyverno rules | SCC admission can allocate a UID from the project range. The chart pins UID 10001 and may need an OpenShift-specific security context. <!-- target --> |
| External access | NGINX ingress | A Route exposes the Service through the OpenShift router. |
| Monitoring | Prometheus and Grafana charts | Check the platform monitoring stack and whether user workload monitoring is enabled. |
| Operators | Helm and Argo CD | Inspect OperatorHub and confirm which operator installations the environment allows. |
| Time to healthy pod | Pending | Pending |
| RAM | Pending | Pending |

Observe the active security context constraint in Developer Sandbox with the access the project allows. Record the admitted pod UID and startup evidence. [Red Hat security context constraints documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/pdf/authentication_and_authorization/OpenShift_Container_Platform-4.17-Authentication_and_authorization-en-US.pdf)
