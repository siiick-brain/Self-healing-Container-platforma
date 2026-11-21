import argparse
import http.server
import json
import tempfile
import threading
import unittest
from pathlib import Path

from measure import measure


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
                args = argparse.Namespace(
                    scenario="latency", config="B", injection_type="app-level",
                    work_url=url, control_url=url, pod=None, timeout=4,
                    interval=0.01, recovery_samples=2,
                )
                with tempfile.TemporaryDirectory() as path:
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


if __name__ == "__main__":
    unittest.main()
