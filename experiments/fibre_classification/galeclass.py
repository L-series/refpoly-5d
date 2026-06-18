"""
Gale-dual complete GL(d,Z)-invariant ("fibre key") for d=5 reflexive polytopes.

Implements the program from sec:fibre-gale of ks_classification.tex:
given the VERTEX configuration of a reflexive polytope (the post-hull object),
compute a canonical GL(d,Z)- and permutation-invariant fingerprint that serves
as a fibre key -- replacing the PALP normal-form bit-string (the map beta).

The hull step alpha (WS -> vertices) is provably irreducible (obstruction thm);
this tool takes the vertices as input.

Fingerprint is LAYERED so we can measure how much discriminating power each
layer of the Gale/oriented-matroid/arithmetic theory contributes, and locate
the Gale dimension g at which a given layer stops being complete.
"""
import numpy as np
from scipy.spatial import ConvexHull
from math import gcd
from functools import reduce
import hashlib

D = 5  # ambient dimension


# ---------------------------------------------------------------------------
# decoding
# ---------------------------------------------------------------------------
def decode_vertices(blob, nv):
    """nf_vertices blob is the PALP d x nv matrix, column-major int32."""
    arr = np.frombuffer(blob, dtype='<i4')
    assert arr.size == D * nv, (arr.size, D, nv)
    return arr.reshape(D, nv).T.astype(np.int64)   # (nv, d)


