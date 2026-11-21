# PodOOMKilled

Check that the firing alert shows the demo namespace and the expected pod and container. Query the receiver logs and check that the MinIO bucket contains the emitted object key. The gzip JSON includes previous container logs, termination state and pod events. If the prior logs have rotated or the pod was deleted before collection, record that in the incident notes.

```bash
kubectl -n demo get pods
kubectl -n ops logs deployment/diagnostics-receiver --tail=30
mc ls --recursive lab/diagnostics/oom/
```

Use a locally authenticated MinIO alias with permission to read the bucket. Keep raw archives local unless they have been checked for secrets and sensitive log content.

Compare the terminated container's memory limit with the memory dashboard. Inspect the app heap profile on its writable pod volume if it was created before termination. A missing profile does not rule out memory exhaustion.

The automated cleanup job removes only failed demo pods whose reason is Evicted. OOM restarts can occur in a running pod and are handled by the receiver.
