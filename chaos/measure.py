import argparse
import csv
import datetime as dt
import json
import statistics
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event, Lock

CONTEXT = "k3d-self-healing"
KUBECTL = ("kubectl", "--context", CONTEXT)
SCENARIOS = {"crash": "pod", "latency": "network", "leak": "stress"}
MESH_KINDS = {"crash": "podchaos", "latency": "networkchaos", "leak": "stresschaos"}
LATENCY_SECONDS = 15


def get_work(base_url):
    try:
        with urllib.request.urlopen(f"{base_url}/work", timeout=1) as response:
            return response.status == 200
    except urllib.error.HTTPError as exc:
        exc.close()
        return False
    except (OSError, ValueError):
        return False


def get_pods():
    raw = subprocess.check_output(
        [*KUBECTL, "-n", "demo", "get", "pods", "-l", "app.kubernetes.io/name=resilient-app", "-o", "json"],
        timeout=5,
    )
    return json.loads(raw)["items"]


def pod_ready(pod):
    return pod is not None and not pod["metadata"].get("deletionTimestamp") and any(
        condition["type"] == "Ready" and condition["status"] == "True"
        for condition in pod.get("status", {}).get("conditions", [])
    )


def app_container(pod):
    statuses = pod.get("status", {}).get("containerStatuses", []) if pod else []
    return next((status for status in statuses if status["name"] == "app"), {})


def controller_uid(pod):
    return next((ref["uid"] for ref in pod["metadata"].get("ownerReferences", []) if ref.get("controller")), None)


def mesh_manifest(args, name):
    fixture = Path(__file__).with_name("experiments") / f"{args.scenario}.yaml"
    patch = {"metadata": {"name": name}, "spec": {"selector": {
        "labelSelectors": None, "pods": {"demo": [args.pod]},
    }}}
    return subprocess.check_output(
        [*KUBECTL, "patch", "--local", "-f", str(fixture), "--type=merge", "-p", json.dumps(patch), "-o", "json"],
        timeout=5,
    )


def mesh_status(resource):
    raw = subprocess.check_output([*KUBECTL, "-n", "demo", "get", *resource, "-o", "json"], timeout=5)
    status = json.loads(raw).get("status", {})
    records = status.get("experiment", {}).get("containerRecords", [])
    applied = [
        dt.datetime.fromisoformat(event["timestamp"]).timestamp()
        for record in records for event in record.get("events", [])
        if event["operation"] == "Apply" and event["type"] == "Succeeded" and event.get("timestamp")
    ]
    recovered = any(
        condition["type"] == "AllRecovered" and condition["status"] == "True"
        for condition in status.get("conditions", [])
    ) and any(record.get("recoveredCount", 0) > 0 for record in records)
    return min(applied, default=None), recovered


def app_control(args, action):
    request = urllib.request.Request(f"{args.control_url.rstrip('/')}/chaos/{action}", method="POST")
    with urllib.request.urlopen(request, timeout=5):
        return time.time()


def inject(args, manifest):
    if args.injection_type == "chaos-mesh":
        subprocess.run([*KUBECTL, "create", "-f", "-"], input=manifest, check=True, timeout=15)
        return None
    return app_control(args, args.scenario)


def timestamp(epoch):
    return None if epoch is None else dt.datetime.fromtimestamp(epoch, dt.UTC).isoformat()


def sample_work(args, stop, probes, lock, observed_at):
    while not stop.is_set():
        started = observed_at()
        healthy = get_work(args.work_url)
        with lock:
            probes.append((started, observed_at(), healthy))
        stop.wait(args.interval)


