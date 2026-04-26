#!/usr/bin/env python3
"""Aggregate per-round bench JSON records and emit a comparison verdict.

Reads every ``round_*_<scenario>_<NN>.json`` (or analogous warmup files,
which it ignores) under ``--dir``, groups them by
``(scenario_id, variant, concurrency_shape)``, and writes
``aggregate.json`` next to ``--dir`` (or at ``--out`` when overridden).

Implements the variance-aware regression formula from
``docs/performance/2026-04-26-encode-decode-baseline/architecture.md``
section 6:

    delta_pct        = (candidate_median - baseline_median) / baseline_median * 100
    stddev_a         = stddev across ref_a rounds (in median ns/op terms)
    variance_gate    = stddev_a * variance_gate_multiplier      (default 3.0x)
    fixed_floor_pct  = 3.0
    effective_gate   = max(variance_gate, fixed_floor_pct * baseline_median / 100)

    REGRESSION  if delta_pct < max_regression_pct AND
                   abs(candidate_median - baseline_median) > effective_gate
    IMPROVEMENT if delta_pct >= target_gain_pct AND
                   the magnitude exceeds the effective gate
    NEUTRAL     otherwise

Always prints exactly one ``NATIVE_BENCH ...`` summary line so CI log
scrapers can parse it. Exits 0 on PASS or BASELINE, 1 on FAIL.

Stdlib only (Python 3.10+) — no external packages, per the
native-benchmarks hard rules.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "1"
DEFAULT_VARIANCE_GATE_MULTIPLIER = 3.0
DEFAULT_FIXED_FLOOR_PCT = 3.0
DEFAULT_TARGET_GAIN_PCT = 5.0
DEFAULT_MAX_REGRESSION_PCT = -3.0


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dir", type=Path, required=True,
                   help="Directory containing round_*.json files for the candidate ref (variant B).")
    p.add_argument("--baseline-dir", type=Path, default=None,
                   help="Directory of baseline (ref_a) round_*.json files. "
                        "Omit on the first run; the script then emits "
                        "result=BASELINE and skips the gate.")
    p.add_argument("--out", type=Path, default=None,
                   help="Write aggregate.json here (default: <dir>/../aggregate.json).")
    p.add_argument("--gate", action="store_true",
                   help="Apply the regression gate; exit 1 on FAIL.")
    p.add_argument("--target-gain-pct", type=float,
                   default=DEFAULT_TARGET_GAIN_PCT)
    p.add_argument("--max-regression-pct", type=float,
                   default=DEFAULT_MAX_REGRESSION_PCT)
    p.add_argument("--variance-gate-multiplier", type=float,
                   default=DEFAULT_VARIANCE_GATE_MULTIPLIER)
    p.add_argument("--fixed-floor-pct", type=float,
                   default=DEFAULT_FIXED_FLOOR_PCT)
    return p.parse_args()


def discover_rounds(dir_path: Path) -> list[dict[str, Any]]:
    """Read every measured round file in ``dir_path`` (recursively)."""
    if not dir_path.exists():
        return []
    out: list[dict[str, Any]] = []
    for fp in sorted(dir_path.rglob("round_*.json")):
        # Skip files written by the warmup pass (warmup_*.json).
        if fp.name.startswith("warmup_"):
            continue
        try:
            with fp.open("r", encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, json.JSONDecodeError) as e:
            print(f"WARN: cannot read {fp}: {e}", file=sys.stderr)
            continue
        if not _is_valid_record(rec):
            print(f"WARN: invalid record schema in {fp}", file=sys.stderr)
            continue
        out.append(rec)
    return out


_REQUIRED_FIELDS = (
    "scenario_id", "layer", "language", "variant", "git_sha", "metrics",
)


def _is_valid_record(rec: dict[str, Any]) -> bool:
    if not isinstance(rec, dict):
        return False
    for field in _REQUIRED_FIELDS:
        if field not in rec:
            return False
    if not isinstance(rec.get("metrics"), dict):
        return False
    if "ns_per_op_median" not in rec["metrics"]:
        return False
    return True


def group_records(records: list[dict[str, Any]]) -> dict[tuple[str, str, str], list[dict[str, Any]]]:
    grouped: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for rec in records:
        scenario_id = rec.get("scenario_id", "")
        variant = rec.get("variant", "A")
        counters = rec.get("counters") or {}
        concurrency = counters.get("concurrency_shape", "N=1")
        key = (scenario_id, variant, concurrency)
        grouped.setdefault(key, []).append(rec)
    return grouped


def _collect_medians(records: list[dict[str, Any]]) -> list[float]:
    out: list[float] = []
    for rec in records:
        v = rec.get("metrics", {}).get("ns_per_op_median")
        if v is None:
            continue
        try:
            f = float(v)
        except (TypeError, ValueError):
            continue
        if math.isnan(f) or math.isinf(f):
            continue
        out.append(f)
    return out


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    sorted_vals = sorted(values)
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    idx = int(round((pct / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[max(0, min(idx, len(sorted_vals) - 1))]


def aggregate_one_group(records: list[dict[str, Any]]) -> dict[str, Any]:
    medians = _collect_medians(records)
    if not medians:
        return {
            "rounds": 0,
            "median": 0.0,
            "stddev": 0.0,
            "p95": 0.0,
            "p99": 0.0,
        }
    return {
        "rounds": len(medians),
        "median": statistics.median(medians),
        "stddev": (statistics.stdev(medians) if len(medians) > 1 else 0.0),
        "p95": _percentile(medians, 95),
        "p99": _percentile(medians, 99),
    }


def compare_one(
    baseline_agg: dict[str, Any] | None,
    candidate_agg: dict[str, Any],
    target_gain_pct: float,
    max_regression_pct: float,
    variance_gate_multiplier: float,
    fixed_floor_pct: float,
) -> dict[str, Any]:
    """Return a comparison record for one (scenario, variant, concurrency)."""
    if baseline_agg is None or baseline_agg["rounds"] == 0:
        return {
            "status": "baseline",
            "candidate_median": candidate_agg["median"],
            "baseline_median": None,
            "delta_pct": None,
            "effective_gate_ns": None,
        }

    if candidate_agg["rounds"] == 0:
        return {
            "status": "missing",
            "candidate_median": None,
            "baseline_median": baseline_agg["median"],
            "delta_pct": None,
            "effective_gate_ns": None,
        }

    bm = baseline_agg["median"]
    cm = candidate_agg["median"]
    delta_ns = cm - bm
    delta_pct = (delta_ns / bm * 100.0) if bm != 0 else 0.0

    variance_gate = baseline_agg["stddev"] * variance_gate_multiplier
    fixed_floor_ns = abs(bm) * (fixed_floor_pct / 100.0)
    effective_gate = max(variance_gate, fixed_floor_ns)

    # ns/op is "lower is better": a negative delta_pct means the
    # candidate ran faster (an IMPROVEMENT); a positive delta_pct means
    # it ran slower (a REGRESSION). The two thresholds are configured
    # as positive magnitudes, applied with appropriate sign here:
    #   target_gain_pct = 5.0   -> IMPROVEMENT when delta_pct <= -5.0
    #   max_regression_pct = -3.0 -> REGRESSION when delta_pct >= +3.0
    # The plan stores `max_regression_pct` as a negative number for
    # historical reasons; we use abs() so the gate is symmetric and
    # readable.
    status = "neutral"
    regression_threshold = abs(max_regression_pct)
    improvement_threshold = -abs(target_gain_pct)
    if delta_pct >= regression_threshold and abs(delta_ns) > effective_gate:
        status = "regression"
    elif delta_pct <= improvement_threshold and abs(delta_ns) > effective_gate:
        status = "improvement"

    return {
        "status": status,
        "candidate_median": cm,
        "baseline_median": bm,
        "delta_ns": delta_ns,
        "delta_pct": delta_pct,
        "effective_gate_ns": effective_gate,
        "baseline_stddev": baseline_agg["stddev"],
        "candidate_stddev": candidate_agg["stddev"],
    }


def short_sha(records: list[dict[str, Any]]) -> str:
    for rec in records:
        sha = rec.get("git_sha") or ""
        if sha and sha != "unknown":
            return sha[:8]
    return "unknown"


def main() -> int:
    args = parse_args()

    candidate_records = discover_rounds(args.dir)
    if not candidate_records:
        print(f"NATIVE_BENCH result=FAIL scenarios=0 regressions=0 improvements=0 "
              f"ref_a=none ref_b=none note=no-records-in-dir", flush=True)
        return 1

    candidate_groups = group_records(candidate_records)

    baseline_groups: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    if args.baseline_dir is not None:
        baseline_records = discover_rounds(args.baseline_dir)
        baseline_groups = group_records(baseline_records)

    is_baseline_run = args.baseline_dir is None

    aggregate: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "ref_a": short_sha(
            sum(baseline_groups.values(), []) if baseline_groups else []
        ),
        "ref_b": short_sha(candidate_records),
        "thresholds": {
            "target_gain_pct": args.target_gain_pct,
            "max_regression_pct": args.max_regression_pct,
            "variance_gate_multiplier": args.variance_gate_multiplier,
            "fixed_floor_pct": args.fixed_floor_pct,
        },
        "scenarios": [],
    }

    regressions = 0
    improvements = 0
    n_scenarios = 0

    all_keys = sorted(set(candidate_groups) | set(baseline_groups))
    for key in all_keys:
        scenario_id, variant, concurrency = key
        candidate_recs = candidate_groups.get(key, [])
        baseline_recs = baseline_groups.get(key, [])
        candidate_agg = aggregate_one_group(candidate_recs)
        baseline_agg = aggregate_one_group(baseline_recs) if baseline_recs else None

        comparison = compare_one(
            baseline_agg if not is_baseline_run else None,
            candidate_agg,
            args.target_gain_pct,
            args.max_regression_pct,
            args.variance_gate_multiplier,
            args.fixed_floor_pct,
        )
        n_scenarios += 1
        if comparison["status"] == "regression":
            regressions += 1
        elif comparison["status"] == "improvement":
            improvements += 1

        aggregate["scenarios"].append({
            "scenario_id": scenario_id,
            "variant": variant,
            "concurrency_shape": concurrency,
            "candidate": candidate_agg,
            "baseline": baseline_agg if baseline_agg else {"rounds": 0},
            "comparison": comparison,
        })

    if is_baseline_run:
        result = "BASELINE"
        ref_a_field = "none"
    elif regressions > 0:
        result = "FAIL"
        ref_a_field = aggregate["ref_a"]
    else:
        result = "PASS"
        ref_a_field = aggregate["ref_a"]

    summary_line = (
        f"NATIVE_BENCH result={result} scenarios={n_scenarios} "
        f"regressions={regressions} improvements={improvements} "
        f"ref_a={ref_a_field} ref_b={aggregate['ref_b']}"
    )
    aggregate["summary_line"] = summary_line
    aggregate["regressions"] = regressions
    aggregate["improvements"] = improvements
    aggregate["result"] = result

    out_path = args.out
    if out_path is None:
        out_path = args.dir.parent / "aggregate.json"
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w", encoding="utf-8") as fh:
            json.dump(aggregate, fh, indent=2)
            fh.write("\n")
    except OSError as e:
        print(f"WARN: cannot write {out_path}: {e}", file=sys.stderr)

    print(summary_line, flush=True)

    if args.gate and result == "FAIL":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
