"""Validate tagged k6 evidence and report on the hosted fault matrix."""

import argparse
import datetime as dt
import gzip
import json
import math
import re
import statistics
import zlib
from pathlib import Path
from urllib.parse import urlsplit


EXPECTED_METHODS = {"crash": "chaos-mesh", "latency": "app-level", "leak": "chaos-mesh"}
SCENARIOS = tuple(EXPECTED_METHODS)
QUOTAS = {"A": 10, "A2": 10, "B": 20, "C": 20}
METHODS = set(EXPECTED_METHODS.values())


def read_object(path):
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("expected an ISO 8601 timestamp")
    parsed = dt.datetime.fromisoformat(value)
    if parsed.utcoffset() is None:
        raise ValueError("expected a timestamp with a UTC offset")
    return parsed


def k6_window(directory, run_id, endpoint, start, end):
    plain = directory / "points.json"
    compressed = directory / "points.json.gz"
    if plain.exists() == compressed.exists():
        raise ValueError("expected exactly one of points.json and points.json.gz")

    opened = plain.open("rt", encoding="utf-8") if plain.exists() else gzip.open(compressed, "rt", encoding="utf-8")
    first = last = None
    requests = failures = drops = 0
    with opened as points:
        for line_number, line in enumerate(points, 1):
            try:
                point = json.loads(line)
                if point["type"] == "Metric":
                    continue
                if point["type"] != "Point":
                    raise ValueError("expected a k6 Metric or Point")
                if point["metric"] not in ("http_req_failed", "dropped_iterations"):
                    continue
                data = point["data"]
                tags = data["tags"]
                if tags.get("run_id") != run_id:
                    raise ValueError("missing or mismatched run_id tag")
                observed = timestamp(data["time"])
                value = data["value"]
                is_request = point["metric"] == "http_req_failed"
                if type(value) not in (int, float):
                    raise ValueError("expected a numeric sample value")
                if is_request:
                    if tags.get("url") != endpoint:
                        raise ValueError("request URL does not match recorded work endpoint")
                    if value not in (0, 1):
                        raise ValueError("expected an HTTP failure sample of 0 or 1")
                elif not math.isfinite(value) or value <= 0 or value != int(value):
                    raise ValueError("expected a positive dropped-iteration count")
            except (AttributeError, KeyError, TypeError, ValueError) as error:
                raise ValueError(f"{points.name} line {line_number}: {error}") from error

            first = observed if first is None else min(first, observed)
            last = observed if last is None else max(last, observed)
            if start <= observed <= end:
                if is_request:
                    requests += 1
                    failures += int(value)
                else:
                    drops += int(value)

    if first is None or first >= start or last <= end or requests + drops == 0:
        raise ValueError("k6 needs samples before, during, and after the observation window")
    return requests, failures, drops


def evidence(row, directory):
    metadata = read_object(directory / "metadata.json")
    if metadata["run_id"] != row["run_id"]:
        raise ValueError("metadata run_id does not match trial")
    if type(metadata["k6_exit_code"]) is not int or metadata["k6_exit_code"] != 0:
        raise ValueError("k6 did not finish successfully")
    rate, duration, base_url = (metadata[key] for key in ("rate", "duration_s", "work_url"))
    if any(type(value) is not int or value <= 0 for value in (rate, duration)):
        raise ValueError("rate and duration_s must be positive integers")
    if not isinstance(base_url, str):
        raise ValueError("work_url must be an HTTP base URL")
    url = urlsplit(base_url)
    if url.scheme not in ("http", "https") or not url.hostname or url.query or url.fragment or base_url.endswith("/"):
        raise ValueError("work_url must be an HTTP base URL without a trailing slash, query, or fragment")

    start = timestamp(row["injected_at"])
    end = timestamp(metadata["window_end_at"])
    if end <= start:
        raise ValueError("window_end_at must be after injection")
    observed = metadata["recovery_observed"]
    if type(observed) is not bool:
        raise ValueError("recovery_observed must be a boolean")

    mttr = row["mttr_s"]
    restored = row["traffic_restored_at"]
    detected = timestamp(row["detected_at"]) if row["detected_at"] is not None else None
    if detected is not None and not start <= detected <= end:
        raise ValueError("detected_at lies outside the observation window")
    if observed and detected is not None:
        expected_mttr = (end - start).total_seconds()
        if (type(mttr) not in (int, float) or not math.isfinite(mttr) or mttr < 0
                or abs(mttr - expected_mttr) > 0.000002 or timestamp(restored) != end):
            raise ValueError("recovered trial has inconsistent recovery time")
        outcome = "recovered"
    else:
        if mttr is not None or restored is not None:
            raise ValueError("MTTR requires observed impact and recovery")
        outcome = "no_detected_impact" if observed else "recovery_unobserved"

    probe_drop = row["dropped_requests_pct"]
    if probe_drop is not None and (type(probe_drop) not in (int, float) or not 0 <= probe_drop <= 100):
        raise ValueError("dropped_requests_pct must be null or 0–100")

    requests, failures, drops = k6_window(directory, row["run_id"], f"{base_url}/work", start, end)
    load = {"rate": rate, "duration_s": duration, "work_url": base_url}
    return {
        "run_id": row["run_id"],
        "injection_type": row["injection_type"],
        "load": load,
        "outcome": outcome,
        "mttr_s": mttr,
        "probe_dropped_pct": probe_drop,
        "k6_http_requests": requests,
        "k6_http_failures": failures,
        "k6_dropped_iterations": drops,
    }


