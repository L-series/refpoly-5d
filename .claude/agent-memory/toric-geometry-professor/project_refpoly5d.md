---
name: project-refpoly5d
description: refpoly-5d repo classifies unique 5d reflexive polytopes from weight systems (PALP normal forms, dedup over Skarke-Scholler dataset); F-theory motivation.
metadata:
  type: project
---

The `refpoly-5d` repository is the companion to the paper "Classification of
Unique Five-Dimensional Reflexive Polytopes from Weight Systems."

Pipeline (per README): starts from the Skarke--Scholler dataset (~185 billion
weight systems, 3.2 TB), computes PALP normal forms under $GL(5,\mathbb{Z})$,
hashes canonical matrices, and deduplicates via two-phase external sort-merge
across distributed nodes. Critical paths verified with CBMC and Frama-C.

**Why:** 5d reflexive polytopes are the ambient-space seeds for Calabi--Yau
fourfolds (anticanonical hypersurfaces in 5d toric varieties), which are exactly
the geometries used in F-theory compactifications. Dimension 5 is NOT in the
completed Kreuzer--Skarke classification (which stops at dim 4 = 473,800,776),
so this is frontier work.

**How to apply:** When explaining CY / mirror-symmetry / Batyrev theory, connect
to CY fourfolds and F-theory, and note the dim-5 classification is open. Relevant
to user profile [[user-profile]].
