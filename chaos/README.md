# Run fault measurements

## Hosted matrix

Manually run the Hosted recovery matrix workflow after the three passing smoke logs are committed. Use app-level latency for all hosted profiles and Chaos Mesh for crash and memory exhaustion. The workflow tests the four profiles in parallel on disposable k3d clusters. Each profile uses the same published image digest and fixed k6 settings.

The workflow uploads a separate artifact for each profile and validates the combined evidence as `matrix-summary`. A partial run fails the matrix check but retains the available artifacts. An unobserved recovery or undetected impact stays unresolved in the report. Run a bad-canary or Git revert exercise separately from the fault matrix.

The `resume_profile_c` input reruns only C at the original GitOps revision and image digest. It adds the 120 validated A, A2, and B trials from run `45064244265` and checks the revision and image for each shard before validating the full matrix again. The `matrix-provenance.json` file identifies which run supplied each profile. Use the default input to collect a fresh four-profile matrix. [Original run](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45064244265)

Run `make report` from a fresh clone with Python 3 to regenerate the 12-cell table offline from the [archived trial observations](../results/chaos-matrix/matrix-summary.json). The command checks the trial counts and recomputes median and p95 recovery times and the request failure rate. It uses the recorded outcomes and does not start Kubernetes or replay k6 traffic. Use the hosted workflow to rerun the experiments.

When `results/chaos/` contains local trials, `make report` summarizes those trials. Set `CHAOS_RESULTS` to select another local directory, or run `python3 chaos/matrix_evidence.py --archive results/chaos-matrix/matrix-summary.json` to print the published table explicitly.

## Local smoke and trials

Start the full k3d profile. Select a ready app pod from the output of the first command and set `POD` to its name. Run each smoke command separately and wait for it to finish.

```bash
kubectl --context k3d-self-healing -n demo get pods -l app.kubernetes.io/name=resilient-app
POD='<ready pod name>'
python3 chaos/smoke.py network --pod "$POD"
python3 chaos/smoke.py stress --pod "$POD"
python3 chaos/smoke.py pod --pod "$POD"
```

Each check writes its live result to `results/chaos-smoke/` and removes the specific experiment it started. Exit code 2 means cleanup needs verification before another fault. For any failed check, verify the recorded fallback in the lab and add its evidence to the same log. An app-level fallback has a different failure mechanism, so report it as such. Commit the three smoke logs before starting the matrix. Select a new ready pod after PodChaos replaces the original.

Apply one of the overlays in `profiles/` after the base k3d values. Change the values in the local GitOps source for a managed run so reconciliation preserves the test configuration. Verify that the workload is ready and its probe and rollout settings match the overlay. For each of crash, latency and leak, collect 10 trials each for A and A2 and 20 each for B and C. Keep the fault mechanism and load settings consistent within each condition and record them alongside the results.

Choose a ready `resilient-app` pod in the `demo` namespace. Start k6 in one terminal before the trial and leave it running through recovery. Use a fresh output directory for each trial. For example, run this in the first terminal.

```bash
mkdir -p results/load/B-crash-01
DURATION=3m k6 run --out json=results/load/B-crash-01/points.json \
  --summary-export results/load/B-crash-01/summary.json k6/work.js
```

While k6 is producing requests, run the following in the second terminal with `POD` set to the chosen name.

```bash
set -o pipefail
python3 chaos/measure.py run crash B --injection-type chaos-mesh --pod "$POD" \
  | tee results/load/B-crash-01/trial.log
python3 chaos/measure.py summary
```

For an app-level fallback, open a port-forward to the selected pod on localhost port 18080. Pass the same pod name with `--pod` and use `--injection-type app-level`. The runner checks the ingress work endpoint independently of the control request. Both latency modes hold the fault for 15 seconds. For a crash trial using PodChaos, choose a new ready target for the next run if the original was replaced.

The runner requires a Chaos Mesh controller record of successful injection for a Mesh trial. Recovery requires a ready target or its replacement and consecutive successful ingress probes after the timed fault clears. A memory trial requires an `OOMKilled` result for the target app container. When both ingress and pod health appear normal throughout the trial, recovery time stays empty. The CSV reports loss among harness probes. Use the timestamped k6 output and the trial ID printed in `trial.log` to correlate client request failures and dropped iterations with the measurement window.