def matrix_report(results, load_root):
    cells = {(scenario, config): [] for scenario in SCENARIOS for config in QUOTAS}
    recorded = dict.fromkeys(cells, 0)
    methods = {cell: set() for cell in cells}
    seen = set()
    errors = []
    for path in sorted(results.glob("*.json")):
        try:
            row = read_object(path)
            run_id = row["run_id"]
            if not isinstance(run_id, str) or not re.fullmatch(r"[0-9a-f]{32}", run_id):
                raise ValueError("run_id must be the runner's 32-digit lowercase UUID")
            if run_id in seen:
                raise ValueError(f"duplicate run_id {run_id}")
            if path.stem != run_id:
                raise ValueError("trial filename must match run_id")
            seen.add(run_id)
            cell = (row["scenario"], row["config"])
            if cell not in cells:
                raise ValueError("unknown scenario or configuration")
            method = row["injection_type"]
            if method not in METHODS:
                raise ValueError("unknown injection_type")
            recorded[cell] += 1
            methods[cell].add(method)
            cells[cell].append(evidence(row, load_root / run_id))
        except (OSError, EOFError, KeyError, OverflowError, TypeError, ValueError, zlib.error) as error:
            errors.append(f"{path.name}: {error}")

    scenario_loads = {scenario: set() for scenario in SCENARIOS}
    groups = []
    for (scenario, config), trials in cells.items():
        cell = (scenario, config)
        required = QUOTAS[config]
        if recorded[cell] != required or len(trials) != required:
            errors.append(f"{scenario}/{config}: expected {required}, found {recorded[cell]} rows "
                          f"and {len(trials)} with validated k6 evidence")
        if len(methods[cell]) > 1:
            errors.append(f"{scenario}/{config}: mixed injection methods")
        expected_method = EXPECTED_METHODS[scenario]
        if methods[cell] - {expected_method}:
            errors.append(f"{scenario}/{config}: expected {expected_method} injection")
        for trial in trials:
            scenario_loads[scenario].add(tuple(trial["load"].values()))

        times = sorted(trial["mttr_s"] for trial in trials if trial["mttr_s"] is not None)
        requests = sum(trial["k6_http_requests"] for trial in trials)
        failures = sum(trial["k6_http_failures"] for trial in trials)
        groups.append({
            "scenario": scenario,
            "config": config,
            "expected_runs": required,
            "recorded_runs": recorded[cell],
            "validated_runs": len(trials),
            "injection_methods": sorted(methods[cell]),
            "recovered_runs": len(times),
            "no_detected_impact_runs": sum(trial["outcome"] == "no_detected_impact" for trial in trials),
            "recovery_unobserved_runs": sum(trial["outcome"] == "recovery_unobserved" for trial in trials),
            "median_mttr_s": statistics.median(times) if times else None,
            "p95_mttr_s": times[math.ceil(0.95 * len(times)) - 1] if times else None,
            "k6_http_requests": requests,
            "k6_http_failures": failures,
            "k6_http_failed_pct": 100 * failures / requests if requests else None,
            "k6_dropped_iterations": sum(trial["k6_dropped_iterations"] for trial in trials) if trials else None,
            "trials": trials,
        })

    for scenario, settings in scenario_loads.items():
        if len(settings) > 1:
            errors.append(f"{scenario}: load settings differ across trials or profiles")

    return {"complete": not errors, "errors": errors, "cells": groups}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, default=Path("results/chaos"))
    parser.add_argument("--load", type=Path, default=Path("results/load"))
    args = parser.parse_args()
    report = matrix_report(args.results, args.load)
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
