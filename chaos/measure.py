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

CONTEXT = "k3d-self-healing"
KUBECTL = ("kubectl", "--context", CONTEXT)
SCENARIOS = {"crash": "pod", "latency": "network", "leak": "stress"}


def get_work(base_url):
    try:
        with urllib.request.urlopen(f"{base_url}/work", timeout=1) as response:
            return response.status == 200
    except urllib.error.HTTPError as exc:
        exc.close()
        return False
    except (OSError, ValueError):
        return False


def pod_state(name):
    raw = subprocess.check_output(
        [*KUBECTL, "-n", "demo", "get", "pod", name, "--ignore-not-found", "-o", "json"],
        timeout=5,
    )
    if not raw.strip():
        return None
    pod = json.loads(raw)
    if "containerStatuses" not in pod.get("status", {}):
        raise ValueError(f"Pod {name} has no container status")
    status = next(item for item in pod["status"]["containerStatuses"] if item["name"] == "app")
    ready = any(
        condition["type"] == "Ready" and condition["status"] == "True"
        for condition in pod["status"].get("conditions", [])
    )
    return pod["metadata"]["uid"], status["restartCount"], ready


def inject(args):
    if args.injection_type == "chaos-mesh":
        fixture = Path(__file__).with_name("experiments") / f"{args.scenario}.yaml"
        return subprocess.run([*KUBECTL, "apply", "-f", str(fixture)], check=True, timeout=15)
    request = urllib.request.Request(
        f"{args.control_url.rstrip('/')}/chaos/{args.scenario}", method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=5):
            pass
    except (ConnectionResetError, OSError) as exc:
        if args.scenario != "crash" or isinstance(exc, urllib.error.HTTPError):
            raise


def timestamp(epoch):
    return None if epoch is None else dt.datetime.fromtimestamp(epoch, dt.UTC).isoformat()


def measure(args, results):
    baseline = pod_state(args.pod) if args.pod else None
    if args.pod and (baseline is None or not baseline[2]):
        raise RuntimeError("Start with the selected pod ready")
    if not get_work(args.work_url):
        raise RuntimeError("The baseline work endpoint is unavailable")

    run_id = uuid.uuid4().hex
    start_wall = time.time()
    start = time.monotonic()
    detected = restarted = restored = None
    successes = attempts = consecutive = 0
    with ThreadPoolExecutor(max_workers=1) as executor:
        fault = executor.submit(inject, args)
        try:
            while time.monotonic() - start < args.timeout:
                healthy = get_work(args.work_url)
                state = pod_state(args.pod) if args.pod else None
                elapsed = time.monotonic() - start
                attempts += 1
                successes += healthy
                changed = baseline and (state is None or state[:2] != baseline[:2])
                if state and changed and restarted is None:
                    restarted = elapsed
                if detected is None and (not healthy or changed or (state and not state[2])):
                    detected = elapsed
                if detected is not None:
                    consecutive = consecutive + 1 if healthy else 0
                    if consecutive >= args.recovery_samples:
                        restored = elapsed
                        if fault.done():
                            break
                time.sleep(args.interval)
            fault.result(timeout=20)
        finally:
            if args.injection_type == "chaos-mesh":
                fixture = Path(__file__).with_name("experiments") / f"{args.scenario}.yaml"
                subprocess.run(
                    [*KUBECTL, "delete", "-f", str(fixture), "--ignore-not-found"],
                    check=True,
                    timeout=20,
                )
            elif args.scenario != "crash":
                reset = urllib.request.Request(f"{args.control_url.rstrip('/')}/chaos/reset", method="POST")
                try:
                    with urllib.request.urlopen(reset, timeout=5):
                        pass
                except OSError as exc:
                    print(f"Reset could not be confirmed: {exc}")

    def observed(elapsed):
        return timestamp(start_wall + elapsed) if elapsed is not None else None

    row = {
        "scenario": args.scenario,
        "config": args.config,
        "run_id": run_id,
        "injected_at": timestamp(start_wall),
        "detected_at": observed(detected),
        "restarted_at": observed(restarted),
        "traffic_restored_at": observed(restored),
        "detection_s": detected,
        "restart_s": restarted,
        "mttr_s": restored,
        "dropped_requests_pct": 100 * (attempts - successes) / attempts if attempts else None,
        "injection_type": args.injection_type,
    }
    results.mkdir(parents=True, exist_ok=True)
    (results / f"{run_id}.json").write_text(json.dumps(row, indent=2) + "\n")
    with (results / f"{run_id}.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=row)
        writer.writeheader()
        writer.writerow(row)
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
    run.add_argument("--pod")
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
    measure(args, args.results)


if __name__ == "__main__":
    main()
