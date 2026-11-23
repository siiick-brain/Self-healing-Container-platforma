#!/usr/bin/env bash
set -euo pipefail
kube=(kubectl --context k3d-self-healing)
node=${1:?Pass a k3d-self-healing agent node hosting an app pod}
[[ $node =~ ^k3d-self-healing-agent-[0-9]+$ ]]
drain_flags=(--ignore-daemonsets --timeout=2m)
if [[ ${2:-} == --disposable-hosted ]]; then
  [[ ${GITHUB_ACTIONS:-false} == true && $OSTYPE == linux-gnu* ]]
  api=$("${kube[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  [[ $api =~ ^https://(127\.0\.0\.1|0\.0\.0\.0|localhost):[0-9]+$ ]]
  drain_flags+=(--delete-emptydir-data)
fi
"${kube[@]}" -n demo get pods -l app.kubernetes.io/name=resilient-app   --field-selector "spec.nodeName=$node" -o name | grep -q .
trap '"${kube[@]}" uncordon "$node"' EXIT
"${kube[@]}" -n demo get pdb
"${kube[@]}" drain "$node" "${drain_flags[@]}"
"${kube[@]}" -n demo wait --for=condition=Ready pod   -l app.kubernetes.io/name=resilient-app --timeout=2m
