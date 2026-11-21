# Project tooling

Run the local platform from Ubuntu on WSL2 with Docker Desktop integrated. The environment check records installed tools, available memory and the netem test in results/env.

| Tool | Project use |
| --- | --- |
| Docker and k3d | Run the local Kubernetes cluster |
| kubectl and Helm | Inspect the cluster and render or install charts |
| Terraform | Validate the AKS configuration |
| promtool | Check alert rules and test fixtures |
| kubeconform | Validate rendered Kubernetes manifests |
| GitHub CLI | Authenticate with GitHub and inspect pull requests |
| Python and k6 | Measure recovery and generate steady traffic |

Run `bash scripts/check-environment.sh` from the repository root before starting the local cluster.
