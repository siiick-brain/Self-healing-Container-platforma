# Live fault smoke

The manual GitHub Actions run confirmed PodChaos replacement and StressChaos recovery after an OOM kill. NetworkChaos was rejected at admission because its direction required a target selector. Each check confirmed cleanup.

| Check | Evidence |
| --- | --- |
| PodChaos | [Controller and replacement log](pod.txt) |
| StressChaos | [Controller, termination and recovery log](stress.txt) |
| NetworkChaos admission | [Admission rejection log](network-admission-rejection.txt) |
| NetworkChaos on GitHub-hosted k3d | [iptables and cleanup log](network-runtime-failure.txt) |

The hosted runner could not program the target pod’s iptables chains. The disposable cluster was removed. Use the app-level latency fallback in a fresh hosted run and save its verified log as `network.txt` before the measurement matrix.

[Hosted NetworkChaos retry and original artifacts](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45029315264/attempts/2)

[GitHub Actions run and original artifacts](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45028398095)
