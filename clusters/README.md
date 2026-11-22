# Local platform

Run from WSL with Docker and the project tools available.

```bash
bash clusters/platform.sh core
curl -fsS http://127.0.0.1:8080/work
bash clusters/tests/network-policy.sh
```

Use `K3D_AGENTS=2` on a tight host before creating the cluster. Only the work endpoint is routed through ingress. The monitoring namespace can scrape the app directly.

For the full profile provision the MinIO secrets described in the receiver runbook after core creates the namespaces. Then run `bash clusters/platform.sh full`. Tear the lab down with `bash clusters/platform.sh down`.

Drain an agent while a k6 run is active and save the output under results. For a replacement-cluster upgrade check, change the pinned k3s image in a review branch and rebuild the disposable cluster. Record cluster version, pod health and the network policy smoke output for each image. This tests a clean reinstall with the new version.

GitOps pulls from the published repository. Use `GITOPS_REPO` and `GITOPS_REVISION` to select the repository and revision for the root and its project-owned child applications. Vendor charts keep their pinned versions.
