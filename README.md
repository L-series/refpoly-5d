# refpoly-5d

Companion repository to the paper:

> **Classification of Unique Five-Dimensional Polytopes from Weight Systems**

## Overview

This repository classifies the distinct five-dimensional lattice polytopes
arising from weight systems in the [ws-5d dataset](https://huggingface.co/datasets/calabi-yau-data/ws-5d)
(`calabi-yau-data/ws-5d`). The dataset has two variants, each 4000 Parquet
shards of IP weight systems:

- **reflexive** (~185B weight systems) — classified in the predecessor project;
- **non-reflexive** (~135B weight systems) — the current target of this repo,
  since these also yield interesting polytopes.

Both variants run through the **same** pipeline:

1. For each (combined) weight system, compute the polytope's **normal form**
   under GL(5,ℤ) equivalence using the PALP library (`Make_CWS_Points` →
   `Find_Equations` → `Make_Poly_Sym_NF`).
2. **Hash** the canonical normal-form matrix.
3. **Deduplicate** across the full dataset via a work-stealing thread pool and a
   two-phase external sort-merge across distributed compute nodes.

The output is a single deduplicated catalogue of unique polytopes. Each row is
one polytope: its NF hash (`hash_lo/hi`), frequency `count`, a representative
weight system (`weight0..5` + `source_index`; ws-5d is always a single 1×6
weight system, degree = Σweights) and geometry (`vertex_count`, `facet_count`,
`point_count`). For the **reflexive** variant the catalogue also carries the
lattice-dual metadata (`dual_point_count`, Hodge numbers `h11/h12/h13`); for the
**non-reflexive** variant — which has no lattice dual — those columns are
omitted (pass `--non-reflexive`, see below).

## Structure

```
refpoly-5d/
├── src/classify/     C++ classifier: CWS → PALP normal form → hash → dedup
│   ├── classifier.cpp        main pipeline (reader, thread pool, merge, output)
│   ├── palp_api.h            thread-safe C wrapper around PALP's NF routines
│   ├── geometry_backend.*    CPU backend (CUDA path compiled out here)
│   ├── nf_dump.cpp           diagnostic: prints the NF the classifier computes
│   ├── add_nf.cpp            enrich unique_polytopes.parquet with NF matrices
│   ├── CMakeLists.txt        CPU-only build (SIMD/PGO/LLL+FP toggles)
│   └── build.sh              convenience build wrapper
├── src/process/      standalone parquet post-processing tools (no PALP dep)
│   ├── concat_parquet.cpp    concatenate a part-*.parquet dataset into one file
│   ├── merge_computed.cpp    join in cleaned Hodge columns (reflexive workflow)
│   └── build.sh              convenience build wrapper
├── docs/             OPTIMIZATIONS.md — SIMD/PGO/LLL+FP results and build flags
├── tests/            normal-form correctness gate (PALP poly.x oracle + golden)
├── bench/            WS → NF → hash benchmark harness with per-host baseline
├── scripts/          dataset download (HuggingFace) + build-env helper
├── proofs/           Lean 4 formalization of the classification correctness
├── latex/notes/      theory + Kreuzer–Skarke classification notes
├── PALP/             PALP as a git submodule (a fork with dim-5 point-walk
│                     changes the classifier depends on)
└── Makefile          `make test`, `make bench`, …
```

## Getting started

### 1. Submodule

PALP is a git submodule pinned to the fork/commit the classifier is validated
against. After cloning:

```bash
git submodule update --init --recursive
```

### 2. Toolchain

The classifier links Arrow/Parquet C++ and compiles PALP as a static library.
Provide a toolchain with Arrow + Parquet, CMake, and Ninja — for example:

```bash
micromamba create -n refpoly-5d -c conda-forge arrow-cpp parquet cmake ninja
```

`scripts/env.sh` puts such an environment on `PATH`/`PKG_CONFIG_PATH` (set
`CONDA_PREFIX` to your env first):

```bash
source scripts/env.sh
```

### 3. Build

```bash
./src/classify/build.sh          # -> src/classify/build/classifier (+ nf_dump)
```

The AVX-512 SIMD hull scan is **on by default** (+21–25% single-core; auto-falls
back to scalar without AVX-512). Optional flags: `--no-simd`, `--pgo`,
`--lllfp` — see [`docs/OPTIMIZATIONS.md`](docs/OPTIMIZATIONS.md).

The standalone parquet tools build separately:

```bash
./src/process/build.sh           # -> src/process/build/{concat_parquet,merge_computed}
```

### 4. Download data

The dataset is public; a HuggingFace token (optional, avoids rate limits) is
read from `.env` — copy `.env.example` to `.env` and fill in `HF_TOKEN`.

```bash
python scripts/download_ws5d.py --list                       # show variants/counts
python scripts/download_ws5d.py --variant non-reflexive --all   # -> data/ws-5d-non-reflexive/
python scripts/download_ws5d.py --variant non-reflexive --start 0 --end 99  # a shard range
```

### 5. Run the classifier

```bash
# benchmark on 100k rows
./src/classify/build/classifier --input data/ws-5d-non-reflexive --output results --benchmark 100000

# process the non-reflexive shards across runners (omits dual/Hodge columns)
./src/classify/build/classifier --input data/ws-5d-non-reflexive --output results \
    --non-reflexive --start 0 --end 999 --threads 32

# the reflexive variant (default schema, with dual point count + Hodge numbers)
./src/classify/build/classifier --input data/ws-5d-reflexive --output results \
    --start 0 --end 999 --threads 32
```

The pipeline is identical for both variants; `--non-reflexive` only drops the
lattice-dual output columns (`dual_point_count`, `h11/h12/h13`) that are
undefined for non-reflexive polytopes. `--merge <dir>` (checkpoint merge) takes
the same flag so its output schema matches.

For the full-scale distributed run, use `--spill-runs` (append mode: bounded
RAM, no growing dedup map) with one process per NUMA socket, and a two-level
`--merge` (per-node `--emit-ckpt` catalogues → global merge). The SLURM scripts
in `scripts/slurm/` orchestrate this; see `docs/OPTIMIZATIONS.md` for the
throughput rationale.

Concatenate a sharded result dataset into one file with the process tools:

```bash
./src/process/build/concat_parquet results/parts results/unique_polytopes.parquet
```

Enrich the catalogue with the actual normal-form vertex matrices (adds an
`nf_vertices` column, row-major int32 `[5 × vertex_count]`; works on both
schemas):

```bash
./src/classify/build/add_nf --input results/unique_polytopes.parquet \
    --output results/enriched.parquet --threads 32
```

## Testing & benchmarking

The correctness gate and benchmark harness are built on the PALP `poly.x`
oracle and a committed golden fixture, so they need no external data.

```bash
make test    # NF/hash regression: oracle + frozen digests + the built classifier
make bench   # WS → NF → hash throughput vs bench/baseline.json
```

- `tests/` freezes the normal form of a size-stratified corpus of weight systems
  (from `poly.x -N`) plus canonical digests. `make test` checks that (a) the
  oracle still reproduces every golden NF, (b) the frozen digests are unchanged,
  and (c) the built `classifier`'s own NF path (`nf_dump`) reproduces every
  golden NF bit-for-bit. See `tests/README.md`.
- `bench/` measures normal-form throughput (weight systems/second) and per-hash
  throughput over the canonical NF bytes, tracked against a per-host baseline.
  See `bench/README.md`.

## Requirements

| Component | Tool | Purpose |
|-----------|------|---------|
| Classifier | Arrow/Parquet C++, CMake ≥ 3.20, Ninja, a C/C++ toolchain | Build and run the pipeline |
| Data download | Python 3 + `huggingface_hub`, `hf-transfer`, `python-dotenv` | Fetch ws-5d shards |
| Tests/bench | Python 3 (stdlib only) | Correctness gate + benchmarks |
| LaTeX notes *(optional)* | `pdflatex` (TeX Live) | Build the notes in `latex/notes/` |

The `latex/notes/` directory contains two standalone documents:

- `theory_notes.tex` — toric geometry, Calabi–Yau manifolds, reflexive
  polyhedra, and Batyrev's construction.
- `ks_classification.tex` — the Kreuzer–Skarke classification programme
  underpinning the pipeline.

```bash
cd latex/notes
pdflatex theory_notes.tex
pdflatex ks_classification.tex   # run twice for cross-references and ToC
```

## Citation

If you use this code or data, please cite the accompanying paper (reference to
be added upon publication).
