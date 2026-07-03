# Single-thread performance & build options

The classifier's single-thread cost is ~99% inside PALP's normal-form
computation (Arrow read + hashing + dedup is ~1–3%). Profiling the PALP path
over the ws-5d corpus put the time at roughly:

| PALP stage | share | what it does |
|---|---:|---|
| `Find_Equations` (convex hull) | ~71% | `GLZ_Start_Simplex`, `FE_Search_Bad_Eq`, `Search_New_Vertex`, `Make_New_CEqs` — the last two **scan every lattice point** per candidate facet/vertex |
| `Make_CWS_Points` (point enumeration) | ~17% | triangular lattice-point walk |
| `Make_Poly_Sym_NF` (normal form) | ~11% | canonicalisation |

Three optimizations were implemented and measured on an AMD EPYC 9554P
(single-core, best-of-2), gated by the golden NF regression (`make test`). Only
one is a win and it is **on by default**; the other two are opt-in and off.

## SIMD hull point-scan — **+21–25%, default ON**

`FE_Search_Bad_Eq` and `Search_New_Vertex` evaluate the dim-5 linear form
`c + Σ aₖ·xₖ` over all `np` points and do not auto-vectorise (early-exit /
arg-min control flow). We vectorise **only the dot-product arithmetic** with
AVX-512 (8 points/iteration) and keep the callers' exact scalar decision logic,
so the normal form is **bit-identical**.

The key subtlety: an AoS stride-5 **gather** loses on Zen4 (−12…16%; the scalar
contiguous 40-byte point loads are already fast). The win requires **contiguous**
vector loads, so the point list is transposed to struct-of-arrays **once per
`Find_Equations`** (points are invariant across the hull loop) into a
thread-local buffer and reused across the dozens of scans one hull performs.

| | reflexive (100k) | non-reflexive (175k) |
|---|---:|---:|
| scalar baseline | 13,418 CWS/s | 12,144 CWS/s |
| **SIMD** | **16,791 (+25%)** | **14,747 (+21%)** |

- Build flag: `ENABLE_SIMD_SCAN` (CMake, default `ON`) → defines `PALP_SIMD_SCAN`.
  Disable with `./src/classify/build.sh --no-simd`.
- Auto-falls back to scalar where AVX-512F+DQ are unavailable (`-march=native`
  must supply the ISA; it does on the Zen4 target).
- Runtime tunable `PALP_SIMD_MIN_NP` (default 96): polytopes with fewer points
  skip the transpose and use the scalar scan (flat optimum measured 32–128).

## PGO — neutral, opt-in

Profile-guided optimization (`./src/classify/build.sh --pgo`, two-phase
generate → train on `bench/corpus/corpus_100k.txt` → use). Measured within noise
(reflexive +1.5%, non-reflexive −1.3%): the hot path is arithmetic-bound point
scanning, not branch-misprediction or code layout, so PGO has little to improve.
Kept as an option; not enabled by default.

## LLL + Fincke–Pohst point walk — net loss on ws-5d, opt-in

PALP's fork carries an LLL+Fincke–Pohst replacement for the triangular
lattice-point walk in `Make_CWS_Points` (`#ifdef LLLFP_WALK` in `Coord.c`),
intended to help large-volume candidates. Enable with
`./src/classify/build.sh --lllfp` (CMake `ENABLE_LLLFP=ON`, default `OFF`).

Measured a **net loss** on this dataset at every gate. With the default
(`PALP_LF_LOGVOL_MIN=0`, fp on everything) it is −19% on reflexive; sweeping the
heavy-gate on the tail-heavy non-reflexive sample, the fp walk **never beats**
the triangular walk — even the max-`np`≈180k boxes are too small per-dimension
for Fincke–Pohst's asymptotic advantage to pay for its setup cost. Correctness
holds (golden 3/3). Retained + documented for genuinely large-volume datasets,
but **should not be enabled for ws-5d**.

Runtime knobs (when built with `--lllfp`): `PALP_WALK` (`fp`/`tri`/`check`),
`PALP_LF_LOGVOL_MIN` (heavy-gate on summed box bit-length; 0 = always fp),
`PALP_LF_NODECAP` (triangular-fallback node cap).

## Summary

| Optimization | Default | Effect on ws-5d | Enable |
|---|---|---|---|
| SIMD hull scan | **ON** | **+21–25%** | (on) / `--no-simd` to disable |
| PGO | off | neutral | `--pgo` |
| LLL+FP walk | off | net loss | `--lllfp` |

## Multi-core & distributed throughput

The single-thread work above is only part of the story: at full scale the
classifier is run massively parallel, and there the bottleneck is **not** PALP
compute. Measured on an AMD EPYC 9554 (2×64 cores) over full 34M-row shards:

| hot loop does… | CWS/s (1 socket, 64 thr) | per-core |
|---|---:|---:|
| compute + hash + **hash-map insert** (old default) | 310k | 4.9k |
| compute + hash, **no insert** | 836k | 13.1k |
| raw PALP NF only (no hash) | 835k | 13.0k |

So the per-CWS **hash-map insert** — a fat record inserted at random into a
GB-scale, ever-growing table — saturated memory bandwidth and cost **2.7×**;
hashing itself is free, and the stats atomics are negligible. On top of that, a
single process spanning both NUMA sockets lost ~1.7× to cross-socket memory
traffic (128-thread single process 414k CWS/s vs two socket-bound processes
715k).

Two changes fix it, and are what the distributed pipeline uses:

### Append / spill-runs mode — `--spill-runs`

Instead of deduping into a growing global map, the hot loop **appends
`{hash, row-index, geometry}`** to a per-thread buffer (sequential, cache- and
bandwidth-friendly), then sorts by `(hash, idx)` and collapses equal-hash groups
into deduped `MergeRecord`s, writing **one sorted run per file**. Peak RAM is
bounded to a single file; all cross-file/cross-node dedup is deferred to
`--merge`. The per-file collapse runs in parallel and the run-write is pipelined
behind the next file's compute. Output is **provably identical** to the in-RAM
path (same NF-hash set + per-hash counts).

### One process per NUMA socket

Run one `--spill-runs` classifier per socket, `numactl --cpunodebind=N
--membind=N`, each over half the files. Measured **~1.35M CWS/s/node** (vs 414k
for the naive single-process map path — **2.5×**) → ~8M/s over 6 nodes, ~4–5 h
for the full 137B ws-5d.

### Slim record & two-level merge

Because ws-5d is always a single weight system (1×6, degree = Σ), `PolytopeInfo`
was slimmed to the essentials (**320 B → 80 B**): intermediate runs ~1.4 TB/node
(was 5.5), merge I/O ~4× less, output a clean 13-column parquet. Dedup is a
two-level external sort-merge: each node merges its runs into one node-catalogue
`.ckpt` (`--merge --emit-ckpt`), then a global `--merge` over the node
catalogues produces the final parquet. See `scripts/slurm/`.

Diagnostic env knobs (perf investigation only): `PALP_BENCH_NOSTORE`,
`PALP_BENCH_NOHASH`.
