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

## Requirements

| Component | Tool | Purpose |
|-----------|------|---------|
| LaTeX notes *(optional)* | `pdflatex` (TeX Live) | Compiles `latex/notes/theory_notes.tex` into a PDF summarising the mathematical background. Install via [TeX Live](https://tug.org/texlive/). |

To build the PDF:

```bash
cd latex/notes
pdflatex theory_notes.tex
```

## Citation

If you use this code or data, please cite the accompanying paper (reference to be added upon publication).
