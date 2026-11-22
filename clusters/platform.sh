#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

profile=${1:?Pass core, full or down}
name=self-healing
context=k3d-$name
kube=(kubectl --context "$context")
if [[ $profile == down ]]; then
  k3d cluster delete "$name"
  exit
fi
[[ $profile == core || $profile == full ]]

agents=${K3D_AGENTS:-3}
if [[ $agents != 2 && $agents != 3 ]]; then
  echo 'K3D_AGENTS must be 2 or 3.' >&2
  exit 1
fi

if ! "${kube[@]}" get --raw=/readyz >/dev/null 2>&1; then
  config=$(mktemp)
  trap 'rm -f "$config"' EXIT
  sed "s/^agents: 3$/agents: $agents/" clusters/k3d.yaml > "$config"
  k3d cluster create --config "$config"
fi

"${kube[@]}" wait node --all --for=condition=Ready --timeout=120s
"${kube[@]}" apply -f clusters/namespaces
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm   --version 7.8.13 --namespace argocd --create-namespace --kube-context "$context"   --values clusters/argocd-values.yaml --wait --timeout 5m

repo=${GITOPS_REPO:-https://github.com/siiick-brain/Self-healing-Container-platforma.git}
revision=${GITOPS_REVISION:-main}
apply_root() {
  local source_config project_apps helm_parameters=
  case "$1" in
    core) project_apps='platform-policy|resilient-app' ;;
    full) project_apps='diagnostics-receiver|grafana-dashboards|minio|observability|vpa-recommendation' ;;
  esac
  source_config=$(cat <<EOF
    kustomize:
      patches:
        - target:
            group: argoproj.io
            kind: Application
            name: '$project_apps'
          patch: |-
            - op: replace
              path: /spec/source/repoURL
              value: "$repo"
            - op: replace
              path: /spec/source/targetRevision
              value: "$revision"
EOF
  )
  if [[ $1 == core && ${K3D_NODE_EXPORTER:-true} == false ]]; then
    helm_parameters=$(cat <<'EOF'
                - name: nodeExporter.enabled
                  value: 'false'
EOF
    )
  fi
  if [[ $1 == core && ${GITHUB_ACTIONS:-false} == true && ${K3D_CI_GRAFANA_VIEWER:-false} == true ]]; then
    helm_parameters+=$'\n'$(cat <<'EOF'
                - name: grafana.env.GF_AUTH_ANONYMOUS_ENABLED
                  value: 'true'
                  forceString: true
                - name: grafana.env.GF_AUTH_ANONYMOUS_ORG_ROLE
                  value: Viewer
                - name: grafana.service.type
                  value: ClusterIP
                - name: grafana.ingress.enabled
                  value: 'false'
EOF
    )
  fi
  if [[ -n $helm_parameters ]]; then
    source_config+=$'\n'$(cat <<EOF
        - target:
            group: argoproj.io
            kind: Application
            name: kube-prometheus-stack
          patch: |-
            - op: add
              path: /spec/source/helm/parameters
              value:
$helm_parameters
EOF
    )
  fi
  cat <<EOF | "${kube[@]}" apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-$1
  namespace: argocd
  annotations:
    argocd.argoproj.io/compare-options: ServerSideDiff=true
spec:
  project: default
  source:
    repoURL: "$repo"
    targetRevision: "$revision"
    path: clusters/gitops/$1
$source_config
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

wait_for_apps() {
  local profile=$1 manifest name deadline=$((SECONDS + 300))
  local app_names=("platform-$profile")
  for manifest in "clusters/gitops/$profile"/*.yaml; do
    name=${manifest##*/}
    [[ $name != kustomization.yaml ]] || continue
    app_names+=("${name%.yaml}")
  done

  while (( SECONDS < deadline )); do
    if "${kube[@]}" -n argocd get applications "${app_names[@]}" -o jsonpath='{range .items[*]}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null |
      awk -v count="${#app_names[@]}" '$1 == "Synced" && $2 == "Healthy" { good++ } END { exit !(good == count) }'; then
      return 0
    fi
    sleep 5
  done

  echo "GitOps applications for $profile did not all reach Synced and Healthy." >&2
  "${kube[@]}" -n argocd get applications -o wide >&2 || true
  "${kube[@]}" -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[*].message}{"\n"}{end}' >&2 || true
  "${kube[@]}" get pods -A >&2 || true
  return 1
}

apply_root core
wait_for_apps core
if [[ $profile == full ]]; then
  "${kube[@]}" -n storage get secret minio-credentials >/dev/null
  "${kube[@]}" -n ops get secret diagnostics-minio >/dev/null
  apply_root full
  wait_for_apps full
fi
mkdir -p results/env
mapfile -t nodes < <(docker ps --filter "name=k3d-$name" --format "{{.Names}}")
(( ${#nodes[@]} > 0 ))
docker stats --no-stream "${nodes[@]}" > "results/env/docker-stats-$profile.txt"
"${kube[@]}" get pods -A
