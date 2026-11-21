# Service-level objectives

The availability SLI is the ratio of successful work requests to all work requests. A window with no work requests carries no availability sample. The latency SLI uses the work-request histogram after aggregation by bucket.

| Objective | Window |
| --- | --- |
| Availability of 99.5 percent <!-- target --> | 30 days <!-- target --> |
| p95 below 300 ms <!-- target --> | 30 days <!-- target --> |

The availability objective permits a 0.5 percent error fraction. Compute burn as the observed bad fraction divided by the error budget fraction. Review rapid sustained burn immediately. Track slow burn as follow-up work. Suspend risky rollouts while the budget is exhausted.

| Action | Evaluation |
| --- | --- |
| Page | Pair a long-window burn alert with a short confirmation window |
| Investigate | Use a slower pair to detect lower but persistent burn |
| Review the budget | Inspect the full rolling availability window |

See the [Google SRE Workbook chapter on alerting on SLOs](https://sre.google/workbook/alerting-on-slos/).
