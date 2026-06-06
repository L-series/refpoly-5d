# refpoly-5d

Companion repository to the paper:

> **Classification of Unique Five-Dimensional Reflexive Polytopes from Weight Systems**

## Overview

This repository contains the computational pipeline, code, and data artefacts supporting a complete classification of five-dimensional reflexive polytopes arising from weight systems.

Starting from the Skarke–Scholler dataset (~185 billion weight systems), the pipeline:

1. Computes the normal form of each associated polytope under GL(5,ℤ) equivalence using the PALP library
2. Hashes the resulting canonical matrix
3. Deduplicates across the full 3.2 TB dataset via a two-phase external sort-merge algorithm running across distributed compute nodes

The output is a single deduplicated catalogue of unique polytopes with frequency counts and topological metadata.

Correctness of critical code paths is established through formal verification using bounded model checking (CBMC) and abstract interpretation (Frama-C). The repository also includes data-scientific analysis of the resulting dataset.

## Structure

```
refpoly-5d/
├── README.md
```

## Getting Started

This repository uses [PALP](https://github.com/L-series/PALP) as a git submodule. After cloning, initialize and update the submodule before running the pipeline:

```bash
git submodule update --init --recursive
```

If you cloned with `--recurse-submodules`, this step is already done.

## Requirements

| Component | Tool | Purpose |
|-----------|------|---------|
| LaTeX notes *(optional)* | `pdflatex` (TeX Live) | Compiles the LaTeX notes in `latex/notes/` into PDFs summarising the mathematical background. Install via [TeX Live](https://tug.org/texlive/). |

The `latex/notes/` directory contains two standalone documents:

- `theory_notes.tex` — toric geometry, Calabi–Yau manifolds, reflexive polyhedra, and Batyrev's construction.
- `ks_classification.tex` — the Kreuzer–Skarke classification programme (finiteness, maximal/minimal duality, subpolytope structure, weight systems) underpinning the `refpoly-5d` pipeline.

To build the PDFs:

```bash
cd latex/notes
pdflatex theory_notes.tex
pdflatex ks_classification.tex   # run twice for cross-references and table of contents
```

## Citation

If you use this code or data, please cite the accompanying paper (reference to be added upon publication).
