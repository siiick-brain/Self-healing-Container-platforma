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

"${kube[@]}" apply -f clusters/namespaces
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm   --version 7.8.13 --namespace argocd --create-namespace --kube-context "$context"   --values clusters/argocd-values.yaml --wait --timeout 5m

repo=${GITOPS_REPO:-https://github.com/siiick-brain/Self-healing-Container-platforma.git}
revision=${GITOPS_REVISION:-main}
apply_root() {
  cat <<EOF | "${kube[@]}" apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-$1
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "$repo"
    targetRevision: "$revision"
    path: clusters/gitops/$1
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
  "${kube[@]}" -n argocd wait "application/platform-$1"     --for=jsonpath='{.status.health.status}'=Healthy --timeout=5m
}

apply_root core
if [[ $profile == full ]]; then
  "${kube[@]}" -n storage get secret minio-credentials >/dev/null
  "${kube[@]}" -n ops get secret diagnostics-minio >/dev/null
  apply_root full
fi
mkdir -p results/env
mapfile -t nodes < <(docker ps --filter "name=k3d-$name" --format "{{.Names}}")
(( ${#nodes[@]} > 0 ))
docker stats --no-stream "${nodes[@]}" > "results/env/docker-stats-$profile.txt"
"${kube[@]}" get pods -A
