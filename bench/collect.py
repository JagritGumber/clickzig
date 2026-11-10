#!/usr/bin/env python3
"""Merge raw benchmark output into bench/results.json.

Usage:
    python3 bench/collect.py --env "machine description" \
        --reference ref.jsonl run1.jsonl [run2.jsonl ...] > bench/results.json

Each clickzig run file holds the JSON lines printed by `zig build bench`.
Across runs, every measurement keeps the median duration. The reference
file holds the lines printed by bench/reference_clickhouse_client.sh.
"""

import argparse
import json
import statistics
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--reference", required=True)
    ap.add_argument("runs", nargs="+")
    args = ap.parse_args()

    durations = defaultdict(list)
    rows = {}
    conc = defaultdict(list)
    ping_p50, ping_p99 = [], []
    for path in args.runs:
        for line in open(path):
            r = json.loads(line)
            if r["bench"] == "ping":
                ping_p50.append(r["p50_ns"])
                ping_p99.append(r["p99_ns"])
            elif r["bench"] == "concurrency":
                conc[r["concurrency"]].append(r["ns"])
                rows["concurrency"] = r["queries"]
            else:
                durations[r["bench"]].append(r["ns"])
                rows[r["bench"]] = r["rows"]

    clickzig = {}
    for name, ns_list in durations.items():
        ns = statistics.median(ns_list)
        clickzig[name] = {"rows": rows[name], "ns": ns, "rows_per_s": rows[name] / (ns / 1e9)}

    concurrency = []
    for c in sorted(conc):
        ns = statistics.median(conc[c])
        concurrency.append({"concurrency": c, "ns": ns, "queries_per_s": rows["concurrency"] / (ns / 1e9)})

    reference = {}
    for line in open(args.reference):
        r = json.loads(line)
        reference[r["bench"]] = {"rows": r["rows"], "s": r["s"], "rows_per_s": r["rows"] / r["s"]}

    result = {
        "environment": args.env,
        "clickzig": clickzig,
        "reference": reference,
        "concurrency": concurrency,
        "ping": {"p50_ns": statistics.median(ping_p50), "p99_ns": statistics.median(ping_p99)},
        "notes": [
            "Loopback TCP, client and server in the same container. Medians of 7 timed passes (3 runs for clickzig), ReleaseFast.",
            "clickhouse-client is a reference, not a strict head-to-head: it also re-encodes Native output (to /dev/null); time via --time.",
            "INSERT goes to an ENGINE = Null table; both clients spend ~60ms/batch waiting on the server, so compression does not change it.",
        ],
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
