#!/usr/bin/env bash
# merge.sh — global merge of the per-node catalogues into the final catalogue.
#
# Each worker published one node-catalogue .ckpt (its shard range, already
# deduped + sorted) to $SHARED_ROOT/catalogues/.  This job does the final
# cross-node sort-merge over those catalogues → unique_polytopes.parquet.
# Node catalogues are pre-sorted, so --assume-sorted skips Phase 1 (the k-way
# streaming merge in Phase 2 is bounded-memory).  Runs as the dependent job
# after the worker array (see submit.sh).
set -euo pipefail

: "${SHARED_ROOT:?}"; : "${CLASSIFIER:?}"; : "${THREADS:?}"
if [[ -n "${CONDA_PREFIX:-}" ]]; then
  export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
fi

CK="$SHARED_ROOT/catalogues"
FINAL="$SHARED_ROOT/final"
mkdir -p "$FINAL"

n=$(ls -1 "$CK"/*.ckpt 2>/dev/null | wc -l)
echo "[$(date -Is)] global merge of $n node catalogue(s) from $CK"
[[ "$n" -gt 0 ]] || { echo "ERROR: no node catalogues to merge"; exit 1; }

"$CLASSIFIER" --merge "$CK" --output "$FINAL" \
    --non-reflexive --assume-sorted --threads "$THREADS"

echo "[$(date -Is)] merge complete:"
ls -la "$FINAL"
echo
echo "Optional next step — attach NF vertex matrices:"
echo "  $(dirname "$CLASSIFIER")/add_nf --input $FINAL/unique_polytopes.parquet \\"
echo "      --output $FINAL/enriched.parquet --threads $THREADS"
