#!/usr/bin/env python3
"""Prototype + test the ORIENTED-MATROID (signed-chirotope) layer 'Los'.

Los is a cocircuit-partition multiset: for each 5-subset B of vertices spanning a
hyperplane in the homogenized rank-6 configuration, compute the integer normal w
(cross product), and partition the OTHER vertices by sign(<hat v_j, w>). Color the
vertices by their GL-invariant pairing signature; record, per cocircuit, the pair
{multiset of +colors, multiset of -colors} SYMMETRIZED over the +/- swap (global
reorientation) plus the multiset of 0-colors. Los = hash of the multiset over all B.

Invariant under: GL(5,Z) incl. det=-1 (global sign flip, killed by symmetrization),
vertex permutation (multiset over subsets, equivariant colors), translation
(homogenized brackets are translation-invariant).
"""
import os
for v in ("OMP_NUM_THREADS","OPENBLAS_NUM_THREADS","MKL_NUM_THREADS","NUMEXPR_NUM_THREADS"):
    os.environ[v] = "1"
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, pyarrow as pa, pyarrow.parquet as pq
from itertools import combinations
from collections import Counter, defaultdict
import hashlib
import galeclass as gc
def _p(*a): print(*a, flush=True)

D = 5

def vertex_colors(V, normals):
    """GL+perm-invariant per-vertex color = sorted pairing row <v_i, n_j> over
    facets. Integer labels assigned by SORTED tuple value (canonical, so the
    labeling is permutation-invariant, not first-appearance-order)."""
    PM = V @ normals.T
    rows = [tuple(sorted(int(x) for x in r)) for r in PM]
    order = {t: i for i, t in enumerate(sorted(set(rows)))}
    return [order[t] for t in rows]

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
            Mik = M[i][k]
            row_i = M[i]; row_k = M[k]
            for j in range(k + 1, n):
                row_i[j] = (row_i[j] * akk - Mik * row_k[j]) // prev
        prev = akk
    return sign * M[n - 1][n - 1]

# coordinate magnitude below which float 5x5 dets and int64 dots are exact
_FAST_MAX = 300

def _det_sign(M, fast):
    """exact sign of det of square integer matrix M (list of lists)."""
    if fast:
        return int(np.sign(round(np.linalg.det(np.array(M, dtype=float)))))
    d = _idet(M)
    return (d > 0) - (d < 0)

def _detval(M, fast):
    """exact signed integer determinant of square integer matrix M."""
    if fast:
        return int(round(np.linalg.det(np.array(M, dtype=float))))
    return _idet(M)

def refine_colors(V, normals, rounds=2):
    """WL-style color refinement (GL+perm invariant). Seed = sorted pairing row;
    refine each vertex by the multiset of (pairing value, current facet color),
    where facet colors come from the multiset of incident (vertex color, value)."""
    PM = V @ normals.T                                  # (nv, nf)
    nv, nf = PM.shape
    vcol = vertex_colors(V, normals)
    for _ in range(rounds):
        # facet colors from current vertex colors
        fcol_raw = [tuple(sorted((vcol[i], int(PM[i, j])) for i in range(nv))) for j in range(nf)]
        fo = {t: k for k, t in enumerate(sorted(set(fcol_raw)))}
        fcol = [fo[t] for t in fcol_raw]
        # new vertex colors from current facet colors
        vraw = [(vcol[i], tuple(sorted((int(PM[i, j]), fcol[j]) for j in range(nf)))) for i in range(nv)]
        vo = {t: k for k, t in enumerate(sorted(set(vraw)))}
        nvcol = [vo[t] for t in vraw]
        if nvcol == vcol:
            break
        vcol = nvcol
    return vcol

