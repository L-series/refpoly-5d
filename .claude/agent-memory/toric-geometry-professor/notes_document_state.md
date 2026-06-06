---
name: notes-document-state
description: State of docs/theory_notes.tex — which sections are written vs placeholder.
metadata:
  type: project
---

The running LaTeX lecture notes live at `latex/notes/theory_notes.tex` (amsart
class, standard theorem environments). Created 2026-06-06. (User explicitly chose
`latex/notes/` over `docs/` for the file location.)

There is also a SECOND standalone document `latex/notes/ks_classification.tex`
(created 2026-06-06, same amsart preamble/theorem envs), a self-contained
chapter on the Kreuzer--Skarke classification programme: finiteness
(Hensley/Lagarias--Ziegler), subpolytope->maximal reduction, max/min polar
duality, decomposition of minimal polytopes into simplices/products (IP
property, circuits), and weight systems + combined weight systems, ending with
the full KS pipeline and a refpoly-5d tie-in. References include the two KS
papers (1998 hep-th/9805190, 2000 hep-th/0002240), PALP (math/0204356), Batyrev,
Hensley, Lagarias--Ziegler. Compiles clean with pdflatex (run twice; 8 pages).
README build section lists both .tex files. Each document is its OWN standalone
file (own \documentclass + \maketitle); there is no master/include file.

Section status:
- **Foundations of Toric Geometry** — PLACEHOLDER only (lattices/fans intro + a
  remark noting it is to be filled in). Cones, Cox ring, divisors, intersection
  theory still TODO.
- **Calabi--Yau Manifolds** — WRITTEN: Definition (4 equivalences), Yau's theorem,
  Hodge numbers/moduli.
- **Why Calabi--Yau Manifolds Matter** — WRITTEN: math significance, physics/string
  significance, remark tying to refpoly-5d / F-theory.
- **Reflexive Polyhedra** — WRITTEN: definition, properties (involution, single
  interior point, finiteness), Kreuzer--Skarke counts, P^2 simplex example.
- **Batyrev's Construction and Mirror Symmetry** — WRITTEN: Gorenstein-Fano
  equivalence, main hypersurface theorem w/ adjunction, quintic example, mirror
  symmetry via polar duality + Hodge-number formula.
- **Key Results from the Literature** — WRITTEN: Batyrev 1994, Yau 1978,
  CDGP 1991, Kreuzer--Skarke.

**How to apply:** Append to existing sections rather than duplicating. The Toric
Foundations section is the obvious next thing to flesh out. No \cite/bibliography
yet — references are inline text; consider adding a .bib if it grows.
Related: [[project-refpoly5d]], [[user-profile]].
