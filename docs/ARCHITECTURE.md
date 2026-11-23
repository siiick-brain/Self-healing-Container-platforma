# Architecture

Argo CD reconciles chart and policy configuration from Git. The local ingress sends work requests to the demo service. Prometheus scrapes service metrics. Grafana reads Prometheus queries. Alertmanager calls the receiver, which collects previous logs and writes archives to local MinIO in the full profile.

The core profile has the app, ingress, policy engine, GitOps and monitoring. The full profile adds fault injection, object storage, diagnostic automation, rollout analysis and resource recommendations. The hosted two-agent snapshots show 3.28 GiB of RAM across the core k3d containers and 4.81 GiB for full. These are point-in-time container measurements from a GitHub runner. [Core Docker stats](../results/env/docker-stats-core.txt) · [Full Docker stats](../results/env/docker-stats-full.txt)

The local cluster has one control plane and cannot validate control-plane high availability. AKS Terraform is intended for static validation only. Managed control-plane behavior is untested.

The ingress exposes work traffic. Keep fault controls on an internal path selected explicitly by the operator. Namespace policy separates application workloads, monitoring, storage and operational services.
