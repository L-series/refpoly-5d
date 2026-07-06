#!/usr/bin/env bash
# maxcheck_submit.sh — launch the distributed r-maximality FAST PASS on SLURM.
#
# Splits the 2267 row groups of unique_polytopes_clean.parquet evenly across
# CHUNKS exclusive nodes (one array task per node); each node runs one maxcheck
# process per core over its row-group sub-range (see maxcheck_worker.sh).  Output
# is four append-only index streams per process under $SHARED_ROOT/streams; a
# dependent tally job checks count-conservation and joins the .max indices back
# to full records (maxcheck_tally.py).
#
# The FAST PASS deterministically DEFERs the expensive large-dual tail
# (dual_point_count > DPC_GATE) and any item over the per-item budget; those
# rows are the input to a later slow/robust pass.  It harvests the r-maximal set
# — which lives in the small-dual head — quickly and provably.
#
# Usage:
#   ./scripts/slurm/maxcheck_submit.sh
#   CHUNKS=4 DPC_GATE=2000 BUDGET_MS=1000 ./scripts/slurm/maxcheck_submit.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

export INPUT="${INPUT:-/local/edih210/data/unique_polytopes_clean.parquet}"
export MAXBIN="${MAXBIN:-$REPO_ROOT/src/classify/build-max/maxcheck}"
export TOTAL_RG="${TOTAL_RG:-2267}"
export CHUNKS="${CHUNKS:-4}"          # exclusive nodes (see memory: 4 exclusive-able)
export DPC_GATE="${DPC_GATE:-2000}"   # defer dual_point_count > this
export BUDGET_MS="${BUDGET_MS:-1000}" # per-item wall-clock budget
export RSS_CAP_MB="${RSS_CAP_MB:-12000}"
export CHECKPOINT="${CHECKPOINT:-65536}"
export STACK_KB="${STACK_KB:-2000000}"
export PARTITION="${PARTITION:-all}"
export CONDA_PREFIX="${CONDA_PREFIX:-$HOME/.local/share/micromamba/envs/process-polytopes}"
WALL="${WALL:-24:00:00}"

RUN_ID="${RUN_ID:-maxchk-$(date +%Y%m%d-%H%M%S)}"; export RUN_ID
export SHARED_ROOT="${SHARED_ROOT:-$HOME/refpoly-runs/$RUN_ID}"

[[ -x "$MAXBIN" ]] || { echo "ERROR: maxcheck not built at $MAXBIN"; exit 1; }
[[ -f "$INPUT" ]]  || echo "WARN: INPUT $INPUT not visible from submit host (must be readable on every node)"
mkdir -p "$SHARED_ROOT"/{logs,status,streams,final}

cat <<CFG
=== refpoly-5d r-maximality FAST PASS ===
run id      : $RUN_ID
input       : $INPUT  ($TOTAL_RG row groups)
maxbin      : $MAXBIN
nodes/chunks: $CHUNKS   (~$(( TOTAL_RG / CHUNKS )) row groups each)
dpc gate    : $DPC_GATE   budget: ${BUDGET_MS}ms   stack: ${STACK_KB}KB
shared out  : $SHARED_ROOT/streams  (per-process .max/.nonmax/.defer/.anom)
CFG

JOB=$(sbatch --parsable \
  --job-name="rmax-$RUN_ID" \
  --partition="$PARTITION" \
  --array="0-$(( CHUNKS - 1 ))" \
  --exclusive --nodes=1 --ntasks=1 \
  --time="$WALL" \
  --output="$SHARED_ROOT/logs/slurm-maxchk-%a.out" \
  --export=ALL \
  "$HERE/maxcheck_worker.sh")
echo "submitted maxcheck array: job $JOB (tasks 0-$(( CHUNKS - 1 )))"

# Dependent tally: count-conservation + join .max indices → maximal parquet.
TJOB=$(sbatch --parsable \
  --job-name="rmax-tally-$RUN_ID" \
  --partition="$PARTITION" \
  --dependency="afterok:$JOB" \
  --nodes=1 --ntasks=1 --cpus-per-task=8 \
  --time="2:00:00" \
  --output="$SHARED_ROOT/logs/slurm-tally.out" \
  --export=ALL \
  --wrap="LD_LIBRARY_PATH=\"$CONDA_PREFIX/lib:\${LD_LIBRARY_PATH:-}\" \
          \"$CONDA_PREFIX/bin/python\" \"$HERE/maxcheck_tally.py\" \
          --input \"$INPUT\" --streams \"$SHARED_ROOT/streams\" \
          --out \"$SHARED_ROOT/final\"")
echo "submitted tally job: $TJOB (afterok:$JOB)"
echo
echo "streams  : $SHARED_ROOT/streams"
echo "final    : $SHARED_ROOT/final/maximal.parquet  (+ tally.txt)"
