# The two classification pipelines in 5D: single vs. combined weight systems

*A theory-and-code companion. Every algorithmic step is referenced to the PALP
source in `refpoly-5d/PALP/` (file:line) and, where it exists, to the Lean
formalization in `refpoly-5d/proofs/Refpoly/`.*

---

## 0. What this document is

Reflexive polytopes in dimension $d$ are classified by **weight systems**. There
are two flavours, and they correspond to a genuine geometric dichotomy:

| | minimal core | weight data | ambient dim |
|---|---|---|---|
| **Pipeline A** | a **simplex** ($d+1$ vertices) | a **single** weight vector $q\in\mathbb{Q}^{d+1}_{>0}$ | $n=d+1$ |
| **Pipeline B** | a **non-simplicial** minimal polytope ($d+k$ vertices, $2\le k\le d$) | a **combined** weight system: a $k\times n$ matrix | $n=d+k$ |

Both pipelines share the same skeleton — *enumerate (C)WS → reconstruct a
polytope → test IP/reflexivity → dualize → normal-form → take subpolytopes* —
but they enumerate different objects and use different machinery to do it. This
note explains the theory of each in depth, then maps each step to PALP.

Throughout, $d$ is the polytope dimension (so $d=5$ for Calabi–Yau fourfolds),
$N_\mathbb{R}\cong\mathbb{R}^d$ is the lattice space the polytope lives in, and
$M_\mathbb{R}$ is the dual.

---

## 1. Background objects (shared by both pipelines)

### 1.1 Reflexive, IP, and the polar dual

A lattice polytope $\Delta\subset N_\mathbb{R}$ with $0$ in its interior is

- **IP** ("interior point") if $0\in\mathrm{int}\,\Delta$ — equivalently every
  facet equation $\langle a_F,\cdot\rangle\ge -c_F$ has $c_F>0$;
- **reflexive** if additionally **every facet sits at lattice distance $1$**,
  i.e. $c_F=1$ for all facets — equivalently the polar dual
  $\Delta^\ast=\{y:\langle x,y\rangle\ge-1\ \forall x\in\Delta\}$ is again a
  *lattice* polytope.

> **This single inequality — `c > 0` vs. `c == 1` — is the whole IP/reflexive
> distinction, and it is exactly what separates the two checks in PALP.**
> `Vertex.c:1128 IP_Check` walks the facets and rejects as soon as it finds
> `c <= 0` (`Finish_IP_Check`, `Vertex.c:1114`); `Vertex.c:1170 Ref_Check`
> rejects as soon as it finds `c != 1` (`Finish_REF_Check`, `Vertex.c:1156`).
> `Find_Equations` (`Vertex.c:1081`) produces the vertices `V` and facet
> equations `E` and returns the IP flag.
>
> *Lean:* `IsReflexive` and `polarDual` in `Basic.lean`; the IP property of a
> weight system is `IsIPWeightSystem` in `WeightSystem.lean`.

Reflexive $\Rightarrow$ IP, but **not** conversely. The gap is the entire
subject of §5.

### 1.2 The minimal–maximal interval, and duality

Order reflexive polytopes by inclusion. Two facts (Kreuzer–Skarke) organize the
whole classification:

- **(S) every reflexive polytope embeds in a *maximal* one** — *Lean:*
  `exists_maximal_superset` (T2.2, `MaxMin.lean`);
- **(D) polar duality reverses inclusion and swaps maximal $\leftrightarrow$
  minimal**: $\Delta$ maximal $\iff$ $\Delta^\ast$ minimal — *Lean:*
  `maximal_iff_dual_minimal` (T3.4), `exists_minimal_subset` (`MaxMin.lean`).

So one classifies the **minimal** polytopes (small, few vertices, described by
weight systems) and dualizes to recover the maximal ones; everything else lies
in the interval between a minimal subpolytope and a maximal superpolytope.

### 1.3 A weight system carries **two** polytopes

This is the point most easily confused. A single weight system $q$ determines:

