#!/usr/bin/env python3
"""
Classifier thread-scaling benchmark.

Measures end-to-end throughput of the built `classifier` binary (Parquet read →
per-thread PALP NF → hash → dedup) as a function of thread count. Each worker
gets its own PALP workspace, so on a compute-bound input scaling should be
near-linear; this benchmark makes the input compute-bound by **weak scaling** —
every thread count processes `rows_per_thread` rows *per thread*, so the wall
time stays roughly constant and single-vs-multi throughput is directly
comparable (rather than the tiny-sample, overhead-bound regime of bench_nf.py).

Inputs are built by tiling bench/corpus/corpus_100k.txt (100k unique weight
systems) up to the needed row count and written as one Parquet per thread count
under --data-dir (cached, reused across reps).

Usage:
    bench_classifier.py                              # default sweep
    bench_classifier.py --threads 1,8,64 --reps 5
    bench_classifier.py --rows-per-thread 150000
    bench_classifier.py --update / --check           # per-host baseline

Requires: pyarrow, and a built classifier (src/classify/build/classifier or
$REFPOLY_CLASSIFIER). The Arrow runtime libs must be loadable; if $CONDA_PREFIX
is set its lib dir is added to LD_LIBRARY_PATH automatically.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCH_DIR.parent
CORPUS = BENCH_DIR / "corpus" / "corpus_100k.txt"
DEFAULT_CLASSIFIER = REPO_ROOT / "src" / "classify" / "build" / "classifier"
BASELINE = BENCH_DIR / "baseline_classifier.json"

_THR_RE = re.compile(r"Throughput:\s+([0-9.]+)\s*CWS/s")


def classifier_path() -> Path:
    env = os.environ.get("REFPOLY_CLASSIFIER")
    return Path(env) if env else DEFAULT_CLASSIFIER


def run_env() -> dict:
    env = dict(os.environ)
    cp = env.get("CONDA_PREFIX")
    if cp:
        lib = f"{cp}/lib"
        env["LD_LIBRARY_PATH"] = lib + (":" + env["LD_LIBRARY_PATH"]
                                        if env.get("LD_LIBRARY_PATH") else "")
    return env


def build_input(corpus_rows: list[list[int]], n_rows: int, out_dir: Path) -> None:
    """Write one Parquet of exactly n_rows (tiling corpus) to out_dir, if absent."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    marker = out_dir / f".rows-{n_rows}"
    if marker.exists():
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.parquet"):
        old.unlink()
    # tile weight columns to n_rows
    ncorp = len(corpus_rows)
    idx = [i % ncorp for i in range(n_rows)]
    cols = {f"weight{c}": pa.array([corpus_rows[i][1 + c] for i in idx], pa.int32())
            for c in range(6)}
    pq.write_table(pa.table(cols), out_dir / "ws-0000.parquet")
    for m in out_dir.glob(".rows-*"):
        m.unlink()
    marker.write_text("")


def measure(binary: Path, in_dir: Path, out_dir: Path, threads: int, env: dict) -> tuple:
    """Run the classifier once; return (throughput_cws_s, wall_s)."""
    import shutil
    if out_dir.exists():
        shutil.rmtree(out_dir)
    t0 = time.perf_counter()
    proc = subprocess.run(
        [str(binary), "--input", str(in_dir), "--output", str(out_dir),
         "--threads", str(threads)],
        capture_output=True, text=True, env=env)
    wall = time.perf_counter() - t0
    m = _THR_RE.search(proc.stdout + "\n" + proc.stderr)
    if not m:
        sys.stderr.write(proc.stdout[-2000:] + "\n" + proc.stderr[-1500:] + "\n")
        raise RuntimeError(f"could not parse throughput (threads={threads})")
    return float(m.group(1)), wall


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--threads", default="1,2,4,8,16,32,64",
                    help="comma-separated thread counts")
    ap.add_argument("--rows-per-thread", type=int, default=150000,
                    help="rows processed per thread (weak scaling)")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--data-dir", default=None,
                    help="where to build input parquets (default: scratch under /tmp)")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--slack", type=float, default=0.75)
    args = ap.parse_args()

    binary = classifier_path()
    if not binary.exists():
        sys.exit(f"classifier not built at {binary}; run src/classify/build.sh "
                 f"(or set REFPOLY_CLASSIFIER)")
    if not CORPUS.exists():
        sys.exit(f"corpus missing: {CORPUS}; run tests/curate_corpus.py")

    thread_list = [int(x) for x in args.threads.split(",")]
    corpus_rows = [[int(x) for x in l.split()]
                   for l in CORPUS.read_text().splitlines() if l.strip()]

    data_dir = Path(args.data_dir) if args.data_dir else Path(
        os.environ.get("TMPDIR", "/tmp")) / "refpoly_bench_classifier"
    env = run_env()

    print(f"classifier: {binary}")
    print(f"weak scaling: {args.rows_per_thread:,} rows/thread, {args.reps} reps, "
          f"{len(corpus_rows):,} unique WS tiled\n")
    print(f"{'threads':>7} {'rows':>12} {'median CWS/s':>14} {'speedup':>8} "
          f"{'per-core':>9} {'wall s':>7}")

    results = {}
    base_thr = None
    for t in thread_list:
        n_rows = t * args.rows_per_thread
        in_dir = data_dir / f"in_t{t}"
        build_input(corpus_rows, n_rows, in_dir)
        thrs, walls = [], []
        for _ in range(args.reps):
            thr, wall = measure(binary, in_dir, data_dir / "out", t, env)
            thrs.append(thr)
            walls.append(wall)
        med = statistics.median(thrs)
        if t == thread_list[0]:
            base_thr = med
        speedup = med / base_thr if base_thr else 1.0
        per_core = med / t
        results[str(t)] = {"rows": n_rows, "median_cws_s": med,
                           "speedup_vs_first": speedup, "per_core_cws_s": per_core,
                           "wall_s_median": statistics.median(walls)}
        print(f"{t:>7} {n_rows:>12,} {med:>14,.0f} {speedup:>7.2f}x "
              f"{per_core:>9,.0f} {statistics.median(walls):>7.2f}")

    record = {"host": f"{platform.node()}:{platform.machine()}",
              "rows_per_thread": args.rows_per_thread, "by_threads": results}

    if args.update:
        data = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
        data.setdefault("by_host", {})[record["host"]] = record
        BASELINE.write_text(json.dumps(data, indent=2) + "\n")
        print(f"\nbaseline updated for {record['host']} -> {BASELINE}")

    if args.check:
        if not BASELINE.exists():
            print("\nno baseline_classifier.json; run --update first")
            return 1
        base = json.loads(BASELINE.read_text()).get("by_host", {}).get(record["host"])
        if not base:
            print(f"\nno baseline for host {record['host']}")
            return 1
        regressions = []
        for t, r in results.items():
            b = base["by_threads"].get(t)
            if b and r["median_cws_s"] < args.slack * b["median_cws_s"]:
                regressions.append(
                    f"threads={t}: {r['median_cws_s']:,.0f} < {args.slack:.0%} "
                    f"of {b['median_cws_s']:,.0f} CWS/s")
        if regressions:
            print("\nREGRESSION:")
            for x in regressions:
                print(f"  - {x}")
            return 1
        print(f"\nOK: within {args.slack:.0%} of baseline for {record['host']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
