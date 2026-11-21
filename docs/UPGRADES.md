# Upgrade procedure

Capture cluster version and app health before changing the k3s image pin. Confirm the change is compatible with the local k3d release. Under k6 load, drain an agent hosting an app replica and verify that the disruption budget leaves service available. Record the client results and the node and pod state.

Rebuild a disposable cluster with the proposed image and resync GitOps. Compare ingress, policy and monitoring checks. Save both version checks and both proof runs in [results](../results/). Revert the image pin and rebuild if the replacement fails.
