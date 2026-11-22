#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

[[ ${GITHUB_ACTIONS:-} == true && $OSTYPE == linux-gnu* ]] || {
  echo 'This check requires a disposable Linux CI runner.' >&2
  exit 2
}

kube=(kubectl --context k3d-self-healing --request-timeout=15s)
server=$("${kube[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ $server =~ ^https://(127\.0\.0\.1|localhost|0\.0\.0\.0):[0-9]+$ ]] || {
  echo 'Expected a local k3d API server.' >&2
  exit 2
}

image=ghcr.io/siiick-brain/diagnostics-receiver:main
mode=${1:?Use prepare, provision or archive.}
case "$mode" in
  prepare)
    docker build -t "$image" ops/receiver
    k3d image import -c self-healing "$image"
    root_user=$(openssl rand -hex 12)
    root_password=$(openssl rand -hex 24)
    writer_user=$(openssl rand -hex 12)
    writer_password=$(openssl rand -hex 24)
    printf '::add-mask::%s\n' "$root_user" "$root_password" "$writer_user" "$writer_password"
    "${kube[@]}" -n storage create secret generic minio-credentials \
      --from-literal=root-user="$root_user" --from-literal=root-password="$root_password"
    "${kube[@]}" -n ops create secret generic diagnostics-minio \
      --from-literal=access-key="$writer_user" --from-literal=secret-key="$writer_password"
    exit 0
    ;;
  archive)
    [[ ${2:-} =~ ^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$ ]] || {
      echo 'Expected the UID of the OOM-killed pod.' >&2
      exit 2
    }
    ;;
  provision) ;;
  *) echo "Unknown diagnostics step: $mode" >&2; exit 2 ;;
esac

root_user=$("${kube[@]}" -n storage get secret minio-credentials -o jsonpath='{.data.root-user}' | base64 -d)
root_password=$("${kube[@]}" -n storage get secret minio-credentials -o jsonpath='{.data.root-password}' | base64 -d)
tmp=$(mktemp -d)
forward_pid=
cleanup() {
  if [[ -n $forward_pid ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT

endpoint=http://127.0.0.1:19000
kubectl --context k3d-self-healing -n storage port-forward --address 127.0.0.1 service/minio 19000:9000 >"$tmp/forward.log" 2>&1 &
forward_pid=$!
curl -fsS --retry 12 --retry-connrefused --retry-delay 1 --max-time 3 \
  "$endpoint/minio/health/ready" >/dev/null || { cat "$tmp/forward.log" >&2; exit 1; }

if [[ $mode == provision ]]; then
  release=RELEASE.2025-08-13T08-35-41Z
  curl -fsSLo "$tmp/mc" "https://github.com/minio/mc/releases/download/$release/mc.linux-amd64.$release"
  printf '%s  %s\n' '01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891' "$tmp/mc" |
    sha256sum --check --strict
  chmod +x "$tmp/mc"
  mc=("$tmp/mc" --config-dir "$tmp/config")
  export MC_HOST_lab="http://$root_user:$root_password@127.0.0.1:19000"
  writer_user=$("${kube[@]}" -n ops get secret diagnostics-minio -o jsonpath='{.data.access-key}' | base64 -d)
  writer_password=$("${kube[@]}" -n ops get secret diagnostics-minio -o jsonpath='{.data.secret-key}' | base64 -d)

  "${mc[@]}" mb --ignore-existing lab/diagnostics
  "${mc[@]}" admin user add lab "$writer_user" "$writer_password" >/dev/null
  "${mc[@]}" admin policy create lab diagnostics-writer ops/receiver/diagnostics-policy.json
  "${mc[@]}" admin policy attach lab diagnostics-writer --user "$writer_user" >/dev/null

  object=diagnostics/oom/ci/storage-smoke
  printf 'diagnostics storage smoke\n' >"$tmp/proof.txt"
  writer=(curl -sS --max-time 10 --aws-sigv4 'aws:amz:us-east-1:s3' --user "$writer_user:$writer_password")
  "${writer[@]}" --fail --upload-file "$tmp/proof.txt" "$endpoint/$object" >/dev/null
  status=$("${writer[@]}" --output /dev/null --write-out '%{http_code}' "$endpoint/$object")
  [[ $status == 403 ]] || { echo "Expected writer reads to be denied, got HTTP $status." >&2; exit 1; }
  "${mc[@]}" cat "lab/$object" | cmp "$tmp/proof.txt" -
  "${mc[@]}" rm "lab/$object"
  echo 'Receiver credentials can write under oom/ and are denied reads. Runner credentials verified the object.'
  exit 0
fi

# Use the runner's copy of the receiver image for its pinned boto3 dependency.
export AWS_ACCESS_KEY_ID=$root_user AWS_SECRET_ACCESS_KEY=$root_password
docker run --rm -i --network host --entrypoint python \
  --env AWS_ACCESS_KEY_ID --env AWS_SECRET_ACCESS_KEY "$image" - "$endpoint" "$2" <<'PY'
import gzip
import json
import sys
import time

import boto3
from botocore.config import Config

endpoint, uid = sys.argv[1:]
s3 = boto3.client(
    "s3", endpoint_url=endpoint, region_name="us-east-1",
    config=Config(s3={"addressing_style": "path"}, connect_timeout=5, read_timeout=10),
)
bucket = "diagnostics"
deadline = time.monotonic() + 100
while time.monotonic() < deadline:
    objects = s3.list_objects_v2(Bucket=bucket, Prefix=f"oom/{uid}/").get("Contents", [])
    if objects:
        key = objects[0]["Key"]
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        record = json.loads(gzip.decompress(body))
        assert record["pod_uid"] == uid and record["termination"]["reason"] == "OOMKilled"
        assert isinstance(record["previous_logs"], str) and isinstance(record["events"], list)
        print(json.dumps({
            "object": key,
            "pod_uid": uid,
            "termination_reason": "OOMKilled",
            "previous_log_bytes": len(record["previous_logs"].encode()),
            "events_recorded": len(record["events"]),
        }))
        break
    time.sleep(4)
else:
    raise SystemExit("No receiver archive matched the OOM-killed pod.")
PY
