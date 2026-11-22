"""Capture before and after evidence for the k3d recommendation-only VPA."""

import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

CONTEXT = "k3d-self-healing"
APP = "resilient-app"
SELECTOR = f"app.kubernetes.io/name={APP},app.kubernetes.io/instance={APP}"
TARGET = {"apiVersion": "apps/v1", "kind": "Deployment", "name": APP}


def kubectl(*args):
    command = ["kubectl", "--context", CONTEXT, "--request-timeout=10s", *args, "-o", "json"]
    return json.loads(subprocess.check_output(command, timeout=15))


def require_local_cluster():
    config = kubectl("config", "view", "--minify")
    server = urlsplit(config["clusters"][0]["cluster"]["server"])
    if server.scheme != "https" or server.hostname not in {"127.0.0.1", "localhost", "::1", "0.0.0.0"}:
        raise RuntimeError(f"Expected a local API server for {CONTEXT}.")
    nodes = kubectl("get", "nodes")["items"]
    if not nodes or any(not node["metadata"]["name"].startswith(f"{CONTEXT}-") for node in nodes):
        raise RuntimeError(f"Expected only nodes from {CONTEXT}.")


def get(*args):
    return kubectl("-n", "demo", "get", *args)


def vpa_state():
    vpa = get(f"verticalpodautoscaler/{APP}")
    policy = vpa["spec"]
    if policy["updatePolicy"]["updateMode"] != "Off" or policy["targetRef"] != TARGET:
        raise RuntimeError("The VPA must target the demo Deployment with updateMode Off.")
    recommendations = vpa.get("status", {}).get("recommendation", {}).get("containerRecommendations", [])
    recommendation = next((entry for entry in recommendations if entry["containerName"] == "app"), None)
    return {
        "uid": vpa["metadata"]["uid"],
        "policy": policy,
        "recommendation": recommendation,
    }


def resources(spec):
    app = next((item for item in spec["containers"] if item["name"] == "app"), {})
    values = app.get("resources", {})
    if any(not values.get(group, {}).get(kind) for group in ("requests", "limits") for kind in ("cpu", "memory")):
        raise RuntimeError("Expected app CPU and memory requests and limits.")
    return values


def snapshot(deadline, require_recommendation):
    while time.monotonic() < deadline:
        vpa = vpa_state()
        target = (vpa["recommendation"] or {}).get("target", {})
        if not require_recommendation or (target.get("cpu") and target.get("memory")):
            deployment = get(f"deployment/{APP}")
            active = [pod for pod in get("pods", "-l", SELECTOR)["items"] if not pod["metadata"].get("deletionTimestamp")]
            expected = deployment["spec"]["replicas"]
            ready = [
                pod for pod in active if any(
                    condition["type"] == "Ready" and condition["status"] == "True"
                    for condition in pod.get("status", {}).get("conditions", [])
                )
            ]
            if expected > 0 and len(active) == len(ready) == expected:
                return {
                    "captured_at_utc": datetime.now(timezone.utc).isoformat(),
                    "vpa": vpa,
                    "deployment_uid": deployment["metadata"]["uid"],
                    "deployment_resources": resources(deployment["spec"]["template"]["spec"]),
                    "pods": {pod["metadata"]["name"]: resources(pod["spec"]) for pod in ready},
                }
        time.sleep(5)
    missing = "a recommendation and ready app pods" if require_recommendation else "ready app pods"
    raise RuntimeError(f"Timed out waiting for {missing}.")


def check_resources(evidence):
    if any(values != evidence["deployment_resources"] for values in evidence["pods"].values()):
        raise RuntimeError("Observed pod resources differ from the Deployment template.")


def write_evidence(path, evidence):
    with path.open("x", encoding="utf-8") as output:
        json.dump(evidence, output, indent=2, sort_keys=True)
        output.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("before", "after"))
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    try:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        path = args.output_dir / f"{args.phase}.json"
        recommendation = args.output_dir / "recommendation.json"
        if path.exists():
            raise RuntimeError(f"Evidence already exists at {path}.")
        require_local_cluster()

        if args.phase == "before":
            if recommendation.exists():
                raise RuntimeError(f"Evidence already exists at {recommendation}.")
            before = snapshot(time.monotonic() + 90, require_recommendation=False)
            write_evidence(path, before)
            check_resources(before)
            evidence = snapshot(time.monotonic() + 180, require_recommendation=True)
        else:
            before = json.loads((args.output_dir / "before.json").read_text(encoding="utf-8"))
            if not recommendation.is_file():
                raise RuntimeError("Run the before phase successfully before the fault smoke.")
            evidence = snapshot(time.monotonic() + 90, require_recommendation=True)
            write_evidence(path, evidence)

        check_resources(before)
        check_resources(evidence)
        if (before["deployment_uid"] != evidence["deployment_uid"]
                or before["vpa"]["uid"] != evidence["vpa"]["uid"]
                or before["vpa"]["policy"] != evidence["vpa"]["policy"]
                or before["deployment_resources"] != evidence["deployment_resources"]):
            raise RuntimeError("The Deployment, VPA policy or configured app resources changed between captures.")
        if args.phase == "before":
            write_evidence(recommendation, evidence)
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"VPA evidence failed: {error}\n")

    print(f"VPA mode Off, observed pod and Deployment requests and limits match ({args.phase}).")
    print(f"Recorded evidence to {path}.")


if __name__ == "__main__":
    main()
