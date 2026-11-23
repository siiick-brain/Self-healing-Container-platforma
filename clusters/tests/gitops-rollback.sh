#!/usr/bin/env bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REF:-} == refs/heads/* ]] || {
  echo 'Run rollback evidence from a branch on a disposable GitHub Actions runner.' >&2
  exit 2
}

branch=${GITOPS_REVISION:-proof/gitops-rollback}
[[ $branch =~ ^proof/gitops-rollback(-[a-z0-9]+(-[a-z0-9]+)*)?$ && ${#branch} -le 80 ]] || {
  echo 'Expected proof/gitops-rollback or a retry branch with a lowercase alphanumeric suffix.' >&2
  exit 2
}
ref=refs/heads/$branch
baseline=$(git rev-parse HEAD)
origin=$(git remote get-url origin)
repository=${GITHUB_SERVER_URL:?}/${GITHUB_REPOSITORY:?}
[[ $baseline == "${GITHUB_SHA:-}" && ${origin%.git} == "$repository" &&
  ${GITOPS_REPO:-} == "$repository.git" ]] || {
  echo 'Expected the dispatched commit and a proof branch in the workflow repository.' >&2
  exit 2
}
values=charts/resilient-app/values-k3d.yaml
url=http://127.0.0.1:8080/work
kube=(kubectl --context k3d-self-healing --request-timeout=10s)

verify_baseline() {
  [[ $(timeout 10s git ls-remote --exit-code --refs origin "$ref" | cut -f1) == "$baseline" ]] || {
    echo "$ref must point to workflow commit $baseline before the baseline run." >&2
    return 1
  }
}

if [[ ${1:-} == preflight ]]; then
  verify_baseline
  exit 0
fi
output=${2:?Expected an evidence directory.}
mkdir -p "$output"

revision() {
  local wanted=$1 replicas=$2 state health
  state=$("${kube[@]}" -n argocd get application resilient-app -o json) || return 1
  jq -e --arg sha "$wanted" '
    .status.sync.revision == $sha and .status.sync.status == "Synced" and
    .status.health.status == "Healthy"
  ' <<< "$state" >/dev/null || return 1
  health=$("${kube[@]}" -n demo get deployment resilient-app -o json) || return 1
  jq -e --argjson replicas "$replicas" '
    .status.observedGeneration == .metadata.generation and .spec.replicas == $replicas and
    (.status.readyReplicas // 0) == $replicas
  ' <<< "$health" >/dev/null
}

work_status() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url"
}

request_refresh() {
  "${kube[@]}" -n argocd get application resilient-app -o json |
    jq -e --arg repo "$GITOPS_REPO" --arg branch "$branch" '
      .spec.source.repoURL == $repo and .spec.source.targetRevision == $branch and
      .spec.syncPolicy.automated != null and .spec.syncPolicy.automated.enabled != false
    ' >/dev/null
  "${kube[@]}" -n argocd annotate application resilient-app argocd.argoproj.io/refresh=hard --overwrite
}

capture_state() {
  local sha=$1 replicas=$2 phase=$3 http app deployment pods
  app=$("${kube[@]}" -n argocd get application resilient-app -o json |
    jq -c '{revision: .status.sync.revision, sync: .status.sync.status, health: .status.health.status,
            operation: .status.operationState.phase,
            conditions: [.status.conditions[]? | {type, lastTransitionTime}]}') || app=null
  deployment=$("${kube[@]}" -n demo get deployment resilient-app -o json |
    jq -c '{generation: .metadata.generation, observed_generation: .status.observedGeneration,
            desired: .spec.replicas, ready: (.status.readyReplicas // 0),
            conditions: [.status.conditions[]? | {type, status, reason}]}') || deployment=null
  pods=$("${kube[@]}" -n demo get pods -l app.kubernetes.io/instance=resilient-app -o json |
    jq -c '[.items[:10][] | {name: .metadata.name, phase: .status.phase,
      ready: any(.status.conditions[]?; .type == "Ready" and .status == "True"),
      waiting: [.status.containerStatuses[]? | .state.waiting.reason // empty]}]') || pods=null
  http=$(work_status) || http=000
  jq -n --arg sha "$sha" --argjson replicas "$replicas" --arg http "$http" \
    --argjson app "$app" --argjson deployment "$deployment" --argjson pods "$pods" '
    {expected_revision: $sha, expected_replicas: $replicas, http_status: $http,
     application: $app, deployment: $deployment, pods: $pods}' > "$output/$phase-last-observation.json"
}

wait_for_push() {
  local previous=$1 deadline=$((SECONDS + 600)) sha
  while (( SECONDS < deadline )); do
    if sha=$(timeout 10s git ls-remote --exit-code --refs origin "$ref" | cut -f1) &&
      [[ $sha =~ ^[0-9a-f]{40}$ && $sha != "$previous" ]]; then
      printf '%s\n' "$sha"
      return 0
    fi
    sleep 2
  done
  echo "No new push was observed for $ref." >&2
  return 1
}

wait_for_state() {
  local sha=$1 replicas=$2 expected_status=$3 phase=$4 deadline=$((SECONDS + 300)) status
  while (( SECONDS < deadline )); do
    if revision "$sha" "$replicas" && status=$(work_status) && [[ $status =~ $expected_status ]]; then
      printf '%s\n' "$status"
      return 0
    fi
    sleep 2
  done
  echo "Revision $sha did not produce $replicas ready replicas and HTTP status $expected_status." >&2
  capture_state "$sha" "$replicas" "$phase" || true
  return 1
}

case ${1:-} in
  baseline)
    verify_baseline
    status=$(wait_for_state "$baseline" 3 '^200$' baseline)
    jq -n --arg sha "$baseline" --argjson http "$status" '{revision: $sha, http_status: $http, ready_replicas: 3}' > "$output/baseline.json"
    ;;
  bad)
    [[ -s $output/baseline.json ]]
    bad=$(wait_for_push "$baseline")
    pushed_at=$(date -u +%s)
    git fetch --quiet --no-tags --depth=2 origin "$bad"
    [[ $(git rev-parse "$bad^1") == "$baseline" && $(git diff --name-only "$baseline" "$bad") == "$values" ]]
    diff -u <(git show "$bad:$values") <(git show "$baseline:$values"; printf '\nreplicaCount: 0\n')
    request_refresh
    status=$(wait_for_state "$bad" 0 '^5[0-9]{2}$' bad)
    jq -n --arg sha "$bad" --argjson push "$pushed_at" --argjson observed "$(date -u +%s)" --argjson http "$status" \
      '{revision: $sha, bad_push_observed_epoch_s: $push, bad_state_observed_epoch_s: $observed, http_status: $http, ready_replicas: 0}' > "$output/bad.json"
    ;;
  revert)
    bad=$(jq -er .revision "$output/bad.json")
    reverted=$(wait_for_push "$bad")
    revert_at=$(date -u +%s)
    git fetch --quiet --no-tags --depth=2 origin "$reverted"
    [[ $(git rev-parse "$reverted^1") == "$bad" && $(git rev-parse "$reverted^{tree}") == "$(git rev-parse "$baseline^{tree}")" ]]
    request_refresh
    status=$(wait_for_state "$reverted" 3 '^200$' revert)
    jq -n --slurpfile bad "$output/bad.json" --arg sha "$reverted" --argjson push "$revert_at" \
      --argjson healthy "$(date -u +%s)" --argjson http "$status" '
        {bad_revision: $bad[0].revision, reverted_revision: $sha, http_status: $http, ready_replicas: 3,
         bad_push_observed_epoch_s: $bad[0].bad_push_observed_epoch_s,
         bad_state_observed_epoch_s: $bad[0].bad_state_observed_epoch_s,
         revert_push_observed_epoch_s: $push, healthy_observed_epoch_s: $healthy,
         mttr_s: ($healthy - $bad[0].bad_push_observed_epoch_s),
         revert_to_healthy_s: ($healthy - $push)}' | tee "$output/rollback.json"
    ;;
  *) echo 'Usage: gitops-rollback.sh baseline|bad|revert EVIDENCE_DIR' >&2; exit 2 ;;
esac
