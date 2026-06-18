---
name: ref-full-classification-stats
description: Where the authoritative full d=5 classification statistics live (per-vertex-count, count distributions) vs the small test sample.
metadata:
  type: reference
---

Two tiers of d=5 reflexive-polytope data exist; do not confuse them.

- SMALL TEST SAMPLE: `~/data/ws5d_sieved_dataset_v2_clean_test.parquet`
  (502,432 NFs, 9.3M WS). Per-row schema incl. `nf_vertices` blob, `weight_systems`,
  `count`. WARNING: its `vertex_count`/`facet_count` columns are CORRUPT; get true
  nv from `nf_vertices` length (len//20 in d=5). Good for per-WS-fibre inspection,
  NOT for global distributions (it is a biased sample).

- FULL CLASSIFICATION (authoritative, 2,377,115,412 NFs / 185,269,499,015 WS):
  `~/data/unique_polytopes_clean.parquet` (the materialized 2.3B-row table), with
  precomputed summaries under `~/repos/process-polytopes/results/`:
    * `count_stats/count_by_vertex.csv` + `SUMMARY.md` -- exact per-vertex-count
      breakdown: n_polytopes, mean/median/p90/p99/max count, total_count (WS mass)
      for nv=6..46. THE table for vertex-count / Gale-dimension calibration.
    * `count_stats/extremes.txt`, `eda/`, `analysis_345/` -- Hodge/EDA/identities.
  To recompute from scratch: scan `unique_polytopes_clean.parquet` (vertex_count
  column IS valid there, unlike the test sample); ~340s for the full scan.

Use this when the user asks about global vertex-count / fibre-size / Gale-stratum
distributions over the WHOLE classification.
Related: [[fibre-dataset-findings]], [[project-refpoly5d]].
