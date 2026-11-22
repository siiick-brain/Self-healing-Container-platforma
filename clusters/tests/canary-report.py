import json
import sys
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main(directory):
    timing = json.loads((directory / "timing.json").read_text())
    requested, aborted, stable = (
        instant(timing[key]) for key in ("requested_at", "aborted_at", "stable_ready_at")
    )
    if not requested < aborted <= stable:
        raise ValueError("Canary timestamps are out of order.")
    if not 0 <= timing["measured_canary_success_ratio"] < 0.995:
        raise ValueError("Expected a measured success ratio below the rollout threshold.")

    before, during, after = Counter(), Counter(), Counter()
    with (directory / "load.ndjson").open() as load:
        for line in load:
            point = json.loads(line)
            if point.get("type") != "Point" or point.get("metric") != "canary_requests":
                continue
            data = point["data"]
            release = data["tags"]["release"]
            if data["value"] != 1 or release not in {"stable", "bad", "other"}:
                raise ValueError("Unexpected request sample.")
            when = instant(data["time"])
            if when < requested:
                before[release] += 1
            elif when <= aborted:
                during[release] += 1
            elif when >= stable + timedelta(seconds=5):
                after[release] += 1

    if before["stable"] < 20 or before["bad"] or before["other"]:
        raise ValueError("Expected a healthy baseline with at least 20 requests.")
    if during["bad"] == 0 or during["stable"] == 0:
        raise ValueError("Expected bad and stable responses before controller abort.")
    if after["stable"] < 20 or after["bad"] or after["other"]:
        raise ValueError("Expected at least 20 stable requests and no failures after recovery.")

    total = sum(during.values())
    report = {
        **timing,
        "time_to_abort_s": round((aborted - requested).total_seconds(), 3),
        "requests_before_abort": total,
        "bad_version_requests_before_abort": during["bad"],
        "bad_version_request_share_pct": round(100 * during["bad"] / total, 3),
        "other_outcomes_before_abort": during["other"],
        "healthy_requests_at_baseline": before["stable"],
        "healthy_requests_after_recovery": after["stable"],
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