# ---------------------------------------------------------------------------
# integer linear algebra
# ---------------------------------------------------------------------------
def _primitive(v):
    g = reduce(gcd, (abs(int(x)) for x in v), 0)
    if g == 0:
        return v.astype(np.int64)
    return (v // g).astype(np.int64)


def smith_invariant_factors(M):
    """Smith normal form invariant factors of integer matrix M (via sympy)."""
    from sympy import Matrix
    if M.size == 0:
        return ()
    snf = Matrix(M.tolist())
    from sympy.matrices.normalforms import smith_normal_form
    S = smith_normal_form(snf)
    diag = [int(S[i, i]) for i in range(min(S.shape))]
    return tuple(abs(d) for d in diag if d != 0)


def integer_kernel(A):
    """Integer basis (rows) of the right kernel of integer matrix A (m x n).
    Returns g x n integer matrix B with A @ B.T == 0, via sympy nullspace + clearing."""
    from sympy import Matrix
    Asym = Matrix(A.tolist())
    ns = Asym.nullspace()
    rows = []
    for vec in ns:
        denom = reduce(lambda a, b: a * b // gcd(a, b), [t.q for t in vec], 1)
        ivec = [int(t * denom) for t in vec]
        rows.append(_primitive(np.array(ivec, dtype=object).astype(np.int64)))
    if not rows:
        return np.zeros((0, A.shape[1]), dtype=np.int64)
    return np.array(rows, dtype=np.int64)


# ---------------------------------------------------------------------------
# facets / dual
# ---------------------------------------------------------------------------
def _cofactor_normal(pts):
    """Integer primitive normal to the hyperplane through d affinely-independent
    integer points (d points in d-space). Uses the generalized cross product of
    the d-1 difference vectors (signed minors) -- exact, pure numpy."""
    diffs = (pts[1:] - pts[0]).astype(float)        # (d-1, d)
    n = np.empty(D, dtype=np.int64)
    cols = list(range(D))
    for k in range(D):
        sub = diffs[:, [c for c in cols if c != k]]  # (d-1, d-1)
        n[k] = int(round(np.linalg.det(sub))) * (-1 if k % 2 else 1)
    return _primitive(n)


def facets_of(V):
    """Return (normals, offsets, incidence, reflexive) for conv(V).
    normals: primitive integer facet normals n with <n,x> >= offset on the polytope,
    offset = -1 for every facet iff the polytope is reflexive."""
    hull = ConvexHull(V.astype(float))
    # each Qhull simplex spans one flat facet; compute its exact integer normal
    # and dedup by (primitive normal, offset). Coplanar simplices collapse.
    uniq = {}
    for simplex in hull.simplices:
        pts = V[simplex]
        n = _cofactor_normal(pts)
        if not n.any():            # Qhull artifact: coplanar/degenerate simplex
            continue
        off = int(n @ pts[0])
        if off == 0:               # facet hyperplane can't pass through interior origin
            continue
        if off > 0:
            n = -n; off = -off
        uniq[(tuple(int(x) for x in n), off)] = None
    normals = np.array([n for (n, off) in uniq], dtype=np.int64)
    offsets = np.array([off for (n, off) in uniq], dtype=np.int64)
    reflexive = bool(np.all(offsets == -1))
    P = V @ normals.T                                 # (nv, nfacets)
    incidence = [frozenset(np.where(P[:, j] == offsets[j])[0].tolist())
                 for j in range(len(normals))]
    return normals, offsets, incidence, reflexive


def normalized_volume(V):
    """Lattice-normalized volume = d! * euclidean volume (integer for lattice poly)."""
    hull = ConvexHull(V.astype(float))
    from math import factorial
    return int(round(hull.volume * factorial(D)))


# ---------------------------------------------------------------------------
# the layered Gale fibre-key fingerprint
# ---------------------------------------------------------------------------
from itertools import combinations


def _hash(obj):
    return hashlib.sha1(repr(obj).encode()).hexdigest()[:16]


def bracket_magnitudes(V):
    """Sorted multiset of |det(hat A_S)| over all (d+1)-subsets S of vertices.
    hat A_S homogenizes the d+1 chosen vertices: this is the chirotope-magnitude
    (GKZ bracket) data of the point configuration -- a GL(d,Z)+perm invariant
    (det multiplies by det(U)=+-1 under GL, columns reorder under perm)."""
    nv = V.shape[0]
    H = np.hstack([np.ones((nv, 1), dtype=np.int64), V])   # (nv, d+1)
    idx = list(combinations(range(nv), D + 1))
    mats = H[np.array(idx)]                                  # (C, d+1, d+1)
    dets = np.rint(np.linalg.det(mats.astype(float))).astype(np.int64)
    return tuple(sorted(np.abs(dets).tolist()))


def pairing_invariants(V, normals, offsets):
    """Vertex-facet pairing matrix PM[i,j] = <v_i, n_j>; return permutation-
    invariant summaries: multiset of sorted rows and of sorted columns.
    <v,n> is GL(d,Z)-invariant (v->Uv, n->U^{-T}n)."""
    PM = V @ normals.T                                       # (nv, nfacets)
    rows = tuple(sorted(tuple(sorted(r.tolist())) for r in PM))
    cols = tuple(sorted(tuple(sorted(c.tolist())) for c in PM.T))
    entry_mult = tuple(sorted(PM.flatten().tolist()))
    return rows, cols, entry_mult


def arithmetic_decoration(V, normals):
    """Smith-normal-form / lattice invariants (the arithmetic that separates
    same-chirotope-different-lattice classes, e.g. the simplex false positives)."""
    sf_V = smith_invariant_factors(V)                       # spans of M-lattice
    sf_N = smith_invariant_factors(normals)                 # spans of N-lattice
    return sf_V, sf_N


def fingerprint(V, want=("L0", "L1", "Lpm", "Lar", "Lbr")):
    """Layered, GL(5,Z)- and permutation-invariant fibre key, computed purely
    from the vertex configuration (no PALP normal form). Returns dict layer->key.
    Layers are cumulative refinements:
      L0  : (g, n_v, n_facets, normalized volume)            -- coarse combinatorial
      L1  : + multiset of facet sizes & vertex degrees       -- matroid / combinatorial type
      Lpm : + vertex-facet pairing-matrix multisets          -- approaches NF
      Lar : + Smith-normal-form lattice decoration           -- arithmetic refinement
      Lbr : + chirotope bracket-magnitude multiset           -- full Gale/OM magnitudes
    """
    V = np.asarray(V, dtype=np.int64)
    nv = V.shape[0]
    g = nv - (D + 1)
    normals, offsets, incidence, refl = facets_of(V)
    nf = len(normals)
    nvol = normalized_volume(V)
    out = {}
    base = (g, nv, nf, nvol)
    if "L0" in want:
        out["L0"] = base
    if "L1" in want:
        fsizes = tuple(sorted(len(s) for s in incidence))
        vdeg = tuple(sorted(sum(1 for s in incidence if i in s) for i in range(nv)))
        out["L1"] = base + (fsizes, vdeg)
    if "Lpm" in want:
        rows, cols, ent = pairing_invariants(V, normals, offsets)
        out["Lpm"] = base + (_hash((rows, cols, ent)),)
    if "Lar" in want:
        sf_V, sf_N = arithmetic_decoration(V, normals)
        out["Lar"] = base + (sf_V, sf_N)
    if "Lbr" in want:
        out["Lbr"] = base + (_hash(bracket_magnitudes(V)),)
    return out, refl


def full_key(V):
    """Single combined canonical key = concatenation of all layers."""
    fp, refl = fingerprint(V)
    rows, cols, ent = pairing_invariants(V, *facets_of(V)[:2])
    return _hash((fp["L1"], fp["Lpm"], fp["Lar"], fp["Lbr"]))


# ---------------------------------------------------------------------------
# Los: the SIGNED-chirotope (oriented-matroid) layer, and the exact GL(5,Z)
# isomorphism resolver for the bounded-invariant hard core.
#
# Verified (job d651e2f4): Los is GL(5,Z)+S_nv+reflection invariant (g=1..30).
# On the 88,588,676-fibre d=5 list the cheap key (free + L1 + Lpm) leaves 85
# residual fibres (42 groups, g=2..11). Those 85 are pairwise GL-INEQUIVALENT
# (gl_equiv below) yet identical on L1,Lpm,Lar,Lbr AND Los -- the bounded
# multiset invariants saturate; the resolver closes the residue to injectivity.
# ---------------------------------------------------------------------------
from collections import Counter as _Counter
from itertools import product as _product


def vertex_colors(V, normals):
    """GL+perm-invariant per-vertex color = sorted pairing row <v_i, n_j>; integer
    labels assigned by SORTED tuple value (canonical, permutation-invariant)."""
    PM = np.asarray(V, dtype=np.int64) @ np.asarray(normals, dtype=np.int64).T
    rows = [tuple(sorted(int(x) for x in r)) for r in PM]
    order = {t: i for i, t in enumerate(sorted(set(rows)))}
    return [order[t] for t in rows]


def refine_colors(V, normals, rounds=3):
    """WL-style color refinement (GL+perm invariant) seeded by vertex_colors."""
    V = np.asarray(V, dtype=np.int64); normals = np.asarray(normals, dtype=np.int64)
    PM = V @ normals.T
    nv, nf = PM.shape
    vcol = vertex_colors(V, normals)
    for _ in range(rounds):
        fcol_raw = [tuple(sorted((vcol[i], int(PM[i, j])) for i in range(nv))) for j in range(nf)]
        fo = {t: k for k, t in enumerate(sorted(set(fcol_raw)))}
        fcol = [fo[t] for t in fcol_raw]
        vraw = [(vcol[i], tuple(sorted((int(PM[i, j]), fcol[j]) for j in range(nf)))) for i in range(nv)]
        vo = {t: k for k, t in enumerate(sorted(set(vraw)))}
        nvcol = [vo[t] for t in vraw]
        if nvcol == vcol:
            break
        vcol = nvcol
    return vcol


def _idet(M):
    """Exact integer determinant via fraction-free (Bareiss) elimination."""
    M = [[int(x) for x in row] for row in M]
    n = len(M); sign = 1; prev = 1
    for k in range(n - 1):
        if M[k][k] == 0:
            sw = next((i for i in range(k + 1, n) if M[i][k] != 0), None)
            if sw is None:
                return 0
            M[k], M[sw] = M[sw], M[k]; sign = -sign
        akk = M[k][k]
        for i in range(k + 1, n):
            Mik = M[i][k]; row_i = M[i]; row_k = M[k]
            for j in range(k + 1, n):
                row_i[j] = (row_i[j] * akk - Mik * row_k[j]) // prev
        prev = akk
    return sign * M[n - 1][n - 1]


def _detval(M, fast):
    """exact signed integer determinant; float fast path only for small entries."""
    if fast:
        return int(round(np.linalg.det(np.array(M, dtype=float))))
    return _idet(M)


def oriented_signature(V, normals=None, refine=3):
    """Layer Los: color-keyed SIGNED INTEGER-bracket multiset, symmetrized by a
    single global reorientation. Vertices are color-ordered; on color-distinct
    (d+1)-subsets the signed bracket is canonical (recorded), else magnitude only.
    GL(5,Z)+permutation+reorientation invariant. Hybrid arithmetic: verified-exact
    float path for |coord|<=40, exact Bareiss otherwise."""
    V = np.asarray(V, dtype=np.int64)
    nv = V.shape[0]
    if normals is None:
        normals, _, _, _ = facets_of(V)
    colors = refine_colors(V, normals, rounds=refine)
    H64 = np.hstack([np.ones((nv, 1), dtype=np.int64), V])
    fast = int(np.abs(H64).max()) <= 40
    Hpy = H64.tolist()
    sig = _Counter()
    for b in combinations(range(nv), D + 1):
        cs = [colors[i] for i in b]
        key = tuple(sorted(cs))
        if len(set(cs)) == D + 1:
            order_b = [i for _, i in sorted(zip(cs, b))]
            sig[(key, 0, _detval([Hpy[i] for i in order_b], fast))] += 1
        else:
            sig[(key, 1, abs(_detval([Hpy[i] for i in b], fast)))] += 1
    items = tuple(sorted(sig.items()))
    flipped = tuple(sorted(((k, t, (-v if t == 0 else v)), c) for (k, t, v), c in sig.items()))
    return _hash(min(items, flipped))


def _find_basis(V):
    idx = []; rows = []
    for i in range(len(V)):
        cand = rows + [V[i]]
        if np.linalg.matrix_rank(np.array(cand, dtype=float)) == len(cand):
            rows.append(V[i]); idx.append(i)
            if len(idx) == D:
                break
    return idx


def gl_equiv(V1, V2, colors1=None, colors2=None, cap=200000):
    """Exact GL(5,Z)+permutation isomorphism test: True/False if some unimodular U
    maps the vertex set V1 onto V2. Conclusive (color-restricted exhaustive search);
    returns ('TOO_BIG', size) only if the candidate count exceeds `cap`. This is the
    resolver that closes the bounded-invariant hard core to injectivity."""
    V1 = np.asarray(V1, dtype=np.int64); V2 = np.asarray(V2, dtype=np.int64)
    if colors1 is None:
        colors1 = refine_colors(V1, facets_of(V1)[0])
    if colors2 is None:
        colors2 = refine_colors(V2, facets_of(V2)[0])
    if sorted(colors1) != sorted(colors2):
        return False
    nv = len(V1)
    basis = _find_basis(V1)
    if len(basis) < D:
        return None
    M1 = V1[basis].T.astype(np.int64)
    M1inv = np.linalg.inv(M1.astype(float))
    tgt = [colors1[i] for i in basis]
    pools = [[j for j in range(nv) if colors2[j] == t] for t in tgt]
    if any(len(p) == 0 for p in pools):
        return False
    size = 1
    for p in pools:
        size *= len(p)
    if size > cap:
        return ("TOO_BIG", size)
    setV2 = set(map(tuple, V2.tolist()))
    V1list = V1.tolist()
    for combo in _product(*pools):
        if len(set(combo)) < D:
            continue
        M2 = V2[list(combo)].T.astype(np.int64)
        Ui = np.rint(M2.astype(float) @ M1inv).astype(np.int64)
        if not np.array_equal(Ui @ M1, M2):
            continue
        if int(round(np.linalg.det(Ui.astype(float)))) not in (1, -1):
            continue
        mapped = set(tuple(int(x) for x in (Ui @ np.array(v, dtype=np.int64))) for v in V1list)
        if mapped == setV2:
            return True
    return False


# ---------------------------------------------------------------------------
# GL(d,Z) + permutation scrambling (to test well-definedness of the key)
# ---------------------------------------------------------------------------
def random_unimodular(rng, n=D, passes=8):
    U = np.eye(n, dtype=np.int64)
    for _ in range(passes):
        i, j = rng.choice(n, 2, replace=False)
        U[i] += rng.integers(-2, 3) * U[j]
    if rng.random() < 0.5:
        U[[0, 1]] = U[[1, 0]]
    return U


def scramble(V, rng):
    """Apply a random GL(d,Z) and a random vertex relabeling: simulates getting
    the polytope as raw hull output in some other basis (NOT in PALP normal form)."""
    U = random_unimodular(rng)
    V2 = (V @ U.T)
    perm = rng.permutation(V2.shape[0])
    return V2[perm]


# ---------------------------------------------------------------------------
# quick self-test
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import pyarrow.parquet as pq
    f = "/home/ahat01/data/ws5d_sieved_dataset_v2_clean_test.parquet"
    t = pq.read_table(f, columns=['nf_vertices', 'bh_mv', 'bh_nv', 'bh_mp', 'point_count']).slice(0, 8).to_pydict()
    for i in range(8):
        V = decode_vertices(t['nf_vertices'][i], t['bh_mv'][i])
        normals, offs, inc, refl = facets_of(V)
        nf_col = t['bh_nv'][i]
        print(f"row {i}: nv={V.shape[0]} g={V.shape[0]-6} "
              f"facets_found={len(normals)} bh_nv(col)={nf_col} "
              f"reflexive={refl} normvol={normalized_volume(V)}")
