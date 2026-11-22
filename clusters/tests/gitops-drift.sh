#!/usr/bin/env bash
set -euo pipefail

context=k3d-self-healing
kube=(kubectl --context "$context" --request-timeout=10s)
app=("${kube[@]}" -n demo)

"${kube[@]}" config view --minify -o json | jq -e '
  .clusters | length == 1 and
    (.[0].cluster.server | test("^https://(127\\.0\\.0\\.1|0\\.0\\.0\\.0|localhost):[0-9]+$"))' >/dev/null
"${kube[@]}" get nodes -o json | jq -e --arg prefix "$context-" '
  .items | length > 0 and all(.[]; .metadata.name | startswith($prefix))' >/dev/null
"${kube[@]}" -n argocd get application resilient-app -o json | jq -e '
  .spec.syncPolicy.automated.selfHeal == true and
  .status.sync.status == "Synced" and .status.health.status == "Healthy"' >/dev/null

deployment=deployment/resilient-app
replicas() { "${app[@]}" get "$deployment" -o jsonpath='{.spec.replicas}'; }
[[ $(replicas) == 3 ]]
started=$SECONDS
printf '%s desired_replicas=3 drift_replicas=4\n' "$(date -u +%FT%TZ)"
"${app[@]}" scale "$deployment" --current-replicas=3 --replicas=4
for (( deadline=started+180; SECONDS < deadline; )); do
  if [[ $(replicas) == 3 ]]; then
    printf '%s restored_replicas=3 elapsed_s=%d\n' "$(date -u +%FT%TZ)" "$((SECONDS-started))"
    exit 0
  fi
  sleep 2
done

echo 'Argo CD did not restore the desired replica count in 180 seconds.' >&2
"${app[@]}" get "$deployment" -o wide >&2 || true
"${app[@]}" scale "$deployment" --current-replicas=4 --replicas=3 >&2 || true
exit 1
