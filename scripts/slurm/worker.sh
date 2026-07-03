#!/usr/bin/env bash
# worker.sh — one SLURM array task = one node = one contiguous shard range.
#
# Streams the dataset to keep local disk bounded: for each batch of BATCH shards
# it (1) downloads them to node-local disk, (2) runs the classifier accumulating
# into a single full-snapshot checkpoint (--resume across batches), (3) DELETES
# the consumed shards. At the end it publishes the node's final checkpoint to the
# shared filesystem for the cross-node merge.
#
# All configuration arrives via the environment (exported by submit.sh).
set -euo pipefail

: "${RUN_ID:?}"; : "${CHUNKS:?}"; : "${TOTAL_FILES:?}"; : "${VARIANT:?}"
: "${BATCH:?}"; : "${THREADS:?}"; : "${CLASSIFIER:?}"
: "${SHARED_ROOT:?}"; : "${LOCAL_ROOT:?}"
CID="${SLURM_ARRAY_TASK_ID:?worker.sh must run as a SLURM array task}"

REPO_ID="calabi-yau-data/ws-5d"
STEM="ws-5d-${VARIANT}"
BASE_URL="https://huggingface.co/datasets/${REPO_ID}/resolve/main/${VARIANT}"
NODE="$(hostname -s)"
DL_PAR="${DL_PAR:-8}"

# Arrow/Parquet runtime libs (conda env on the shared filesystem). NOTE: this is
# for the classifier only — curl must NOT see conda's libcurl, so every curl call
# below runs under `env -u LD_LIBRARY_PATH` to use the system libcurl.
if [[ -n "${CONDA_PREFIX:-}" ]]; then
  export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
fi

# curl helper that always uses the system libcurl (not conda's).
scurl() { env -u LD_LIBRARY_PATH curl "$@"; }

LOCAL="$LOCAL_ROOT/$RUN_ID/chunk-$CID"
IN="$LOCAL/input"; CK="$LOCAL/ckpt"; OUT="$LOCAL/out"
mkdir -p "$IN" "$CK" "$OUT" "$SHARED_ROOT"/{logs,status,checkpoints}
LOG="$SHARED_ROOT/logs/chunk-$(printf '%02d' "$CID").log"
STATUS="$SHARED_ROOT/status/chunk-$(printf '%02d' "$CID").status"

log() { echo "[$(date -Is)] chunk$CID $NODE: $*" | tee -a "$LOG"; }

# ── Even file distribution (spread the remainder over the first chunks) ───────
per=$(( TOTAL_FILES / CHUNKS )); rem=$(( TOTAL_FILES % CHUNKS ))
if (( CID < rem )); then START=$(( CID * (per + 1) )); COUNT=$(( per + 1 ))
else                    START=$(( rem * (per + 1) + (CID - rem) * per )); COUNT=$per; fi
END=$(( START + COUNT - 1 ))
log "range files $START..$END ($COUNT files)  batch=$BATCH threads=$THREADS local=$LOCAL"

# ── Validate the HF token once; fall back to anonymous (the dataset is public) ─
if [[ -n "${HF_TOKEN:-}" ]]; then
  who=$(scurl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $HF_TOKEN" \
        https://huggingface.co/api/whoami-v2 2>/dev/null || echo 000)
  if [[ "$who" == "200" ]]; then
    log "HF token valid — authenticated downloads"
  else
    log "WARNING: HF_TOKEN invalid (whoami=$who); downloading anonymously (public dataset)"
    unset HF_TOKEN
  fi
fi

# ── Download one shard by index, with retries + parquet-magic integrity check ─
# Prefers the authenticated hop when a valid token is present, always falls back
# to anonymous. The bytes come from a presigned CDN URL either way. Token never
# logged; curl uses system libcurl via scurl().
dl_one() {
  local i="$1" f url dst a
  f="$(printf '%s-%04d.parquet' "$STEM" "$i")"
  url="$BASE_URL/$f"; dst="$IN/$f"
  [[ -s "$dst" && "$(tail -c4 "$dst" 2>/dev/null)" == "PAR1" ]] && return 0
  for a in 1 2 3 4 5; do
    if [[ -n "${HF_TOKEN:-}" ]] \
       && scurl -fsSL -H "Authorization: Bearer ${HF_TOKEN}" -o "$dst" "$url" \
       && [[ "$(tail -c4 "$dst")" == "PAR1" ]]; then return 0; fi
    if scurl -fsSL -o "$dst" "$url" \
       && [[ "$(tail -c4 "$dst")" == "PAR1" ]]; then return 0; fi
    sleep $(( a * 3 ))
  done
  echo "DOWNLOAD FAILED: shard $i ($f)" >&2
  return 1
}
export -f dl_one scurl
export IN STEM BASE_URL HF_TOKEN

download_batch() {  # $1=first $2=last
  seq "$1" "$2" | xargs -P "$DL_PAR" -I {} bash -c 'dl_one "$@"' _ {}
}

# ── Stream the node's range in batches ───────────────────────────────────────
t0=$SECONDS
for (( bs = START; bs <= END; bs += BATCH )); do
  be=$(( bs + BATCH - 1 )); (( be > END )) && be=$END

  log "downloading shards $bs..$be"
  download_batch "$bs" "$be"

  resume=(); (( bs > START )) && resume=(--resume)
  log "classifying shards $bs..$be"
  "$CLASSIFIER" --input "$IN" --output "$OUT" --checkpoint "$CK" \
      --non-reflexive --threads "$THREADS" --offset "$bs" "${resume[@]}" \
      >> "$LOG" 2>&1

  # Free disk: drop the shards we just consumed.
  rm -f "$IN"/*.parquet
  # Keep only the newest full-snapshot checkpoint so --resume loads it exactly
  # once (each checkpoint is a complete snapshot; older ones are strict subsets).
  ls -t "$CK"/*.ckpt 2>/dev/null | tail -n +2 | xargs -r rm -f || true

  done_files=$(( be - START + 1 ))
  uniq=$(grep -aoE 'Unique polytopes:[[:space:]]+[0-9]+' "$LOG" | tail -1 \
         | grep -oE '[0-9]+' || echo 0)
  rate=$(grep -aoE 'Throughput:[[:space:]]+[0-9]+' "$LOG" | tail -1 \
         | grep -oE '[0-9]+' || echo 0)
  {
    echo "chunk=$CID node=$NODE state=running"
    echo "files_done=$done_files/$COUNT last_batch=${bs}..${be}"
    echo "unique~$uniq  last_cws_s~$rate  elapsed_s=$(( SECONDS - t0 ))"
    echo "ts=$(date -Is)"
  } > "$STATUS"
  log "batch $bs..$be done: files_done=$done_files/$COUNT unique~$uniq"
done

# ── Publish this node's final checkpoint for the cross-node merge ─────────────
final="$(ls -t "$CK"/*.ckpt 2>/dev/null | head -1 || true)"
if [[ -z "$final" ]]; then
  log "ERROR: no checkpoint produced"; echo "state=FAILED" >> "$STATUS"; exit 1
fi
dest="$SHARED_ROOT/checkpoints/chunk-$(printf '%02d' "$CID").ckpt"
cp "$final" "$dest"
log "DONE: published $(basename "$dest") ($(du -h "$dest" | cut -f1))"
{ echo "chunk=$CID node=$NODE state=COMPLETE files_done=$COUNT/$COUNT"; \
  echo "checkpoint=$dest ts=$(date -Is)"; } > "$STATUS"
