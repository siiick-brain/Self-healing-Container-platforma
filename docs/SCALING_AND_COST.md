# Scaling and cost

Run the local stack on the laptop and keep AKS validation static. The observed laptop environment is recorded in [results/env/wsl.txt](../results/env/wsl.txt).

## VPA recommendation

The hosted VPA recommended an app request of 15m CPU and 100 MiB memory with update mode `Off`. The Deployment and all three ready app pods kept requests of 50m CPU and 32 MiB memory and limits of 250m CPU and 128 MiB memory before and after the fault checks. [VPA evidence](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45063333678/artifacts/14769814346)

Repeat the fault checks before adopting a new resource request. Compare recovery time and request loss under the same load settings.

## With 10x budget

Evaluate multi-region traffic and failover, a service mesh for identity and traffic policy, fleet rollout controls, managed Prometheus, on-call paging and trace links through metric exemplars. Validate the extra operational cost against measured reliability goals.
