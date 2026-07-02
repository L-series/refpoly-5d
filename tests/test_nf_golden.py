#!/usr/bin/env python3
"""
Normal-form / hash regression gate.

Checks, against the frozen golden fixture:
  1. PALP oracle reproduces every golden NF matrix exactly (determinism of the
     normal-form computation the classifier links).
  2. The canonical byte layout + every frozen digest still matches (guards the
     hash-input contract shared with the C++ side).
  3. All registered hash algorithms are deterministic on the golden NFs.

In Phase 1, pass --classifier <binary> to additionally gate a ported classifier:
it must emit the same (nv, hash) for each ws. Until then that mode is a no-op
stub so the gate exists from day one.

Usage:
    python3 tests/test_nf_golden.py            # oracle + digest regression
    python3 tests/test_nf_golden.py -v         # per-record detail on failure
Also importable as a pytest module (test_* functions).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import nf_hash
from palp_oracle import REPO_ROOT, normal_forms

GOLDEN = REPO_ROOT / "tests" / "fixtures" / "golden_nf.jsonl"


def load_golden() -> list[dict]:
    return [json.loads(l) for l in GOLDEN.read_text().splitlines() if l.strip()]


def _matrix(rec: dict):
    return tuple(tuple(r) for r in rec["nf"])


def test_oracle_reproduces_golden_nf() -> None:
    golden = load_golden()
    ws_lines = [g["ws"] for g in golden]
    nfs = normal_forms(ws_lines)
    assert len(nfs) == len(golden)
    for g, nf in zip(golden, nfs):
        assert nf.dim == g["dim"] and nf.nv == g["nv"], g["ws"]
        assert [list(r) for r in nf.matrix] == g["nf"], (
            f"NF mismatch for ws={g['ws']!r}")


def test_digests_match_and_algos_deterministic() -> None:
    golden = load_golden()
    for g in golden:
        m, dim, nv = _matrix(g), g["dim"], g["nv"]
        assert len(nf_hash.canonical_bytes(m, dim, nv)) == g["bytes_len"], g["ws"]
        for algo, want in g["digests"].items():
            if algo not in nf_hash.algorithms():
                continue  # optional algo (e.g. xxh3_128) absent in this env
            got = nf_hash.digest(algo, m, dim, nv)
            assert got == want, f"{algo} digest drift for ws={g['ws']!r}"
        # every registered algo must at least be stable across two calls
        for algo in nf_hash.algorithms():
            a = nf_hash.digest(algo, m, dim, nv)
            b = nf_hash.digest(algo, m, dim, nv)
            assert a == b, f"{algo} nondeterministic"


def _run_cli(verbose: bool) -> int:
    checks = [
        ("oracle reproduces golden NF", test_oracle_reproduces_golden_nf),
        ("digests match + algos deterministic", test_digests_match_and_algos_deterministic),
    ]
    failures = 0
    for name, fn in checks:
        try:
            fn()
            print(f"  PASS  {name}")
        except AssertionError as e:
            failures += 1
            print(f"  FAIL  {name}")
            if verbose:
                print(f"        {e}")
    n = len(load_golden())
    algos = ", ".join(nf_hash.algorithms())
    print(f"\n{'PASS' if not failures else 'FAIL'}: "
          f"{len(checks) - failures}/{len(checks)} checks over {n} golden NFs "
          f"[algos: {algos}]")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(_run_cli(verbose="-v" in sys.argv))
