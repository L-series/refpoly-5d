---
name: fibre-dataset-findings
description: Empirical findings on the d=5 WS->NF fibre from the real Schoeller-Skarke parquet dataset (~/data/ws5d_sieved_dataset_v2_clean*), incl. vertex-count / Gale-dimension calibration.
metadata:
  type: project
---

The user has a materialized WS->NF map at `~/data/ws5d_sieved_dataset_v2_clean*.parquet`
(test sample: `..._test.parquet`, 502,432 unique NFs, 148MB, 1 row group).
Schema per row (= one unique normal form):
`nf_vertices`(binary), `weight_systems`(list<list<int32>> = ALL WS in that fibre),
`count`(int64 = fibre size, == len(weight_systems)), `vertex_count`,`facet_count`,
`point_count`,`dual_point_count`, `h11,h12,h13,h22`, `chi`, `bh_mp,bh_mv,bh_np,bh_nv`
(the M:np nv / N:np nv Batyrev signature). Larger files: `unique_polytopes*.parquet`
(84-252 GB), `ws5d_sieved_dataset_v2_clean[_lists].parquet` (~21 GB).

**DATA-QUALITY GOTCHA (verified 2026-06-15):** in the *_test.parquet sample the
`vertex_count` and `facet_count` columns are CORRUPT / mislabeled (vertex_count
holds large IDs/hashes like 983054; ~88% of facet_count is the INT32_MIN
sentinel or 2e9 garbage). DO NOT use those columns. The TRUE vertex count is
recoverable from `nf_vertices`: it is a flat little-endian int32 array encoding a
d x nv matrix (d=5 rows = coords, nv cols = vertices, PALP NF convention). So
nv = len(nf_vertices_bytes)//(4*d) = len//20. All 502,432 blobs are divisible by
20; min nv = 7, max = 36, mean 16.47, median 16. (Verified: nv=7 blob reshapes to
a clean 5x7 Hermite-leading NF matrix.)

**VERTEX-COUNT / GALE-DIMENSION CALIBRATION (the headline new result).**
AUTHORITATIVE source = the FULL classification, not the 502K sample:
`~/repos/process-polytopes/results/count_stats/count_by_vertex.csv` + `SUMMARY.md`
(scan of `~/data/unique_polytopes_clean.parquet`, 2,377,115,412 NFs /
185,269,499,015 WS; cross-checks exactly). True nv per NF is also recoverable from
the test parquet's `nf_vertices` blob as len//(4*d)=len//20 (the vertex_count
COLUMN there is corrupt). Gale dim g = nv-d-1 = nv-6 in d=5.

FULL-DATA per-vertex breakdown (cumulative tractable strata):
- nv=6 (g=0, SIMPLICES, Conrads exact): 50,001 NFs = 0.0021% of NFs, but
  1,311,836,904 WS = 0.708% of WS mass (mean fibre ~26,236!).
- g<=1 (nv<=7): 428,705 NFs (0.018%) / 6.19B WS (3.34%).
- g<=2 (nv<=8): 2,285,313 NFs (0.096%) / 16.09B WS (8.68%).
- g<=5 (nv<=11): 65.9M NFs (2.77%) / 69.5B WS (37.5%).
- g<=10 (nv<=16): 863.7M NFs (36.3%) / 155.8B WS (84.1%).
- Distribution peaks at nv=17 by NF count (252M), nv=12 by WS mass; median nv ~17.

KEY NON-OBVIOUS ASYMMETRY: by NF count the tractable few-vertex strata are
negligible (g<=2 = 0.096%), BUT by WEIGHT-SYSTEM MASS they are sizeable
(g<=2 = 8.7%, g<=5 = 37.5%), because low-vertex polytopes have HUGE mean fibres
(nv=6: ~26k WS each; nv=7: ~12.9k). The SINGLE LARGEST FIBRE in the entire
classification -- weight system [62,81,491,1206,1647,1840], deg 5327, count
650,642,665 -- is a nv=7 (g=1) polytope (h11=28348, the max-h11 extreme). So a
generalized-Conrads predictor on the g<=2 strata would cover few NFs but resolve
a DISPROPORTIONATE share of WS-pairs (the metric the dedup cost is actually paid
in). Honest conclusion: program is the right CEILING; covers ~0.1% of NFs but
~9% of WS mass at g<=2; the high-Gale-dim residue dominates the NF count and
provably needs the GL(5,Z) NF.
Earlier 502K-sample numbers (g<=2 = 28 NFs) were a BIASED sample (it contained
zero nv=6 simplices); use the full-data numbers above.

**EARLIER VERIFIED EMPIRICAL FACTS (test sample, still hold):**
- Fibre-size distribution HEAVILY skewed: 36% of NFs singletons, median fibre=2,
  mean ~18.5 (this sample) / ~80 (full SS list), MAX=656,054. The spread is the story.
- Within a fibre, DEGREE is NOT constant (~0.15%) and weight MULTISET NOT constant
  (0%). The hull alpha merges WS of different degree/weights. => degree+multiset
  are invariants of the SIMPLICIAL CORE, NOT the Newton-polytope NF.
- STRICTLY fibre-constant WS-local invariants (only valid sieve components, 100%
  over 40k multi-WS fibres): #distinct weights, Gorenstein flag (w_i|D),
  multiplicity profile, any weight=1, #weights==1. NOT constant: degree, min, max,
  #Gorenstein slots, degree parity.
- These valid WS-local invariants resolve only ~0.17% of WS-pairs as 'different';
  99.8% need the hull+NF. Full polytope signature (Hodge+pointcounts+vc/fc) nearly
  injective: 502,425 distinct sigs for 502,432 NFs (7 collisions).

**Upshot for the user's stay-in-WS goal:** a purely WS-local same-NF sieve is
necessary-only and very weak. The reflexive-SIMPLEX subclass is the clean
exception (Conrads), and the natural generalization is the low-Gale-dimension
(nv=d+2, d+3) strata -- but the SS maximal list almost never lands there.

Scratch scripts: /home/ahat01/.claude/jobs/d651e2f4/tmp (ephemeral).
Related: [[fibre-worked-examples]], [[notes-document-state]], [[project-refpoly5d]].
