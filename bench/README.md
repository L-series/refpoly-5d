# bench/ — pipeline benchmark harness

The single benchmark entry point for the pipeline (replacing the ~70 one-off
scripts in the source repo). Tracks the two stages that dominate the classify
path and records a per-host baseline so regressions are caught early.

## Metrics

| metric | what it measures |
|---|---|
| `nf_throughput_ws_per_s` | weight systems normalized per second (`poly.x -Nf`) |
| `hash_MBps[algo]` | throughput of each registered hash over the canonical NF bytes — the pluggable-hash comparison |

## Run

```bash
make bench            # measure, print, no write
make bench-update     # measure + record bench/baseline.json for this host
make bench-check      # measure + fail if >25% below this host's baseline
python3 bench/bench_nf.py --n 2000   # quick subset
```

## Baseline

`baseline.json` is keyed by `host:machine` because timings are machine-dependent;
`--check` only compares against the same host. Commit baseline updates when you
intentionally accept a new performance level.

Reference (host `rci-head`, 10k corpus): NF ≈ 11k ws/s — consistent with the
source repo's measured ~11k CWS/s CPU path, a sanity check on the oracle.

## Phase 1

When the C++ classifier lands, add a `--classifier <binary>` backend here so the
same corpus times the real pipeline (NF + dedup) and the poly.x number becomes
the lower-bound reference.
