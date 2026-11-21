# Run local fault measurements

Use the k3d lab. First run each experiment manually against the demo and save the output as pod.txt, network.txt and stress.txt under results/chaos-smoke. Record a failed smoke check and its fallback in the same file. Have the owner commit the smoke evidence. Remove each Chaos Mesh object before starting the next experiment.

Apply one of the overlays in profiles after the base k3d values. Change the values in the local GitOps source for a managed run so reconciliation preserves the test configuration.

Keep constant k6 traffic running while measuring and export its summary for independent load evidence.

```bash
k6 run --summary-export results/k6-work.json k6/work.js
python3 chaos/measure.py run crash B --injection-type chaos-mesh
python3 chaos/measure.py summary
```

For an app-level fallback, open a pod port-forward on localhost port 18080 and pass the selected pod name with --pod. Use --injection-type app-level. The harness checks the ingress work endpoint independently of the control request.

A recovery sample is a successful work probe after detection. The CSV reports loss among harness probes. Retain k6 summaries for the constant-load client?s own loss and dropped iterations. If redundancy masks the fault, recovery time stays empty unless the harness observes a failed health probe or a change in the selected pod.