1. **the minimal core** — the simplex on vertices $V_i$ satisfying the circuit
   relation $\sum_i q_i V_i = 0$ (the $q_i$ are the barycentric coordinates of
   $0$); in $d=5$ this has $6$ vertices.
   *Lean:* `simplex_weights` (`Minimal.lean`).
2. **the maximal Newton polytope** $\Delta_q$ — the convex hull of *all* lattice
   points $y$ in the weight hyperplane with $y_i\ge-1$:
   $$\Delta_q=\mathrm{conv}\bigl(\mathbb{Z}^n\cap\{y\in W_q : y_i\ge-1\}\bigr),
   \qquad W_q=\{y:\textstyle\sum_i q_i y_i=0\}.$$
   In shifted coordinates $x=y+\mathbf 1$ these are the nonnegative integer
   solutions of $\sum_i x_i q_i=\sum_i q_i$ — i.e. the degree-$\deg$ monomials of
   the weighted polynomial ring. This generically has *many* vertices.
   *Lean:* `wsHyperplane`, `wsLatticeGensAt`, `wsPolytopeAt`,
   `IsIPWeightSystem` (`WeightSystem.lean`); *PALP:* built by
   `Make_CWS_Points` (`Coord.c:1015`).

`minimal core` $\subseteq$ `maximal` $\Delta_q$ — this is an **inclusion in the
same space** $W_q$, *not* a duality: the simplex is the economical IP core, and
$\Delta_q$ is the full hull of *all* generators, with many more vertices (e.g. a
6-vertex core inside a 43-vertex $\Delta_q$). The polar **dual** of $\Delta_q$ is
a *different* minimal reflexive polytope $\Delta_q^\ast$ in the dual lattice (the
max$\leftrightarrow$min duality of §1.2) — generally **not** the simplex, and the
one whose facet count equals $\Delta_q$'s vertex count. A $d$-simplex has only
$d{+}1$ facets, so the core simplex cannot account for $\Delta_q$'s many
vertices; those are extra lattice generators, not duals of simplex facets. When
you read "$\Delta_q$ has lots of vertices" that is the **maximal** one; "single
weight system $\leftrightarrow$ simplex" refers to the **minimal** one. PALP
enumerates the weight data, reconstructs $\Delta_q$, and tests *it*.

---

## 2. The shared skeleton

Both pipelines instantiate the same five stages. The differences (§3, §4) are
entirely in stages ① and ②.

```
 ①  enumerate (C)WS            cws.x            cws.c
 ②  reconstruct the polytope   Make_CWS_Points  Coord.c:1015
 ③  IP / reflexivity test      Find_Equations / IP_Check / Ref_Check   Vertex.c
 ④  polar dual                 Make_Dual_Poly   Polynf.c:3210 (Aux_Make_Dual_Poly)
 ⑤  normal form + subpolytopes Make_All_Subpolys / class.x   Subpoly.c, class.c
```

The driver `poly.x` (`poly.c`) runs ②–④ on one input; `class.x` (`class.c`)
runs ⑤, managing the normal-form database for the in-between polytopes.

---

## 3. Pipeline A — single weight systems (simplicial minimal cores)

### 3.1 Theory

A single weight system is $q=(w_1,\dots,w_n)$, positive integers, $\gcd=1$,
$n=d+1$. It is **IP** iff its maximal Newton polytope $\Delta_q$ has $0$ in its
interior (§1.1). The simplicial minimal polytopes — and, by duality, a large
family of maximal reflexive polytopes — are exactly these.

