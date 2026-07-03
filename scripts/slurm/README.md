# Distributed classification on the SLURM cluster

Classifies the ws-5d dataset across nodes. Each node streams its shard range
(download a batch → classify → **delete the batch**, so node-local input stays
tiny), running **one classifier process per NUMA socket** so both memory
controllers are used and cross-socket traffic is avoided. Each process is in
**append / spill-runs** mode: per file it computes NF + hash across its socket's
cores, sorts + collapses, and spills one sorted run — no growing in-RAM dedup
map (RAM bounded to one file). Dedup is a **two-level sort-merge**: each node
merges its own runs into one node-catalogue `.ckpt`, then a dependent job merges
the node catalogues into the final parquet.

Why this shape: the per-CWS hash-map insert (not PALP compute) was the
throughput bottleneck, and a single process spanning both sockets lost ~1.7× to
NUMA. See `docs/OPTIMIZATIONS.md`. Measured ~1.35M CWS/s/node → ~8M/s over 6
nodes (~4–5 h for the full 137B).

## Files

| script | role |
|---|---|
| `submit.sh`  | driver: splits shards, submits the worker array + dependent merge job |
| `worker.sh`  | one array task = one node: per-socket streaming spill, then per-node sort-merge → node catalogue `.ckpt` |
| `merge.sh`   | dependent job: global `--merge` of the node catalogues → `final/unique_polytopes.parquet` |
| `monitor.sh` | aggregate live progress across chunks |

## Usage

```bash
# from the repo root, with the classifier built (src/classify/build.sh)
./scripts/slurm/submit.sh                       # 6 nodes (default), non-reflexive
CHUNKS=7 ./scripts/slurm/submit.sh              # use all 7 nodes (when healthy)
CHUNKS=6 BATCH=40 ./scripts/slurm/submit.sh

# watch progress
./scripts/slurm/monitor.sh $HOME/refpoly-runs/<run_id> --watch
```

Output: `$HOME/refpoly-runs/<run_id>/final/unique_polytopes.parquet`
(then optionally `add_nf` to attach NF vertex matrices — see `merge.sh` output).

## Configuration (env vars, all optional)

`CHUNKS` (nodes, default 6) · `BATCH` (shards per download/classify/delete cycle
**per socket**, default 25) · `THREADS` (cores/node, default 128; split evenly
across NUMA sockets) · `PARTITION` (default `all`) · `VARIANT` (default
`non-reflexive`) · `LOCAL_ROOT` (default `/local/edih210/ahatz01`) ·
`SHARED_ROOT` · `DL_PAR` (parallel downloads/socket) · `WALL` / `MERGE_WALL`.

## How it stays correct

Each per-file run is a sorted, deduped list of `MergeRecord`s. Node and global
stages are external sort-merges (bounded memory; node catalogues and runs are
pre-sorted so `--assume-sorted` skips the sort phase). The append path and the
two-level merge were each verified to produce an **identical NF-hash set and
per-hash counts** as a single in-RAM run; the full worker pipeline was validated
end-to-end on one node (files 0–3, 2 sockets, streamed) reproducing the exact
independently-measured unique count (86,741,745).

## HuggingFace token

`submit.sh` sources the repo `.env` and forwards `HF_TOKEN` to every node (via
the job environment; never printed or committed — `.env` is gitignored). The
token is validated with `whoami-v2`; **if it is invalid the workers download
anonymously** — the dataset is public, so this still works, just without the
higher authenticated rate limits. Replace the token in `.env` to re-enable auth.

## Notes / caveats

- **Even split**: the node range is computed so all files are covered with no
  gaps/overlaps (remainder on the first chunks); within a node it is split
  evenly across sockets.
- **Memory**: bounded per file (append buffer + one file's rows, a few tens of
  GB per socket) — no growing global map. The node and global merges are
  external and bounded-memory.
- **Disk**: node-local runs are ~1.4 TB/node at full scale (`/local` has 11–16
  TB free) and are freed after the node catalogue is published; only the small
  node catalogues and the final parquet cross the shared filesystem.
- **Resilience**: the worker array is resubmittable per-chunk; already-downloaded
  shards are skipped and each download retries with an integrity (PAR1) check.
  Runs are uniquely named (`<tag>-<global_idx>.ckpt`) and written atomically, so
  a resubmit overwrites exactly its own runs.
