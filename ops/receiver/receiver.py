import gzip
import hashlib
import http.client
import json
import logging
import os
import re
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

SERVICE_ACCOUNT = Path("/var/run/secrets/kubernetes.io/serviceaccount")
NAMESPACE = "demo"
MAX_BODY = 256 * 1024
MAX_LOG = 1024 * 1024
LOG = logging.getLogger(__name__)


def kube(path, *, method="GET", data=None, max_size=4 * MAX_LOG):
    token = (SERVICE_ACCOUNT / "token").read_text().strip()
    context = ssl.create_default_context(cafile=SERVICE_ACCOUNT / "ca.crt")
    request = Request(
        f"https://kubernetes.default.svc/api/v1/namespaces/{NAMESPACE}/{path}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method=method,
    )
    with urlopen(request, context=context, timeout=5) as response:
        content = response.read(max_size + 1)
    if len(content) > max_size:
        raise ValueError("Kubernetes response exceeds limit")
    return content


def collect(labels):
    pod = labels.get("pod", "")
    container = labels.get("container", "")
    if not all(isinstance(name, str) and re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", name) for name in (pod, container)):
        return
    pod_data = json.loads(kube(f"pods/{pod}"))
    uid = pod_data["metadata"]["uid"]
    if labels.get("uid") and labels["uid"] != uid:
        return

    statuses = pod_data.get("status", {}).get("containerStatuses", [])
    state = next((item for item in statuses if item["name"] == container), {})
    terminated = state.get("lastState", {}).get("terminated") or state.get("state", {}).get("terminated")
    if not terminated or terminated.get("reason") != "OOMKilled":
        return

    log_params = urlencode({"container": container, "previous": "true", "limitBytes": MAX_LOG})
    try:
        previous_logs = kube(f"pods/{pod}/log?{log_params}", max_size=MAX_LOG).decode(errors="replace")
        log_error = None
    except HTTPError as error:
        if error.code not in (400, 404):
            raise
        previous_logs = None
        log_error = f"Kubernetes returned HTTP {error.code} for previous logs"

    event_params = urlencode({"fieldSelector": f"involvedObject.uid={uid}", "limit": 100})
    events = json.loads(kube(f"events?{event_params}"))
    return {
        "namespace": NAMESPACE,
        "pod": pod,
        "pod_uid": uid,
        "container": container,
        "termination": terminated,
        "restart_count": state.get("restartCount"),
        "previous_logs": previous_logs,
        "previous_logs_error": log_error,
        "events": events.get("items", []),
        "events_truncated": bool(events.get("metadata", {}).get("continue")),
    }


def archive(alerts):
    s3 = None
    for alert in alerts:
        if not isinstance(alert, dict) or alert.get("status") != "firing":
            continue
        labels = alert.get("labels", {})
        if not isinstance(labels, dict) or labels.get("alertname") != "PodOOMKilled" or labels.get("namespace") != NAMESPACE:
            continue
        try:
            diagnostics = collect(labels)
        except HTTPError as error:
            if error.code == 404:
                LOG.info("Pod disappeared before diagnostics could be collected")
                continue
            raise
        if diagnostics is None:
            continue
        if s3 is None:
            s3 = boto3.client(
                "s3",
                endpoint_url=os.getenv("MINIO_ENDPOINT", "http://minio.storage.svc:9000"),
                region_name="us-east-1",
                config=Config(s3={"addressing_style": "path"}, connect_timeout=5, read_timeout=10),
            )
        identity = json.dumps(diagnostics["termination"], sort_keys=True).encode()
        key = f"oom/{diagnostics['pod_uid']}/{diagnostics['container']}/{hashlib.sha256(identity).hexdigest()}.json.gz"
        s3.put_object(
            Bucket=os.getenv("DIAGNOSTICS_BUCKET", "diagnostics"),
            Key=key,
            Body=gzip.compress(json.dumps(diagnostics).encode()),
            ContentType="application/json",
            ContentEncoding="gzip",
        )
        LOG.info("Archived %s", key)


def purge_evicted():
    cursor = ""
    while True:
        query = urlencode({"fieldSelector": "status.phase=Failed", "limit": 100, "continue": cursor})
        page = json.loads(kube(f"pods?{query}"))
        for pod in page["items"]:
            if pod.get("status", {}).get("reason") != "Evicted":
                continue
            metadata = pod["metadata"]
            try:
                kube(
                    f"pods/{metadata['name']}",
                    method="DELETE",
                    data={"preconditions": {"uid": metadata["uid"]}},
                )
            except HTTPError as error:
                if error.code not in (404, 409):
                    raise
        cursor = page.get("metadata", {}).get("continue", "")
        if not cursor:
            return


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(15)
        super().setup()

    def do_GET(self):
        self.send_response(200 if self.path == "/healthz" else 404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/alerts":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                self.send_error(413)
                return
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict) or not isinstance(payload.get("alerts"), list):
                raise ValueError("missing alerts")
        except (ValueError, OSError, http.client.HTTPException):
            self.send_error(400)
            return
        try:
            archive(payload["alerts"])
        except (OSError, BotoCoreError, ClientError, ValueError):
            LOG.exception("Could not archive diagnostics")
            self.send_error(503)
            return
        self.send_response(204)
        self.end_headers()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    if sys.argv[1:] == ["purge-evicted"]:
        purge_evicted()
    else:
        with ThreadingHTTPServer(("0.0.0.0", 8080), Handler) as server:
            server.serve_forever()