The enumeration is **constructive and bounded by dimension, not by degree**. One
builds the polytope by adding lattice points to the interior point
$\mathbf 1=(1,\dots,1)$; each added point that lies outside the current affine
span raises the affine rank; the rank is capped at $d$, so every weight system
is pinned after $\le d{+}1$ points. Finiteness of each branching step comes from
positivity alone: a candidate lattice point $x$ obeys $x_iq_i\le x\!\cdot\!q$, so
$x_i\le \deg/w_i$ — a finite range. **No global degree bound is needed for
termination.** (See §5.3 for the Sylvester bound's actual, separate role.)

*Lean:* this is precisely `branch_finite`, `descent_lemma`, `reach_aux`, and
`algorithm_complete` (T7.5/T7.6, `Algorithm.lean`) — completeness in $\le d{+}1$
rank-increasing steps, with no degree bound.

### 3.2 PALP map

**Entry / dispatch.** `cws.x` is `cws.c:106 main`. The relevant flags:

| flag | function | meaning |
|---|---|---|
| `-d <d> [-r<r2>]` | `RgcWeights` (`cws.c:532`) | recursive enumeration of weight systems |
| `-w <d>` | `Init_IP_Weights` (`cws.c:609`) | enumeration by total degree (`MakeIpWeights`, `cws.c:1196`) |
| `-2` | `AddHalf` (`cws.c:577`) | the $q_n=\tfrac12$ reduction (see §3.4) |

The recursive enumerator's state is `RgcClassData` (`cws.c:144`): dimension `d`,
the normalization `r2`, the points being added `x[][]`, the running candidate
equations `q[]`, and the output list `wli[]`.

**① The recursive build (the heart).**
`RecConstructRgcWeights(n, X)` (`cws.c:433`) holds the candidate weight-equations
`q[n-1]` consistent with points $x_0,\dots,x_{n-1}$ and the new point $x_n$:

- `ComputeQ0` (`cws.c:293`) seeds the equations (the coordinate constraints; the
  `r2` parity here is the $\sum=1$ vs $\sum=\tfrac12$ normalization);
- `ComputeQ(n,X)` (`cws.c:321`) updates `q[n]` from `q[n-1]` and $x_n$, combining
  oppositely-signed equations (the circuit / oriented-matroid step);
- `ComputeAndAddAverageWeight` (`cws.c:378`) forms one representative weight
  vector from the equation system and appends it via `RgcAddweight`
  (`cws.c:172`, sorted insert `RgcInsertat`, `cws.c:164`);
- the nested `while`/`for` loop over `y[]` (`cws.c:449–468`) **enumerates the
  integer points of the current simplex** and recurses — this is the
  point-adding tree;
- `ComputeAndAddLastQ` (`cws.c:405`) closes off the final coordinate when
  $n=d-2\to d-1$.

**Termination/pruning** is `LastPointForbidden` (`cws.c:266`): it enforces the
canonical (non-increasing) ordering, `ysum >= 2`, and the `r2`/`allow11`
conditions. The recursion depth is bounded by `POLY_Dmax` $=d$ — dimension, not
degree, exactly as in §3.1.

**② Reconstruct $\Delta_q$.** `Make_CWS_Points` (`Coord.c:1015`) turns the
weight data into the lattice points of $\Delta_q$: build the weight-lattice
basis (`Make_CWS_Basis`, `Coord.c:732`), find an interior point
(`Compute_X0`, `Coord.c:972`), lift via `Poly_To_Ambi` (`Coord.c:764`).
*Lean analog:* `wsLatticeGensAt` / `CWS.subspace`.

**③ IP test.** Within the enumerator, `WsIpCheck` (`cws.c:480`) builds the
degree-$\deg$ monomial points, calls `Find_Equations` (`Vertex.c:1081`), and
verifies (a) at least $d$ facet equations and (b) that $\mathbf 1$ is *strictly*
interior (`Eval_Eq_on_V > 0`, rejecting any `c == 0`). It returns the point
count if IP. Stand-alone analysis uses `IP_Check` / `Ref_Check` (§5).
*Lean analog:* `IsIPWeightSystem`; the "no weight exceeds half" necessary
condition is `not_ip_of_weight_gt_half` (L5.6, `WeightSystem.lean`).

### 3.3 The two normalizations: $\sum q_i=1$ and $\sum q_i=\tfrac12$

`RgcWeights` takes `-r<r2>`: `r2=2` is the standard normalization
($\sum q_i=1$, interior point at "radius 1"); `r2=1` is the half-integral case
($\sum q_i=\tfrac12$). `ComputeQ0` (`cws.c:293`) branches on `r2` parity
accordingly. The two runs together (the $n=6,r=1$ and $n=5,r=\tfrac12$ searches)
cover the $d=5$ weight systems.

### 3.4 The $q_n=\tfrac12$ reduction

`AddHalf` (`cws.c:577`, flag `-2`) reads a weight system and appends a final
weight equal to *half the total*. Geometrically $\Delta_q$ becomes a **double
pyramid** whose bottom apexes are the depth-2 generators of the truncated
system — which is why a weight $=\tfrac12$ is the boundary case of the
$x_i\le\deg/w_i$ bound and gets peeled off. *Lean:* this is `ip_half_reduction`
(L5.8, `WeightSystem.lean`) — currently the deferred geometric lemma.

---

## 4. Pipeline B — combined weight systems (non-simplicial minimal cores)

### 4.1 Theory

Not every minimal polytope is a simplex. By **Kreuzer–Skarke Lemma 1**, a
non-simplicial minimal polytope decomposes into a lower-dimensional minimal
piece plus a "good simplex," and iterating yields a presentation by a
**combined weight system (CWS)**: $k$ weight systems on a common coordinate set,
arranged as a $k\times n$ matrix, with $n=d+k$.

> A minimal polytope with $k$ blocks has $d+k$ vertices: $k=1$ gives the
> $d{+}1$-vertex simplex (Pipeline A); $k=2,\dots,d$ give the genuinely
> non-simplicial cores, $d{+}2,\dots,2d$ vertices (so $7,\dots,10$ in $d=5$).

The CWS polytope lives in the **joint kernel** of the $k$ weight equations,
$$ C.\mathrm{subspace}=\bigcap_{a=1}^{k}\{y:\langle W_a,y\rangle=0\},$$
of dimension $n-k=d$, and is IP iff $0$ is interior there.

*Lean:* the structure `CWS k n` (matrix `W`, nonneg, cover, independence),
`CWS.subspace`, `CWS.IsIP` (`WeightSystem.lean`). Two theorems:
- **each block of an IP CWS is itself an IP weight system** —
  `cws_ip_component` (T5.10), proved via the open-mapping/projection argument;
- **the decomposition theorem itself** — `minimal_structure` (L4.3,
  `Minimal.lean`), the deferred research-level piece. This is the exact analog
  of PALP's `IP_Simplex_Decomp` (below).

### 4.2 PALP map

**Entry.** `cws.x -c <d>` → `Init_IP_CWS` (`cws.c:754`). The working state is
`WSaux`; the combined output is the `CWS` struct (`Global.h:145`):

```c
typedef struct {
  Long W[AMBI_Dmax][AMBI_Dmax], d[AMBI_Dmax];      // nw weight rows + their degrees
  int  nw, N, z[POLY_Dmax][AMBI_Dmax], m[POLY_Dmax], nz, index;
} CWS;                                              // nw = k, N = n, z/m/nz = Z_m sublattice
```

This is precisely the Lean `CWS k n` (`W : Fin k → V n`); `nw`$=k$, `N`$=n$,
and the `z`/`m`/`nz`/`index` fields are the quotient-lattice ($\mathbb{Z}_m$)
data that has no single-WS analog.

**① CWS enumeration.**
- `createweights(X, npoints)` (`cws.c:944`) recursively grows a point/weight
  configuration (the nested `x0..x4` loops are the bounded coordinate ranges,
  with the `(sum>2)&&(maxx>1)` admissibility cut);
- `testweisys(X, npoints)` (`cws.c:870`) **solves the linear system** for the
  weights of a configuration by Gaussian elimination over the rationals
  (`rI/rQ/rD/rP/rS` rational ops, `Rat.c`) — this is where the matrix of weights
  is computed;
- `makesubsets(X)` (`cws.c:994`) enumerates which points lie on which weight
  hyperplane — i.e. the **block structure** of the combined system;
- bookkeeping: `addweight` (`cws.c:813`), `insertat` (`cws.c:803`), `checkwrite`
  (`cws.c:862`), `weicomp` (`cws.c:795`).

**Assembling the matrix.** `W_TO_CWS` (`cws.c:1950`) and `RW_TO_CWS`
(`cws.c:1974`) place a single `Weight` into a CWS *row* with the correct
zero-padding (`Nf` front / `Nb` middle / `Nr` rear zero blocks) — i.e. they
build the $k\times n$ matrix with each block supported on its own coordinates.
Printing: `Print_CWS` (`cws.c:1833`), `PRINT_CWS` (`cws.c:1910`).

**②–④ identical to Pipeline A.** `Make_CWS_Points` (`Coord.c:1015`) already
handles `nw > 1` (it reduces to the sublattice via `CWS_2_SublatZ`,
`Coord.c:779`, and `Reduce_PPL_2_Sublat`, `Coord.c:795`); then the same
`Find_Equations` / `IP_Check` / `Ref_Check` and dual.

**The inverse direction (analysis).** Given a polytope, recovering its (combined)
weight system is `IP_Simplex_Decomp` (`Polynf.c:3157`): it decomposes the vertex
matrix into IP simplices, emitting `nw` weight systems. **This is the
computational counterpart of `minimal_structure` (L4.3)** — the theorem that a
minimal polytope splits into simplicial pieces. (Used in fibration/$E$-polynomial
analysis, e.g. `E_Poly.c:518`, `Polynf.c:3435`.)

---

## 5. Where the two pipelines — and the dimensions — diverge

### 5.1 Side-by-side

| aspect | Pipeline A (single WS) | Pipeline B (CWS) |
|---|---|---|
| minimal core | simplex, $d{+}1$ vertices | non-simplex, $d{+}k$ vertices |
| weight data | vector $q\in\mathbb{Q}^{d+1}$ | $k\times n$ matrix, $n=d+k$ |
| ambient/subspace | hyperplane $W_q$ | joint kernel $\bigcap_a\ker W_a$ |
| PALP enumerator | `RgcWeights` / recursive simplex tree (`cws.c:433`) | `Init_IP_CWS` / subset + rational solve (`cws.c:754,870,994`) |
| extra lattice data | none | $\mathbb{Z}_m$ quotient (`z`,`m`,`nz`,`index`) |
| Lean object | `wsHyperplane`, `IsIPWeightSystem` | `CWS`, `CWS.IsIP`, `cws_ip_component` |
| how blocks relate | n/a | every block is itself IP (T5.10) |
| decomposition theorem | n/a | KS Lemma 1 = `minimal_structure` (L4.3) = `IP_Simplex_Decomp` |

Stages ②–⑤ are **shared**: once you have the (C)WS, reconstruction, IP/reflexive
testing, dualization, normal form, and subpolytope enumeration are the same code.

### 5.2 The $d=5$ watershed: IP $\ne$ reflexive (the pyramid lemma fails)

In $d\le4$ the **pyramid lemma** holds: every IP weight system already gives a
reflexive polytope, so testing IP suffices. In $d=5$ this **provably fails**:
many IP weight systems give a non-reflexive $\Delta_q$. PALP encodes this exact
dichotomy in one line:

```c
/* Subpoly.c:2046 */
if ((_P->n < 5) ? !IP_Check(_P, &V, &E) : !Ref_Check(_P, &V, &E)) { ... }
```

For dimension `_P->n < 5` it uses the cheap `IP_Check`; for `>= 5` it must use
the stronger `Ref_Check`. *Lean:* `pyramid_lemma_dim_le_four` (L6.1) and the
counterexample `pyramid_counterexample_dim_five` (R6.3, `PyramidLemma.lean`).
Concretely, of the **322,383,760,930** IP weight systems in $d=5$, only
**185,269,499,015** are reflexive — so $\approx137$ billion are IP-but-not-
reflexive, and PALP filters them with `Ref_Check`. (The pseudoreflexivity that
makes that filter well-behaved is `pseudoreflexive`, T5.11, `WeightSystem.lean`.)

### 5.3 The Sylvester degree bound is *not* load-bearing

The maximal degree of a $d=5$ weight system is $3263442=1806\cdot1807$, attained
by the Sylvester system $(\tfrac12,\tfrac13,\tfrac17,\tfrac1{43},\tfrac1{1807},
\tfrac1{3263442})$. This is a **complexity** fact, not a correctness ingredient:
termination of stage ① comes from the dimension bound (§3.1), and the headline
`algorithm_complete` does not use it. *Lean:* `max_degree_dim5` (T8.4,
`Sylvester.lean`) is a documented, non-load-bearing remark; the supporting
identities `sylvester_sum_inv`, `prod_sylvester`, `qct6_sum` are proved.

A clean way to see why it is subtle: a normalized weight $q_i=w_i/\deg$ is a
genuine **unit fraction** $1/x_i$ (with $x_i=\deg/w_i\in\mathbb{Z}$) iff
$w_i\mid\deg$ — and $w_i\mid\deg$ for all $i$ is exactly the **reflexive-simplex
(Gorenstein)** condition. So the clean Sylvester/Curtiss argument applies on the
reflexive-simplex sub-class only. That sub-class is tiny — unit-fraction
partitions of $1$ into $6$ terms number $3462$ (OEIS A002966) — whereas the IP
class is $\sim3\times10^{11}$. The bound holds for all IP systems, but proving it
there needs the direct Skarke induction, not the unit-fraction shortcut.

### 5.4 Stage ⑤ and why $d=5$ is not finished

The in-between polytopes (everything strictly between a minimal subpolytope and
a maximal superpolytope) are enumerated by `Make_All_Subpolys`
(`Subpoly.c:925`), reduced to normal form (`Reduce_Poly`, `Subpoly.c:790`), and
deduplicated in the `class.x` database (`class.c:280`). In $d\le4$ this completes
(473,800,776 reflexive 4-polytopes). In $d=5$ it does **not** — both because the
number of in-between polytopes is astronomical and because the pyramid-lemma
failure (§5.2) removes the "weight systems determine everything" shortcut.

**Note on the CWS *maximal* polytopes.** These are *not* blocked conceptually:
they are produced by the same `Init_IP_CWS` → `Make_CWS_Points` → `Ref_Check`
path as the single-WS ones (the pipeline handles `nw>1` already). What is blocked
is the *full* enumeration including all in-between polytopes. SS18's headline
$322$-billion count is single weight systems; the CWS layer is the same kind of
computation, additional and less canonical to report.

---

## 6. Consolidated cross-reference (theory ↔ PALP ↔ Lean)

| theory step | PALP (`file:line`) | Lean (`proofs/Refpoly/`) |
|---|---|---|
| data: polytope points | `PolyPointList` `Global.h:109` | `V n`, `IsLatticePoint` (`Basic.lean`) |
| data: facets | `Equation`/`EqList` `Global.h:129,137` | facet eqns via `polarDual` (`Basic.lean`) |
| data: single WS | (`Weight`), `RgcClassData` `cws.c:144` | `wsHyperplane` (`WeightSystem.lean`) |
| data: CWS matrix | `CWS` `Global.h:145` | `CWS k n` (`WeightSystem.lean`) |
| ① enumerate single WS | `RgcWeights`→`RecConstructRgcWeights` `cws.c:532,433` | `algorithm_complete` (`Algorithm.lean`) |
| ① branch finiteness | `LastPointForbidden` `cws.c:266` | `branch_finite` (`Algorithm.lean`) |
| ① $\sum=\tfrac12$ reduction | `AddHalf` `cws.c:577` | `ip_half_reduction` L5.8 (`WeightSystem.lean`) |
| ① enumerate CWS | `Init_IP_CWS`,`createweights`,`testweisys`,`makesubsets` `cws.c:754,944,870,994` | (CWS enumerated blockwise) |
| ① assemble CWS matrix | `W_TO_CWS`/`RW_TO_CWS` `cws.c:1950,1974` | `CWS.W` (`WeightSystem.lean`) |
| ② reconstruct $\Delta$ | `Make_CWS_Points` `Coord.c:1015` | `wsLatticeGensAt`,`CWS.subspace` |
| ③ IP test | `IP_Check`,`WsIpCheck` `Vertex.c:1128`,`cws.c:480` | `IsIPWeightSystem`,`CWS.IsIP` |
| ③ reflexive test | `Ref_Check` `Vertex.c:1170` | `IsReflexive` (`Basic.lean`) |
| ③ no weight $>\tfrac12$ | (within `WsIpCheck`) | `not_ip_of_weight_gt_half` L5.6 |
| ④ polar dual | `Aux_Make_Dual_Poly` `Polynf.c:3210` | `polarDual`,`pseudoreflexive` T5.11 |
| min↔max duality | (`class.x` strategy) | `maximal_iff_dual_minimal` T3.4 (`MaxMin.lean`) |
| WS$\to$min core | (circuit relation) | `simplex_weights` (`Minimal.lean`) |
| poly$\to$(C)WS decomp | `IP_Simplex_Decomp` `Polynf.c:3157` | `minimal_structure` L4.3 (`Minimal.lean`) |
| each block IP | (implicit) | `cws_ip_component` T5.10 |
| ⑤ subpolytopes | `Make_All_Subpolys` `Subpoly.c:925` | (the $d\le4$ "by enumeration" arm) |
| ⑤ normal form / class | `Reduce_Poly`,`class.c:280` | — |
| $d\le4$ vs $d=5$ switch | `Subpoly.c:2046` | `pyramid_lemma_dim_le_four` L6.1 / R6.3 |
| degree bound (complexity) | (reported, not enforced) | `max_degree_dim5` T8.4 (`Sylvester.lean`) |
| finiteness inputs | (assumed) | `hensley_volume_bound` T1.1, `lagarias_ziegler_box` T1.3 |

---

## 7. Honest status

- **Pipeline A (single WS)** is complete and operational in PALP, and the
  correctness backbone (constructive completeness + branch finiteness, with **no
  degree bound**) is formalized in `Algorithm.lean` (sorry-free).
- **Pipeline B (CWS)** is operational in PALP; on the Lean side the *abstract*
  CWS theory is in place (`cws_ip_component` T5.10 proved under an explicit
  block-surjectivity hypothesis), but the **decomposition theorem**
  `minimal_structure` (L4.3 / KS Lemma 1, = `IP_Simplex_Decomp`) is the
  open, research-level sorry.
- The **$d=5$ classification is not complete** for reflexive polytopes (stage ⑤
  explodes; pyramid lemma fails). What *is* complete is the weight-system
  enumeration plus the structural theorems; the project's headline is "proof by
  enumeration in $d=2,3,4$, counterexample in $d=5$."
- `max_degree_dim5` (Sylvester bound) is a documented complexity remark, not
  load-bearing for any correctness theorem.

---

## 8. References

- H. Skarke, *Weight systems for toric Calabi–Yau varieties and reflexivity of
  Newton polyhedra*, arXiv:alg-geom/9603007.
- M. Kreuzer, H. Skarke, *On the classification of reflexive polyhedra*,
  arXiv:hep-th/9512204; and the PALP package,
  http://hep.itp.tuwien.ac.at/~kreuzer/CY/ .
- F. Schöller, H. Skarke, *All Weight Systems for Calabi–Yau Fourfolds from
  Reflexivity*, arXiv:1808.02422.
- H. Conrads, *Weighted projective spaces and reflexive simplices*, Manuscripta
  Math. 107 (2002) — the $w_i\mid\deg$ / unit-fraction correspondence.
- D. R. Curtiss, *On Kellogg's Diophantine Problem*, Amer. Math. Monthly 29
  (1922) — the Sylvester-sequence extremal bound. Sylvester sequence: OEIS
  A000058; $6$-term unit-fraction partitions of $1$: OEIS A002966.
- Companion: `latex/notes/ks_classification.tex` (the longer narrative);
  this repo's Lean formalization in `proofs/Refpoly/`.
```
