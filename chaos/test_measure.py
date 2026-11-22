import argparse
import http.server
import json
import tempfile
import threading
import time
import unittest
from itertools import chain, repeat
from pathlib import Path
from unittest.mock import patch

from measure import measure


def pod(name="target", ready=True, owner="replica-set"):
    return {
        "metadata": {"name": name, "uid": name, "ownerReferences": [{"uid": owner, "controller": True}]},
        "status": {
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
            "containerStatuses": [{"name": "app", "restartCount": 0}],
        },
    }


def args_for(scenario="latency", injection_type="chaos-mesh", **options):
    params = dict(scenario=scenario, config="B", injection_type=injection_type,
                  work_url="http://127.0.0.1:8080", control_url="http://127.0.0.1:18080", pod="target",
                  timeout=4, interval=0.01, recovery_samples=2)
    return argparse.Namespace(**(params | options))


class Server(http.server.BaseHTTPRequestHandler):
    remaining_failures = 0

    def do_GET(self):
        if self.server.remaining_failures:
            self.server.remaining_failures -= 1
            self.send_response(503)
        else:
            self.send_response(200)
        self.end_headers()

    def do_POST(self):
        if self.path == "/chaos/latency":
            self.server.remaining_failures = 4
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_args):
        pass


class MeasurementTest(unittest.TestCase):
    def test_record_fault_and_recovery(self):
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server) as server:
            server.remaining_failures = 0
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}"
                args = args_for(injection_type="app-level", work_url=url, control_url=url)
                with (tempfile.TemporaryDirectory() as path,
                      patch("measure.get_pods", return_value=[pod()]), patch("measure.LATENCY_SECONDS", 0.05)):
                    results = Path(path)
                    measure(args, results)
                    row = json.loads(next(results.glob("*.json")).read_text())
                    schema = json.loads(Path(__file__).with_name("schema.json").read_text())
                    self.assertEqual(set(row), set(schema["required"]))
                    self.assertEqual(row["injection_type"], "app-level")
                    self.assertGreater(row["mttr_s"], row["detection_s"])
                    self.assertGreater(row["dropped_requests_pct"], 0)
                    self.assertIsNone(row["restart_s"])
                    self.assertTrue(next(results.glob("*.csv")).is_file())
            finally:
                server.shutdown()
                thread.join()

    def test_mesh_waits_for_fault_release_and_target_readiness(self):
        ready, unready = [pod()], [pod(ready=False)]
        applied_at = time.time()
        with (tempfile.TemporaryDirectory() as path, patch("measure.mesh_manifest", return_value=b"{}"),
              patch("measure.subprocess.run") as kubectl, patch("measure.get_work", return_value=True),
              patch("measure.mesh_status", side_effect=chain([(applied_at, False)] * 4, repeat((applied_at, True)))),
              patch("measure.get_pods", side_effect=chain([ready, unready, ready, ready, ready, unready], repeat(ready))) as pods):
            results = Path(path)
            run_id = "a" * 32
            metadata = results / "observed-window"
            measure(args_for(), results, run_id=run_id, window_metadata=metadata)
            row = json.loads((results / f"{run_id}.json").read_text())
            window = json.loads(metadata.read_text())
            self.assertEqual(window["run_id"], row["run_id"])
            self.assertEqual(window["window_end_at"], row["traffic_restored_at"])
            self.assertTrue(window["recovery_observed"])
            with self.assertRaisesRegex(FileExistsError, "Trial output already exists"):
                measure(args_for(), results, run_id=run_id, window_metadata=metadata)
            self.assertGreaterEqual(pods.call_count, 8)
            self.assertEqual(row["dropped_requests_pct"], 0)
            self.assertGreater(row["mttr_s"], row["detection_s"])
            create, delete = [call.args[0] for call in kubectl.call_args_list]
            self.assertIn("create", create)
            self.assertIn("delete", delete)

    def test_mesh_submission_without_controller_injection_produces_no_trial(self):
        with (tempfile.TemporaryDirectory() as path, patch("measure.mesh_manifest", return_value=b"{}"),
              patch("measure.subprocess.run") as kubectl, patch("measure.get_work", return_value=True),
              patch("measure.mesh_status", return_value=(None, False)), patch("measure.get_pods", return_value=[pod()])):
            results = Path(path)
            with self.assertRaisesRegex(RuntimeError, "did not confirm successful injection"):
                measure(args_for(timeout=0.05), results)
            self.assertEqual(list(results.iterdir()), [])
            self.assertIn("delete", kubectl.call_args.args[0])

    def test_mesh_classifies_ingress_outage_before_injection_confirmation(self):
        for after_injection in (True, False):
            with self.subTest(after_injection=after_injection):
                start_outage = threading.Event()
                recovered = threading.Event()
                failed = False
                applied_at = None

                def work(_url):
                    nonlocal failed
                    if start_outage.is_set():
                        if not failed:
                            failed = True
                            return False
                        recovered.set()
                    return True

                def status(_resource):
                    nonlocal applied_at
                    if applied_at is None:
                        before_outage = time.time()
                        start_outage.set()
                        self.assertTrue(recovered.wait(timeout=1), "Probes stopped while awaiting Mesh confirmation")
                        applied_at = before_outage if after_injection else time.time()
                    return applied_at, True

                with (tempfile.TemporaryDirectory() as path, patch("measure.mesh_manifest", return_value=b"{}"),
                      patch("measure.subprocess.run"), patch("measure.get_work", side_effect=work),
                      patch("measure.mesh_status", side_effect=status), patch("measure.get_pods", return_value=[pod()])):
                    results = Path(path)
                    measure(args_for(), results)
                    row = json.loads(next(results.glob("*.json")).read_text())
                    if after_injection:
                        self.assertGreater(row["dropped_requests_pct"], 0)
                        self.assertGreater(row["mttr_s"], row["detection_s"])
                    else:
                        self.assertEqual(row["dropped_requests_pct"], 0)
                        self.assertIsNone(row["detection_s"])

    def test_pod_kill_tracks_replacement_from_the_same_controller(self):
        applied_at = time.time()
        other_pods = [pod("existing"), pod("other-revision", owner="other-replica-set")]
        snapshots = [
            [pod(), *other_pods], other_pods,
            [*other_pods, pod("replacement", ready=False)],
            [*other_pods, pod("replacement")], [*other_pods, pod("replacement")],
        ]
        with (tempfile.TemporaryDirectory() as path, patch("measure.mesh_manifest", return_value=b"{}"),
              patch("measure.subprocess.run"), patch("measure.get_work", return_value=True),
              patch("measure.mesh_status", return_value=(applied_at, False)),
              patch("measure.get_pods", side_effect=chain(snapshots, repeat(snapshots[-1]))) as pods):
            results = Path(path)
            measure(args_for(scenario="crash"), results)
            row = json.loads(next(results.glob("*.json")).read_text())
            self.assertGreaterEqual(pods.call_count, 5)
            self.assertGreater(row["restart_s"], row["detection_s"])
            self.assertGreater(row["mttr_s"], row["restart_s"])


if __name__ == "__main__":
    unittest.main()
