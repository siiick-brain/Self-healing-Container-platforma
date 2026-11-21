# Scaling and cost

Run the local stack on the laptop and keep AKS validation static. The observed laptop environment is recorded in [results/env/wsl.txt](../results/env/wsl.txt). The profile resource comparison and VPA results are pending.

Record actual requests, limits and recommendation output before changing resources. Repeat the fault runs after the change and compare the same recovery and request-loss measures.

## With 10x budget

Evaluate multi-region traffic and failover, a service mesh for identity and traffic policy, fleet rollout controls, managed Prometheus, on-call paging and trace links through metric exemplars. Validate the extra operational cost against measured reliability goals.
