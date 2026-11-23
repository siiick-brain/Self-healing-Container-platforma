#!/usr/bin/env bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
  echo 'The admission proof requires a disposable GitHub-hosted runner.' >&2
  exit 2
}

context=k3d-self-healing
kube=(kubectl --context "$context" --request-timeout=15s)
server=$("${kube[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ $server =~ ^https://(127\.0\.0\.1|localhost|0\.0\.0\.0):[0-9]+$ ]] || {
  echo 'Expected a local k3d API server.' >&2
  exit 2
}
"${kube[@]}" get nodes -o json | jq -e --arg prefix "$context-" '
  .items | length > 0 and all(.[]; .metadata.name | startswith($prefix))' >/dev/null

fixture=$(cat <<'JSON'
{
  "apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": "admission-policy-proof", "namespace": "demo"},
  "spec": {
    "securityContext": {"runAsNonRoot": true, "runAsUser": 10001},
    "containers": [{
      "name": "app", "image": "ghcr.io/siiick-brain/resilient-app:main",
      "resources": {"limits": {"cpu": "250m", "memory": "128Mi"}}
    }]
  }
}
JSON
)
dry_run=("${kube[@]}" -n demo create --dry-run=server -f -)

"${dry_run[@]}" <<< "$fixture"
expect_denied() {
  local rule=$1 edit=$2 pod denial
  pod=$(jq -e "$edit" <<< "$fixture")
  if denial=$("${dry_run[@]}" <<< "$pod" 2>&1); then
    echo "Expected Kyverno to deny $rule, but the dry run succeeded." >&2
    return 1
  fi
  printf '%s\n' "$denial"
  if [[ $denial != *'restrict-demo-pods'* || $denial != *"$rule"* ]]; then
    echo "Expected a denial from restrict-demo-pods/$rule." >&2
    return 1
  fi
}

expect_denied require-non-root-pods '.spec.securityContext = {runAsNonRoot: false, runAsUser: 0}'
expect_denied require-resource-limits 'del(.spec.containers[0].resources.limits)'
echo 'Kyverno accepted the compliant pod and denied both invalid pods in server dry run.'
