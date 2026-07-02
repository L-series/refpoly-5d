#!/usr/bin/env python3
"""
Download ws-5d weight-system parquet files from HuggingFace.

The dataset (calabi-yau-data/ws-5d) has two variants of 5d IP weight systems:
  - reflexive     : 4000 files (the ~185B set classified in the source repo)
  - non-reflexive : 994 files  (the ~135B set this repo targets)

Both are downloaded with the same code; pick with --variant. Files that already
exist locally are skipped, so re-running backfills a partial download.

Examples:
  # discover the current file counts on the Hub (no token needed)
  python scripts/download_ws5d.py --list

  # download the whole non-reflexive dataset into ./data/ws-5d-non-reflexive
  python scripts/download_ws5d.py --variant non-reflexive --all

  # download a shard range (for distributed runners)
  python scripts/download_ws5d.py --variant non-reflexive --start 0 --end 99

Auth: set HF_TOKEN in the environment or a .env file (see .env.example). The
dataset is public, so a token is optional but recommended to avoid rate limits.
Install deps: pip install huggingface_hub hf-transfer python-dotenv
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO_ID = "calabi-yau-data/ws-5d"
REPO_TYPE = "dataset"

# Known layout (confirm/refresh with --list). `total` is the file count as of
# 2026-07; --list re-derives it live from the Hub.
VARIANTS = {
    "reflexive":     {"subfolder": "reflexive",     "stem": "ws-5d-reflexive",     "total": 4000},
    "non-reflexive": {"subfolder": "non-reflexive", "stem": "ws-5d-non-reflexive", "total": 4000},
}


def discover_counts() -> dict:
    """Query the Hub tree API for the parquet count of each variant (no token).

    The tree endpoint paginates (~1000 entries/page) via a ``Link: ...
    rel="next"`` header, so follow it to the end to count large folders.
    """
    counts: dict[str, int] = {}
    for cfg in VARIANTS.values():
        sub = cfg["subfolder"]
        url = (f"https://huggingface.co/api/datasets/{REPO_ID}"
               f"/tree/main/{sub}?recursive=1")
        n = 0
        while url:
            req = urllib.request.Request(url, headers={"User-Agent": "refpoly-5d/1.0"})
            resp = urllib.request.urlopen(req, timeout=60)
            entries = json.load(resp)
            n += sum(1 for e in entries
                     if e.get("type") == "file" and e.get("path", "").endswith(".parquet"))
            # follow pagination: Link header with rel="next"
            url = None
            link = resp.headers.get("Link", "")
            for part in link.split(","):
                if 'rel="next"' in part:
                    url = part[part.find("<") + 1:part.find(">")]
        counts[sub] = n
    return counts


def load_token() -> str | None:
    try:
        from dotenv import load_dotenv
        load_dotenv()
    except ImportError:
        pass
    return os.environ.get("HF_TOKEN")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variant", choices=sorted(VARIANTS), default="non-reflexive")
    ap.add_argument("--start", type=int, help="first file index (inclusive)")
    ap.add_argument("--end", type=int, help="last file index (inclusive)")
    ap.add_argument("--all", action="store_true", help="download every file for the variant")
    ap.add_argument("--out-dir", type=str, default=None,
                    help="output dir (default: ./data/ws-5d-<variant>)")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--list", action="store_true",
                    help="print live per-variant file counts and exit")
    args = ap.parse_args()

    if args.list:
        try:
            counts = discover_counts()
        except Exception as e:
            sys.exit(f"could not query Hub: {type(e).__name__}: {e}")
        for name, cfg in sorted(VARIANTS.items()):
            live = counts.get(cfg["subfolder"], "?")
            print(f"{name:<14} {cfg['subfolder']}/{cfg['stem']}-NNNN.parquet  "
                  f"live={live}  (configured total={cfg['total']})")
        return 0

    cfg = VARIANTS[args.variant]
    if args.all:
        start, end = 0, cfg["total"] - 1
    elif args.start is not None and args.end is not None:
        start, end = args.start, args.end
    else:
        sys.exit("specify --all or both --start and --end")
    if not (0 <= start <= end < cfg["total"]):
        sys.exit(f"indices must satisfy 0 <= start <= end < {cfg['total']}")

    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        sys.exit("missing dependency; run: pip install huggingface_hub hf-transfer python-dotenv")

    token = load_token()
    os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")

    out_dir = Path(args.out_dir) if args.out_dir else Path("data") / f"ws-5d-{args.variant}"
    out_dir.mkdir(parents=True, exist_ok=True)

    names = [f"{cfg['subfolder']}/{cfg['stem']}-{i:04d}.parquet" for i in range(start, end + 1)]
    print(f"variant={args.variant}  files {start:04d}-{end:04d} ({len(names)})  -> {out_dir.resolve()}")

    def download_one(fname: str):
        local = out_dir / Path(fname).name
        if local.exists():
            return fname, "skip"
        hf_hub_download(repo_id=REPO_ID, repo_type=REPO_TYPE, filename=fname,
                        local_dir=str(out_dir), token=token)
        return fname, "ok"

    failed = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {pool.submit(download_one, f): f for f in names}
        for i, fut in enumerate(as_completed(futs), 1):
            short = Path(futs[fut]).name
            try:
                _, status = fut.result()
                print(f"[{i}/{len(names)}] {short} — {status}")
            except Exception as exc:
                print(f"[{i}/{len(names)}] {short} — FAILED: {exc}")
                failed.append(futs[fut])

    if failed:
        print(f"\n{len(failed)} file(s) failed; re-run to retry (existing files are skipped).")
        return 1
    print(f"\nAll {len(names)} files present in {out_dir.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
