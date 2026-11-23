# First hosted recovery matrix stopped before measurement

On November 22, 2026, the recovery matrix passed preflight and started four profile jobs. All four exited before collecting trial evidence. The validator reported zero validated trials, leaving the profile comparison without recovery metrics. [Matrix run](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45060821994)

## Timeline in UTC

| Time | Observation |
| --- | --- |
| 19:31 to 19:32 | Profiles B and C started their full clusters. Both then exited in the step that binds the profile and app image digest. |
| 19:38 | Profiles A and A2 timed out during Argo CD startup. Their pod listings recorded Redis in `ImagePullBackOff`. |
| 19:39 | The summary job downloaded the four profile artifacts and failed evidence validation. |

See the [profile A artifact](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45060821994/artifacts/14769601960), [profile A2 artifact](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45060821994/artifacts/14769309757), [profile B job](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45060821994/job/137326173559), [profile C job](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45060821994/job/137326173444), and [summary job](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45060821994/job/137329603483).

## Cause and follow-up

Argo CD startup depended on the cluster pulling Redis. The A and A2 pod listings show that pull failing. The registry error itself remains unknown. After B and C updated the app configuration, the workflow checked the requested profile and digest once. Argo CD reconciles that configuration asynchronously, so the immediate check could encounter the previous profile and exit before tests began. The failed jobs identify the binding step. The field that differed remains unknown.

The follow-up change preloads Redis from a pinned digest in CI and saves Argo CD events. The binding step waits up to five minutes for Argo CD to report the requested profile and revision as synced and healthy. All four profiles reached the measurement step on the next run. Each then stopped because the official k6 `v0.58.0` archive reported `v1.0.0-rc1` for the same release commit. The revised runner verifies the archive digest and checks the displayed build identifier before cluster startup. The profile comparison still requires a run with validated trials. [Follow-up change](https://github.com/siiick-brain/Self-healing-Container-platforma/pull/17) · [Second matrix run](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45063325536) · [k6 release](https://github.com/grafana/k6/releases/tag/v0.58.0)
