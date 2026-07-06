#!/usr/bin/env python3
"""maxcheck_tally.py — reduce the fast-pass index streams to results + a proof
of count-conservation.

The maxcheck workers emit four append-only index streams of fixed 8-byte
(row_group:uint32, row:uint32) records:

    *.max     provably r-maximal
    *.nonmax  provably not maximal
    *.defer   not decided this pass (dpc-gated tail / budget / overflow / crash)
    *.anom    not a valid reflexive polytope (should be empty for this dataset)

This tool:
  1. loads every stream under --streams, dedups (a supervised restart can only
     ever re-emit rows it had already truncated away, but we dedup defensively),
  2. checks COUNT-CONSERVATION: the four disjoint index sets must partition all
     N rows of the source parquet exactly (|max|+|nonmax|+|defer|+|anom| == N,
     and the sets are pairwise disjoint) — this is the completeness guarantee,
  3. joins the .max indices back to the FULL source records → maximal.parquet,
  4. writes the .defer indices → deferred.parquet-index for the slow pass,
  5. reports polytope-multiplicity-weighted totals using the `count` column.
"""
import argparse, glob, os, struct, sys
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq


def load_stream(paths):
    """Return an (n,2) int64 array of (rg,row) from a set of stream files."""
    chunks = []
    for p in paths:
        b = open(p, "rb").read()
        n = len(b) // 8
        if n:
            a = np.frombuffer(b[: n * 8], dtype=np.uint32).reshape(n, 2)
            chunks.append(a.astype(np.int64))
    if not chunks:
        return np.empty((0, 2), dtype=np.int64)
    return np.concatenate(chunks, axis=0)


def keyset(a):
    """Pack (rg,row) into a single int64 key array (rg<<32 | row), unique."""
    if a.shape[0] == 0:
        return np.empty(0, dtype=np.int64)
    return np.unique((a[:, 0] << 32) | a[:, 1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="unique_polytopes_clean.parquet")
    ap.add_argument("--streams", required=True, help="dir with per-process *.max/.nonmax/.defer/.anom")
    ap.add_argument("--out", required=True, help="output dir")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    tags = ["max", "nonmax", "defer", "anom"]
    keys = {}
    for t in tags:
        keys[t] = keyset(load_stream(sorted(glob.glob(os.path.join(args.streams, f"*.{t}")))))
        print(f"  {t:7s}: {len(keys[t]):,} unique rows")

    pf = pq.ParquetFile(args.input)
    N = pf.metadata.num_rows
    total = sum(len(keys[t]) for t in tags)

    # ── pairwise disjointness + partition check ─────────────────────────────
    ok = True
    allk = np.concatenate([keys[t] for t in tags]) if total else np.empty(0, np.int64)
    if len(np.unique(allk)) != total:
        print("!! OVERLAP: streams are not pairwise disjoint", file=sys.stderr); ok = False
    if total != N:
        print(f"!! COUNT MISMATCH: streams cover {total:,} of {N:,} rows "
              f"({N-total:+,} missing)", file=sys.stderr); ok = False

    # ── multiplicity-weighted totals via the `count` column ─────────────────
    # Build a per-(rg) index → tag map to sum counts without loading nf.
    max_rows, defer_rows = keys["max"], keys["defer"]
    weighted = {t: 0 for t in tags}
    n_rg = pf.num_row_groups
    base = 0
    # Precompute row-group base offsets (rows are globally ordered by rg).
    rg_sizes = [pf.metadata.row_group(i).num_rows for i in range(n_rg)]
    rg_base = np.concatenate([[0], np.cumsum(rg_sizes)])[:-1]
    # For weighting we need `count` per row; stream only the count column.
    tagmap = {}
    for t in tags:
        for k in keys[t]:
            tagmap[int(k)] = t
    row_idx = 0
    for rg in range(n_rg):
        tbl = pf.read_row_group(rg, columns=["count"])
        cnt = tbl.column("count").to_numpy(zero_copy_only=False)
        for r in range(len(cnt)):
            k = (rg << 32) | r
            t = tagmap.get(k)
            if t is not None:
                weighted[t] += int(cnt[r])
        row_idx += len(cnt)

    # ── join .max indices → full maximal records ────────────────────────────
    if len(max_rows):
        by_rg = {}
        for k in max_rows:
            by_rg.setdefault(int(k) >> 32, []).append(int(k) & 0xFFFFFFFF)
        parts = []
        for rg in sorted(by_rg):
            tbl = pf.read_row_group(rg)
            parts.append(tbl.take(pa.array(sorted(by_rg[rg]))))
        maximal = pa.concat_tables(parts)
        pq.write_table(maximal, os.path.join(args.out, "maximal.parquet"))
        print(f"  wrote maximal.parquet: {maximal.num_rows:,} rows")

    # ── deferred index → parquet for the slow pass ──────────────────────────
    if len(defer_rows):
        dt = pa.table({"row_group": pa.array((defer_rows >> 32).astype(np.int32)),
                       "row": pa.array((defer_rows & 0xFFFFFFFF).astype(np.int32))})
        pq.write_table(dt, os.path.join(args.out, "deferred_index.parquet"))
        print(f"  wrote deferred_index.parquet: {len(defer_rows):,} rows")

    # ── tally report ────────────────────────────────────────────────────────
    lines = [
        "r-maximality fast-pass tally",
        f"source           : {args.input}",
        f"total rows (N)   : {N:,}",
        "",
        f"{'stream':8s} {'unique_rows':>16s} {'count_weighted':>18s}",
    ]
    for t in tags:
        lines.append(f"{t:8s} {len(keys[t]):16,d} {weighted[t]:18,d}")
    lines += [
        "",
        f"sum(unique_rows) : {total:,}   (== N: {total==N})",
        f"pairwise disjoint: {len(np.unique(allk))==total}",
        f"COUNT-CONSERVED  : {ok}",
        "",
        "NOTE: `defer` rows are NOT classified — they are the input to the slow",
        "robust pass.  The classification is complete only once every deferred",
        "row has also been decided.",
    ]
    rep = "\n".join(lines)
    print("\n" + rep)
    open(os.path.join(args.out, "tally.txt"), "w").write(rep + "\n")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
