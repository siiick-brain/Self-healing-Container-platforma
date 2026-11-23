# Canary abort and Git revert

Measure automatic canary abort from rollout analysis separately from Git revert recovery. The controller aborts the canary without creating a commit.

## Git revert proof

The hosted rollback workflow watches only `proof/gitops-rollback` on a disposable k3d cluster. It checks that the original revision serves `/work`, that the deliberate bad change creates zero ready replicas and a 5xx response, and that the reverted revision serves HTTP 200 with three ready replicas. The report measures from the first observed bad push to health after the revert. It also records the interval from the first observed revert push to health. Both timestamps use the runner's two-second polling loop and include GitOps reconciliation time.

In a clean Bash worktree, start the proof branch at the current `origin/main` revision. Dispatch the workflow from `main`.

```bash
git fetch origin main
git switch -c proof/gitops-rollback origin/main
git push -u origin proof/gitops-rollback
gh workflow run gitops-rollback.yml --ref main
```

Wait for **Observe the bad push and confirm the outage** to start. Commit the zero-replica fixture on the proof branch.

```bash
test "$(git branch --show-current)" = proof/gitops-rollback &&
  printf '\nreplicaCount: 0\n' >> charts/resilient-app/values-k3d.yaml &&
  git add charts/resilient-app/values-k3d.yaml &&
  git commit -m "test: record an unavailable GitOps release" &&
  git push
```

Wait for **Observe the revert push and confirm recovery** to start. Revert the fixture.

```bash
test "$(git branch --show-current)" = proof/gitops-rollback &&
  git revert --no-edit HEAD &&
  git push
```

Download `gitops-rollback-evidence` from the completed run. The canary abort uses the rollout controller and a separate evidence report.
