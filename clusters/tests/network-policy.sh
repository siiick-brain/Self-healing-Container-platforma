#!/usr/bin/env bash
set -euo pipefail
kube=(kubectl --context k3d-self-healing)
name=policy-smoke-$RANDOM
selector=app.kubernetes.io/name=resilient-app

"${kube[@]}" -n demo wait pod -l "$selector" --for=condition=Ready --timeout=90s
read -r pod_ip node < <(
  "${kube[@]}" -n demo get pod -l "$selector" -o jsonpath='{.items[0].status.podIP}{" "}{.items[0].spec.nodeName}{"\n"}'
)
url=http://$pod_ip:8080/work
printf -v overrides '{"spec":{"nodeName":"%s"}}' "$node"
printf 'Testing app pod %s from node %s\n' "$pod_ip" "$node"

probe() {
  local namespace=$1
  shift
  "${kube[@]}" -n "$namespace" run "$name" --restart=Never --rm -i --pod-running-timeout=90s \
    --overrides="$overrides" --image=curlimages/curl:8.12.1 --command -- \
    curl -fsS --connect-timeout 2 --max-time 5 "$@" "$url"
}

probe ingress-nginx --retry 3 --retry-connrefused
if output=$(probe default 2>&1); then
  printf '%s\n' "$output"
  echo 'The unauthorized request reached the app.' >&2
  exit 1
fi
printf '%s\n' "$output"
if ! grep -q 'curl: (28)' <<< "$output"; then
  echo 'Expected the unauthorized request to time out.' >&2
  exit 1
fi
