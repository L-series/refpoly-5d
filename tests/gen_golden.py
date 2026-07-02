#!/usr/bin/env python3
"""
Generate the golden normal-form regression fixture.

Runs every weight system in tests/fixtures/corpus_small.txt through the PALP
oracle and freezes, per line:
    { ws, dim, nv, nf (row-major matrix), bytes_len, digests{algo: hex} }
into tests/fixtures/golden_nf.jsonl.

The frozen NF matrix is the tool-independent ground truth; the digests pin the
canonical byte layout (see nf_hash.py) so the ported classifier is gated both on
reproducing the matrix and on hashing it identically. `sha256`/`blake2b128` are
always recorded; `xxh3_128` (the production hash) is added when available.
"""
from __future__ import annotations

import json
from pathlib import Path

import nf_hash
from palp_oracle import REPO_ROOT, normal_forms

CORPUS = REPO_ROOT / "tests" / "fixtures" / "corpus_small.txt"
GOLDEN = REPO_ROOT / "tests" / "fixtures" / "golden_nf.jsonl"

# Digests to freeze. Portable ones are mandatory; xxh3_128 is opportunistic.
FREEZE_ALGOS = ["sha256", "blake2b128"]


def main() -> None:
    ws_lines = [l for l in CORPUS.read_text().splitlines() if l.strip()]
    nfs = normal_forms(ws_lines)

    algos = [a for a in FREEZE_ALGOS if a in nf_hash.algorithms()]
    if "xxh3_128" in nf_hash.algorithms():
        algos.append("xxh3_128")

    with GOLDEN.open("w") as f:
        for ws, nf in zip(ws_lines, nfs):
            digests = {a: nf_hash.digest(a, nf.matrix, nf.dim, nf.nv) for a in algos}
            rec = {
                "ws": ws,
                "dim": nf.dim,
                "nv": nf.nv,
                "nf": [list(r) for r in nf.matrix],
                "bytes_len": len(nf_hash.canonical_bytes(nf.matrix, nf.dim, nf.nv)),
                "digests": digests,
            }
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")

    print(f"wrote {len(nfs)} golden records -> {GOLDEN}")
    print(f"frozen digest algos: {algos}")


if __name__ == "__main__":
    main()
