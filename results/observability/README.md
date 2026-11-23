# Grafana smoke evidence

The hosted capture rendered the RED and SLO dashboards using live Prometheus data. The capture shows a short window of lab traffic. The SLO dashboard labels availability over the observed history. [GitHub Actions run and original artifact](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45027584492)

| Artifact | Evidence |
| --- | --- |
| RED dashboard | [Request rate, errors, latency and pod memory](grafana-red.png) |
| SLO dashboard | [Availability and burn-rate panels](grafana-slo.png) |
| Prometheus response | [Request rate and availability samples](grafana-prometheus.json) |
| Dashboard demo | [Live RED and SLO walkthrough](grafana-demo.gif) · [Capture artifact](https://github.com/siiick-brain/Self-healing-Container-platforma/actions/runs/45086182061/artifacts/14779557752) |
