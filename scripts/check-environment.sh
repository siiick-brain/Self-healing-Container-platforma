#!/usr/bin/env bash
set -euo pipefail
mkdir -p results/env
{
  failed=0
  uname -r
  if ! grep -qi 'WSL2' /proc/sys/kernel/osrelease; then
    echo 'WSL2 kernel check failed'
    failed=1
  fi
  for tool in docker kubectl helm k3d terraform promtool kubeconform gh; do
    if ! command -v "$tool"; then
      printf 'Missing tool: %s
' "$tool"
      failed=1
    fi
  done
  free -h
  if docker info --format '{{.ServerVersion}}'; then
    if docker run --rm --cap-add NET_ADMIN alpine sh -c 'apk add -q iproute2 && tc qdisc add dev lo root netem delay 100ms && tc qdisc show dev lo'; then
      echo 'netem available'
    else
      echo 'netem unverified. Use app-level injection for latency.'
    fi
  else
    failed=1
  fi
  exit "$failed"
} 2>&1 | tee results/env/wsl.txt
