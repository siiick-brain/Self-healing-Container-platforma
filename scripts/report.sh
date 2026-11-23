#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
archive=results/chaos-matrix/matrix-summary.json
if [[ -z ${CHAOS_RESULTS:-} && -f $archive ]] && ! compgen -G 'results/chaos/*.json' >/dev/null; then
  exec python3 chaos/matrix_evidence.py --archive "$archive"
fi
exec python3 chaos/measure.py --results "${CHAOS_RESULTS:-results/chaos}" summary
