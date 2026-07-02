#!/usr/bin/env python3
"""
Curate reproducible corpora from the source sample of weight systems.

Produces two committed text files of `degree w1..w6` lines:
  tests/fixtures/corpus_small.txt   — diverse, small: correctness golden set
  bench/corpus/corpus_10k.txt       — larger fixed corpus for benchmarking

Selection is deterministic (sorted, fixed strides) so the corpora are stable
across runs. The small corpus is stratified by polytope size (the `M:<points>`
field) so the golden set spans trivial to large point counts — the large cases
are where the ported classifier's point enumeration is most likely to diverge.

Source: process-polytopes/samples/sample-100k.txt (100k reflexive 5d WS).
Run once; the outputs are committed so tests need no external data.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC = REPO_ROOT.parent / "process-polytopes" / "samples" / "sample-100k.txt"

SMALL_OUT = REPO_ROOT / "tests" / "fixtures" / "corpus_small.txt"
BENCH_OUT = REPO_ROOT / "bench" / "corpus" / "corpus_10k.txt"

SMALL_N = 400
BENCH_N = 10000

_M_RE = re.compile(r"M:(\d+)")


def ws_line(raw: str) -> str:
    """Extract `degree w1..w6` (the first 7 whitespace tokens)."""
    toks = raw.split()
    return " ".join(toks[:7])


def point_count(raw: str) -> int:
    m = _M_RE.search(raw)
    return int(m.group(1)) if m else 0


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"source sample not found: {SRC}")
    rows = [l for l in SRC.read_text().splitlines() if l.strip()]

    # bench corpus: first BENCH_N in file order (stable, representative).
    bench = [ws_line(r) for r in rows[:BENCH_N]]
    BENCH_OUT.parent.mkdir(parents=True, exist_ok=True)
    BENCH_OUT.write_text("\n".join(bench) + "\n")

    # small corpus: stratify by point count, take an even stride across the
    # size-sorted list so tiny and large polytopes are both represented.
    by_size = sorted(rows, key=point_count)
    stride = max(1, len(by_size) // SMALL_N)
    picked = by_size[::stride][:SMALL_N]
    small = [ws_line(r) for r in picked]
    SMALL_OUT.parent.mkdir(parents=True, exist_ok=True)
    SMALL_OUT.write_text("\n".join(small) + "\n")

    print(f"wrote {len(small)} lines -> {SMALL_OUT}")
    print(f"  point-count range: {point_count(picked[0])}..{point_count(picked[-1])}")
    print(f"wrote {len(bench)} lines -> {BENCH_OUT}")


if __name__ == "__main__":
    main()
