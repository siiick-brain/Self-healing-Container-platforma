#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec python3 chaos/measure.py --results "${CHAOS_RESULTS:-results/chaos}" run \
  "${SCENARIO:?Set SCENARIO to crash, latency or leak}" "${CONFIG:?Set CONFIG to A, A2, B or C}" \
  --injection-type "${INJECTION_TYPE:-chaos-mesh}" --pod "${POD:?Set POD to a ready local demo app pod}"
