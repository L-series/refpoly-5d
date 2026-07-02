"""
Canonical serialization + pluggable hashing of a PALP normal form.

The dedup identity of a polytope is the hash of its normal-form matrix. To keep
the Python oracle and the C++ classifier byte-compatible, the *hash input bytes*
are defined once, here, to match `classifier.cpp::hash_normal_form`:

    row-major, `dim` rows x `nv` columns, each entry a little-endian int64
    (PALP `Long` == `long` == 64-bit on the x86-64 build).

Only the used dim x nv portion is serialized (no VERT_Nmax padding), exactly as
the C++ does. Any hash algorithm is then a pure function of these bytes, so the
choice of algorithm is a swappable policy — this is where alternative hashes are
benchmarked (Phase 0) without touching correctness.
"""
from __future__ import annotations

import hashlib
import struct
from typing import Callable

# name -> (hexdigest over canonical bytes). Portable algos only by default;
# xxh3-128 (the classifier's production hash) registers itself if the optional
# `xxhash` module is importable.
_REGISTRY: dict[str, Callable[[bytes], str]] = {}


def register(name: str, fn: Callable[[bytes], str]) -> None:
    _REGISTRY[name] = fn


def algorithms() -> list[str]:
    return sorted(_REGISTRY)


def canonical_bytes(matrix, dim: int, nv: int) -> bytes:
    """int64-LE, row-major, dim x nv — the exact hash input the classifier uses."""
    if len(matrix) != dim:
        raise ValueError(f"matrix has {len(matrix)} rows, expected dim={dim}")
    flat = []
    for row in matrix:
        if len(row) != nv:
            raise ValueError(f"row width {len(row)} != nv={nv}")
        flat.extend(int(x) for x in row)
    return struct.pack(f"<{len(flat)}q", *flat)


def digest(name: str, matrix, dim: int, nv: int) -> str:
    return _REGISTRY[name](canonical_bytes(matrix, dim, nv))


# ── built-in, always-available algorithms ────────────────────────────────────
register("sha256", lambda b: hashlib.sha256(b).hexdigest())
# blake2b-128: a fast 128-bit digest available in the stdlib, a portable stand-in
# for the production 128-bit key when xxhash is not installed.
register("blake2b128", lambda b: hashlib.blake2b(b, digest_size=16).hexdigest())

# ── optional production hash (matches the classifier) ────────────────────────
try:  # pragma: no cover - depends on environment
    import xxhash

    def _xxh3_128(b: bytes) -> str:
        return xxhash.xxh3_128(b).hexdigest()

    register("xxh3_128", _xxh3_128)
except ImportError:
    pass
