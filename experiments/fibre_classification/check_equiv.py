#!/usr/bin/env python3
"""Decisive test on the 42 residual-collision groups: are the collision-mates the
SAME lattice polytope or genuinely GL(5,Z)-INequivalent?

nf_vertices is PALP's CANONICAL normal form => GL-equivalent polytopes have
BYTE-IDENTICAL matrices, and distinct NF matrices are GL-inequivalent.
We check, per group:
  (a) byte-identity of the nf_vertices blobs,
  (b) equality as point SETS (column multiset),
  (c) the SIGNED-chirotope content the magnitude key (Lbr) throws away:
      sorted multiset of |det| is equal by construction; we test whether the
      *number of positive vs negative* oriented bases (after a canonical vertex
      ordering by a GL-invariant) differs -- a proxy for orientation data.
"""
import os
for v in ("OMP_NUM_THREADS","OPENBLAS_NUM_THREADS","MKL_NUM_THREADS","NUMEXPR_NUM_THREADS"):
    os.environ[v] = "1"
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, pyarrow as pa, pyarrow.parquet as pq
from collections import defaultdict
import galeclass as gc
def _p(*a): print(*a, flush=True)

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

def canon_pointset(V):
    """sorted tuple of vertex columns -> GL-noninvariant but permutation-canonical."""
    return tuple(sorted(tuple(int(x) for x in row) for row in V.tolist()))

def signed_chiro_counts(V):
    """After ordering vertices by a canonical GL-invariant per-vertex key, count
    (#positive, #negative, #zero) oriented (d+1)-bases. The magnitude key keeps
    only |det|; this keeps the sign pattern under one canonical order."""
    from itertools import combinations
    nv = V.shape[0]
    H = np.hstack([np.ones((nv,1), dtype=np.int64), V])
    # canonical vertex order: by (row of pairing sums) is hard; use lexicographic
    # of the vertex coords (NOT GL-invariant, but identical for identical NF and a
    # stable tie-break for genuinely different ones -- diagnostic only)
    order = sorted(range(nv), key=lambda i: tuple(V[i].tolist()))
    Ho = H[order]
    pos=neg=zero=0
    for idx in combinations(range(nv), 6):
        det = round(float(np.linalg.det(Ho[list(idx)].astype(float))))
        if det>0: pos+=1
        elif det<0: neg+=1
        else: zero+=1
    return pos,neg,zero

# reconstruct groups by full cheap key (free, L1 hash, Lpm hash)
for r in recs:
    V = gc.decode_vertices(r['blob'], r['nv'])
    fp,_ = gc.fingerprint(V, want=("L1","Lpm"))
    r['ck'] = (r['free'], gc._hash(fp["L1"]), fp["Lpm"][-1]); r['V']=V
groups = defaultdict(list)
for r in recs: groups[r['ck']].append(r)
groups = {k:v for k,v in groups.items() if len(v)>1}

n_byte_id=0; n_set_id=0; n_distinct=0; sign_diff=0
_p(f"groups: {len(groups)}\n")
for gi,(k,mem) in enumerate(sorted(groups.items(), key=lambda kv:-len(kv[1]))):
    g = mem[0]['nv']-6
    blobs = set(m['blob'] for m in mem)
    sets  = set(canon_pointset(m['V']) for m in mem)
    byte_id = len(blobs)==1
    set_id  = len(sets)==1
    n_byte_id += int(byte_id); n_set_id += int(set_id)
    n_distinct += int(not set_id)
    sc = [signed_chiro_counts(m['V']) for m in mem]
    sc_diff = len(set(sc))>1
    sign_diff += int(sc_diff and not set_id)
    if gi < 12 or (not set_id):
        _p(f"g={g:2d} size={len(mem)} | byte_identical={byte_id} | pointset_identical={set_id}"
           f" | signed_chiro_counts={sc} differ={sc_diff}")

_p(f"\n=== VERDICT over {len(groups)} groups ===")
_p(f"groups with byte-identical NF blobs (literal duplicate rows): {n_byte_id}")
_p(f"groups identical as point sets (same polytope, reordered)   : {n_set_id}")
_p(f"groups with genuinely DIFFERENT NF point sets               : {n_distinct}")
_p(f"  of those, separated by SIGNED chirotope counts            : {sign_diff}")
