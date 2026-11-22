import argparse
import subprocess
import unittest
from itertools import chain, repeat
from unittest.mock import MagicMock, patch

import smoke
from test_measure import pod


class SmokeTest(unittest.TestCase):
    def setUp(self):
        self.baseline = pod()
        self.baseline["spec"] = {"nodeName": "k3d-self-healing-agent-0"}
        self.logs = []

    def test_pass_requires_controller_and_scenario_evidence_before_cleanup(self):
        restarted = pod()
        restarted["status"]["containerStatuses"][0].update(
            restartCount=1, lastState={"terminated": {"reason": "OOMKilled"}},
        )
        for scenario, subsequent_pod, proof in [
            ("crash", pod("replacement"), "same-controller replacement ready"),
            ("latency", self.baseline, "Controller reports fault recovered"),
            ("leak", restarted, "Target app container reported OOMKilled"),
        ]:
            with self.subTest(scenario=scenario):
                self.logs.clear()
                with (patch("smoke.get_pods", side_effect=chain([[self.baseline]], repeat([subsequent_pod]))),
                      patch("smoke.mesh_manifest", return_value=b"{}"),
                      patch("smoke.mesh_status", return_value=(1_700_000_000, scenario != "crash")),
                      patch("smoke.get_work", return_value=True), patch("smoke.time.sleep"),
                      patch("smoke.subprocess.run", return_value=subprocess.CompletedProcess([], 0, b"")) as run):
                    self.assertEqual(smoke.smoke(argparse.Namespace(scenario=scenario, pod="target"),
                                                 self.logs.append), 0)

                self.assertIn(proof, "\n".join(self.logs))
                self.assertEqual(self.logs[-2:], ["Cleanup confirmed", "PASS: Chaos Mesh smoke verified"])
                self.assertIn("create", run.call_args_list[0].args[0])
                self.assertIn("delete", run.call_args_list[1].args[0])

    def test_app_latency_measures_delay_and_resets_the_same_target(self):
        reply = MagicMock()
        reply.__enter__.return_value.status = 200
        inputs = argparse.Namespace(scenario="latency", pod="target", control_url="http://127.0.0.1:18080")
        with (patch("smoke.get_pods", return_value=[self.baseline]),
              patch("smoke.get_work", return_value=True),
              patch("smoke.app_control") as control,
              patch("smoke.urllib.request.urlopen", return_value=reply),
              patch("smoke.time.monotonic", side_effect=[100, 101.5]),
              patch("smoke.mesh_manifest") as mesh):
            self.assertEqual(smoke.smoke(inputs, self.logs.append, app_latency=True), 0)
        self.assertEqual([entry.args[1] for entry in control.call_args_list], ["latency", "reset"])
        self.assertEqual(self.logs[-2:], ["Cleanup confirmed", "PASS: App-level latency smoke verified"])
        mesh.assert_not_called()

    def test_cleanup_failure_blocks_fallback(self):
        with (patch("smoke.get_pods", return_value=[self.baseline]),
              patch("smoke.mesh_manifest", return_value=b"{}"), patch("smoke.get_work", return_value=True),
              patch("smoke.observe", side_effect=RuntimeError("no controller evidence")),
              patch("smoke.subprocess.check_output", return_value=b""),
              patch("smoke.subprocess.run", side_effect=[
                  subprocess.CompletedProcess([], 0, b""), subprocess.TimeoutExpired("delete", 25),
              ])):
            self.assertEqual(smoke.smoke(argparse.Namespace(scenario="latency", pod="target"),
                                         self.logs.append), 2)

        self.assertIn("Cleanup unverified", "\n".join(self.logs))
        self.assertNotIn("Selected fallback", "\n".join(self.logs))


if __name__ == "__main__":
    unittest.main()
