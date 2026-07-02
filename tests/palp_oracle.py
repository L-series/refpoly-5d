"""
PALP normal-form oracle.

Runs weight systems through the *committed* PALP `poly.x -N` binary — the same
normal-form code the classifier links as a library — and parses the resulting
GL(5,Z) canonical vertex matrices. This is the ground-truth reference that the
ported C++ classifier (Phase 1) must reproduce bit-for-bit.

A "weight system" line here is PALP's degree+weights text form, e.g.
    99 5 10 11 11 18 44
(degree 99, six weights -> a 5-dimensional Newton polytope). One or two weight
systems per line (a combined weight system, CWS) are both accepted by poly.x;
the parser keys purely on the emitted "Normal form" blocks, so it is agnostic
to the input arity.
"""
from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_POLY_X = REPO_ROOT / "PALP" / "poly.x"

_HEADER_RE = re.compile(r"^\s*(\d+)\s+(\d+)\s+Normal form of vertices")


def poly_x_path() -> Path:
    """Location of the poly.x binary (override with POLY_X env var)."""
    p = os.environ.get("POLY_X")
    return Path(p) if p else DEFAULT_POLY_X


@dataclass(frozen=True)
class NormalForm:
    dim: int                    # ambient dimension (5 for the ws-5d data)
    nv: int                     # number of vertices (columns)
    matrix: tuple               # dim rows, each a tuple of nv ints (row-major)

    def rows(self):
        return self.matrix


def _parse_nf_stream(text: str) -> list[NormalForm]:
    """Parse the concatenated `poly.x -Nf` output into NormalForm blocks."""
    lines = text.splitlines()
    out: list[NormalForm] = []
    i = 0
    n = len(lines)
    while i < n:
        m = _HEADER_RE.match(lines[i])
        if not m:
            i += 1
            continue
        dim, nv = int(m.group(1)), int(m.group(2))
        i += 1
        matrix = []
        for _ in range(dim):
            if i >= n:
                raise ValueError("truncated NF block (ran out of rows)")
            vals = [int(x) for x in lines[i].split()]
            if len(vals) != nv:
                raise ValueError(
                    f"NF row width {len(vals)} != nv {nv}: {lines[i]!r}")
            matrix.append(tuple(vals))
            i += 1
        out.append(NormalForm(dim=dim, nv=nv, matrix=tuple(matrix)))
    return out


def normal_forms(ws_lines: list[str], poly_x: Path | None = None) -> list[NormalForm]:
    """
    Compute normal forms for a batch of weight-system lines.

    Returns one NormalForm per input line, in input order. Raises if the number
    of parsed NF blocks does not match the number of inputs — the corpora are
    curated to be IP/reflexive so every line must yield exactly one NF; a
    mismatch means a bad line or a PALP limit and must surface, not be skipped.
    """
    poly_x = Path(poly_x) if poly_x else poly_x_path()
    if not poly_x.exists():
        raise FileNotFoundError(
            f"poly.x not found at {poly_x}; build PALP or set POLY_X")
    stdin = "".join(l.rstrip("\n") + "\n" for l in ws_lines if l.strip())
    proc = subprocess.run(
        [str(poly_x), "-Nf"], input=stdin, capture_output=True, text=True)
    nfs = _parse_nf_stream(proc.stdout)
    n_in = sum(1 for l in ws_lines if l.strip())
    if len(nfs) != n_in:
        raise ValueError(
            f"parsed {len(nfs)} NF blocks for {n_in} inputs; "
            f"stderr:\n{proc.stderr[:2000]}")
    return nfs
