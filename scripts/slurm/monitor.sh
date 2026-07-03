#!/usr/bin/env bash
# monitor.sh — aggregate progress across all chunks of a run.
#
# Usage:
#   ./monitor.sh <shared_root> [--watch]
#   ./monitor.sh $HOME/refpoly-runs/<run_id>
set -uo pipefail

SHARED_ROOT="${1:-${SHARED_ROOT:-}}"
[[ -n "$SHARED_ROOT" ]] || { echo "usage: monitor.sh <shared_root> [--watch]"; exit 1; }
WATCH="${2:-}"

show() {
  echo "================ $(date -Is) ================"
  echo "run: $SHARED_ROOT"
  echo
  echo "--- squeue (this user) ---"
  squeue -u "$(whoami)" -o "%.12i %.22j %.9T %.11M %.5D %R" 2>/dev/null | head -30
  echo
  echo "--- per-chunk status ---"
  shopt -s nullglob
  local total_done=0 total_files=0 any=0
  for f in "$SHARED_ROOT"/status/chunk-*.status; do
    any=1
    sed 's/^/  /' "$f"
    # accumulate files_done=X/Y for a rough overall percentage
    local fd
    fd=$(grep -oE 'files_done=[0-9]+/[0-9]+' "$f" | tail -1 | grep -oE '[0-9]+/[0-9]+')
    if [[ -n "$fd" ]]; then
      total_done=$(( total_done + ${fd%/*} ))
      total_files=$(( total_files + ${fd#*/} ))
    fi
    echo
  done
  [[ "$any" == 1 ]] || echo "  (no status files yet)"
  if (( total_files > 0 )); then
    printf -- "--- overall: %d/%d shards processed (%d%%) ---\n" \
      "$total_done" "$total_files" $(( 100 * total_done / total_files ))
  fi
  local nck
  nck=$(ls -1 "$SHARED_ROOT"/checkpoints/*.ckpt 2>/dev/null | wc -l)
  echo "--- published node checkpoints: $nck ---"
  if [[ -f "$SHARED_ROOT/final/unique_polytopes.parquet" ]]; then
    echo "--- FINAL result present: $SHARED_ROOT/final/unique_polytopes.parquet ---"
  fi
}

if [[ "$WATCH" == "--watch" ]]; then
  while true; do clear; show; sleep 30; done
else
  show
fi
