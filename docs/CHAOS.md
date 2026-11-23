# Fault experiments

Run experiments only against the local demo. Keep k6 traffic active and record run configuration, injection type and the report under results.

| Fault | Hypothesis |
| --- | --- |
| Crash | The workload controller restores capacity after a process or pod terminates |
| Slow response | Readiness changes can remove an impaired pod from traffic when the fault affects the readiness path |
| Memory exhaustion | A memory limit bounds the fault and the container restarts after termination |

Validate PodChaos, NetworkChaos and StressChaos manually before the matrix. Save evidence under [results](../results/). When a controller-based fault fails, record the failure and select the equivalent app-level fault control. Use a pod port-forward for fault controls and the local ingress work endpoint for traffic.

Apply configurations A with probes disabled, A2 with default probes, B with tuned probes and C with tuned probes plus the canary strategy. Record MTTR and failure percentages per scenario per configuration. Keep rollback and canary-abort reports separate. Store the measurements in [results](../results/).

The hosted smoke recorded PodChaos replacement, a StressChaos OOM kill followed by a restart, and an app-level slowdown after the hosted NetworkChaos check failed. The full matrix validated 180 trials. Tuned probes reduced the share of failed requests in the slowdown scenario. Crash recovery times stayed close across profiles. All memory-exhaustion observation windows recorded zero failed k6 requests. [Smoke evidence](../results/chaos-smoke/) · [Matrix results](../results/chaos-matrix/matrix-summary.json)
