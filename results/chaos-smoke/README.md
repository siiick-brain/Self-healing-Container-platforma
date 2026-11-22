# Live fault smoke

The hosted smoke run confirmed PodChaos replacement, StressChaos recovery after an OOM kill and the app-level latency fallback. Each check confirmed cleanup. The archive check matched the MinIO record to the OOM-killed pod UID and verified termination state, previous logs and events.

| Check | Evidence |
| --- | --- |
| PodChaos | [Controller and replacement log](pod.txt) |
| StressChaos | [Controller, termination and recovery log](stress.txt) |
| App-level latency fallback | [Delay and reset log](network.txt) |
| OOM diagnostics | [Verified MinIO object record](oom-archive.json) |
| NetworkChaos admission | [Admission rejection log](network-admission-rejection.txt) |
| NetworkChaos on GitHub-hosted k3d | [iptables and cleanup log](network-runtime-failure.txt) |

NetworkChaos first failed admission and later failed to program the target pod’s iptables chains. The failed cluster was removed. A fresh runner verified the app-level fallback, which is the latency mechanism for the hosted matrix.

[Hosted NetworkChaos retry and original artifacts](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45029315264/attempts/2)

[GitHub Actions run and original artifacts](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45028398095)

[Passing hosted fault run and original artifacts](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45058993114)
