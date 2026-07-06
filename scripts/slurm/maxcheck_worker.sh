#!/usr/bin/env bash
# maxcheck_worker.sh — one SLURM array task = one node = a contiguous row-group
# range of unique_polytopes_clean.parquet, classified for r-maximality.
#
# Design:
#   * The r-maximality test (src/classify/maxcheck) is single-threaded and
#     CPU-bound, so we run ONE maxcheck process per core, each owning a disjoint
#     sub-range of this node's row groups (numactl-bound to its socket to avoid
#     cross-socket memory traffic).
#   * Each process is wrapped in a SUPERVISOR LOOP: maxcheck classifies to four
#     append-only index streams (.max/.nonmax/.defer/.anom) and checkpoints a
#     marker.  If a single polytope blows the per-item budget, overflows PALP's
#     arrays, or crashes the process (deep-recursion stack overflow → SIGSEGV),
#     the process appends that row to a persistent skip-set and exits; the loop
#     relaunches it, it resumes from the last checkpoint and DEFERs the skipped
#     row.  Every row therefore lands in exactly one stream — provably complete,
#     no silent drops, no guessed verdicts.
#   * A large stack (ulimit -s) lets the deep-but-finite searches complete in
#     process instead of being deferred as SIGSEGV; anything still too deep is
#     safely caught and deferred.
#
# The deferred rows (dpc-gated tail + budget/overflow/crash) are the input to a
# later slow/robust pass; see docs and maxcheck_tally.py for count-conservation.
set -euo pipefail

: "${RUN_ID:?}"; : "${SHARED_ROOT:?}"; : "${INPUT:?}"; : "${MAXBIN:?}"
: "${TOTAL_RG:?}"; : "${CHUNKS:?}"
CID="${SLURM_ARRAY_TASK_ID:?maxcheck_worker.sh must run as a SLURM array task}"

DPC_GATE="${DPC_GATE:-2000}"        # deterministic size gate (dual points)
BUDGET_MS="${BUDGET_MS:-1000}"      # per-item wall-clock budget
RSS_CAP_MB="${RSS_CAP_MB:-12000}"   # recycle a worker above this RSS
CHECKPOINT="${CHECKPOINT:-65536}"   # rows between fsync/marker checkpoints
STACK_KB="${STACK_KB:-2000000}"     # large stack: complete deep searches in-proc
NODE="$(hostname -s)"; NN="$(printf '%02d' "$CID")"

run_bin() { LD_LIBRARY_PATH="${CONDA_PREFIX:-}/lib:${LD_LIBRARY_PATH:-}" "$@"; }
ulimit -s "$STACK_KB" 2>/dev/null || echo "WARN: could not raise stack to $STACK_KB KB"

STREAMS="$SHARED_ROOT/streams"; LOGS="$SHARED_ROOT/logs"; STAT="$SHARED_ROOT/status"
mkdir -p "$STREAMS" "$LOGS" "$STAT"
LOG="$LOGS/maxchk-$NN.log"
log() { echo "[$(date -Is)] node$CID $NODE: $*" | tee -a "$LOG"; }

# ── This node's global row-group range (even split; remainder on first tasks) ─
per=$(( TOTAL_RG / CHUNKS )); rem=$(( TOTAL_RG % CHUNKS ))
if (( CID < rem )); then RG0=$(( CID*(per+1) )); RGN=$(( per+1 ))
else                    RG0=$(( rem*(per+1) + (CID-rem)*per )); RGN=$per; fi
RG1=$(( RG0 + RGN ))                 # exclusive upper bound
log "row-group range [$RG0,$RG1) ($RGN rgs)  gate=$DPC_GATE budget=${BUDGET_MS}ms stack=${STACK_KB}KB"

# ── Topology ─────────────────────────────────────────────────────────────────
SOCKETS="$(lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')"; [[ "${SOCKETS:-0}" -ge 1 ]] || SOCKETS=1
CPUS="$(nproc)"
command -v numactl >/dev/null || { log "WARN: numactl missing — no socket binding"; SOCKETS=1; }
NPROC="${NPROC:-$CPUS}"              # parallel maxcheck processes on this node
(( NPROC < 1 )) && NPROC=1
(( NPROC > RGN )) && NPROC=$RGN      # no more processes than row groups

# ── Supervisor loop for one maxcheck process over [lo,hi) ────────────────────
supervise() {  # $1=proc-idx  $2=rg-lo  $3=rg-hi  $4=socket
  local pi="$1" lo="$2" hi="$3" sk="$4"
  local work="$STREAMS/w-$NN-$(printf '%03d' "$pi")"
  local plog="$LOGS/maxchk-$NN-p$(printf '%03d' "$pi").log"
  local bind=(); (( SOCKETS > 1 )) && bind=(numactl --cpunodebind="$sk" --membind="$sk")
  local a=0
  while :; do
    a=$(( a+1 ))
    set +e
    run_bin "${bind[@]}" "$MAXBIN" \
        --input "$INPUT" --work "$work" --rg-start "$lo" --rg-end "$hi" \
        --dpc-gate "$DPC_GATE" --budget-ms "$BUDGET_MS" \
        --rss-cap-mb "$RSS_CAP_MB" --checkpoint "$CHECKPOINT" >>"$plog" 2>&1
    local rc=$?
    set -e
    if (( rc == 0 )); then echo "[$(date -Is)] p$pi [$lo,$hi) DONE after $a attempts" >>"$plog"; return 0; fi
    # 70=budget/crash abort (skip-set advanced) 72=RSS recycle 134/139=abort/segv
    if (( rc == 70 || rc == 72 || rc == 134 || rc == 139 )); then
      (( a % 50 == 0 )) && echo "[$(date -Is)] p$pi resume (rc=$rc, attempt $a)" >>"$plog"
      continue
    fi
    echo "[$(date -Is)] p$pi FATAL rc=$rc" >>"$plog"; return "$rc"
  done
}

# ── Fan out NPROC supervised processes over disjoint rg sub-ranges ───────────
t0=$SECONDS
sper=$(( RGN / NPROC )); srem=$(( RGN % NPROC ))
cur=$RG0; pids=()
for (( pi=0; pi<NPROC; pi++ )); do
  cnt=$sper; (( pi < srem )) && cnt=$(( sper+1 ))
  lo=$cur; hi=$(( cur+cnt )); cur=$hi
  sk=$(( SOCKETS>1 ? pi % SOCKETS : 0 ))
  supervise "$pi" "$lo" "$hi" "$sk" &
  pids+=($!)
done
log "launched $NPROC supervised maxcheck processes over $RGN row groups"
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
log "all processes finished in $(( SECONDS-t0 ))s (fail=$fail)"

{ echo "node=$CID host=$NODE state=$([[ $fail -eq 0 ]] && echo COMPLETE || echo FAILED)";
  echo "rg_range=[$RG0,$RG1) nproc=$NPROC elapsed_s=$(( SECONDS-t0 )) ts=$(date -Is)"; } > "$STAT/maxchk-$NN.status"
exit "$fail"
