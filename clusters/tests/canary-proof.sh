#!/usr/bin/env bash
set -euo pipefail

if [[ ${GITHUB_ACTIONS:-false} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
  echo 'The canary proof requires a disposable GitHub-hosted runner.' >&2
  exit 1
fi

output=${1:?Pass an evidence directory.}
mkdir -p "$output"
kube=(kubectl --context k3d-self-healing --request-timeout=15s)
demo=("${kube[@]}" -n demo)
monitoring=("${kube[@]}" -n monitoring)
release=resilient-canary-proof
stable_image="$release:stable"
bad_image="$release:bad"
selector="app.kubernetes.io/instance=$release"
rollout=("${demo[@]}" get rollout "$release" -o json)

server=$("${kube[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ $server =~ ^https://(127\.0\.0\.1|0\.0\.0\.0|localhost):[0-9]+$ ]]
"${kube[@]}" get nodes -o json |
  jq -e '.items | length > 0 and all(.[]; .metadata.name | startswith("k3d-self-healing-"))' >/dev/null
"${kube[@]}" apply -f clusters/gitops/full/argo-rollouts.yaml
deadline=$((SECONDS + 240))
until "${kube[@]}" -n argocd get application argo-rollouts -o json |
    jq -e '.status.sync.status == "Synced" and .status.health.status == "Healthy"' >/dev/null; do
  (( SECONDS < deadline )) || { echo 'Argo CD did not install Argo Rollouts.' >&2; exit 1; }
  sleep 3
done
"${kube[@]}" wait crd/analysistemplates.argoproj.io crd/rollouts.argoproj.io --for=condition=Established --timeout=45s
"${kube[@]}" apply -f alerts/k8s/canary.yaml -f clusters/tests/canary-podmonitor.yaml

docker build -t "$stable_image" app
docker build -t "$bad_image" --build-arg LAB_CANARY=bad app
docker image inspect --format '{{json .Id}}' "$stable_image" "$bad_image" | jq -s '.' > "$output/image-ids.json"
jq -e 'length == 2 and .[0] != .[1]' "$output/image-ids.json" >/dev/null
k3d image import -c self-healing "$stable_image" "$bad_image"
helm template "$release" charts/resilient-app -n demo \
  -f charts/resilient-app/values-k3d.yaml -f chaos/profiles/c.yaml \
  --set-string image.repository="$release" --set-string image.tag=stable \
  --set serviceMonitor.enabled=false \
  --set 'rollouts.canary.steps[0].setWeight=33' \
  --set-string 'rollouts.canary.steps[1].pause.duration=8m' | "${demo[@]}" apply -f -
"${kube[@]}" apply -f clusters/tests/canary-ingress.yaml
"${demo[@]}" wait rollout "$release" --for='jsonpath={.status.phase}=Healthy' --timeout=120s
"${rollout[@]}" > "$output/baseline-rollout.json"
stable_hash=$(jq -er '.status.stableRS | select(length > 0)' "$output/baseline-rollout.json")
rollout_uid=$(jq -er '.metadata.uid' "$output/baseline-rollout.json")
curl --fail --silent --show-error --retry 10 --retry-all-errors --max-time 5 \
  -H 'Host: canary-proof.localhost' http://127.0.0.1:8080/work | grep -Fx ok

load_pid=
forward_pid=
start_forward() {
  kubectl --context k3d-self-healing -n monitoring port-forward --address 127.0.0.1 \
    svc/kube-prometheus-stack-prometheus 19090:9090 >> "$output/prometheus-forward.txt" 2>&1 &
  forward_pid=$!
}
stop_forward() {
  if [[ -n $forward_pid ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
    forward_pid=
  fi
}
cleanup() {
  if [[ -n $load_pid ]]; then
    kill "$load_pid" 2>/dev/null || true
    wait "$load_pid" 2>/dev/null || true
  fi
  stop_forward
}
trap cleanup EXIT
prometheus=http://127.0.0.1:19090
prometheus_statefulset='prometheus-kube-prometheus-stack-prometheus'
scrape_job="podMonitor/demo/$release/0"
job_name_present() {
  grep -E "^[[:space:]-]*job_name:[[:space:]]+['\"]?${scrape_job}['\"]?[[:space:]]*$" >/dev/null
}
generated_job_present() {
  "${monitoring[@]}" get secret "$prometheus_statefulset" -o jsonpath='{.data.prometheus\.yaml\.gz}' |
    base64 -d | gzip -dc | job_name_present
}
loaded_job_present() {
  curl --noproxy '*' -fsS --max-time 4 "$prometheus/api/v1/status/config" |
    jq -er '.data.yaml' | job_name_present
}
wait_for_probe() {
  local probe=$1 deadline=$((SECONDS + $2))
  until "$probe" 2>/dev/null; do
    (( SECONDS < deadline )) || return 1
    sleep 3
  done
}
log_scrape_config() {
  printf '%s %s\n' "$(date -u +'%FT%TZ')" "$1" | tee -a "$output/scrape-config-status.txt"
}

if ! wait_for_probe generated_job_present 30; then
  log_scrape_config 'Fixture job missing from generated config. Restarting the disposable Prometheus Operator.'
  "${monitoring[@]}" rollout restart deployment/kube-prometheus-stack-operator
  "${monitoring[@]}" rollout status deployment/kube-prometheus-stack-operator --timeout=90s
  wait_for_probe generated_job_present 90 || {
    log_scrape_config 'Fixture job still missing from generated config after operator restart.'
    exit 1
  }
fi
log_scrape_config 'Fixture job present in generated config.'

start_forward
if ! wait_for_probe loaded_job_present 30; then
  log_scrape_config 'Fixture job missing from active config. Recycling the disposable Prometheus pod.'
  [[ $("${monitoring[@]}" get statefulset "$prometheus_statefulset" -o jsonpath='{.spec.replicas}') == 1 ]]
  prometheus_pod="$prometheus_statefulset-0"
  old_uid=$("${monitoring[@]}" get pod "$prometheus_pod" -o jsonpath='{.metadata.uid}')
  replacement_ready() {
    "${monitoring[@]}" get pod "$prometheus_pod" -o json |
      jq -e --arg old "$old_uid" '.metadata.uid != $old and any(.status.conditions[]?; .type == "Ready" and .status == "True")' >/dev/null
  }
  stop_forward
  "${monitoring[@]}" delete pod "$prometheus_pod" --wait=false
  wait_for_probe replacement_ready 120 || {
    log_scrape_config 'Replacement Prometheus pod did not become ready.'
    exit 1
  }
  start_forward
  wait_for_probe loaded_job_present 45 || {
    log_scrape_config 'Fixture job still missing from active config after pod recycle.'
    exit 1
  }
fi
log_scrape_config 'Fixture job present in active config.'

capture_targets() {
  curl --noproxy '*' -fsS --max-time 3 "$prometheus/api/v1/targets?state=any" |
    jq -ce '
      def demo: .labels.namespace == "demo" or .discoveredLabels.__meta_kubernetes_namespace == "demo";
      .data | {
        active: [.activeTargets[] | select(demo) |
          {scrapePool, job: .labels.job, service: .labels.service, proof: .labels.canary_proof,
           pod: .labels.pod, revision: .labels.rollouts_pod_template_hash,
           discoveredRevision: .discoveredLabels.__meta_kubernetes_pod_label_rollouts_pod_template_hash,
           health, lastScrape, lastError}][:50],
        dropped: [.droppedTargets[] | select(demo) |
          {job: .discoveredLabels.job, pod: .discoveredLabels.__meta_kubernetes_pod_name,
           port: .discoveredLabels.__meta_kubernetes_pod_container_port_name,
           revision: .discoveredLabels.__meta_kubernetes_pod_label_rollouts_pod_template_hash}][:50]
      }'
}

deadline=$((SECONDS + 90))
until capture_targets > "$output/stable-targets.json" 2> "$output/prometheus-target-error.txt" &&
    jq -e --arg stable "$stable_hash" --arg release "$release" '
      [.active[] | select(.proof == $release)] |
      length == 3 and all(.[]; .revision == $stable and .health == "up")' \
      "$output/stable-targets.json" >/dev/null; do
  (( SECONDS < deadline )) || { echo 'Prometheus did not scrape three stable targets with the rollout hash.' >&2; exit 1; }
  sleep 3
done

k6 run --out "json=$output/load.ndjson" clusters/tests/canary-load.js > "$output/k6.log" 2>&1 &
load_pid=$!
sleep 12
kill -0 "$load_pid"
requested_at=$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')
patch=$(jq -nc --arg image "$bad_image" '[{op: "replace", path: "/spec/template/spec/containers/0/image", value: $image}]')
"${demo[@]}" patch rollout "$release" --type=json -p "$patch"

deadline=$((SECONDS + 300))
next_scrape_capture=$SECONDS
until "${rollout[@]}" > "$output/aborted-rollout.json" &&
    jq -e --arg stable "$stable_hash" '
      .status.abort == true and .status.stableRS == $stable and
      (.status.currentPodHash | type == "string" and . != $stable) and
      (.status.abortedAt | type == "string")' "$output/aborted-rollout.json" >/dev/null; do
  (( SECONDS < deadline )) || { echo 'The canary did not abort within 300 seconds.' >&2; exit 1; }
  if (( SECONDS >= next_scrape_capture )); then
    if target_snapshot=$(capture_targets 2>> "$output/prometheus-target-error.txt"); then
      jq -cn --arg time "$(date -u +'%FT%TZ')" --argjson targets "$target_snapshot" \
        '{time: $time, targets: $targets}' >> "$output/rollout-targets.ndjson"
    fi
    next_scrape_capture=$((SECONDS + 10))
  fi
  sleep 2
done

bad_hash=$(jq -er '.status.currentPodHash' "$output/aborted-rollout.json")
aborted_at=$(jq -er '.status.abortedAt' "$output/aborted-rollout.json")
"${demo[@]}" get analysisruns -o json > "$output/analysis-runs.json"
curl --noproxy '*' -fsS --max-time 5 --get "$prometheus/api/v1/query" \
  --data-urlencode "query=sum by (rollouts_pod_template_hash,status) (rate(http_requests_total{namespace=\"demo\",canary_proof=\"$release\",path=\"/work\"}[2m]))" \
  --data-urlencode "time=$aborted_at" > "$output/rollout-request-rates.json" || true
analysis=$(jq -ec --arg owner "$rollout_uid" --arg bad "$bad_hash" '
  [.items[] |
    select(any(.metadata.ownerReferences[]?; .uid == $owner)) |
    select(any(.spec.args[]?; .name == "canary-revision" and .value == $bad)) |
    select(.status.phase == "Failed") |
    .metadata.name as $run |
    .status.metricResults[]? | select(.name == "work-success-ratio") |
    .measurements[]? | select(.phase == "Failed") |
    (.value | fromjson?) as $ratio |
    select(($ratio | type) == "array" and ($ratio | length) == 1 and
      ($ratio[0] | type) == "number" and $ratio[0] >= 0 and $ratio[0] < 0.995) |
    {analysis_run: $run, measured_canary_success_ratio: $ratio[0]}] | first // empty' "$output/analysis-runs.json") || {
  echo 'No failed Prometheus measurement matched the aborted revision.' >&2
  exit 1
}

deadline=$((SECONDS + 60))
until "${demo[@]}" get pods -l "$selector" -o json > "$output/recovered-pods.json" &&
    jq -e --arg stable "$stable_hash" '
      (.items | length) == 3 and all(.items[];
      .metadata.labels["rollouts-pod-template-hash"] == $stable and
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))' "$output/recovered-pods.json" >/dev/null; do
  (( SECONDS < deadline )) || { echo 'The stable replicas did not recover.' >&2; exit 1; }
  sleep 2
done

jq -n --arg requested "$requested_at" --arg aborted "$aborted_at" --arg stable "$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')" \
  --arg good_hash "$stable_hash" --arg bad_hash "$bad_hash" --argjson analysis "$analysis" \
  '$analysis + {requested_at: $requested, aborted_at: $aborted, stable_ready_at: $stable, stable_hash: $good_hash, bad_hash: $bad_hash}' \
  > "$output/timing.json"
wait "$load_pid"
load_pid=
python3 clusters/tests/canary-report.py "$output" > "$output/report.json"
cat "$output/report.json"
