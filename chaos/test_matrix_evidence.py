import datetime as dt
import gzip
import json
import tempfile
import unittest
from pathlib import Path

from matrix_evidence import QUOTAS, SCENARIOS, matrix_report


class MatrixEvidenceTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.addCleanup(scratch.cleanup)
        self.results = Path(scratch.name) / "chaos"
        self.results.mkdir()
        self.load = Path(scratch.name) / "load"
        self.start = dt.datetime(2026, 1, 1, tzinfo=dt.UTC)
        self.run_number = 0

    def write_trial(self, scenario="crash", config="A", *, outcome="recovered",
                    point_tag=None, rate=10, method="chaos-mesh", after=True):
        self.run_number += 1
        run_id = f"{self.run_number:032x}"
        start = self.start + dt.timedelta(minutes=self.run_number)
        end = start + dt.timedelta(seconds=2)
        detected = outcome == "recovered"
        recovered = outcome != "recovery_unobserved"
        row = {
            "scenario": scenario, "config": config, "run_id": run_id,
            "injected_at": start.isoformat(), "detected_at": start.isoformat() if detected else None,
            "restarted_at": None, "traffic_restored_at": end.isoformat() if detected else None,
            "detection_s": 0 if detected else None, "restart_s": None,
            "mttr_s": 2 if detected else None, "dropped_requests_pct": 0,
            "injection_type": method,
        }
        (self.results / f"{run_id}.json").write_text(json.dumps(row), encoding="utf-8")
        directory = self.load / run_id
        directory.mkdir(parents=True)
        metadata = {
            "run_id": run_id, "rate": rate, "duration_s": 120, "work_url": "http://127.0.0.1:8080",
            "window_end_at": end.isoformat(), "recovery_observed": recovered, "k6_exit_code": 0,
        }
        (directory / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        samples = [(-1, "http_req_failed", 1), (1, "http_req_failed", 1),
                   (1.1, "http_req_failed", 0), (1.2, "dropped_iterations", 2)]
        if after:
            samples.append((3, "http_req_failed", 1))
        with gzip.open(directory / "points.json.gz", "wt", encoding="utf-8") as stream:
            print(json.dumps({"type": "Metric", "metric": "http_req_failed"}), file=stream)
            for seconds, metric, value in samples:
                point = {
                    "type": "Point", "metric": metric, "data": {
                        "time": (start + dt.timedelta(seconds=seconds)).isoformat(), "value": value,
                        "tags": {"run_id": point_tag or run_id, "url": f'{metadata["work_url"]}/work'},
                    },
                }
                print(json.dumps(point), file=stream)
        return run_id

    def test_exact_matrix_and_observed_outcomes(self):
        for scenario in SCENARIOS:
            for config, count in QUOTAS.items():
                for index in range(count):
                    outcomes = ("no_detected_impact", "recovery_unobserved", "recovered")
                    method = "app-level" if scenario == "latency" else "chaos-mesh"
                    self.write_trial(scenario, config, outcome=outcomes[min(index, 2)], method=method)
        report = matrix_report(self.results, self.load)
        self.assertTrue(report["complete"], report["errors"])
        self.assertEqual(sum(cell["validated_runs"] for cell in report["cells"]), 180)
        for cell in report["cells"]:
            self.assertEqual(cell["k6_http_failed_pct"], 50)
            self.assertEqual(cell["k6_dropped_iterations"], 2 * cell["expected_runs"])
            self.assertEqual(cell["no_detected_impact_runs"], 1)
            self.assertEqual(cell["recovery_unobserved_runs"], 1)
            self.assertIsNone(cell["trials"][0]["mttr_s"])
            self.assertIsNone(cell["trials"][1]["mttr_s"])
            self.assertEqual(cell["median_mttr_s"], 2)

        self.write_trial()
        report = matrix_report(self.results, self.load)
        self.assertFalse(report["complete"])
        self.assertIn("crash/A: expected 10, found 11 rows and 11 with validated k6 evidence", report["errors"])

    def test_duplicate_mixed_method_and_incomparable_load(self):
        run_id = self.write_trial()
        self.write_trial(method="app-level", rate=11)
        (self.results / "copy.json").write_bytes((self.results / f"{run_id}.json").read_bytes())
        report = matrix_report(self.results, self.load)
        self.assertFalse(report["complete"])
        self.assertIn(f"copy.json: duplicate run_id {run_id}", report["errors"])
        self.assertIn("crash/A: mixed injection methods", report["errors"])
        self.assertIn("crash: load settings differ across trials or profiles", report["errors"])

    def test_hosted_method_is_required_even_in_a_uniform_cell(self):
        self.write_trial("latency", "A", method="app-level")
        self.write_trial("latency", "A2")
        self.write_trial("leak", "A", method="app-level")
        report = matrix_report(self.results, self.load)
        self.assertIn("latency/A2: expected app-level injection", report["errors"])
        self.assertIn("leak/A: expected chaos-mesh injection", report["errors"])
        self.assertFalse(any("mixed injection methods" in error for error in report["errors"]))

    def test_unreadable_gzip_leaves_trial_unvalidated(self):
        run_id = self.write_trial()
        path = self.load / run_id / "points.json.gz"
        path.write_bytes(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x07")
        report = matrix_report(self.results, self.load)
        self.assertEqual(report["cells"][0]["validated_runs"], 0)
        self.assertTrue(any(run_id in error and "invalid block type" in error for error in report["errors"]))

    def test_missing_or_uncorrelated_points_leave_trial_unvalidated(self):
        bad_id = self.write_trial(point_tag="wrong")
        early_id = self.write_trial(after=False)
        missing_id = self.write_trial()
        (self.load / missing_id / "metadata.json").unlink()
        report = matrix_report(self.results, self.load)
        self.assertEqual(report["cells"][0]["recorded_runs"], 3)
        self.assertEqual(report["cells"][0]["validated_runs"], 0)
        self.assertTrue(any(bad_id in error and "tag" in error for error in report["errors"]))
        self.assertTrue(any(early_id in error and "before, during, and after" in error for error in report["errors"]))
        self.assertTrue(any(missing_id in error and "metadata.json" in error for error in report["errors"]))


if __name__ == "__main__":
    unittest.main()
