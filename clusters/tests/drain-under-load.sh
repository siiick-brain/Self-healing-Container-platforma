#!/usr/bin/env bash
set -euo pipefail

evidence=${1:?Pass an evidence directory}
mkdir -p "$evidence"
kube=(kubectl --context k3d-self-healing --request-timeout=10s)
selector=app.kubernetes.io/name=resilient-app

"${kube[@]}" -n demo rollout status deployment/resilient-app --timeout=60s
"${kube[@]}" -n demo get pods -l "$selector" -o json > "$evidence/pods-before.json"
"${kube[@]}" -n demo get pdb resilient-app -o json > "$evidence/pdb-before.json"
jq -e '.status.observedGeneration == .metadata.generation and .status.desiredHealthy > 0 and
  .status.disruptionsAllowed > 0' "$evidence/pdb-before.json" >/dev/null

# Keep ingress on its current node so the measurement isolates the app eviction.
ingress_nodes=$("${kube[@]}" -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o json |
  jq -ce '[.items[].spec.nodeName | strings] | unique | select(length > 0)')
target=$(jq -er --argjson ingress "$ingress_nodes" '
  [.items[] | select(.metadata.deletionTimestamp == null and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
    select(.spec.nodeName | test("^k3d-self-healing-agent-[0-9]+$")) |
    select(.spec.nodeName as $node | $ingress | index($node) == null)] |
    group_by(.spec.nodeName) | min_by(length) | .[0] |
    [.spec.nodeName, .metadata.name, .metadata.uid] | @tsv
' "$evidence/pods-before.json")
IFS=$'\t' read -r node pod pod_uid <<< "$target"
[[ -n $node && -n $pod && -n $pod_uid ]] || { echo 'No eligible app pod on a non-ingress agent.' >&2; exit 1; }
"${kube[@]}" get node "$node" -o json > "$evidence/node-before.json"
jq -e '.spec.unschedulable != true' "$evidence/node-before.json" >/dev/null

kubectl --context k3d-self-healing -n demo get endpointslices \
  -l kubernetes.io/service-name=resilient-app --watch --output-watch-events -o json \
  > "$evidence/endpointslice-watch.jsonstream" 2> "$evidence/endpointslice-watch.log" &
watch_pid=$!
load_pid=
started=
cleanup() {
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  if [[ -n $load_pid ]]; then
    kill "$load_pid" 2>/dev/null || true
    wait "$load_pid" 2>/dev/null || true
  fi
  if [[ -n $started ]]; then
    "${kube[@]}" -n ingress-nginx logs -l app.kubernetes.io/component=controller \
      --timestamps --prefix --since-time="$started" --tail=-1 > "$evidence/ingress.log" 2>&1 || true
  fi
}
trap cleanup EXIT

WORK_URL=http://127.0.0.1:8080 RATE=10 DURATION=5m k6 run --no-color --quiet \
  --out "json=$evidence/k6-points.json" k6/work.js > "$evidence/k6.log" 2>&1 &
load_pid=$!
deadline=$((SECONDS + 20))
until grep -Eq '"type":"Point".*"metric":"http_reqs"|"metric":"http_reqs".*"type":"Point"' \
    "$evidence/k6-points.json" 2>/dev/null; do
  if (( SECONDS >= deadline )) || ! kill -0 "$load_pid" 2>/dev/null; then
    echo 'k6 did not record any requests before the drain.' >&2
    cat "$evidence/k6.log" >&2
    exit 1
  fi
  sleep 1
done

started=$(date -u +%FT%T.%NZ)
printf 'Draining %s with ready app pod %s under k6 load.\n' "$node" "$pod"
drain_status=0
bash clusters/tests/drain.sh "$node" --disposable-hosted 2>&1 |
  tee "$evidence/drain.log" || drain_status=$?
finished=$(date -u +%FT%T.%NZ)
"${kube[@]}" get node "$node" -o json > "$evidence/node-after.json"
"${kube[@]}" -n demo get deployment resilient-app -o json > "$evidence/deployment-after.json"
"${kube[@]}" -n demo get pods -l "$selector" -o json > "$evidence/pods-after.json"
"${kube[@]}" -n demo get pdb resilient-app -o json > "$evidence/pdb-after.json"
wait "$load_pid"
load_pid=

python3 - "$evidence" "$started" "$finished" "$node" "$pod_uid" "$drain_status" <<'PY'
from datetime import datetime
import json
from pathlib import Path
import sys

directory, started, finished, node, pod_uid, drain_status = sys.argv[1:]
directory = Path(directory)
start, end = map(datetime.fromisoformat, (started, finished))
windows = {name: {"requests": 0, "failures": 0} for name in ("before", "during", "after")}
dropped = 0
with (directory / "k6-points.json").open() as stream:
    for line in stream:
        point = json.loads(line)
        if point["type"] != "Point":
            continue
        if point["metric"] == "dropped_iterations":
            dropped += point["data"]["value"]
        if point["metric"] != "http_reqs":
            continue
        data = point["data"]
        observed = datetime.fromisoformat(data["time"])
        window = "before" if observed < start else "during" if observed <= end else "after"
        windows[window]["requests"] += 1
        windows[window]["failures"] += data["tags"].get("status") != "200"

node_after = json.loads((directory / "node-after.json").read_text())
deployment = json.loads((directory / "deployment-after.json").read_text())
pods_after = json.loads((directory / "pods-after.json").read_text())["items"]
uncordoned = not node_after["spec"].get("unschedulable", False)
pod_removed = all(pod["metadata"]["uid"] != pod_uid for pod in pods_after)
ready_pods = sum(pod["metadata"].get("deletionTimestamp") is None and any(
    condition["type"] == "Ready" and condition["status"] == "True"
    for condition in pod["status"].get("conditions", [])
) for pod in pods_after)
replicas_ready = ready_pods == deployment["spec"]["replicas"]
summary = {"node": node, "evicted_pod_uid": pod_uid, "drain_started_at": started,
           "drain_finished_at": finished, "drain_exit_code": int(drain_status),
           "uncordoned": uncordoned, "pod_removed": pod_removed, "ready_pods": ready_pods,
           "traffic": windows, "dropped_iterations": dropped}
print(json.dumps(summary, indent=2))
(directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
if int(drain_status) or not uncordoned or not pod_removed or not replicas_ready:
    sys.exit("Drain, pod eviction, replica recovery or uncordon did not complete.")
if dropped or any(not counts["requests"] for counts in windows.values()):
    sys.exit("k6 did not sustain measured traffic before, during and after the drain.")
during = windows["during"]
if during["failures"] * 200 > during["requests"]:
    sys.exit("Availability during the drain was below the 99.5% lab target.")
PY
