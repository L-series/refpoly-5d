---
name: fibre-worked-examples
description: Verified d=5 weight-system examples for the WS->NF fibre / predictor-(4) discussion in ks_classification.tex sec:fibre.
metadata:
  type: project
---

Numerically verified (python+scipy+sympy, exact integer facet normals) examples
used in the `sec:fibre` worked-example subsection of
`latex/notes/ks_classification.tex`. Newton polytope Delta_q = conv(monomials of
deg D = sum w_i, shifted by -1) lives on the 5-dim weight hyperplane. Facet at
lattice distance c; reflexive iff all c==1.

**POSITIVE (predictor (4) fires, provable from WS alone):**
- Permutation coincidence: WS related by reordering the weight multiset (e.g.
  (1,1,1,1,2,2) ~ (1,1,2,2,1,1)) give IDENTICAL Newton polytope via a coordinate
  permutation = lattice automorphism. Same circuit, same #monomials, same NF.
  The cheapest, fully WS-local same-NF certificate.

**NEGATIVE / FALSE-POSITIVE 1 (subtle; even strong fingerprint fails):**
- q=(1,1,1,1,1,1) D=6 and q=(1,1,2,2,2,4) D=12 are BOTH reflexive 5-simplices:
  6 vertices, 6 facets all at distance 1, SAME normalized volume 7776 = 6^5,
  same facet-distance multiset. YET their intrinsic circuit weights (Conrads'
  GL-invariant of a reflexive simplex = positive integer relation sum a_i V_i=0
  among vertices) are (1,1,1,1,1,1) vs (1,1,2,2,2,4) -> NOT GL(5,Z)-equivalent.
  Lesson: nv+nf+normvol+facet-dists all agree but polytopes differ; the
  separating invariant IS the circuit weight (so on the simplex class Conrads'
  circuit normal form is exactly the right, cheap, decisive test).

**FALSE-POSITIVE 2 (coarse; separable by polytope invariants, not by WS sieve):**
- q=(1,1,1,3,4,4) and q=(1,1,2,2,2,6), both D=14, both exactly 651 monomials
  (agree on the two cheapest WS-local invariants D and #monomials), but
  (#verts,#facets) = (14,9) vs (10,7); moreover (1,1,1,3,4,4) is NON-reflexive
  (a facet sits at distance 5) while (1,1,2,2,2,6) is reflexive. Honest demo
  that (D, #monomials) is NOT a sufficient sieve.

Scripts under /home/ahat01/.claude/jobs/d651e2f4/tmp (ephemeral). Key gotcha:
canonical WS are sorted ascending; (1,1,2,2,2,4) has D=12 not 11.
Related: [[notes-document-state]].
