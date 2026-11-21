#!/usr/bin/env bash
set -euo pipefail
kube=(kubectl --context k3d-self-healing)
node=${1:?Pass a k3d-self-healing agent node hosting an app pod}
[[ $node =~ ^k3d-self-healing-agent-[0-9]+$ ]]
"${kube[@]}" -n demo get pods -l app.kubernetes.io/name=resilient-app   --field-selector "spec.nodeName=$node" -o name | grep -q .
trap '"${kube[@]}" uncordon "$node"' EXIT
"${kube[@]}" -n demo get pdb
"${kube[@]}" drain "$node" --ignore-daemonsets --timeout=2m
"${kube[@]}" -n demo wait --for=condition=Ready pod   -l app.kubernetes.io/name=resilient-app --timeout=2m
