# Hosted NetworkChaos injection failure

On November 22, 2026, a disposable GitHub-hosted k3d cluster failed to inject a network delay. The interrupted smoke check produced no packet-level recovery measurement. A fresh cluster later verified the application-level latency fallback.

## Timeline in UTC

| Time | Observation |
| --- | --- |
| 13:43 | Admission rejected a request that specified `both` without a target selector. The smoke check confirmed cleanup. |
| 13:57 | A retry using `to` passed admission. Chaos Mesh selected the pod and then repeatedly failed to program its iptables chains. |
| 13:58 | The observation window expired with zero confirmed injections. Deletion timed out while the experiment still had its records finalizer. |
| 14:00 | The workflow removed the disposable cluster. |
| 19:14 | A fresh run observed a 1.504-second response from the selected pod under the application-level delay. The smoke check reset the delay and confirmed cleanup. |

See the [admission rejection](../../results/chaos-smoke/network-admission-rejection.txt), [runtime failure](../../results/chaos-smoke/network-runtime-failure.txt), [cluster teardown](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45029315264/attempts/2), and [passing fallback run](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45058993114).

## Cause and follow-up

The first request failed validation. The second reached the fault controller, which reported that it could not set the target pod's iptables chains. The logs establish where injection failed. The underlying runner and runtime interaction remains unknown.

The smoke check gates the hosted matrix on verified cleanup and a successful application-level latency check. Record that mechanism alongside the trial results. The observed response delay measures the fallback injection, and packet-level behavior remains unverified on the hosted runner. [Fallback evidence](../../results/chaos-smoke/network.txt)
