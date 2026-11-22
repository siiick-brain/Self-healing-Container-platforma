# k3s rebuild comparison

The [rebuild workflow](../.github/workflows/k3s-upgrade.yml) compares the checked-in `v1.33.5-k3s1` image with [the adjacent `v1.33.6+k3s1` release](https://github.com/k3s-io/k3s/releases/tag/v1.33.6%2Bk3s1). Each GitHub-hosted runner builds a fresh core cluster with k3d `v5.8.3` and the same Git revision. The candidate runner changes its checkout's image pin for that run. The comparison covers fresh installation and GitOps resynchronization. In-place upgrades and persistent data migration need separate tests.

Dispatch the workflow after it is available on the default branch.

```powershell
gh workflow run k3s-upgrade.yml --repo siiick-brain/Self-healing-Container-platforma
```

Download the `k3s-rebuild-baseline` and `k3s-rebuild-candidate` artifacts from the run. Each records the Kubernetes server and node versions, Argo CD application status, `/work` via ingress, allowed and denied network paths, Prometheus scrape health, and resource use. The comparison also checks that both clusters actually ran the same app image digest. Save the resulting proof in [results](../results/).

Run the [node drain check](../clusters/tests/drain-under-load.sh) as a separate scenario to verify service availability under k6 load while the agent drains. The first hosted drain restored three ready replicas and uncordoned the node. Four of 33 requests timed out during eviction, below the 99.5% availability target. [Drain evidence](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45063333678/artifacts/14769814346)
