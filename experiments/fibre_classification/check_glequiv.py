#!/usr/bin/env python3
"""DECISIVE: are the 42 residual-collision pairs GL(5,Z)+permutation EQUIVALENT
(same lattice polytope, so the key is correct) or genuinely INEQUIVALENT (a real
incompleteness)? Exact integer search for a unimodular U with V2 = {U v : v in V1}.
"""
import os
for v in ("OMP_NUM_THREADS","OPENBLAS_NUM_THREADS","MKL_NUM_THREADS","NUMEXPR_NUM_THREADS"):
    os.environ[v] = "1"
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, pyarrow as pa, pyarrow.parquet as pq
from itertools import product
from collections import defaultdict
import galeclass as gc
from galeclass import refine_colors
def _p(*a): print(*a, flush=True)
D = 5

def find_basis(V):
    idx = []; rows = []
    for i in range(len(V)):
        cand = rows + [V[i]]
        if np.linalg.matrix_rank(np.array(cand, dtype=float)) == len(cand):
            rows.append(V[i]); idx.append(i)
            if len(idx) == D:
                break
    return idx

def gl_equiv(V1, V2, c1, c2, cap=200000):
    """True/False if a unimodular U + relabeling maps V1 onto V2 (as vertex sets)."""
    if sorted(c1) != sorted(c2):
        return False
    V1 = np.asarray(V1, dtype=np.int64); V2 = np.asarray(V2, dtype=np.int64)
    nv = len(V1)
    basis = find_basis(V1)
    if len(basis) < D:
        return None
    M1 = V1[basis].T.astype(np.int64)                      # 5x5 (columns = chosen verts)
    M1inv = np.linalg.inv(M1.astype(float))
    tgt = [c1[i] for i in basis]
    pools = [[j for j in range(nv) if c2[j] == tgt[t]] for t in range(D)]
    if any(len(p) == 0 for p in pools):
        return False
    size = 1
    for p in pools: size *= len(p)
    if size > cap:
        return ("TOO_BIG", size)
    setV2 = set(map(tuple, V2.tolist()))
    V1list = V1.tolist()
    for combo in product(*pools):
        if len(set(combo)) < D:
            continue
        M2 = V2[list(combo)].T.astype(np.int64)
        Ufloat = M2.astype(float) @ M1inv
        Ui = np.rint(Ufloat).astype(np.int64)
        if not np.array_equal(Ui @ M1, M2):               # exact verify integer + solves
            continue
        d = int(round(np.linalg.det(Ui.astype(float))))
        if d not in (1, -1):
            continue
        mapped = set(tuple(int(x) for x in (Ui @ np.array(v, dtype=np.int64)))
                     for v in V1list)
        if mapped == setV2:
            return True
    return False

# ---- load the 42 groups ----
DATA = "/home/ahat01/data/ws5d_sieved_dataset_v2_clean.parquet"
TMP  = "/home/ahat01/.claude/jobs/d651e2f4/tmp"
FREE = ['h11','h12','h13','h22','chi','point_count','dual_point_count',
        'bh_mp','bh_np','bh_mv','bh_nv']
rows = np.sort(np.load(os.path.join(TMP, "residual_collision_rows.npy")))
pf = pq.ParquetFile(DATA); nrg = pf.num_row_groups
offs = [0]
for rg in range(nrg): offs.append(offs[-1] + pf.metadata.row_group(rg).num_rows)
offs = np.array(offs)
rg_of = np.searchsorted(offs, rows, side='right') - 1
loc_of = rows - offs[rg_of]
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
    r['V'] = V; r['col'] = refine_colors(V, normals, rounds=3)
groups = defaultdict(list)
for r in recs: groups[r['ck']].append(r)
groups = {k:v for k,v in groups.items() if len(v) > 1}

neq = 0; nineq = 0; nbig = 0
for gi, (k, mem) in enumerate(sorted(groups.items(), key=lambda kv:-len(kv[1]))):
    g = mem[0]['nv'] - 6
    # test all pairs in the group; group is "equivalent" if all members pairwise equiv
    res = []
    for a in range(len(mem)):
        for b in range(a+1, len(mem)):
            res.append(gl_equiv(mem[a]['V'], mem[b]['V'], mem[a]['col'], mem[b]['col']))
    alleq = all(x is True for x in res)
    anyineq = any(x is False for x in res)
    big = any(isinstance(x, tuple) for x in res)
    tag = "EQUIVALENT" if alleq else ("INEQUIVALENT" if anyineq and not big else f"INCONCLUSIVE {res}")
    neq += int(alleq); nineq += int(anyineq and not big and not alleq); nbig += int(big)
    _p(f"g={g:2d} size={len(mem)} rows={[m['row'] for m in mem]} -> {tag}")

_p(f"\n=== GL-EQUIVALENCE VERDICT over {len(groups)} groups ===")
_p(f"EQUIVALENT (same polytope, key CORRECT)   : {neq}")
_p(f"INEQUIVALENT (genuine key incompleteness) : {nineq}")
_p(f"inconclusive (search capped)              : {nbig}")
