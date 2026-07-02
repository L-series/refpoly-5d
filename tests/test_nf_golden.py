#!/usr/bin/env python3
"""
Normal-form / hash regression gate.

Checks, against the frozen golden fixture:
  1. PALP oracle reproduces every golden NF matrix exactly (determinism of the
     normal-form computation the classifier links).
  2. The canonical byte layout + every frozen digest still matches (guards the
     hash-input contract shared with the C++ side).
  3. All registered hash algorithms are deterministic on the golden NFs.

The ported classifier is gated through the `nf_dump` diagnostic, which runs the
classifier's own PALP-library NF path (palp_api.h::palp_compute_nf_from_cws) and
prints each NF. When that binary is present (default build path or --nf-dump
<binary> / REFPOLY_NF_DUMP env), every corpus NF must match the golden matrix
bit-for-bit — this is what proves the C++ port reproduces the oracle.

Usage:
    python3 tests/test_nf_golden.py            # oracle + digest + classifier gate
    python3 tests/test_nf_golden.py -v         # per-record detail on failure
    python3 tests/test_nf_golden.py --nf-dump PATH
Also importable as a pytest module (test_* functions).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import nf_hash
from palp_oracle import REPO_ROOT, normal_forms

GOLDEN = REPO_ROOT / "tests" / "fixtures" / "golden_nf.jsonl"
DEFAULT_NF_DUMP = REPO_ROOT / "src" / "classify" / "build" / "nf_dump"


def nf_dump_binary() -> Path | None:
    """Locate the nf_dump diagnostic (env override, else default build path)."""
    env = os.environ.get("REFPOLY_NF_DUMP")
    p = Path(env) if env else DEFAULT_NF_DUMP
    return p if p.exists() else None


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


def _run_nf_dump(binary: Path, ws_lines: list[str]) -> list[tuple]:
    """Run nf_dump over ws_lines; return (dim, nv, flat_rowmajor) per line."""
    stdin = "".join(l + "\n" for l in ws_lines)
    proc = subprocess.run([str(binary)], input=stdin, capture_output=True, text=True)
    out = []
    for line in proc.stdout.splitlines():
        if line.strip() == "FAIL":
            out.append(None)
            continue
        vals = [int(x) for x in line.split()]
        dim, nv, flat = vals[0], vals[1], vals[2:]
        out.append((dim, nv, flat))
    return out


def test_classifier_matches_golden() -> None:
    """The ported classifier's NF path (via nf_dump) reproduces every golden NF."""
    binary = nf_dump_binary()
    if binary is None:
        return  # binary not built in this environment; skip (oracle checks still run)
    golden = load_golden()
    ws_lines = [g["ws"] for g in golden]
    got = _run_nf_dump(binary, ws_lines)
    assert len(got) == len(golden), f"{len(got)} outputs for {len(golden)} inputs"
    for g, res in zip(golden, got):
        assert res is not None, f"classifier FAILed on ws={g['ws']!r}"
        dim, nv, flat = res
        want = [x for row in g["nf"] for x in row]
        assert (dim, nv) == (g["dim"], g["nv"]), g["ws"]
        assert flat == want, f"classifier NF mismatch for ws={g['ws']!r}"


def _run_cli(verbose: bool) -> int:
    have_binary = nf_dump_binary() is not None
    classifier_label = ("classifier (nf_dump) reproduces golden NF" if have_binary
                        else "classifier gate SKIPPED (nf_dump not built)")
    checks = [
        ("oracle reproduces golden NF", test_oracle_reproduces_golden_nf),
        ("digests match + algos deterministic", test_digests_match_and_algos_deterministic),
        (classifier_label, test_classifier_matches_golden),
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
    if "--nf-dump" in sys.argv:
        os.environ["REFPOLY_NF_DUMP"] = sys.argv[sys.argv.index("--nf-dump") + 1]
    sys.exit(_run_cli(verbose="-v" in sys.argv))
