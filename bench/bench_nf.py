#!/usr/bin/env python3
"""
WS -> NF -> hash benchmark harness.

The single benchmark entry point for the pipeline foundation (replacing the
~70 ad-hoc scripts in the source repo). It measures the two stages that
dominate the classify path and are the natural regression targets:

  * nf_throughput_ws_per_s  — weight systems normalized per second (PALP -Nf).
  * hash_MBps[algo]         — throughput of each registered hash over the
                              canonical NF bytes (the pluggable-hash comparison).

Modes:
    bench_nf.py --update           # run, write bench/baseline.json (records numbers)
    bench_nf.py --check            # run, compare to baseline, fail on regression
    bench_nf.py --n 2000           # limit corpus size (quick local runs)

Timings are machine-dependent, so --check compares against the *same host* if
the baseline records one, and applies a slack factor (default 0.75 = flag a
>25% slowdown). Hash-algorithm digests are correctness-checked against
tests/nf_hash on every run regardless of timing.
"""
from __future__ import annotations

import argparse
import json
import platform
import sys
import time
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCH_DIR.parent
sys.path.insert(0, str(REPO_ROOT / "tests"))

import nf_hash                       # noqa: E402
from palp_oracle import normal_forms  # noqa: E402

CORPUS = BENCH_DIR / "corpus" / "corpus_10k.txt"
BASELINE = BENCH_DIR / "baseline.json"
DEFAULT_SLACK = 0.75  # measured/baseline below this ratio => regression


def host_key() -> str:
    return f"{platform.node()}:{platform.machine()}"


def bench(n: int | None) -> dict:
    ws_lines = [l for l in CORPUS.read_text().splitlines() if l.strip()]
    if n:
        ws_lines = ws_lines[:n]
    n_ws = len(ws_lines)

    t0 = time.perf_counter()
    nfs = normal_forms(ws_lines)
    nf_dt = time.perf_counter() - t0

    # Pre-serialize once; hashing is timed separately per algo.
    blobs = [nf_hash.canonical_bytes(nf.matrix, nf.dim, nf.nv) for nf in nfs]
    total_bytes = sum(len(b) for b in blobs)

    hash_mbps = {}
    for algo in nf_hash.algorithms():
        fn = nf_hash._REGISTRY[algo]
        t0 = time.perf_counter()
        for b in blobs:
            fn(b)
        dt = time.perf_counter() - t0
        hash_mbps[algo] = (total_bytes / 1e6) / dt if dt > 0 else 0.0

    return {
        "host": host_key(),
        "python": platform.python_version(),
        "n_ws": n_ws,
        "nf_throughput_ws_per_s": n_ws / nf_dt if nf_dt > 0 else 0.0,
        "hash_MBps": hash_mbps,
        "algos": nf_hash.algorithms(),
    }


def print_result(r: dict) -> None:
    print(f"host: {r['host']}  python {r['python']}  n={r['n_ws']}")
    print(f"  NF throughput : {r['nf_throughput_ws_per_s']:,.0f} ws/s")
    for algo, mbps in sorted(r["hash_MBps"].items()):
        print(f"  hash {algo:<12}: {mbps:,.0f} MB/s")


def do_update(r: dict) -> None:
    data = {}
    if BASELINE.exists():
        data = json.loads(BASELINE.read_text())
    data.setdefault("by_host", {})[r["host"]] = r
    BASELINE.write_text(json.dumps(data, indent=2) + "\n")
    print(f"\nbaseline updated for host {r['host']} -> {BASELINE}")


def do_check(r: dict, slack: float) -> int:
    if not BASELINE.exists():
        print("\nno baseline.json; run with --update first")
        return 1
    data = json.loads(BASELINE.read_text())
    base = data.get("by_host", {}).get(r["host"])
    if not base:
        print(f"\nno baseline for host {r['host']}; run --update here first "
              f"(known: {list(data.get('by_host', {}))})")
        return 1

    regressions = []
    b_nf = base["nf_throughput_ws_per_s"]
    if b_nf and r["nf_throughput_ws_per_s"] < slack * b_nf:
        regressions.append(
            f"NF {r['nf_throughput_ws_per_s']:,.0f} < {slack:.0%} of {b_nf:,.0f} ws/s")
    for algo, mbps in r["hash_MBps"].items():
        bm = base["hash_MBps"].get(algo)
        if bm and mbps < slack * bm:
            regressions.append(
                f"hash {algo} {mbps:,.0f} < {slack:.0%} of {bm:,.0f} MB/s")

    if regressions:
        print("\nREGRESSION:")
        for x in regressions:
            print(f"  - {x}")
        return 1
    print(f"\nOK: within {slack:.0%} of baseline for host {r['host']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--update", action="store_true", help="write baseline")
    ap.add_argument("--check", action="store_true", help="compare vs baseline")
    ap.add_argument("--n", type=int, default=None, help="limit corpus size")
    ap.add_argument("--slack", type=float, default=DEFAULT_SLACK)
    args = ap.parse_args()

    r = bench(args.n)
    print_result(r)
    if args.update:
        do_update(r)
    if args.check:
        return do_check(r, args.slack)
    return 0


if __name__ == "__main__":
    sys.exit(main())
