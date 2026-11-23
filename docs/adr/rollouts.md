# Canary abort and Git revert

Measure automatic canary abort from rollout analysis separately from Git revert recovery. The controller aborts the canary without creating a commit.

## Git revert proof

The hosted rollback workflow watches a dedicated proof branch in the workflow repository on a disposable k3d cluster. It checks that the original revision serves `/work`, that the deliberate bad change creates zero ready replicas and a 5xx response, and that the reverted revision serves HTTP 200 with three ready replicas. Once the runner verifies each pushed commit, it requests one Argo CD hard refresh. Argo CD applies the change through its automated sync policy. The report measures from the runner's first observation of the bad push to health after the revert. It also records the interval from the first observation of the revert push to health. Both intervals include the refresh and reconciliation.

In a clean Bash worktree, start the proof branch at the exact commit of the workflow branch. The default proof branch is `proof/gitops-rollback`. Use a new lowercase suffix to retry without rewriting the original branch.

```bash
workflow_branch=main
proof_branch=proof/gitops-rollback-retry
git fetch origin "$workflow_branch"
git switch -c "$proof_branch" FETCH_HEAD
git push -u origin "$proof_branch"
gh workflow run gitops-rollback.yml --ref "$workflow_branch" -f proof_branch="$proof_branch"
```

Wait for **Observe the bad push and confirm the outage** to start. Commit the zero-replica fixture on the proof branch.

```bash
test "$(git branch --show-current)" = "$proof_branch" &&
  printf '\nreplicaCount: 0\n' >> charts/resilient-app/values-k3d.yaml &&
  git add charts/resilient-app/values-k3d.yaml &&
  git commit -m "test: record an unavailable GitOps release" &&
  git push
```

Wait for **Observe the revert push and confirm recovery** to start. Revert the fixture.

```bash
test "$(git branch --show-current)" = "$proof_branch" &&
  git revert --no-edit HEAD &&
  git push
```

Download `gitops-rollback-evidence` from the completed run. If a readiness check times out, its last-observation file records the Argo CD sync and health status, Deployment replicas, pod readiness and HTTP status. The canary abort uses the rollout controller and a separate evidence report.

The first hosted rollback returned HTTP 503 with zero ready replicas 182 seconds after the runner observed the bad push. The revert was pushed, but the runner did not verify recovery before its five-minute deadline. [Recorded outage and baseline](../../results/operations/rollback-first-attempt.json) · [Original artifact](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45087156670/artifacts/14780350840)
