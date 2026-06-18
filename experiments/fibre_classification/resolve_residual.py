#!/usr/bin/env python3
"""Drill-down on the 85 residual-collision fibres left by the CHEAP combined key
(free invariants + geometric L1 + Lpm). For each collision group, test whether the
deeper layers Lar (Smith normal forms) and Lbr (chirotope bracket magnitudes)
separate the genuinely-distinct normal forms -- i.e. whether the FULL Gale key is
injective, or whether a true chirotope-equivalent-but-GL-inequivalent residue remains.
"""
import os
for v in ("OMP_NUM_THREADS","OPENBLAS_NUM_THREADS","MKL_NUM_THREADS","NUMEXPR_NUM_THREADS"):
    os.environ[v] = "1"
import sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, pyarrow as pa, pyarrow.parquet as pq
from collections import defaultdict
import galeclass as gc

def _p(*a): print(*a, flush=True)

DATA = "/home/ahat01/data/ws5d_sieved_dataset_v2_clean.parquet"
TMP  = "/home/ahat01/.claude/jobs/d651e2f4/tmp"
FREE = ['h11','h12','h13','h22','chi','point_count','dual_point_count',
        'bh_mp','bh_np','bh_mv','bh_nv']

rows = np.load(os.path.join(TMP, "residual_collision_rows.npy"))
rows = np.sort(rows)
_p(f"residual rows: {rows.size}")

pf = pq.ParquetFile(DATA); nrg = pf.num_row_groups
# cumulative row-group offsets
offs = [0]
for rg in range(nrg):
    offs.append(offs[-1] + pf.metadata.row_group(rg).num_rows)
offs = np.array(offs)

# map each global row to (rg, local)
rg_of = np.searchsorted(offs, rows, side='right') - 1
loc_of = rows - offs[rg_of]
needed = sorted(set(int(x) for x in rg_of))
_p(f"row groups to read: {len(needed)} -> {needed}")

# gather per-row data. Read ONLY nf_vertices+bh_mv+FREE (NOT the nested
# weight_systems), and .take() just the target rows before materializing.
recs = []  # dict per residual row
cols = ['nf_vertices','bh_mv'] + FREE
for ci, rg in enumerate(needed):
    locs = loc_of[rg_of == rg]
    glob = rows[rg_of == rg]
    tbl = pf.read_row_group(rg, columns=cols).take(pa.array([int(x) for x in locs]))
    d = tbl.to_pydict()
    for k, gi in enumerate(glob):
        free_tuple = tuple(int(d[c][k]) for c in FREE)
        recs.append(dict(row=int(gi), rg=rg, local=int(locs[k]),
                         free=free_tuple, nv=int(d['bh_mv'][k]),
                         blob=d['nf_vertices'][k]))
    _p(f"  read group {ci+1}/{len(needed)} (rg={rg}, {len(glob)} rows)")
_p(f"gathered {len(recs)} residual fibres\n")

# compute full layered fingerprint for each
for i, r in enumerate(recs):
    V = gc.decode_vertices(r['blob'], r['nv'])
    fp, refl = gc.fingerprint(V, want=("L0","L1","Lpm","Lar","Lbr"))
    r['fp'] = fp; r['refl'] = refl
    r['cheap'] = (r['free'], gc._hash(fp["L1"]), fp["Lpm"][-1])  # = cascade combined key
    r['full']  = (r['free'], gc._hash((fp["L1"], fp["Lpm"], fp["Lar"], fp["Lbr"])))
    if (i+1) % 10 == 0: _p(f"  keyed {i+1}/{len(recs)}")

# regroup by the CHEAP combined key => reconstruct the collision groups
groups = defaultdict(list)
for r in recs:
    groups[r['cheap']].append(r)
groups = {k:v for k,v in groups.items() if len(v) > 1}
_p(f"reconstructed collision groups (cheap key): {len(groups)}  "
   f"(sizes: {sorted(len(v) for v in groups.values())})\n")

# within each group, do the deeper layers separate the members?
resolved_by_Lar = 0; resolved_by_Lbr = 0; still_colliding = 0
true_residual_groups = []
for k, members in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    g = members[0]['nv'] - 6
    # distinct after adding Lar
    lar_keys = set(gc._hash((m['fp']["L1"], m['fp']["Lpm"], m['fp']["Lar"])) for m in members)
    full_keys = set(m['full'][1] for m in members)
    n = len(members)
    sep_lar = len(lar_keys); sep_full = len(full_keys)
    tag = "RESOLVED" if sep_full == n else f"STILL {n-sep_full+1}-WAY COLLIDING"
    _p(f"g={g:2d}  size={n}  distinct(+Lar)={sep_lar}  distinct(+Lar+Lbr)={sep_full}  [{tag}]")
    if sep_full == n:
        if sep_lar == n: resolved_by_Lar += 1
        else: resolved_by_Lbr += 1
    else:
        still_colliding += 1
        true_residual_groups.append((k, members, sep_full))

_p(f"\n=== SUMMARY ===")
_p(f"collision groups total          : {len(groups)}")
_p(f"fully resolved by adding Lar     : {resolved_by_Lar}")
_p(f"fully resolved only with Lbr too : {resolved_by_Lbr}")
_p(f"STILL colliding after full key   : {still_colliding}")

if true_residual_groups:
    _p(f"\n=== TRUE RESIDUAL (full Gale key NOT injective) ===")
    # fetch weight systems lazily for just these rows
    for k, members, sepf in true_residual_groups:
        for m in members:
            tbl = pf.read_row_group(m['rg'], columns=['weight_systems']).take(pa.array([m['local']]))
            m['ws'] = [list(w) for w in tbl.to_pydict()['weight_systems'][0]]
        g = members[0]['nv'] - 6
        _p(f"\n-- group g={g}, {len(members)} fibres, only {sepf} distinct full keys --")
        for m in members:
            _p(f"   row {m['row']:>9}  nv={m['nv']}  WS={m['ws']}")
            _p(f"      L0={m['fp']['L0']}  Lar={m['fp']['Lar']}")
            _p(f"      L1_facets={m['fp']['L1'][4]}")
else:
    _p("\nThe FULL Gale key (L1+Lpm+Lar+Lbr) is INJECTIVE on all 88,588,676 fibres.")
