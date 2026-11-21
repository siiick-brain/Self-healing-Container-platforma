# Observability setup

The Prometheus release must discover the demo PrometheusRule. Alertmanager must discover the demo AlertmanagerConfig. Both objects carry the kube-prometheus-stack release label. Install the Rollouts and Prometheus Operator CRDs before syncing alerts/k8s. Grafana uses the dashboard ConfigMap in the monitoring namespace with Prometheus data source UID prometheus.

Build the receiver on the workstation and import it before syncing its deployment. Use the name of the local cluster in place of CLUSTER.

```bash
docker build -t ghcr.io/siiick-brain/diagnostics-receiver:main ops/receiver
k3d image import -c CLUSTER ghcr.io/siiick-brain/diagnostics-receiver:main
```

## MinIO credentials

Start the core profile before provisioning MinIO. Provision the two Kubernetes Secrets from SOPS and age encrypted YAML. Keep the age private key outside the repository. Generate the public recipient with age-keygen and save it as AGE_RECIPIENT in your shell. Keep the credential files referenced below outside the worktree with private permissions. Use one credential per file without a trailing newline.

```bash
set -o pipefail
mkdir -p ops/receiver/secrets

kubectl -n storage create secret generic minio-credentials \
  --from-file="root-user=$MINIO_ROOT_USER_FILE" \
  --from-file="root-password=$MINIO_ROOT_PASSWORD_FILE" \
  --dry-run=client -o yaml |
  sops encrypt --filename-override minio-credentials.yaml --age "$AGE_RECIPIENT"     --encrypted-regex '^data$' > ops/receiver/secrets/minio-credentials.sops.yaml

kubectl -n ops create secret generic diagnostics-minio \
  --from-file="access-key=$RECEIVER_ACCESS_KEY_FILE" \
  --from-file="secret-key=$RECEIVER_SECRET_KEY_FILE" \
  --dry-run=client -o yaml |
  sops encrypt --filename-override diagnostics-minio.yaml --age "$AGE_RECIPIENT"     --encrypted-regex '^data$' > ops/receiver/secrets/diagnostics-minio.sops.yaml

sops decrypt ops/receiver/secrets/minio-credentials.sops.yaml | kubectl apply -f -
sops decrypt ops/receiver/secrets/diagnostics-minio.sops.yaml | kubectl apply -f -
```

After the storage Secret exists, deploy MinIO with `kubectl apply -n storage -f clusters/storage/minio.yaml` or sync the MinIO Application. Once MinIO is ready, use the locally authenticated administrative alias lab to create the bucket and attach a write policy to the receiver identity. Provision the identity using the same credentials as diagnostics-minio.

```bash
mc mb --ignore-existing lab/diagnostics
mc admin policy create lab diagnostics-writer ops/receiver/diagnostics-policy.json
mc admin policy attach lab diagnostics-writer --user "$RECEIVER_ACCESS_KEY"
```

## Proof

```bash
promtool check rules alerts/app.rules.yaml
promtool test rules alerts/app.test.yaml
kubectl kustomize dashboards
kubectl -n demo get analysistemplate resilient-app-success -o yaml
```

After the memory experiment, inspect receiver logs and the archived object. After a bad canary, inspect its AnalysisRun and confirm that the stable revision retains traffic. Record the corresponding evidence under results/.

Apply the recommendation-only VPA against the Deployment after the recommender and metrics server are healthy. Capture deployment resource settings before and after the sampling window. Record the VPA status alongside them. Apply any chosen settings through the chart as a distinct experiment before rerunning the same chaos suite. The VPA itself leaves limits unchanged.

```bash
kubectl apply -f ops/receiver/vpa/recommendation.yaml
kubectl -n demo get deployment resilient-app -o yaml
kubectl -n demo get vpa resilient-app -o yaml
```
