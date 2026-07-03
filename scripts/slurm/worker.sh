#!/usr/bin/env bash
# worker.sh — one SLURM array task = one node = one contiguous shard range.
#
# Throughput design (see docs/OPTIMIZATIONS.md):
#   * one classifier process per NUMA socket, numactl-bound to that socket's
#     cores + local memory (avoids the cross-socket memory traffic that halves
#     throughput), each handling half the node's shard range;
#   * each process runs in --spill-runs (append) mode: per file it computes NF +
#     hash across its socket's cores, sorts + collapses, and spills one sorted
#     run to node-local disk — no growing global map, RAM bounded to one file;
#   * shards are streamed: download a batch → classify → DELETE the batch, so
#     node-local input stays tiny.
# After both sockets finish, a per-node sort-merge dedups all of the node's runs
# into ONE node-catalogue .ckpt, which is published to shared storage for the
# final global merge (see merge.sh).
set -euo pipefail

: "${RUN_ID:?}"; : "${CHUNKS:?}"; : "${TOTAL_FILES:?}"; : "${VARIANT:?}"
: "${BATCH:?}"; : "${CLASSIFIER:?}"; : "${SHARED_ROOT:?}"; : "${LOCAL_ROOT:?}"
CID="${SLURM_ARRAY_TASK_ID:?worker.sh must run as a SLURM array task}"

REPO_ID="calabi-yau-data/ws-5d"
STEM="ws-5d-${VARIANT}"
BASE_URL="https://huggingface.co/datasets/${REPO_ID}/resolve/main/${VARIANT}"
NODE="$(hostname -s)"
DL_PAR="${DL_PAR:-8}"
NN="$(printf '%02d' "$CID")"

# curl must use the SYSTEM libcurl (not conda's), so downloads run under
# `env -u LD_LIBRARY_PATH`.  The classifier needs conda's Arrow libs, so its
# LD_LIBRARY_PATH is set only on its own invocations (run_cls below).
scurl() { env -u LD_LIBRARY_PATH curl "$@"; }
run_cls() { LD_LIBRARY_PATH="${CONDA_PREFIX:-}/lib:${LD_LIBRARY_PATH:-}" "$@"; }

LOCAL="$LOCAL_ROOT/$RUN_ID/chunk-$CID"
RUNS="$LOCAL/runs"; CAT="$LOCAL/cat"
mkdir -p "$RUNS" "$CAT" "$SHARED_ROOT"/{logs,status,catalogues}
LOG="$SHARED_ROOT/logs/chunk-$NN.log"
STATUS="$SHARED_ROOT/status/chunk-$NN.status"
log() { echo "[$(date -Is)] chunk$CID $NODE: $*" | tee -a "$LOG"; }

# ── Topology: sockets + cores/socket ─────────────────────────────────────────
SOCKETS="$(lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')"
[[ "${SOCKETS:-0}" -ge 1 ]] || SOCKETS=1
CPUS="$(nproc)"
CPS=$(( CPUS / SOCKETS ))            # cores per socket
command -v numactl >/dev/null || { log "WARNING: numactl missing — single process"; SOCKETS=1; CPS=$CPUS; }

# ── This node's file range (even split; remainder on the first chunks) ───────
per=$(( TOTAL_FILES / CHUNKS )); rem=$(( TOTAL_FILES % CHUNKS ))
if (( CID < rem )); then START=$(( CID*(per+1) )); COUNT=$(( per+1 ))
else                    START=$(( rem*(per+1) + (CID-rem)*per )); COUNT=$per; fi
END=$(( START + COUNT - 1 ))
log "range $START..$END ($COUNT files)  sockets=$SOCKETS cores/socket=$CPS batch=$BATCH"

