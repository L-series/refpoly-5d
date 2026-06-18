"""End-to-end: build the Newton polytope Delta_q directly from a weight system q
(the hull step alpha), compute its Gale key, and check it matches the dataset's
stored normal form for the same fibre -- WITHOUT any normal-form computation.

Delta_q = conv{ y in Z^n : sum q_i y_i = 0, y_i >= -1 }   (n = d+1 = 6)
        = (degree-deg monomials x = y+1 >= 0 with sum q_i x_i = deg) shifted.
The d=5 integer coordinates come from a unimodular change of basis sending the
saturated lattice ker(q) cap Z^6 onto Z^5.
"""
import os, numpy as np, itertools, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import galeclass as gc
from math import gcd

def ext_gcd(a, b):
    if b == 0: return (a, 1, 0)
    g, x, y = ext_gcd(b, a % b)
    return (g, y, x - (a // b) * y)

def unimodular_first_row(q):
    """Return unimodular U (n x n, int) with (q @ U) = [g,0,...,0], g=gcd(q).
    Columns U[:,1:] are a saturated lattice basis of ker(q) cap Z^n."""
    q = [int(v) for v in q]; n = len(q)
    U = np.eye(n, dtype=object)
    cur = q[:]
    for i in range(1, n):
        a, b = cur[0], cur[i]
        if b == 0: continue
        g, x, y = ext_gcd(a, b)
        ag, bg = a // g, b // g
        c0 = U[:, 0] * x + U[:, i] * y
        ci = U[:, 0] * (-bg) + U[:, i] * ag
        U[:, 0], U[:, i] = c0, ci
        cur[0], cur[i] = g, 0
    return U

def newton_polytope(q):
    """Vertices (n_v x d, integer) of Delta_q for single weight system q."""
    q = [int(v) for v in q]; n = len(q); deg = sum(q)
    # enumerate x >= 0 with sum q_i x_i = deg  (bounded: x_i <= deg//q_i)
    bounds = [deg // qi for qi in q]
    pts = []
    def rec(i, rem, acc):
        if i == n - 1:
            if rem % q[i] == 0:
                xi = rem // q[i]
                if 0 <= xi <= bounds[i]:
                    pts.append(acc + [xi])
            return
        for xi in range(0, min(bounds[i], rem // q[i]) + 1):
            rec(i + 1, rem - q[i] * xi, acc + [xi])
    rec(0, deg, [])
    X = np.array(pts, dtype=np.int64)            # monomials, sum q_i x_i = deg
    Y = X - 1                                    # shift: y in ker(q) hyperplane
    assert np.all(Y @ np.array(q) == 0)
    # change basis to d=5 integer coords via saturated kernel
    U = unimodular_first_row(q)
    Uinv = np.rint(np.linalg.inv(U.astype(float))).astype(np.int64)
    assert np.array_equal(Uinv @ U.astype(np.int64), np.eye(n, dtype=np.int64)), "U not unimodular"
    C = (Y @ Uinv.T)                              # coords; column 0 should be 0
    assert np.all(C[:, 0] == 0)
    coords = C[:, 1:]                             # (npoints, d)
    # vertices = hull vertices
    from scipy.spatial import ConvexHull
    h = ConvexHull(coords.astype(float))
    verts = coords[np.unique(h.vertices)]
    return verts

if __name__ == "__main__":
    import pyarrow.parquet as pq
    f = "/home/ahat01/data/ws5d_sieved_dataset_v2_clean_test.parquet"
    # smallest-degree example: row 446751, q=[4,5,6,15,15,32], expect n_v=25
    row = 446751
    t = pq.read_table(f, columns=['nf_vertices','bh_mv','weight_systems']).slice(row,1).to_pydict()
    q = list(t['weight_systems'][0][0])
    nv_data = t['bh_mv'][0]
    V_nf = gc.decode_vertices(t['nf_vertices'][0], nv_data)
    print("weight system q =", q, " deg =", sum(q), " dataset n_v =", nv_data)

    V_q = newton_polytope(q)
    print("constructed Delta_q: n_v =", V_q.shape[0])
    k_data, _ = gc.fingerprint(V_nf, want=("L0","L1","Lpm"))
    k_constr, refl = gc.fingerprint(V_q, want=("L0","L1","Lpm"))
    print("reflexive(constructed):", refl)
    print("L0 (g,nv,nf,vol)  data :", k_data["L0"])
    print("L0 (g,nv,nf,vol)  Δ_q  :", k_constr["L0"])
    match = all(k_data[L] == k_constr[L] for L in ("L1","Lpm"))
    print("\nGALE KEY MATCH (Δ_q built from q  ==  stored NF):", match)
