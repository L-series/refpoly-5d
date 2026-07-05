#!/usr/bin/env bash
# run_wp.sh — discharge the ACSL/WP memory-safety contracts (scope 1).
# Requires frama-c + alt-ergo on PATH (local opam switch: `opam switch framac`).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v frama-c &>/dev/null; then
  echo "frama-c not found; enable the opam switch: eval \$(opam env --switch=framac)"
  exit 1
fi
echo "Frama-C: $(frama-c -version 2>&1 | head -1)"

fail=0
for f in wp_xt_transpose.c; do
  echo "── WP: $f ─────────────────────────────────────────────"
  # -wp-rte adds runtime-error (bounds/overflow) VCs; alt-ergo discharges them.
  out=$(frama-c -wp -wp-rte -wp-prover alt-ergo -wp-timeout 20 \
        "$SCRIPT_DIR/$f" 2>&1)
  echo "$out" | grep -E "Proved goals|Qed|Alt-Ergo|Unproved|Timeout|Failed" | head
  if echo "$out" | grep -qE "Unproved|Failed|Timeout"; then
    echo "  RESULT: INCOMPLETE"; fail=1
  else
    echo "  RESULT: ALL GOALS PROVED"
  fi
done
exit $fail
