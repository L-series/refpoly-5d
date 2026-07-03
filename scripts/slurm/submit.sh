#!/usr/bin/env bash
# submit.sh — launch the distributed non-reflexive classification on the cluster.
#
# Splits the dataset's shards evenly across CHUNKS nodes (one exclusive node per
# SLURM array task), each of which streams download -> classify -> delete on
# node-local disk, then a dependent merge job dedups the per-node checkpoints
# into one global catalogue.
#
# The HuggingFace token is read from the repo .env and forwarded to every node
# (via the job environment) so downloads are authenticated (faster, no rate
# limiting). It is never printed or committed.
#
# Usage:
#   ./scripts/slurm/submit.sh
#   CHUNKS=7 BATCH=40 ./scripts/slurm/submit.sh      # override any config below
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# ── Load the HF token from .env (never echoed) ───────────────────────────────
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a; . "$REPO_ROOT/.env"; set +a
fi

# ── Configuration (all overridable via the environment) ──────────────────────
export VARIANT="${VARIANT:-non-reflexive}"
export TOTAL_FILES="${TOTAL_FILES:-4000}"
export CHUNKS="${CHUNKS:-6}"          # nodes to use (6 up now; set 7 when healthy)
export BATCH="${BATCH:-25}"           # shards per download/classify/delete cycle
export THREADS="${THREADS:-128}"      # cores per node
export PARTITION="${PARTITION:-all}"
export LOCAL_ROOT="${LOCAL_ROOT:-/local/edih210/ahatz01}"
export CLASSIFIER="${CLASSIFIER:-$REPO_ROOT/src/classify/build/classifier}"
export CONDA_PREFIX="${CONDA_PREFIX:-$HOME/.local/share/micromamba/envs/process-polytopes}"
export DL_PAR="${DL_PAR:-8}"          # parallel downloads per node
WALL="${WALL:-24:00:00}"
MERGE_WALL="${MERGE_WALL:-6:00:00}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"; export RUN_ID
export SHARED_ROOT="${SHARED_ROOT:-$HOME/refpoly-runs/$RUN_ID}"

# ── Preflight ────────────────────────────────────────────────────────────────
[[ -x "$CLASSIFIER" ]] || { echo "ERROR: classifier not built at $CLASSIFIER"; exit 1; }
if [[ -n "${HF_TOKEN:-}" ]]; then
  who=$(env -u LD_LIBRARY_PATH curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $HF_TOKEN" \
        https://huggingface.co/api/whoami-v2 2>/dev/null || echo 000)
  if [[ "$who" == "200" ]]; then echo "HF_TOKEN: valid (authenticated downloads)"
  else echo "WARNING: HF_TOKEN in .env is INVALID (whoami=$who) — workers will download"
       echo "         anonymously. The dataset is public so this still works, but replace"
       echo "         the token in .env with a valid one to avoid rate limits."
  fi
else
  echo "WARNING: HF_TOKEN unset — anonymous downloads (public dataset; may rate-limit)"
fi
mkdir -p "$SHARED_ROOT"/{logs,status,checkpoints}

cat <<CFG
=== refpoly-5d distributed classification ===
run id      : $RUN_ID
variant     : $VARIANT   files: $TOTAL_FILES
nodes/chunks: $CHUNKS  (~$(( TOTAL_FILES / CHUNKS )) shards each)  batch: $BATCH
threads/node: $THREADS   partition: $PARTITION
local scratch: $LOCAL_ROOT/$RUN_ID
shared out  : $SHARED_ROOT
HF auth     : $([[ -n "${HF_TOKEN:-}" ]] && echo yes || echo no)
CFG

# ── Worker array: one exclusive node per chunk ───────────────────────────────
JOB=$(sbatch --parsable \
  --job-name="refpoly-$RUN_ID" \
  --partition="$PARTITION" \
  --array="0-$(( CHUNKS - 1 ))" \
  --exclusive --nodes=1 --ntasks=1 --cpus-per-task="$THREADS" \
  --time="$WALL" \
  --output="$SHARED_ROOT/logs/slurm-worker-%a.out" \
  --export=ALL \
  "$HERE/worker.sh")
echo "submitted worker array: job $JOB (tasks 0-$(( CHUNKS - 1 )))"

# ── Merge job: runs only if every worker succeeded ───────────────────────────
MJOB=$(sbatch --parsable \
  --job-name="refpoly-merge-$RUN_ID" \
  --partition="$PARTITION" \
  --dependency="afterok:$JOB" \
  --nodes=1 --ntasks=1 --cpus-per-task="$THREADS" \
  --time="$MERGE_WALL" \
  --output="$SHARED_ROOT/logs/slurm-merge.out" \
  --export=ALL \
  "$HERE/merge.sh")
echo "submitted merge job: $MJOB (afterok:$JOB)"
echo
echo "monitor: $HERE/monitor.sh $SHARED_ROOT --watch"
echo "final result will be: $SHARED_ROOT/final/unique_polytopes.parquet"
