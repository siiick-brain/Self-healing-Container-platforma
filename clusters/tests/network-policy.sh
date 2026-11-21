#!/usr/bin/env bash
set -euo pipefail
kube=(kubectl --context k3d-self-healing)
name=policy-smoke-$RANDOM
url=http://resilient-app.demo.svc.cluster.local:8080/work
probe() {
  "${kube[@]}" -n "$1" run "$name" --restart=Never --rm -i --pod-running-timeout=90s     --image=curlimages/curl:8.12.1 --command -- curl -fsS --max-time 5 "$url"
}
probe ingress-nginx
set +e
output=$(probe default 2>&1)
result=$?
set -e
printf '%s\n' "$output"
if (( result == 0 )) || ! grep -q 'curl: (28)' <<< "$output"; then
  echo 'Expected the unauthorized request to time out.' >&2
  exit 1
fi
