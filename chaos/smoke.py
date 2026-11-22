import argparse
import subprocess
import time
import uuid
from pathlib import Path

from measure import CONTEXT, KUBECTL, MESH_KINDS, SCENARIOS
from measure import app_container, controller_uid, get_pods, get_work, mesh_manifest, mesh_status, pod_ready, timestamp

WORK_URL = "http://127.0.0.1:8080"
OBSERVATION_SECONDS = 60
DEMO = (*KUBECTL, "-n", "demo", "--request-timeout=10s")
COMMAND_ERRORS = (OSError, subprocess.SubprocessError)


def cli_error(error):
    stderr = getattr(error, "stderr", None)
    return stderr.decode(errors="replace").strip() if stderr else str(error)


def observe(args, resource, baseline, original_uids, log):
    target_uid = baseline["metadata"]["uid"]
    owner = controller_uid(baseline)
    initial_restarts = app_container(baseline)["restartCount"]
    applied = released = oom_killed = target_unready = False
    successful_probes = failed_probes = consecutive = 0
    deadline = time.monotonic() + OBSERVATION_SECONDS
    try:
        while time.monotonic() < deadline:
            injection, recovered = mesh_status(resource)
            if injection is not None and not applied:
                log(f"Controller Apply succeeded at {timestamp(injection)}")
                applied = True
            if recovered and not released:
                log("Controller reports fault recovered")
                released = True

            pods = get_pods()
            target = next((pod for pod in pods if pod["metadata"]["uid"] == target_uid), None)
            container = app_container(target)
            restarts = container.get("restartCount", 0)
            reason = container.get("lastState", {}).get("terminated", {}).get("reason")
            if restarts > initial_restarts and reason == "OOMKilled" and not oom_killed:
                log(f"Target app container reported OOMKilled, restart count {initial_restarts} -> {restarts}")
                oom_killed = True
            target_unready |= not pod_ready(target)

            if args.scenario == "crash":
                replacement = next((pod for pod in pods if pod["metadata"]["uid"] not in original_uids
                                    and controller_uid(pod) == owner and pod_ready(pod)), None)
                target_gone = target is None or target["metadata"].get("deletionTimestamp")
                ready = bool(target_gone and replacement)
            else:
                ready = released and pod_ready(target) and (args.scenario == "latency" or oom_killed)
            work_healthy = get_work(WORK_URL)
            if applied:
                successful_probes += work_healthy
                failed_probes += not work_healthy
            consecutive = consecutive + 1 if applied and ready and work_healthy else 0
            if consecutive == 3:
                if args.scenario == "crash":
                    name = replacement["metadata"]["name"]
                    uid = replacement["metadata"]["uid"]
                    log(f"Target pod removed and same-controller replacement ready, pod={name} uid={uid}")
                log("Three consecutive healthy ingress probes with the workload ready")
                return
            time.sleep(0.5)
    finally:
        log(f"Samples after controller confirmation, ingress healthy={successful_probes} "
            f"ingress failed={failed_probes}; original target unready or absent={target_unready}")

    raise RuntimeError("Observation expired before confirming injection and workload recovery")


def smoke(args, log):
    resource = (MESH_KINDS[args.scenario], f"resilient-app-smoke-{uuid.uuid4().hex}")
    log(f"Context={CONTEXT} namespace=demo target={args.pod} resource={'/'.join(resource)}")
    try:
        pods = get_pods()
        baseline = next((pod for pod in pods if pod["metadata"]["name"] == args.pod), None)
        if not pod_ready(baseline) or not app_container(baseline):
            raise RuntimeError("Start with the selected demo app pod ready")
        node = baseline.get("spec", {}).get("nodeName", "")
        if not node.startswith(f"{CONTEXT}-"):
            raise RuntimeError(f"Unexpected node for the local demo: {node}")
        if args.scenario == "crash" and controller_uid(baseline) is None:
            raise RuntimeError("PodChaos requires a workload-managed target")
        if not get_work(WORK_URL):
            raise RuntimeError(f"Baseline ingress unavailable at {WORK_URL}/work")
        log(f"Baseline ready, node={node} target_uid={baseline['metadata']['uid']} ingress healthy")
        manifest = mesh_manifest(args, resource[1])
    except (*COMMAND_ERRORS, RuntimeError) as error:
        log(f"FAIL before submitting the experiment: {cli_error(error)}")
        log("Fallback deferred until the local demo passes preflight")
        return 1

    cleaned = False
    passed = False
    try:
        created = subprocess.run([*DEMO, "create", "-f", "-"], input=manifest,
                                 capture_output=True, check=True, timeout=15)
        log(created.stdout.decode(errors="replace").strip())
        observe(args, resource, baseline, {pod["metadata"]["uid"] for pod in pods}, log)
        passed = True
    except (*COMMAND_ERRORS, RuntimeError, KeyboardInterrupt) as error:
        log(f"FAIL: {cli_error(error) or 'interrupted'}")
        try:
            details = subprocess.check_output([*DEMO, "describe", *resource], stderr=subprocess.STDOUT, timeout=12)
            log(details.decode(errors="replace").strip())
        except COMMAND_ERRORS:
            pass
    finally:
        try:
            subprocess.run([*DEMO, "delete", *resource, "--ignore-not-found", "--timeout=20s"],
                           capture_output=True, check=True, timeout=25)
            cleaned = True
            log("Cleanup confirmed")
        except COMMAND_ERRORS as error:
            log(f"Cleanup unverified: {cli_error(error)}")

    if not cleaned:
        log("FAIL: verify cleanup before starting another experiment or a fallback")
        return 2
    if passed:
        log("PASS: Chaos Mesh smoke verified")
        return 0
    log(f"Selected fallback: app-level POST /chaos/{args.scenario} through a ready pod's port-forward; "
        "fallback execution pending")
    return 1


def main():
    parser = argparse.ArgumentParser(description="Run one real Chaos Mesh smoke check in the local k3d demo")
    parser.add_argument("fault", choices=SCENARIOS.values())
    parser.add_argument("--pod", required=True, help="Ready resilient-app pod in the local demo namespace")
    args = parser.parse_args()
    args.scenario = next(scenario for scenario, fault in SCENARIOS.items() if fault == args.fault)
    path = Path(__file__).resolve().parents[1] / "results" / "chaos-smoke" / f"{args.fault}.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        def log(message):
            line = f"{timestamp(time.time())} {message}"
            print(line, file=stream, flush=True)
            print(line, flush=True)

        return smoke(args, log)


if __name__ == "__main__":
    raise SystemExit(main())
