# Resilient app chart

Use release name `resilient-app` in the `demo` namespace for the platform manifests. The chart creates a Deployment by default. Set `rollouts.enabled=true` to use a Rollout with the same pod template and Service. Switch workload modes on separate releases or uninstall the previous release before switching to avoid overlapping controllers. Install the Argo Rollouts CRDs before using Rollout mode.

The primary Service uses replica-based weighting in Rollout mode. The canary Service targets the candidate ReplicaSet. When enabling `rollouts.analysis.enabled`, first install the configured AnalysisTemplate in the release namespace and enable the ServiceMonitor. Supply traffic to the primary Service during the canary window so the analysis can sample the candidate. Create a release with a distinct image tag for each deployment comparison.

The k3d profile requires the Prometheus Operator CRDs and enables the lab fault endpoints. Keep those endpoints off external ingress. The AKS profile enables CPU-based autoscaling and leaves the lab fault endpoints disabled. The optional chart NetworkPolicy permits app ingress from the ingress and monitoring namespaces plus DNS egress. NetworkPolicy operates on ports. Restrict public HTTP paths at the ingress.

The app has a read-only root filesystem. The diagnostics volume gives the heap profiler a writable location and is scoped to the pod. Do not repeat `CHAOS_ENABLED`, `MEMORY_LIMIT_BYTES` or `HEAP_PROFILE_PATH` in the extra `env` list.

## Render and validate

Run from the repository root.

```bash
chart=charts/resilient-app
schema='https://raw.githubusercontent.com/datreeio/CRDs-catalog/784ec895547a36e548e6810b41f27baade3a0890/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
set -o pipefail
for profile in k3d aks; do
  helm lint "$chart" -f "$chart/values-$profile.yaml"
  helm template resilient-app "$chart" -n demo -f "$chart/values-$profile.yaml" |
    kubeconform -strict -summary -schema-location default -schema-location "$schema"
done
helm template resilient-app "$chart" -n demo -f "$chart/values-k3d.yaml" \
  --set rollouts.enabled=true --set rollouts.analysis.enabled=true --set networkPolicy.enabled=true |
  kubeconform -strict -summary -schema-location default -schema-location "$schema"
```

## Versioning

Bump `Chart.yaml` for every chart release. Use a patch bump for a backward-compatible repair, a minor bump for a backward-compatible feature and a major bump for an incompatible values or workload change. Update `appVersion` when recording a new app release. Set `image.tag` in the deployment configuration to select the image independently of the chart package version.
