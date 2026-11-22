# Live fault smoke

The manual GitHub Actions run confirmed PodChaos replacement and StressChaos recovery after an OOM kill. NetworkChaos was rejected at admission because its direction required a target selector. Each check confirmed cleanup.

| Check | Evidence |
| --- | --- |
| PodChaos | [Controller and replacement log](pod.txt) |
| StressChaos | [Controller, termination and recovery log](stress.txt) |
| NetworkChaos admission | [Admission rejection log](network-admission-rejection.txt) |

Run NetworkChaos with the corrected manifest before the measurement matrix. Save the passing log as `network.txt`.

[GitHub Actions run and original artifacts](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45028398095)
