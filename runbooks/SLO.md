# Availability alerts

Open the Resilient app SLO and RED dashboards. Confirm the error ratio and request rate for the affected windows. The availability SLI counts server errors on the work endpoint. If the request rate is missing, check the scrape targets and traffic generator.

For HighBurnRate, compare the short and long windows. Check app restarts and recent Argo CD syncs. If the incident follows a bad deployment, revert the relevant change in Git and time the recovery after sync. Keep rollback measurements separate from canary abort timing.

For SLOAvailabilityBreach, inspect the observed availability history and account for gaps in the available data before drawing conclusions about the full target window.

For a failed canary analysis, inspect the AnalysisRun and measure the time to abort. The rollout controller manages the abort. The reference for the burn-rate approach is the [Google SRE Workbook](https://sre.google/workbook/alerting-on-slos/).
