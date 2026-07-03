#!/usr/bin/env bash
# merge.sh — dedup the per-node checkpoints into one global catalogue.
#
# Each worker published a full-snapshot checkpoint of its own shard range. The
# classifier's --merge does an external (bounded-memory) sort-merge across them,
# so the same polytope seen on multiple nodes is combined here. Runs as the
# dependent job after the worker array (see submit.sh).
set -euo pipefail

: "${SHARED_ROOT:?}"; : "${CLASSIFIER:?}"; : "${THREADS:?}"
if [[ -n "${CONDA_PREFIX:-}" ]]; then
  export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
fi

CK="$SHARED_ROOT/checkpoints"
FINAL="$SHARED_ROOT/final"
mkdir -p "$FINAL"

n=$(ls -1 "$CK"/*.ckpt 2>/dev/null | wc -l)
echo "[$(date -Is)] merging $n node checkpoint(s) from $CK"
[[ "$n" -gt 0 ]] || { echo "ERROR: no checkpoints to merge"; exit 1; }

"$CLASSIFIER" --merge "$CK" --output "$FINAL" --non-reflexive --threads "$THREADS"

echo "[$(date -Is)] merge complete:"
ls -la "$FINAL"
echo
echo "Optional next steps:"
echo "  # attach the NF vertex matrices"
echo "  $(dirname "$CLASSIFIER")/add_nf --input $FINAL/unique_polytopes.parquet \\"
echo "      --output $FINAL/enriched.parquet --threads $THREADS"
