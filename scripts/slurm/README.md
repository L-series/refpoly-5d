# Distributed classification on the SLURM cluster

Streams the ws-5d dataset across nodes: each node downloads its shard range to
node-local disk in batches, classifies (NF → hash → dedup), and **deletes shards
as it consumes them**, so local disk stays bounded. A dependent merge job dedups
the per-node results into one global catalogue.

## Files

| script | role |
|---|---|
| `submit.sh`  | driver: splits shards, submits the worker array + dependent merge job |
| `worker.sh`  | one SLURM array task = one node = one contiguous shard range (download → classify → delete, streamed) |
| `merge.sh`   | dependent job: `--merge` all node checkpoints → `final/unique_polytopes.parquet` |
| `monitor.sh` | aggregate live progress across chunks |

## Usage

```bash
# from the repo root, with the classifier built (src/classify/build.sh)
./scripts/slurm/submit.sh                       # 6 nodes (default), non-reflexive
CHUNKS=7 ./scripts/slurm/submit.sh              # use all 7 nodes (when healthy)
CHUNKS=6 BATCH=40 THREADS=128 ./scripts/slurm/submit.sh

# watch progress
./scripts/slurm/monitor.sh $HOME/refpoly-runs/<run_id> --watch
```

Output: `$HOME/refpoly-runs/<run_id>/final/unique_polytopes.parquet`
(then optionally `add_nf` to attach NF vertex matrices — see `merge.sh` output).

## Configuration (env vars, all optional)

`CHUNKS` (nodes, default 6) · `BATCH` (shards per download/classify/delete cycle,
default 25) · `THREADS` (cores/node, default 128) · `PARTITION` (default `all`) ·
`VARIANT` (default `non-reflexive`) · `LOCAL_ROOT` (default
`/local/edih210/ahatz01`) · `SHARED_ROOT` · `DL_PAR` (parallel downloads/node) ·
`WALL` / `MERGE_WALL`.

## How it stays correct while streaming

A classifier checkpoint is a **full snapshot** of the dedup map, and `--resume`
reloads it. Each batch runs with `--resume` into the same checkpoint dir; the
worker keeps only the newest snapshot so `--resume` loads it exactly once. This
was verified to produce the **identical** unique count (and exact `sum(count)`
accounting) as a single non-streamed run, and the cross-node merge likewise
dedups disjoint node outputs correctly.

## HuggingFace token

`submit.sh` sources the repo `.env` and forwards `HF_TOKEN` to every node (via
the job environment; never printed or committed — `.env` is gitignored). The
token is validated with `whoami-v2`; **if it is invalid the workers download
anonymously** — the dataset is public, so this still works, just without the
higher authenticated rate limits. Replace the token in `.env` to re-enable auth.

## Notes / caveats

- **Even split**: shard `i` range is computed so all files are covered with no
  gaps/overlaps; the remainder is spread over the first chunks (666–667
  files/node at 6 nodes, 571–572 at 7).
- **Memory**: each node accumulates its shard range's dedup map in RAM. The
  classifier logs RSS + map size per file. If a node approaches its RAM limit,
  raise `CHUNKS` (fewer shards per node → smaller per-node map). The final
  `--merge` is an external sort-merge and is bounded-memory.
- **I/O**: downloads land on node-local `LOCAL_ROOT`; nothing large crosses the
  shared filesystem except the per-node checkpoints and the final catalogue.
- **Resilience**: the worker array is resubmittable per-chunk; already-downloaded
  shards are skipped and each download retries with an integrity (PAR1) check.
