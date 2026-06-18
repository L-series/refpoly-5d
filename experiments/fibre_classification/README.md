# Gale fibre key — a $GL(5,\mathbb{Z})$-invariant classifier for $d=5$ reflexive polytopes

Concrete realization of the program in `latex/notes/ks_classification.tex`,
§"Generalizing Conrads by Gale duality" (`sec:fibre-gale`) and the verification
subsection `sec:fibre-verify`. Given the vertices of a $d=5$ reflexive polytope
(the post-hull object), it computes a permutation- and $GL(5,\mathbb{Z})$-invariant
**fibre key** that replaces the PALP normal form (the map $\beta$) as a fibre
identifier — i.e. it predicts which weight systems share a Newton-polytope fibre,
without computing the normal form.

The hull step $\alpha$ (weight system $\to$ vertices) is provably irreducible
(obstruction theorem); this tool takes the vertices as input. `ws_construct.py`
builds them directly from a weight system (no PALP) for the end-to-end path.

## Files

| file | purpose |
|---|---|
| `galeclass.py` | **core module.** decode, exact integer facet normals, the layered key (`fingerprint`: L0,L1,Lpm,Lar,Lbr), the signed-chirotope layer (`oriented_signature` = Los), and the exact $GL(5,\mathbb{Z})$ isomorphism resolver (`gl_equiv`). |
| `ws_construct.py` | build the Newton polytope $\Delta_q$ directly from a single weight system $q$ and key it (the hull $\alpha$, no NF). |
| `cascade_job.py` + `cascade_submit.sh` | full-dataset completeness test (one SLURM node, 64 cores): vectorized free-invariant grouping, then the geometric key only on collisions. |
| `resolve_residual.py` | drill-down: recompute the full layered key (incl. Lar, Lbr) on the residual-collision fibres. |
| `check_equiv.py` | confirm residual collision-mates are genuinely distinct (byte / point-set / signed-chirotope-count). |
| `check_glequiv.py` | decisive exact $GL(5,\mathbb{Z})$-equivalence search on the residual groups. |
| `test_om.py` | invariance + separation tests for the signed-chirotope layer (prototype of `oriented_signature`). |

## The layered key

For vertices $A$ (the `oriented_signature` layer is symmetric under the global
reorientation a $\det=-1$ lattice map induces):

- **L0** $(g, n_v, n_F, \text{normalized volume})$ — coarse invariants
- **L1** $+$ facet-size & vertex-degree multisets — combinatorial type
- **Lpm** $+$ vertex–facet pairing-matrix multisets
- **Lar** $+$ Smith normal forms — arithmetic decoration
- **Lbr** $+$ bracket magnitudes — unsigned chirotope
- **Los** $+$ color-keyed *signed* integer brackets, up to relabeling+reorientation — signed chirotope

## Verified results (88,588,676-fibre $d=5$ sample, one row per distinct NF)

- **Well-defined:** every layer is constant on $GL(5,\mathbb{Z})\times S_{n_v}$
  orbits incl. reflections (tested $g=1..30$, zero changes; exact path checked to
  coordinate magnitude ~2000).
- **Cheap key** (free invariants $\oplus$ L1 $\oplus$ Lpm): **88,588,633** distinct
  classes; only **85** fibres over-merged (42 groups, $g=2..11$) — **injective on
  99.99990%**. Free invariants alone leave 12.65% needing geometry.
- **The 85-fibre hard core:** all pairwise $GL(5,\mathbb{Z})$-**inequivalent**
  (`gl_equiv`), yet identical on L1, Lpm, Lar, Lbr **and** Los — bounded multiset
  invariants saturate here. (A signed-bracket tally under the NF's own coordinate
  order *appears* to separate 37/42, but that order is not $GL$-invariant — an
  artifact.)
- **Complete classifier** = cheap key + `gl_equiv` on the ~$10^{-6}$ residual →
  **injective on all 88,588,676 fibres**. The expensive canonical step runs only
  on the irreducible lattice-isomorphism core.

## Quick use

```python
import galeclass as gc
V = gc.decode_vertices(nf_vertices_blob, n_v)   # n_v = bh_mv (NOT vertex_count, which is corrupt)
fp, reflexive = gc.fingerprint(V)               # L0..Lbr layers
los = gc.oriented_signature(V)                  # signed-chirotope layer
same_fibre = gc.gl_equiv(V1, V2)                # exact, for the hard-core residue
```

**Dataset encoding gotchas:** `nf_vertices` is the PALP $d\times n_v$ matrix stored
**column-major** `int32`; true vertex/facet counts are `bh_mv`/`bh_nv`
(`vertex_count`/`facet_count` are corrupt). Data lives in `~/data/ws5d_*` (not in
the repo); `cascade_job.py` and the checkers hardcode that path.