def oriented_signature2(V, normals=None, refine=2):
    """Color-keyed SIGNED INTEGER-bracket signature, symmetrized by a single global
    reorientation. For each (d+1)=6-subset S, with vertices color-ordered: record
    (sorted color key, signed integer bracket) when the 6 colors are DISTINCT (a
    canonical order, so the sign is well-defined), else (key, magnitude only) since
    the sign is not canonical on ties. This captures the JOINT sign+magnitude+local-
    color structure -- strictly stronger than |bracket| magnitudes (Lbr) and than
    sign-only chirotope. Multiset over S; canonical = min over the single global
    sign flip (negate all signed brackets). GL(5,Z)+perm+reorientation invariant."""
    V = np.asarray(V, dtype=np.int64)
    nv = V.shape[0]
    if normals is None:
        normals, _, _, _ = gc.facets_of(V)
    colors = refine_colors(V, normals, rounds=refine)
    H64 = np.hstack([np.ones((nv, 1), dtype=np.int64), V])
    fast = int(np.abs(H64).max()) <= 40
    Hpy = H64.tolist()
    sig = Counter()
    for b in combinations(range(nv), D + 1):
        cs = [colors[i] for i in b]
        key = tuple(sorted(cs))
        if len(set(cs)) == D + 1:                      # all distinct -> canonical order
            order_b = [i for _, i in sorted(zip(cs, b))]
            val = _detval([Hpy[i] for i in order_b], fast)   # signed
            sig[(key, 0, val)] += 1
        else:
            val = abs(_detval([Hpy[i] for i in b], fast))    # magnitude only (well-defined)
            sig[(key, 1, val)] += 1
    items = tuple(sorted(sig.items()))
    # single global reorientation flips the sign of every signed (tag 0) bracket
    flipped = tuple(sorted(((k, t, (-v if t == 0 else v)), c) for (k, t, v), c in sig.items()))
    return hashlib.sha1(repr(min(items, flipped)).encode()).hexdigest()[:16]

def oriented_sig_cocircuit(V, normals=None):
    """Cocircuit-partition oriented-matroid signature (layer Los). Hybrid exact
    arithmetic: fast float path for small coords (verified exact), exact Bareiss
    (Python bigints) otherwise -> invariant for ANY integer representation."""
    V = np.asarray(V, dtype=np.int64)
    nv = V.shape[0]
    if normals is None:
        normals, _, _, _ = gc.facets_of(V)
    colors = vertex_colors(V, normals)
    H64 = np.hstack([np.ones((nv, 1), dtype=np.int64), V])
    mx = int(np.abs(H64).max())
    fast = mx <= _FAST_MAX
    Hpy = H64.tolist()
    sig = Counter()
    for b in combinations(range(nv), D):
        Mb = [Hpy[i] for i in b]
        w = [0] * 6
        if fast:
            Mf = np.array(Mb, dtype=float)
            for k in range(6):
                sub = np.delete(Mf, k, axis=1)
                dk = int(round(np.linalg.det(sub)))
                w[k] = dk if k % 2 == 0 else -dk
        else:
            for k in range(6):
                sub = [[row[c] for c in range(6) if c != k] for row in Mb]
                dk = _idet(sub)
                w[k] = dk if k % 2 == 0 else -dk
        if not any(w):
            continue
        others = [j for j in range(nv) if j not in b]
        pos = []; neg = []; zer = []
        for j in others:
            s = sum(Hpy[j][c] * w[c] for c in range(6))
            (pos if s > 0 else neg if s < 0 else zer).append(colors[j])
        pos = tuple(sorted(pos)); neg = tuple(sorted(neg)); zer = tuple(sorted(zer))
        sig[(zer, tuple(sorted((pos, neg))))] += 1   # symmetrize global reorientation
    payload = tuple(sorted(sig.items()))
    return hashlib.sha1(repr(payload).encode()).hexdigest()[:16]

