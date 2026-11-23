# k3s rebuild comparison

The [rebuild workflow](../.github/workflows/k3s-upgrade.yml) compares the checked-in `v1.33.5-k3s1` image with [the adjacent `v1.33.6+k3s1` release](https://github.com/k3s-io/k3s/releases/tag/v1.33.6%2Bk3s1). Each GitHub-hosted runner builds a fresh core cluster with k3d `v5.8.3` and the same Git revision. The candidate runner changes its checkout's image pin for that run. The comparison covers fresh installation and GitOps resynchronization. In-place upgrades and persistent data migration need separate tests.

Dispatch the workflow after it is available on the default branch.

```powershell
gh workflow run k3s-upgrade.yml --repo siiick-brain/Self-healing-Container-platforma
```

The hosted comparison verified core in 3m 12s on `v1.33.5+k3s1` and 3m 57s on `v1.33.6+k3s1`. Both clusters ran the same app image digest, synced the same Git revision, served `/work` through ingress, allowed and denied the expected network paths, and reported three healthy Prometheus app targets. [Comparison results](../results/operations/k3s-rebuild.json) · [Hosted run](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45086783637)

Run the [node drain check](../clusters/tests/drain-under-load.sh) to verify service availability under k6 load. The first run restored three ready replicas and uncordoned the node, but four of 33 requests timed out during the drain. The retest with a five-second preStop hook restored three ready replicas and recorded zero failures across 439 requests during the drain. [First drain](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45063333678/artifacts/14769814346) · [Drain retest results](../results/operations/drain-retest.json)
