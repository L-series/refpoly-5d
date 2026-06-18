#!/usr/bin/env python3
"""SINGLE SLURM job, cascade completeness test of the Gale fibre key on ALL
88.5M d=5 reflexive fibres.

Pass 1 (vectorized, no geometry): group every fibre by the FREE GL-invariants
   (Hodge h11..h22, chi, lattice point/vertex/facet counts). Fibres with a unique
   free-invariant tuple are already separated by the combined key.
Pass 2 (parallel geometry, only on free-invariant collisions): for the residual
   rows, compute the geometric Gale key (L1 facet combinatorics + Lpm vertex-facet
   pairing matrix) and test whether (free tuple, geom key) separates them.

A residual collision = two DISTINCT normal forms sharing the full combined key
=> a genuine incompleteness of the key. Reported stratified by g = n_v - 6.
"""
import os
for v in ("OMP_NUM_THREADS","OPENBLAS_NUM_THREADS","MKL_NUM_THREADS","NUMEXPR_NUM_THREADS"):
    os.environ[v] = "1"
import sys, time, hashlib, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import pyarrow.parquet as pq
from multiprocessing import Pool
from collections import Counter
import galeclass as gc

DATA = "/home/ahat01/data/ws5d_sieved_dataset_v2_clean.parquet"
TMP  = "/home/ahat01/.claude/jobs/d651e2f4/tmp"
FREE = ['h11','h12','h13','h22','chi','point_count','dual_point_count',
        'bh_mp','bh_np','bh_mv','bh_nv']

def geom_key(args):
    blob, nv = args
    V = gc.decode_vertices(blob, nv)
    fp, refl = gc.fingerprint(V, want=("L1","Lpm"))
    h = hashlib.blake2b(repr((fp["L1"], fp["Lpm"])).encode(), digest_size=16).digest()
    return (int.from_bytes(h[:8],"little"), int.from_bytes(h[8:],"little"), int(refl))

def main():
    ncpu = int(os.environ.get("SLURM_CPUS_PER_TASK", os.cpu_count() or 8))
    pf = pq.ParquetFile(DATA); nrg = pf.num_row_groups; total = pf.metadata.num_rows
    print(f"[{time.strftime('%H:%M:%S')}] host={os.uname().nodename} ncpu={ncpu} "
          f"rows={total:,} rgs={nrg}", flush=True)
    t0 = time.time()

    # ---------- PASS 1: free invariants, vectorized ----------
    tab = pq.read_table(DATA, columns=FREE)
    N = tab.num_rows
    M = np.empty((N, len(FREE)), dtype=np.int64)
    for j, c in enumerate(FREE):
        M[:, j] = tab.column(c).to_numpy(zero_copy_only=False)
    nv_all = M[:, FREE.index('bh_mv')].astype(np.int64)
    g_all = (nv_all - 6).astype(np.int16)
    del tab
    # exact grouping via structured void view
    Mc = np.ascontiguousarray(M.astype(np.int32))
    void = Mc.view([('', np.int32)] * len(FREE)).ravel()
    uniq, inv, counts = np.unique(void, return_inverse=True, return_counts=True)
    free_distinct = len(uniq)
    in_coll = counts[inv] > 1
    nfree_coll = int(in_coll.sum())
    print(f"[{time.strftime('%H:%M:%S')}] PASS1 done {time.time()-t0:.0f}s | "
          f"distinct free-invariant keys: {free_distinct:,} | "
          f"fibres needing geometry: {nfree_coll:,} ({100*nfree_coll/N:.4f}%)", flush=True)
    del M, Mc, void, counts, uniq

    # ---------- PASS 2: geometric key on residual rows only ----------
    coll_rows = np.where(in_coll)[0]
    geom_hi = np.zeros(N, dtype=np.uint64)
    geom_lo = np.zeros(N, dtype=np.uint64)
    refl_all = np.ones(N, dtype=np.int8)
    done = 0; t1 = time.time()
    pfh = pq.ParquetFile(DATA)
    with Pool(ncpu) as pool:
        base = 0
        for rg in range(nrg):
            n = pfh.metadata.row_group(rg).num_rows
            local = np.where(in_coll[base:base + n])[0]
            if local.size:
                sub = pfh.read_row_group(rg, columns=['nf_vertices', 'bh_mv']).to_pydict()
                rows_here = base + local
                args = [(sub['nf_vertices'][int(li)], int(sub['bh_mv'][int(li)])) for li in local]
                for r, (a, b, rf) in zip(rows_here, pool.imap(geom_key, args, chunksize=256)):
                    geom_hi[r] = a; geom_lo[r] = b; refl_all[r] = rf
                done += local.size
            base += n
            if rg % 20 == 0:
                el = time.time() - t1
                print(f"[{time.strftime('%H:%M:%S')}] PASS2 rg {rg+1}/{nrg} "
                      f"geom_done={done:,}/{nfree_coll:,}", flush=True)

    # ---------- combined-key residual collision detection ----------
    # within the free-collision set, residual collision iff same (free group inv, geom hash)
    fi = inv[coll_rows].astype(np.int64)
    comb = np.ascontiguousarray(np.column_stack(
        [fi, geom_hi[coll_rows].astype(np.int64), geom_lo[coll_rows].astype(np.int64)]))
    cv = comb.view([('', np.int64)] * 3).ravel()
    _, cinv, ccounts = np.unique(cv, return_inverse=True, return_counts=True)
    resid_mask = ccounts[cinv] > 1
    nresid = int(resid_mask.sum())
    distinct_total = total - nresid   # fibres outside coll_set are unique; residual collide
    # (each residual group of size k contributes k-1 lost distinctions; but for a clean
    #  headline we report fibres-in-collision and distinct-key count below)
    # exact distinct keys = (N - nfree_coll) + number_of_distinct_combined_keys_in_collset
    distinct_in_coll = len(np.unique(cv))
    distinct_keys = (total - nfree_coll) + distinct_in_coll

    print(f"\n=== GALE FIBRE KEY completeness on {total:,} fibres "
          f"({time.time()-t0:.0f}s total) ===", flush=True)
    print(f"nonreflexive fibres        : {int((refl_all[coll_rows]==0).sum())} (among tested)")
    print(f"distinct combined keys     : {distinct_keys:,}")
    print(f"fibres in residual collision: {nresid:,}  ({100*nresid/total:.6f}%)")
    gco = Counter(int(x) for x in g_all[coll_rows][resid_mask])
    if gco:
        print("residual collisions by Gale dimension g:")
        for gg in sorted(gco): print(f"  g={gg:2d} (n_v={gg+6:2d}): {gco[gg]}")
    else:
        print("ZERO residual collisions: combined Gale key is INJECTIVE on all 88.5M fibres.")

    resid_global = coll_rows[resid_mask]
    np.save(os.path.join(TMP, "residual_collision_rows.npy"), resid_global)
    json.dump({"total": int(total), "free_distinct": int(free_distinct),
               "free_coll": int(nfree_coll), "distinct_keys": int(distinct_keys),
               "residual_coll": int(nresid),
               "resid_by_g": {int(k): int(v) for k, v in gco.items()},
               "tot_by_g": {int(k): int(v) for k, v in Counter(int(x) for x in g_all).items()}},
              open(os.path.join(TMP, "agg_summary.json"), "w"))
    print("\nSAVED agg_summary.json ; DONE.", flush=True)

if __name__ == "__main__":
    main()