# ---------------------------------------------------------------------------
if __name__ == "__main__":
    DATA = "/home/ahat01/data/ws5d_sieved_dataset_v2_clean.parquet"
    TEST = "/home/ahat01/data/ws5d_sieved_dataset_v2_clean_test.parquet"
    TMP  = "/home/ahat01/.claude/jobs/d651e2f4/tmp"

    def mild_scramble(V, rng):
        """GL(5,Z) (det +/-1) + permutation + reflection, keeping coords bounded
        so the verified-exact fast path is exercised."""
        U = np.eye(D, dtype=np.int64)
        for _ in range(6):
            i, j = rng.choice(D, 2, replace=False)
            U[i] += rng.integers(-1, 2) * U[j]           # +-1 elementary ops
        if rng.random() < 0.5:                            # reflection (det -1)
            U[0] = -U[0]
        V2 = V @ U.T
        return V2[rng.permutation(V2.shape[0])]

    # ---- (1) INVARIANCE: GL(det +/-1) + perm + reflection, Los must not change ----
    _p("=== invariance test (GL det +/-1 + permutation + reflection) ===")
    t = pq.read_table(TEST, columns=['nf_vertices','bh_mv']).to_pydict()
    rng = np.random.default_rng(0)
    pick = [0, 100, 1000, 5000, 20000, 100000, 250000, 446751]
    ok = True
    for r in pick:
        V = gc.decode_vertices(t['nf_vertices'][r], t['bh_mv'][r])
        base = oriented_signature2(V)
        good = 0
        for _ in range(5):
            V2 = mild_scramble(V, rng)
            same = oriented_signature2(V2) == base
            ok &= same; good += int(same)
        _p(f"  row {r:>7} g={V.shape[0]-6:2d} nv={V.shape[0]:2d}: invariant over 5 scrambles = {good}/5")
    # one exact-path (large-coord) check
    V = gc.decode_vertices(t['nf_vertices'][0], t['bh_mv'][0])
    Ubig = np.array([[1,3,0,0,0],[0,1,0,0,0],[2,0,1,0,0],[0,0,0,1,5],[0,0,0,0,1]], dtype=np.int64)
    for _ in range(3): Ubig = Ubig @ Ubig
    Vbig = (V @ Ubig.T)
    exact_ok = oriented_signature2(Vbig) == oriented_signature2(V)
    _p(f"  exact-path (coords up to {int(np.abs(Vbig).max())}) invariant = {exact_ok}")
    ok &= exact_ok
    _p(f"INVARIANCE OK: {ok}\n")

    # ---- (2) SEPARATION: do the 42 residual groups split under Los? ----
    _p("=== separation test on the 42 residual-collision groups ===")
    rows = np.sort(np.load(os.path.join(TMP, "residual_collision_rows.npy")))
    pf = pq.ParquetFile(DATA); nrg = pf.num_row_groups
    offs = [0]
    for rg in range(nrg): offs.append(offs[-1] + pf.metadata.row_group(rg).num_rows)
    offs = np.array(offs)
    rg_of = np.searchsorted(offs, rows, side='right') - 1
    loc_of = rows - offs[rg_of]
    FREE = ['h11','h12','h13','h22','chi','point_count','dual_point_count',
            'bh_mp','bh_np','bh_mv','bh_nv']
    recs = []
    for rg in sorted(set(int(x) for x in rg_of)):
        locs = loc_of[rg_of == rg]; glob = rows[rg_of == rg]
        tbl = pf.read_row_group(rg, columns=['nf_vertices','bh_mv']+FREE).take(
            pa.array([int(x) for x in locs]))
        d = tbl.to_pydict()
        for k, gi in enumerate(glob):
            recs.append(dict(row=int(gi), free=tuple(int(d[c][k]) for c in FREE),
                             nv=int(d['bh_mv'][k]), blob=bytes(d['nf_vertices'][k])))
    for r in recs:
        V = gc.decode_vertices(r['blob'], r['nv'])
        normals,_,_,_ = gc.facets_of(V)
        fp,_ = gc.fingerprint(V, want=("L1","Lpm"))
        r['ck'] = (r['free'], gc._hash(fp["L1"]), fp["Lpm"][-1])
        r['los'] = oriented_signature2(V, normals)
    groups = defaultdict(list)
    for r in recs: groups[r['ck']].append(r)
    groups = {k:v for k,v in groups.items() if len(v) > 1}
    nsep = 0; nfail = 0
    for k, mem in sorted(groups.items(), key=lambda kv:-len(kv[1])):
        g = mem[0]['nv']-6
        los = [m['los'] for m in mem]
        distinct = len(set(los))
        sep = distinct == len(mem)
        nsep += int(sep); nfail += int(not sep)
        tag = "SPLIT" if sep else f"STILL {len(mem)-distinct+1}-COLLIDING"
        _p(f"g={g:2d} size={len(mem)} distinct_Los={distinct} [{tag}]")
    _p(f"\n=== SEPARATION VERDICT ===")
    _p(f"groups fully split by Los : {nsep}/{len(groups)}")
    _p(f"groups still colliding    : {nfail}")
    if nfail == 0:
        _p("\nThe augmented key (free + L1 + Lpm + Los) is INJECTIVE on all 88,588,676 fibres.")