def measure(args, results, *, run_id=None, window_metadata=None):
    if run_id is not None and (len(run_id) != 32 or any(character not in "0123456789abcdef" for character in run_id)):
        raise ValueError("Run ID must be 32 lowercase hexadecimal characters")
    run_id = run_id or uuid.uuid4().hex
    if ((results / f"{run_id}.json").exists() or (results / f"{run_id}.csv").exists()
            or (window_metadata is not None and window_metadata.exists())):
        raise FileExistsError("Trial output already exists")

    initial_pods = get_pods()
    baseline = next((pod for pod in initial_pods if pod["metadata"]["name"] == args.pod), None)
    if not pod_ready(baseline) or not app_container(baseline):
        raise RuntimeError("Start with the selected demo app pod ready")
    if not get_work(args.work_url):
        raise RuntimeError("The baseline work endpoint is unavailable")

    mesh = args.injection_type == "chaos-mesh"
    replaces_pod = mesh and args.scenario == "crash"
    owner = controller_uid(baseline)
    if replaces_pod and owner is None:
        raise RuntimeError("Pod-kill requires a workload-managed target")
    original_uids = {pod["metadata"]["uid"] for pod in initial_pods}
    target_uid = baseline["metadata"]["uid"]
    initial_restarts = app_container(baseline)["restartCount"]
    resource = (MESH_KINDS[args.scenario], f"resilient-app-{run_id}")
    manifest = mesh_manifest(args, resource[1]) if mesh else None
    start_wall = time.time()
    start = time.monotonic()

    def observed_at():
        return start_wall + (time.monotonic() - start)

    injected = detected = restarted = recovered_at = eligible_since = None
    released = oom_killed = False
    processed = consecutive = 0
    probes = []
    stop = Event()
    lock = Lock()
    with ThreadPoolExecutor(max_workers=2) as executor:
        fault = executor.submit(inject, args, manifest)
        sampler = executor.submit(sample_work, args, stop, probes, lock, observed_at)
        try:
            while time.monotonic() - start < args.timeout:
                if not fault.done():
                    time.sleep(args.interval)
                    continue
                accepted = fault.result()
                if mesh:
                    applied, recovered = mesh_status(resource)
                    injected = injected if injected is not None else applied
                    released = injected is not None and (args.scenario == "crash" or recovered)
                else:
                    injected = accepted
                    if args.scenario == "latency" and not released and time.time() - injected >= LATENCY_SECONDS:
                        app_control(args, "reset")
                        released = True
                    elif args.scenario != "latency":
                        released = True
                if injected is None:
                    time.sleep(args.interval)
                    continue

                pods = get_pods()
                target = next((pod for pod in pods if pod["metadata"]["uid"] == target_uid), None)
                observed = observed_at()
                elapsed = max(0, observed - injected)

                container = app_container(target)
                container_restarted = container.get("restartCount", 0) > initial_restarts
                terminated = container.get("lastState", {}).get("terminated", {})
                oom_killed |= container_restarted and terminated.get("reason") == "OOMKilled"
                if detected is None and (not pod_ready(target) or container_restarted):
                    detected = elapsed

                current = target
                if replaces_pod and (target is None or target["metadata"].get("deletionTimestamp")):
                    current = next((pod for pod in pods if pod["metadata"]["uid"] not in original_uids
                                    and controller_uid(pod) == owner and pod_ready(pod)), None)
                    if current is not None and restarted is None:
                        restarted = elapsed
                elif container_restarted and "running" in container.get("state", {}) and restarted is None:
                    restarted = elapsed

                fault_observed = args.scenario == "latency" or restarted is not None
                if args.scenario == "leak":
                    fault_observed = fault_observed and oom_killed
                if released and pod_ready(current) and fault_observed:
                    if eligible_since is None:
                        eligible_since = observed
                else:
                    eligible_since = None
                    consecutive = 0

                with lock:
                    new_probes = probes[processed:]
                processed += len(new_probes)
                for probe_start, completed, healthy in new_probes:
                    if eligible_since is not None and probe_start >= eligible_since:
                        consecutive = consecutive + 1 if healthy else 0
                        if consecutive == args.recovery_samples:
                            recovered_at = completed
                            break
                if recovered_at is not None:
                    break
                time.sleep(args.interval)
        finally:
            finished_at = observed_at()
            stop.set()
            try:
                fault.result()
                sampler.result()
            finally:
                if mesh:
                    subprocess.run(
                        [*KUBECTL, "-n", "demo", "delete", *resource, "--ignore-not-found"],
                        check=True, timeout=20,
                    )
                elif (args.scenario == "latency" and not released) or (args.scenario == "leak" and restarted is None):
                    app_control(args, "reset")

    if injected is None:
        raise RuntimeError("Chaos Mesh did not confirm successful injection; no trial recorded")
    if args.scenario == "leak" and not oom_killed:
        raise RuntimeError("The targeted app container did not report OOMKilled; no trial recorded")

    window_end = recovered_at if recovered_at is not None else finished_at
    measured = [probe for probe in probes if injected <= probe[1] <= window_end]
    failures = [completed for _, completed, healthy in measured if not healthy]
    if failures:
        ingress_detection = failures[0] - injected
        detected = ingress_detection if detected is None else min(detected, ingress_detection)
    restored = recovered_at - injected if detected is not None and recovered_at is not None else None

    def observed(elapsed):
        return timestamp(injected + elapsed) if elapsed is not None else None

    row = {
        "scenario": args.scenario,
        "config": args.config,
        "run_id": run_id,
        "injected_at": timestamp(injected),
        "detected_at": observed(detected),
        "restarted_at": observed(restarted),
        "traffic_restored_at": observed(restored),
        "detection_s": detected,
        "restart_s": restarted,
        "mttr_s": restored,
        "dropped_requests_pct": 100 * len(failures) / len(measured) if measured else None,
        "injection_type": args.injection_type,
    }
    results.mkdir(parents=True, exist_ok=True)
    (results / f"{run_id}.json").write_text(json.dumps(row, indent=2) + "\n")
    with (results / f"{run_id}.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=row)
        writer.writeheader()
        writer.writerow(row)
    if window_metadata is not None:
        window = {
            "run_id": run_id,
            "window_end_at": timestamp(window_end),
            "recovery_observed": recovered_at is not None,
        }
        with window_metadata.open("x", encoding="utf-8") as stream:
            json.dump(window, stream, indent=2)
            stream.write("\n")
    print(json.dumps(row))


def summary(results):
    groups = {}
    for path in sorted(results.glob("*.json")):
        row = json.loads(path.read_text())
        groups.setdefault((row["scenario"], row["config"], row["injection_type"]), []).append(row)
    print("scenario,config,injection_type,runs,recovered,median_s,p95_s,mean_probe_dropped_pct")
    for key, rows in sorted(groups.items()):
        mttr = sorted(row["mttr_s"] for row in rows if row["mttr_s"] is not None)
        drops = [row["dropped_requests_pct"] for row in rows if row["dropped_requests_pct"] is not None]
        p95 = mttr[(95 * len(mttr) + 99) // 100 - 1] if mttr else ""
        print(*key, len(rows), len(mttr), statistics.median(mttr) if mttr else "",
              p95, statistics.mean(drops) if drops else "", sep=",")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", type=Path, default=Path("results/chaos"))
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("summary")
    run = commands.add_parser("run")
    run.add_argument("scenario", choices=SCENARIOS)
    run.add_argument("config", choices=("A", "A2", "B", "C"))
    run.add_argument("--injection-type", choices=("app-level", "chaos-mesh"), required=True)
    run.add_argument("--work-url", default="http://127.0.0.1:8080")
    run.add_argument("--control-url", default="http://127.0.0.1:18080")
    run.add_argument("--pod", required=True, help="Ready resilient-app pod in the local demo namespace")
    run.add_argument("--run-id", help="Use this ID to correlate the trial with its k6 capture")
    run.add_argument("--window-metadata", type=Path, help="Write the observed trial window to a separate JSON file")
    run.add_argument("--timeout", type=float, default=90)
    run.add_argument("--interval", type=float, default=0.25)
    run.add_argument("--recovery-samples", type=int, default=3)
    args = parser.parse_args()
    if args.command == "summary":
        summary(args.results)
        return

    if min(args.timeout, args.interval, args.recovery_samples) <= 0:
        parser.error("Timeout, interval and recovery samples must be positive")
    missing = [
        name for name in SCENARIOS.values()
        if subprocess.run(
            ["git", "cat-file", "-e", f"HEAD:results/chaos-smoke/{name}.txt"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0
    ]
    if missing:
        parser.error("Record the manual smoke tests first: " + ", ".join(missing))
    measure(args, args.results, run_id=args.run_id, window_metadata=args.window_metadata)


if __name__ == "__main__":
    main()