# ── Validate HF token once; fall back to anonymous (public dataset) ──────────
if [[ -n "${HF_TOKEN:-}" ]]; then
  who=$(scurl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $HF_TOKEN" \
        https://huggingface.co/api/whoami-v2 2>/dev/null || echo 000)
  [[ "$who" == 200 ]] && log "HF token valid — authenticated downloads" \
    || { log "WARNING: HF_TOKEN invalid (whoami=$who); anonymous downloads"; unset HF_TOKEN; }
fi

dl_one() {  # $1 = global shard index; downloads into $INDIR
  local i="$1" f url dst a
  f="$(printf '%s-%04d.parquet' "$STEM" "$i")"; url="$BASE_URL/$f"; dst="$INDIR/$f"
  [[ -s "$dst" && "$(tail -c4 "$dst" 2>/dev/null)" == "PAR1" ]] && return 0
  for a in 1 2 3 4 5; do
    if [[ -n "${HF_TOKEN:-}" ]] \
       && scurl -fsSL -H "Authorization: Bearer ${HF_TOKEN}" -o "$dst" "$url" \
       && [[ "$(tail -c4 "$dst")" == "PAR1" ]]; then return 0; fi
    if scurl -fsSL -o "$dst" "$url" && [[ "$(tail -c4 "$dst")" == "PAR1" ]]; then return 0; fi
    sleep $(( a*3 ))
  done
  echo "DOWNLOAD FAILED: shard $i ($f)" >&2; return 1
}
export -f dl_one scurl
export STEM BASE_URL HF_TOKEN

# ── One socket-bound streaming sub-worker over [s_start, s_end] ──────────────
socket_worker() {
  local sk="$1" s_start="$2" s_end="$3"
  local slog="$SHARED_ROOT/logs/chunk-$NN-s$sk.log"
  local indir="$LOCAL/in-s$sk"; mkdir -p "$indir"
  local bind=(); (( SOCKETS > 1 )) && bind=(numactl --cpunodebind="$sk" --membind="$sk")
  (( s_start <= s_end )) || { echo "socket $sk: empty range" >>"$slog"; return 0; }

  local bs be
  for (( bs=s_start; bs<=s_end; bs+=BATCH )); do
    be=$(( bs+BATCH-1 )); (( be > s_end )) && be=$s_end
    INDIR="$indir"; export INDIR
    echo "[$(date -Is)] s$sk download $bs..$be" >>"$slog"
    seq "$bs" "$be" | xargs -P "$DL_PAR" -I {} bash -c 'dl_one "$@"' _ {} >>"$slog" 2>&1
    echo "[$(date -Is)] s$sk classify $bs..$be" >>"$slog"
    run_cls "${bind[@]}" "$CLASSIFIER" \
        --input "$indir" --output "$LOCAL/out-s$sk" --runs-dir "$RUNS" \
        --spill-runs --run-tag "c$NN-s$sk" --offset "$bs" \
        --non-reflexive --threads "$CPS" >>"$slog" 2>&1
    rm -f "$indir"/*.parquet
    echo "[$(date -Is)] s$sk done $bs..$be" >>"$slog"
  done
}

# ── Launch one sub-worker per socket, concurrently ───────────────────────────
t0=$SECONDS
if (( SOCKETS <= 1 )); then
  INDIR="$LOCAL/in-s0" socket_worker 0 "$START" "$END"
else
  # split the node's range across sockets (even, remainder on socket 0)
  sper=$(( COUNT / SOCKETS )); srem=$(( COUNT % SOCKETS ))
  cur=$START
  pids=()
  for (( sk=0; sk<SOCKETS; sk++ )); do
    scnt=$sper; (( sk < srem )) && scnt=$(( sper+1 ))
    s_start=$cur; s_end=$(( cur+scnt-1 )); cur=$(( s_end+1 ))
    log "socket $sk → files $s_start..$s_end ($scnt)"
    socket_worker "$sk" "$s_start" "$s_end" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
fi
log "all sockets done in $(( SECONDS-t0 ))s; runs: $(ls -1 "$RUNS"/*.ckpt 2>/dev/null | wc -l)"
{ echo "chunk=$CID node=$NODE state=merging"; \
  echo "runs=$(ls -1 "$RUNS"/*.ckpt 2>/dev/null | wc -l) elapsed_s=$(( SECONDS-t0 ))"; \
  echo "ts=$(date -Is)"; } > "$STATUS"

# ── Per-node sort-merge: all runs → one node-catalogue .ckpt ─────────────────
# Runs are pre-sorted (spill writes sorted runs) → --assume-sorted skips Phase 1.
log "per-node sort-merge → node catalogue"
run_cls "$CLASSIFIER" --merge "$RUNS" --output "$CAT" \
    --emit-ckpt --merge-tag "chunk-$NN" --non-reflexive --assume-sorted \
    --threads "$CPUS" >>"$LOG" 2>&1

NODE_CAT="$CAT/chunk-$NN.ckpt"
[[ -s "$NODE_CAT" ]] || { log "ERROR: no node catalogue produced"; echo "state=FAILED" >>"$STATUS"; exit 1; }
dest="$SHARED_ROOT/catalogues/chunk-$NN.ckpt"
cp "$NODE_CAT" "$dest"
# Free node-local scratch now that the catalogue is published.
rm -rf "$RUNS"
log "DONE: published $(basename "$dest") ($(du -h "$dest" | cut -f1)) in $(( SECONDS-t0 ))s"
{ echo "chunk=$CID node=$NODE state=COMPLETE files=$COUNT/$COUNT"; \
  echo "catalogue=$dest elapsed_s=$(( SECONDS-t0 )) ts=$(date -Is)"; } > "$STATUS"
