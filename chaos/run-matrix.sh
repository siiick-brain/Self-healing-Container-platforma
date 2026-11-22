#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 || -z ${2:-} ]]; then
  echo "Usage: bash chaos/run-matrix.sh A|A2|B|C OUTPUT_DIR" >&2
  exit 2
fi
profile=$1
case "$profile" in
  A|A2) repeats=10 ;;
  B|C) repeats=20 ;;
  *) echo "Unknown profile: $profile" >&2; exit 2 ;;
esac
output=$2
[[ $output = /* ]] || output="$PWD/$output"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { echo "$*" >&2; exit 1; }

[[ ${GITHUB_ACTIONS:-} == true && $OSTYPE == linux-gnu* ]] ||
  fail "Run the matrix on the disposable GitHub Actions Linux lab."

for fault in pod stress network; do
  evidence=$(git show "HEAD:results/chaos-smoke/$fault.txt") ||
    fail "Missing committed $fault smoke log."
  if [[ $fault == network ]]; then
    grep -Eq '^([^[:space:]]+ )?PASS: App-level latency smoke verified[[:space:]]*$' <<< "$evidence" ||
      fail "The committed network log must confirm the app-level latency fallback."
    grep -Eq '^([^[:space:]]+ )?Cleanup confirmed[[:space:]]*$' <<< "$evidence" ||
      fail "The committed network log must confirm cleanup."
  else
    grep -Eq '^([^[:space:]]+ )?PASS: Chaos Mesh smoke verified[[:space:]]*$' <<< "$evidence" ||
      fail "The committed $fault log must confirm the Chaos Mesh smoke check."
  fi
done

k6_version=$(k6 version)
[[ $k6_version == 'k6 v0.58.0 '* ]] || fail "Expected k6 v0.58.0, found $k6_version"
[[ ${APP_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Expected a pinned application image digest."
context=k3d-self-healing
kube=(kubectl --context "$context" --request-timeout=10s)
demo=("${kube[@]}" -n demo)
selector='app.kubernetes.io/name=resilient-app,app.kubernetes.io/instance=resilient-app'
work_url=http://127.0.0.1:8080
rate=10
duration=120
timeout=90

"${kube[@]}" config view --minify -o json | jq -e '
  .clusters | length == 1 and
    (.[0].cluster.server | test("^https://(127\\.0\\.0\\.1|0\\.0\\.0\\.0|localhost):[0-9]+$"))
' >/dev/null || fail "The k3d API server must be local to this runner."
"${kube[@]}" get nodes -o json | jq -e --arg prefix "$context-" '
  .items | length > 0 and all(.[]; .metadata.name | startswith($prefix))
' >/dev/null || fail "Unexpected nodes in the disposable k3d cluster."
"${kube[@]}" get crd podchaos.chaos-mesh.org stresschaos.chaos-mesh.org >/dev/null

kind=deployment
other_kind=rollout
if [[ $profile == C ]]; then
  kind=rollout
  other_kind=deployment
fi
other_workload=$("${demo[@]}" get "$other_kind" resilient-app --ignore-not-found -o name)
[[ -z $other_workload ]] || fail "Unexpected $other_workload for profile $profile."
workload=$("${demo[@]}" get "$kind" resilient-app -o json)
jq -e --arg profile "$profile" --arg digest "$APP_DIGEST" '
  def probe($path; $period; $failures):
    .httpGet.path == $path and .httpGet.port == "http" and
    .periodSeconds == $period and .failureThreshold == $failures and .timeoutSeconds == 1;
  .spec.replicas == 3 and
  ($profile != "C" or
    (.spec.strategy.canary.canaryService == "resilient-app-canary" and
      any(.spec.strategy.canary.analysis.templates[]?; .templateName == "resilient-app-success"))) and
  any(.spec.template.spec.containers[]; .name == "app" and
    (.image | endswith("@" + $digest)) and
    any(.env[]; .name == "CHAOS_ENABLED" and .value == "true") and
    (if $profile == "A" then .livenessProbe == null and .readinessProbe == null
     elif $profile == "A2" then (.livenessProbe | probe("/healthz"; 10; 3)) and
       (.readinessProbe | probe("/readyz"; 10; 3))
     else (.livenessProbe | probe("/healthz"; 5; 3)) and (.readinessProbe | probe("/readyz"; 2; 2))
     end))
' <<< "$workload" >/dev/null || fail "The live $kind does not match profile $profile."
workload_uid=$(jq -er '.metadata.uid' <<< "$workload")
template=$(jq -ce '.spec.template.spec.containers[] | select(.name == "app") |
  {image, livenessProbe, readinessProbe, resources}' <<< "$workload")

ready_target() {
  local preferred=${1:-} deadline=$((SECONDS + 90)) pod
  while (( SECONDS < deadline )); do
    pod=$("${demo[@]}" get replicasets,pods -l "$selector" -o json |
      jq -r --arg owner "$workload_uid" --arg prefix "$context-" --arg preferred "$preferred" \
        --argjson template "$template" '
          def owned_by($uids):
            any(.metadata.ownerReferences[]?; .controller and (.uid as $uid | $uids | index($uid) != null));
          [.items[] | select(.kind == "ReplicaSet" and owned_by([$owner])) | .metadata.uid] as $sets |
          [.items[] | select(.kind == "Pod" and .metadata.deletionTimestamp == null)] |
          select(length == 3 and all(.[]; owned_by($sets) and
            ((.spec.nodeName // "") | startswith($prefix)) and
            any(.spec.containers[]; .name == "app" and
              ({image, livenessProbe, readinessProbe, resources} == $template)) and
            any(.status.conditions[]?; .type == "Ready" and .status == "True") and
            any(.status.containerStatuses[]?; .name == "app" and .ready))) |
          sort_by(.metadata.creationTimestamp, .metadata.name)[] |
          select($preferred == "" or .metadata.name == $preferred) | .metadata.name
        ' | sed -n '1p') || return 1
    if [[ -n $pod ]]; then
      printf '%s\n' "$pod"
      return 0
    fi
    sleep 2
  done
  echo "Profile $profile did not have three ready target replicas (requested: ${preferred:-any})." >&2
  return 1
}

mkdir -p "$output"
mkdir "$output/trials" "$output/load"

load_dir=
load_pid=
measure_pid=
forward_pid=
mesh_resource=
control_url=
reset_pending=
finish_capture() {
  local k6_exit_code=0 capture_status=0
  [[ -n $load_pid ]] || return 0
  wait "$load_pid" || k6_exit_code=$?
  load_pid=
  python3 - "$load_dir" "$output/trials" "$rate" "$duration" "$work_url" "$k6_exit_code" <<'PY' || capture_status=$?
import json
import sys
from datetime import datetime
from pathlib import Path

directory, trials = map(Path, sys.argv[1:3])
rate, duration = map(int, sys.argv[3:5])
work_url = sys.argv[5]
exit_code = int(sys.argv[6])
window_path = directory / "window.json"
window = json.loads(window_path.read_text()) if window_path.exists() else {}
with (directory / "metadata.json").open("x") as stream:
    json.dump({
        "run_id": directory.name,
        "rate": rate,
        "duration_s": duration,
        "work_url": work_url,
        "window_end_at": window.get("window_end_at"),
        "recovery_observed": window.get("recovery_observed", False),
        "k6_exit_code": exit_code,
    }, stream, indent=2)
    stream.write("\n")

row_path = trials / f"{directory.name}.json"
if exit_code:
    sys.exit(0)
if not row_path.exists() or window.get("run_id") != directory.name:
    sys.exit("Trial row or matching measurement window is missing")
row = json.loads(row_path.read_text())
first = last = None
with (directory / "points.json").open() as stream:
    for line in stream:
        point = json.loads(line)
        if point["type"] == "Point" and point["metric"] == "http_reqs":
            data = point["data"]
            if data["tags"].get("run_id") != directory.name:
                sys.exit("k6 HTTP request point has an unexpected run_id")
            sample = datetime.fromisoformat(data["time"])
            first = sample if first is None else min(first, sample)
            last = sample if last is None else max(last, sample)

injected = datetime.fromisoformat(row["injected_at"])
end = datetime.fromisoformat(window["window_end_at"])
if (first is None or end < injected or (injected - first).total_seconds() < 5 or
        (last - end).total_seconds() < 5 or (last - first).total_seconds() < duration - 2):
    sys.exit("k6 capture did not span the complete trial plus warmup and recovery buffer")
PY
  (( k6_exit_code == 0 )) || return "$k6_exit_code"
  return "$capture_status"
}

cleanup_fault() {
  if [[ -n $mesh_resource ]]; then
    "${demo[@]}" delete "$mesh_resource" --ignore-not-found --timeout=20s || return 1
    mesh_resource=
  fi
  if [[ -n $reset_pending ]]; then
    curl -fsS --noproxy '*' --max-time 5 -X POST "$control_url/chaos/reset" || return 1
    reset_pending=
  fi
  if [[ -n $forward_pid ]]; then
    kill -TERM "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
    forward_pid=
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ -n $measure_pid ]]; then
    kill -TERM -- "-$measure_pid" 2>/dev/null || kill -TERM "$measure_pid" 2>/dev/null || true
    wait "$measure_pid" 2>/dev/null || true
  fi
  if ! cleanup_fault; then
    echo "Trial cleanup could not be confirmed." >&2
    if [[ -n $forward_pid ]]; then
      kill -TERM "$forward_pid" 2>/dev/null || true
      wait "$forward_pid" 2>/dev/null || true
    fi
    status=1
  fi
  if [[ -n $load_pid ]]; then
    kill -TERM "$load_pid" 2>/dev/null || true
    finish_capture || true
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_trial() {
  local scenario=$1 pod=$2 round=$3 run_id injection=chaos-mesh
  local deadline port measure_status=0 k6_status=0
  run_id=$(python3 -c 'from uuid import uuid4; print(uuid4().hex)')
  load_dir="$output/load/$run_id"
  mkdir "$load_dir"
  printf 'Profile=%s scenario=%s trial=%s/%s pod=%s run_id=%s\n' \
    "$profile" "$scenario" "$round" "$repeats" "$pod" "$run_id" | tee "$load_dir/trial.log"
  curl -fsS --noproxy '*' --max-time 5 "$work_url/work" >/dev/null

  if [[ $scenario == latency ]]; then
    injection=app-level
    kubectl --context "$context" -n demo port-forward --address 127.0.0.1 "pod/$pod" :8080 \
      >"$load_dir/port-forward.log" 2>&1 &
    forward_pid=$!
    deadline=$((SECONDS + 15))
    port=
    while (( SECONDS < deadline )); do
      kill -0 "$forward_pid" 2>/dev/null || fail "Port-forward failed for $pod."
      port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$/\1/p' "$load_dir/port-forward.log")
      [[ -z $port ]] || break
      sleep 1
    done
    [[ -n $port ]] || fail "Port-forward did not become ready for $pod."
    control_url="http://127.0.0.1:$port"
    curl -fsS --noproxy '*' --max-time 5 "$control_url/healthz" >/dev/null
  fi

  NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
    K6_NO_USAGE_REPORT=true RATE=$rate DURATION=${duration}s WORK_URL=$work_url \
    k6 run --tag "run_id=$run_id" --out "json=$load_dir/points.json" k6/work.js >"$load_dir/k6.log" 2>&1 &
  load_pid=$!
  deadline=$((SECONDS + 15))
  until [[ -f $load_dir/points.json ]] &&
    awk '/"type":"Point"/ && /"metric":"http_reqs"/ { seen = 1; exit } END { exit !seen }' \
      "$load_dir/points.json"; do
    kill -0 "$load_pid" 2>/dev/null || fail "k6 exited before producing HTTP request samples."
    (( SECONDS < deadline )) || fail "k6 did not produce HTTP request samples during startup."
    sleep 1
  done
  sleep 10
  kill -0 "$load_pid" 2>/dev/null || fail "k6 exited during warmup."

  case "$scenario" in
    crash) mesh_resource="podchaos/resilient-app-$run_id" ;;
    leak) mesh_resource="stresschaos/resilient-app-$run_id" ;;
    latency) reset_pending=1 ;;
  esac
  NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 setsid python3 chaos/measure.py --results "$output/trials" \
    run "$scenario" "$profile" --injection-type "$injection" --pod "$pod" --run-id "$run_id" \
    --window-metadata "$load_dir/window.json" --timeout "$timeout" --work-url "$work_url" \
    --control-url "${control_url:-http://127.0.0.1:18080}" >>"$load_dir/trial.log" 2>&1 &
  measure_pid=$!
  wait "$measure_pid" || measure_status=$?
  measure_pid=
  cleanup_fault || fail "Could not confirm cleanup for trial $run_id."

  finish_capture || k6_status=$?
  if (( measure_status != 0 )); then
    cat "$load_dir/trial.log" >&2
    return "$measure_status"
  fi
  (( k6_status == 0 )) || fail "k6 capture failed for trial $run_id. See $load_dir."
  gzip "$load_dir/points.json"
  cat "$load_dir/trial.log"
}

for (( round = 1; round <= repeats; round++ )); do
  pod=$(ready_target)
  run_trial leak "$pod" "$round"
  # Replace the pod in the scheduled crash trial so OOM restart backoff cannot accumulate.
  pod=$(ready_target "$pod")
  run_trial crash "$pod" "$round"
  pod=$(ready_target)
  run_trial latency "$pod" "$round"
done
