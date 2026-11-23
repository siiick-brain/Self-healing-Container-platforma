# Service-level objectives

The availability SLI is the ratio of successful work requests to all work requests. A window with no work requests carries no availability sample. The latency SLI uses the work-request histogram after aggregation by bucket.

| Objective | Window |
| --- | --- |
| Availability of 99.5 percent <!-- target --> | 30 days <!-- target --> |
| p95 below 300 ms <!-- target --> | 30 days <!-- target --> |

The availability objective permits a 0.5 percent error fraction. Compute burn as the observed bad fraction divided by the error budget fraction. Review rapid sustained burn immediately. Track slow burn as follow-up work. Suspend risky rollouts while the budget is exhausted.

| Action | Windows | Trigger |
| --- | --- | --- |
| Page | 1 hour and 5 minutes | Both above 14.4 times the error-budget burn rate |
| Page | 6 hours and 30 minutes | Both above 6 times the error-budget burn rate |
| Review the budget | 30 days of observed requests | Availability below 99.5% for 5 minutes |

The [Prometheus rules](../alerts/app.rules.yaml) implement these thresholds. [Google SRE Workbook chapter on alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
