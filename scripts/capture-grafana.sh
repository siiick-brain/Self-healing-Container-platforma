#!/usr/bin/env bash
set -euo pipefail

# Run on a disposable Linux runner after full smoke succeeds. Use the same local
# k3d-self-healing cluster, with dashboards and recording rules already synced.
# Grafana must have anonymous Viewer access in this CI cluster only. Keep its
# Service internal and publish no Grafana ingress or host port. Node 20+, npm,
# kubectl, curl, jq, and permission to install Chromium dependencies are needed.
# RECORD_GRAFANA_DEMO=true also requires FFmpeg and captures a dashboard GIF.
output=${1:?Pass an output directory}
mkdir -p "$output"
output=$(cd "$output" && pwd)
files=(grafana-red.png grafana-slo.png grafana-prometheus.json)
record_demo=${RECORD_GRAFANA_DEMO:-false}
if [[ $record_demo == true ]]; then
  command -v ffmpeg >/dev/null
  files+=(grafana-demo.gif)
fi
for file in "${files[@]}"; do
  if [[ -e "$output/$file" ]]; then
    printf 'Evidence already exists: %s\n' "$output/$file" >&2
    exit 1
  fi
done

umask 077
scratch=$(mktemp -d)
cli="$scratch/node_modules/.bin/playwright-cli"
export PLAYWRIGHT_BROWSERS_PATH="$scratch/browsers"
forward_pid=
cleanup() {
  if [[ -x "$cli" ]]; then "$cli" -s=grafana-evidence close >/dev/null 2>&1 || true; fi
  if [[ -n "$forward_pid" ]]; then kill "$forward_pid" 2>/dev/null || true; fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
cd "$scratch"

grafana=http://127.0.0.1:13000
kubectl --context k3d-self-healing -n monitoring port-forward --address 127.0.0.1 \
  svc/kube-prometheus-stack-grafana 13000:80 > port-forward.log 2>&1 &
forward_pid=$!
curl_local() {
  curl --noproxy '*' --fail --silent --show-error --max-time 5 "$@"
}
if ! curl_local --retry 15 --retry-delay 1 --retry-connrefused "$grafana/api/health" >/dev/null ||
    ! grep -Fq 'Forwarding from 127.0.0.1:13000' port-forward.log; then
  cat port-forward.log >&2
  exit 1
fi
for uid in resilient-red resilient-slo; do
  curl_local "$grafana/api/dashboards/uid/$uid" |
    jq -e --arg uid "$uid" '.dashboard.uid == $uid and all(.dashboard.panels[]; .datasource.uid == "prometheus")' >/dev/null
done

# A 15-second scrape interval needs multiple samples before rate() can evaluate.
from=$(date -u +%s)
for ((request = 0; request < 75; request++)); do
  curl_local http://127.0.0.1:8080/work >/dev/null
  sleep 1
done
to=$(date -u +%s)

query_range() {
  curl_local --get "$grafana/api/datasources/proxy/uid/prometheus/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=$from" \
    --data-urlencode "end=$to" --data-urlencode 'step=5'
}
query_range 'resilient:work_requests:rate5m' > request-rate.json
query_range '1 - resilient:work_errors:ratio30d' > availability.json
jq -e '.status == "success" and any(.data.result[]?.values[]?; try (.[1] | tonumber | isfinite and . > 0) catch false)' request-rate.json >/dev/null || {
  echo 'Grafana returned no positive /work request rate in the capture window.' >&2
  exit 1
}
jq -e '.status == "success" and any(.data.result[]?.values[]?; try (.[1] | tonumber | isfinite) catch false)' availability.json >/dev/null || {
  echo 'Grafana returned no observed availability samples in the capture window.' >&2
  exit 1
}
jq -n --argjson from "$from" --argjson to "$to" \
  --slurpfile requests request-rate.json --slurpfile availability availability.json \
  '{fromUtc: ($from | todateiso8601), toUtc: ($to | todateiso8601),
    requestRate: $requests[0], observedAvailability: $availability[0]}' > grafana-prometheus.json

npm install --prefix "$scratch" --no-audit --no-fund --ignore-scripts @playwright/cli@0.1.25 >/dev/null
test "$("$cli" --version)" = 0.1.25
"$scratch/node_modules/.bin/playwright" install --with-deps chromium
"$cli" -s=grafana-evidence open --browser=chromium
"$cli" -s=grafana-evidence resize 1600 1150

cat > wait-for-dashboard.js <<'JS'
async page => {
  const dashboards = {
    'resilient-red': ['Resilient app RED', 'Work request rate', 'Work error ratio', 'Work request latency', 'App memory by pod'],
    'resilient-slo': ['Resilient app SLO', 'Availability over observed history', 'Short error budget burn', 'Long error budget burn'],
  };
  const uid = new URL(page.url()).pathname.split('/')[2];
  const [title, ...panels] = dashboards[uid];
  await page.getByText(title, { exact: true }).first().waitFor({ state: 'visible' });
  for (const panel of panels) {
    await page.getByText(panel, { exact: true }).first().waitFor({ state: 'visible' });
  }
  await page.locator('.uplot canvas').nth(panels.length - 1).waitFor({ state: 'visible' });
}
JS

for name in red slo; do
  url="$grafana/d/resilient-$name?from=${from}000&to=${to}000&timezone=utc"
  "$cli" -s=grafana-evidence goto "$url"
  "$cli" -s=grafana-evidence run-code --filename=wait-for-dashboard.js
  "$cli" -s=grafana-evidence screenshot --full-page --filename="grafana-$name.png"
  test -s "grafana-$name.png"
  if [[ $record_demo == true ]]; then
    if [[ $name == red ]]; then
      "$cli" -s=grafana-evidence video-start grafana-demo.webm --size=1200x864 --fps=12
      sleep 3
    else
      sleep 3
      "$cli" -s=grafana-evidence video-stop
      ffmpeg -hide_banner -loglevel error -filter_complex_threads 1 -i grafana-demo.webm \
        -filter_complex 'fps=10,split[frames][colors];[colors]palettegen=max_colors=128[palette];[frames][palette]paletteuse' \
        -loop 0 grafana-demo.gif
      test -s grafana-demo.gif
    fi
  fi
done

install -m 0644 "${files[@]}" "$output/"
