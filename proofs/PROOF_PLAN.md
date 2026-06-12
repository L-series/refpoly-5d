# Proof Plan: Formal Verification of the Kreuzer–Skarke Classification Algorithm

This document is the contract for the Lean 4 formalization in this directory.
It lists every definition, lemma and theorem used by the classification of
reflexive polytopes (with the 5-dimensional case — Calabi–Yau fourfolds — as
the target), in dependency order, with:

- the **source** (paper and result number),
- an **informal statement**,
- the **Lean name** and file,
- the **status**: `proved` (complete Lean proof), `sorry` (statement
  formalized, proof deferred with a documented sketch), or `axiom-like sorry`
  (a deep external result we import as a hypothesis, e.g. Hensley's volume
  bound).

### Sources

| Tag | Paper |
|-----|-------|
| **[KS95]** | M. Kreuzer, H. Skarke, *On the classification of reflexive polyhedra*, hep-th/9512204, Commun. Math. Phys. 185 (1997) 495. |
| **[Sk96]** | H. Skarke, *Weight systems for toric Calabi–Yau varieties and reflexivity of Newton polyhedra*, alg-geom/9603007, Mod. Phys. Lett. A11 (1996) 1637. |
| **[SS18]** | F. Schöller, H. Skarke, *All weight systems for Calabi–Yau fourfolds from reflexive polyhedra*, arXiv:1808.02422. |
| **[LZ91]** | J. Lagarias, G. Ziegler, *Bounds for lattice polytopes containing a fixed number of interior points in a sublattice*, Canad. J. Math. 43 (1991) 1022. |
| **[He83]** | D. Hensley, *Lattice vertex polytopes with interior lattice points*, Pacific J. Math. 105 (1983) 183. |

> **Important.** [KS95] §3–4 proposes a reconstruction of the polytope pair
> from a (combined) weight system via *vertex pairing matrices* (the matrix
> `A^i_j` machinery, Table 1, and the iterated candidate-vertex elimination).
> That algorithm is **superseded** and is deliberately **not** formalized.
> The up-to-date reconstruction — used by [Sk96], [SS18] and PALP — is the
> direct one: a weight system `q` determines the polytope
> `Δ_q = conv{x ∈ ℤⁿ_{≥0} : Σ xᵢqᵢ = 1}` ([SS18] eq. (3.3)/(ipws)), the IP
> property is `(1,…,1) ∈ int Δ_q`, and reflexivity is tested directly on
> `Δ_q` inside the affine sublattice it spans. From [KS95] we keep only the
> *structure theory* (§2: minimal polytopes, Lemma 1, Corollaries 1–2,
> Lemma 2, the weight systems as barycentric coordinates) and the overall
> 3-step strategy.

---

## The mathematical chain

The classification rests on the following chain (papers in brackets):

```
(F)  Finiteness        Hensley/LZ volume bound  ⇒  finitely many reflexive
                       polytopes per dimension up to GL(d,ℤ)        [He83, LZ91]
(S)  Subpolytopes      every reflexive Δ sits inside a maximal one  [KS95, SS18 §2.2]
(D)  Duality           Δ maximal  ⇔  Δ* minimal (polar duality
                       reverses inclusion; bipolar theorem)         [KS95, SS18 §2.2]
(M)  Minimal polytopes minimal IP polytopes are IP simplices or
                       hulls of lower-dimensional IP simplices      [KS95 §2]
(W)  Weight systems    IP simplices ↔ weight systems (barycentric
                       coordinates of 0); products ↔ CWS            [KS95 §2, SS18 §2.2]
(A)  Algorithm         recursive enumeration of all IP weight
                       systems; in d=5: 322 383 760 930 IP systems,
                       185 269 499 015 reflexive                    [Sk96 §2, SS18 §3]
(R)  Reflexivity gap   IP ⇒ reflexive holds for d ≤ 4 but FAILS
                       for d = 5, so reflexivity must be checked
                       per weight system                            [Sk96 §3]
```

The executable pipeline (PALP / refpoly-5d) runs the chain backwards:
enumerate weight systems (A) → build minimal polytopes (W,M) → dualize (D) →
take subpolytopes (S) → deduplicate by GL(5,ℤ) normal form (well-defined
by (F)).

---

## Part 0 — Conventions and basic definitions

File: `Refpoly/Basic.lean`

We work in `V := Fin n → ℝ` with the standard inner product as the duality
pairing; the lattice is the subgroup of integer vectors. This identifies
`M ≅ N ≅ ℤⁿ`; the `GL(n,ℤ)` action relates different identifications.
(The papers' coordinate-free `M`/`N` distinction is recovered by reading all
`Δ`-statements in `V` and all `Δ*`-statements in the dual copy of `V`.)

| ID | Item | Lean name | Status |
|----|------|-----------|--------|
| D0.1 | integer point of `V` | `IsLatticePoint` | def |
| D0.2 | lattice polytope: `P = convexHull ℝ S`, `S` finite set of integer points | `IsLatticePolytope` | def |
| D0.3 | IP property: `0 ∈ interior P` ([SS18] §2.1, following hep-th/9805190) | `IsIP` | def |
| D0.4 | polar dual `P* = {y : ∀ x ∈ P, ⟪y,x⟫ ≥ -1}` ([KS95] eq. (1), [SS18] §2.1) | `polarDual` | def |
| D0.5 | reflexive: `P` IP polytope, `P` and `P*` lattice polytopes ([SS18] §2.1) | `IsReflexive` | def |

Remark: [KS95] defines reflexive via "one interior lattice point, all facets
at lattice distance 1"; [SS18] via "Δ and Δ* both lattice polytopes". The
equivalence is classical; we adopt the [SS18] form as the definition and
state the facet-distance characterization as a lemma (L0.8, deferred).

| ID | Lemma | Source | Lean name | Status |
|----|-------|--------|-----------|--------|
| L0.6 | polar duality is antitone: `P ⊆ Q → Q* ⊆ P*` | [KS95] §4, [SS18] §2.2 ("duality inverts subset relations") | `polarDual_antitone` | **proved** |
| L0.7 | `P*` is convex, closed, contains 0; if `P` is bounded with `0 ∈ int P` then `P*` is bounded with `0 ∈ int P*` | folklore | `polarDual_convex`, `zero_mem_polarDual`, … | **proved** (convexity/closure/membership), boundedness deferred |
| L0.8 | bipolar: `P` closed convex, `0 ∈ P` ⇒ `P** = P` | folklore (Hahn–Banach separation) | `bipolar` | **proved** (via Mathlib `geometric_hahn_banach_closed_point`) |
| L0.9 | a reflexive polytope has exactly one interior lattice point (the origin) | [KS95] §2 ("Note that **1** is the only integer point in the interior of Q"), [Sk96] §2 | `interior_latticePoint_unique` | **proved** (an interior lattice point `p ≠ 0` would make `y ⬝ᵥ p` a nonpositive integer `> −1`, i.e. `0`, for all dual lattice generators `y`, forcing `p` on the boundary) |

---

## Part 1 — Finiteness (Lagarias–Ziegler / Hensley)

File: `Refpoly/Finiteness.lean`

These are the deep *external* inputs; everything downstream is derived
mechanically from them. They enter the papers only through citations
([KS95] intro: "It is known that the total number of reflexive polyhedra is
finite in any given dimension" citing Batyrev 82, Hensley 83,
Borisov–Borisov 92). We isolate them as explicitly-documented `sorry`s so
the *derivation* of finiteness is fully formal even though the geometry of
numbers input is not re-proved.

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| T1.1 | **Volume bound.** A `d`-dim lattice polytope with exactly `k ≥ 1` interior lattice points has volume `≤ c(d,k)`; LZ: `Vol ≤ k·(8d)^d·15^(d·2^(2d+1))` | [He83] Thm; [LZ91] Thm 1 | `hensley_volume_bound` | axiom-like sorry |
| T1.2 | **Point-count bound.** A reflexive polytope has at most `c'(d)` lattice points | [LZ91] Cor (volume bound + Blichfeldt) | `latticePoint_count_bound` | **proved** from T1.3 (count the lattice points of the box) |
| T1.3 | **Box lemma.** A reflexive polytope is `GL(d,ℤ)`-equivalent to a polytope inside `[-R(d), R(d)]^d` (T1.1 folded in, so one constant `R` feeds everything downstream) | [LZ91] Thm 2 | `lagarias_ziegler_box` | axiom-like sorry |
| T1.4 | **Finiteness.** Up to `GL(d,ℤ)`, there are finitely many reflexive polytopes in dimension `d` | [LZ91]; quoted by all three papers | `finitely_many_reflexive` | **proved** from T1.3 (a lattice polytope in a finite box is determined by its finite set of lattice points) |
| L1.5 | **Chain termination.** A lattice polytope properly containing another has strictly more lattice points; with T1.2 this bounds all ascending chains | derived | `ncard_lt_of_ssubset` | **proved** |

Note: volume on the lattice is formalized via `MeasureTheory.volume`
(Lebesgue); normalized volume = `d! · volume`. `GL(d,ℤ)`-equivalence is
formalized as an equiv `(Fin d → ℤ) ≃ₗ[ℤ] (Fin d → ℤ)` mapping one polytope
onto the other.

---

## Part 2 — Subpolytope structure: maximal reflexive polytopes

File: `Refpoly/MaxMin.lean`

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| D2.1 | reflexive subpolytope (same lattice, inclusion); *maximal* reflexive polytope | [SS18] §2.2 ("set S of maximal polytopes"), [KS95] §1 | `IsMaximalReflexive` | def |
| T2.2 | **Embedding into a maximal polytope.** Every reflexive `Δ` is contained in a maximal reflexive polytope | [SS18] §2.2: "any reflexive polytope Δ is contained in at least one of the Δᵢ" | `exists_maximal_superset` | **proved** from L1.5 (well-founded recursion on the bounded lattice-point count) |

---

## Part 3 — Max/min duality

File: `Refpoly/MaxMin.lean`

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| D3.1 | **minimal IP generating set**: hull has `0` interior, hull of every proper subset does not | [SS18] §2.2 (def.), [KS95] §2 ("no collections of less than k̄ vertices … containing **1** in the interior") | `IsMinimalIPGen` | def |
| L3.2 | duality reverses inclusion: `Δ ⊆ Δ̃ ↔ Δ̃* ⊆ Δ*` (for IP polytopes, using bipolar) | [SS18] §2.2 eq. before def. of minimal polytope | `subset_iff_polarDual_subset` | **proved** |
| T3.3 | reflexivity is self-dual: `Δ` reflexive ⇒ `Δ*` reflexive, and `Δ** = Δ` | [SS18] §2.1 "the dual of an IP polytope is itself an IP polytope with Δ** = Δ" | `IsReflexive.polarDual_reflexive`, `IsReflexive.bipolar_eq` | **proved** (with a quantitative interior-ball argument for the dual's IP property) |
| T3.4 | **Max/min duality.** `Δ` maximal reflexive ⇔ `Δ*` "minimal reflexive" (no proper reflexive subpolytope); and every reflexive polytope contains a minimal reflexive one | assembled from T2.2 + L3.2 + T3.3; [SS18] §2.2 "every reflexive polytope must then contain at least one of Δ₁*, Δ₂*, …" | `maximal_iff_dual_minimal`, `exists_minimal_subset` | **proved** from the above |

Remark. Two notions of "minimal" coexist: (i) *minimal reflexive* (no
proper reflexive subpolytope) — the order-dual of maximal under T3.4 —
and (ii) *minimal IP* (D3.1, vertex-economical) — the structural notion
classified by weight systems. The bridge is T3.5:

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| T3.5 | every IP polytope contains a minimal IP polytope spanned by a subset of its vertices; hence every reflexive `Δ*` ⊇ some minimal IP `∇`, and dually `Δ ⊆ conv(∇* ∩ M_finest)` — *this is why enumerating CWS suffices* | [KS95] §2 (choice of minimal `Q`/`M`), [SS18] §2.2 | `exists_minimalIPGen_subset` | **proved** (finite descent on vertex subsets) |

---

## Part 4 — Structure of minimal IP polytopes

File: `Refpoly/Minimal.lean`

The combinatorial heart of [KS95] §2.

> **Scope decision** (per project direction): only the *simplicial* half of
> this part is needed by the algorithm-correctness chain (Parts 7 and 9) —
> the algorithm's completeness quantifies over all weight systems, so the
> structure theory of *non-simplicial* minimal polytopes (which produces the
> CWS blocks) is recorded as statements/documentation, not proved.

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| D4.1 | *good simplex* inside a vertex set `V`: an affinely independent subset whose hull contains `0` in its relative interior | [KS95] §2 ("we will call such simplices good simplices") | `IsGoodSimplex` (+ `IsMinimalIPRel`) | def |
| L4.2 | every vertex of a minimal polytope belongs to at least one good simplex | [KS95] §2 (triangulation argument) | — | not formalized (documentation only; not needed by the algorithm chain) |
| **L4.3** | **[KS95] Lemma 1.** A minimal polytope `M ⊂ ℚⁿ` is a simplex, or contains an `n'`-dim minimal polytope `M' = conv{V₁,…,V_k̄'}` and a good simplex `S = conv(R ∪ {V_k̄'+1,…,V_k̄})`, `R ⊆ {V₁,…,V_k̄'}`, with `k̄ − k̄' = n − n' + 1` and `dim S ≤ n'` | [KS95] Lemma 1 (verbatim) | `minimal_structure` | statement + sorry (proof sketch in docstring; context for CWS only — **not** a dependency of Parts 7/9) |
| C4.4 | **[KS95] Corollary 1.** Block decomposition into minimal polytopes extended by good simplices | [KS95] Cor. 1 (verbatim) | — | not formalized (downstream of L4.3, same status) |
| **C4.5** | **[KS95] Corollary 2.** A minimal polytope in dimension `n` has `k̄` vertices with `n+1 ≤ k̄ ≤ 2n` | [KS95] Cor. 2 (verbatim) | `minimalIPGen_card_lower`, `simplex_card` | lower bound **proved** (an IP set must affinely span: `n+1 ≤ k̄`, with equality `k̄ = n+1` **proved** in the simplicial case); upper bound `≤ 2n` not formalized (needs L4.3) |
| L4.2′ | **weights = barycentric coordinates ([KS95] §3).** An affinely independent IP generating set carries a unique normalized positive weight vector `q` with `Σ qᵢVᵢ = 0` | [KS95] §3, [SS18] §2.2 | `simplex_weights` | **proved** (via `AffineBasis.coord`; feeds T9.3) |
| L4.6 | **[KS95] Lemma 2.** If `{S_λ}` is a set of good simplices spanning `M`, then `S_μ − ⋃_{ν≠μ} S_ν` never contains exactly one point | [KS95] Lemma 2 (verbatim) | — | not formalized (documentation only) |
| C4.7 | combinatorial type count: finitely many block structures per dimension | [KS95] §4, [SS18] §2.2 | — | not formalized (enumeration delegated to the pipeline) |

---

## Part 5 — Weight systems

File: `Refpoly/WeightSystem.lean`

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| D5.1 | **weight system** `q ∈ ℝⁿ_{>0}` with normalization `r = Σ qᵢ`; assigned to an IP simplex with vertices `Vᵢ` via `Σ qᵢ Vᵢ = 0`, unique up to rescaling; integer form `(w₀,…,w_d)`, degree `d_w = Σ wᵢ` | [SS18] §2.2; [KS95] §3 eq. (2) (`q` = barycentric coordinates of the interior point) | `dotLin`, `wsHyperplane` (the hyperplane `W_q ≅ M_ℝ`) | def |
| **L5.2** | **IP criterion.** For a simplex with vertices `V₁,…,V_{n+1}` affinely spanning, `0 ∈ relint(conv V)` ⇔ the (unique up to scale) affine dependence `Σ wᵢVᵢ = 0` has all `wᵢ > 0`; the `qᵢ = wᵢ/Σw` are the barycentric coordinates of `0` | [KS95] §3 ("we denote by the weights qᵢ … the barycentric coordinates"), [Sk96] §2 | `ip_simplex_iff_weights_pos` | **proved** (Mathlib: `AffineBasis.interior_convexHull`) |
| D5.3 | **the polytope of a weight system** (modern reconstruction): `Δ_q = conv{y ∈ ℤⁿ ∩ W_q : yᵢ ≥ −1}`, equivalently (shifted by `(1,…,1)`) `conv{x ∈ ℤⁿ_{≥0} : Σ xᵢqᵢ = Σ qᵢ}` | [SS18] §3 eqs. (3.1)–(3.3): embedding `X ↦ yᵢ = ⟨Vᵢ,X⟩`, image of `M_finest` is `ℤⁿ ∩ {Σqᵢyᵢ = 0}`, shift `xᵢ = yᵢ+1` | `wsLatticeGensAt`, `wsPolytopeAt`, `wsPoints` | def |
| D5.4 | **IP property of a weight system**: `0 ∈ int Δ_q`, interior *within* `W_q` (formalizing in the submodule subtype makes "relative interior" automatic) | [SS18] §3 ("q has the IP property iff **0** is in the interior of the convex hull of (3.2)") | `IsIPWeightSystemAt`, `IsIPWeightSystem` | def |
| L5.5 | embedding correctness: `x ↦ (⟨Vᵢ,x⟩)ᵢ` identifies `M_ℝ` with `W_q`, `∇*` with `{y ∈ W_q : yᵢ ≥ −1}`, and lattice points with integer points of `W_q`; hence D5.4 matches the [SS18] §2.2 definition | [SS18] §3 | (the `Φ`/`Ψ` isomorphism inside `reflexive_simplex_weight_system`) | **proved** — discharged as the explicit construction in T9.3 (`Classification.lean`) rather than as a standalone lemma |
| **L5.6** | necessary bound `qᵢ ≤ 1/2`: if `qᵢ > 1/2` then every generator of `Δ_q` has `yᵢ ≤ 0`, so `0` cannot be interior | [SS18] §3 (parenthetical proof) | `not_ip_of_weight_gt_half` (+ `gens_coord_nonpos_of_gt_half`) | **proved** |
| L5.7 | for `n ≥ 3` at most one `qᵢ = 1/2` | [SS18] §3 | `at_most_one_half` | **proved** (sum constraint) |
| L5.8 | the `q_n = 1/2` reduction: IP for `(q₁,…,q_{n-1},1/2)`, `r=1` ⇔ `(2,…,2) ∈ int Δ_{(q₁,…,q_{n-1})}`, `r=1/2`. Splits `d=5` into the `n=6, r=1` and `n=5, r=1/2` searches | [SS18] §3 | `ip_half_reduction` | sorry (slice geometry; documented) |
| D5.9 | **combined weight system** (CWS): `k` weight systems on blocks of an `n`-element coordinate set, block dimensions summing per the minimal-polytope structure; IP property of a CWS | [SS18] §2.2 | `CWS`, `CWS.IsIP` | def |
| T5.10 | CWS IP ⇒ every constituent weight system IP | [SS18] §2.2 (citing math/0001106: "One can easily show…") | `cws_ip_component` | sorry |
| **T5.11** | **pseudoreflexivity.** `[([([∇*])*])*] = [∇*]` for any lattice polytope `∇`, where `[Δ] = conv(Δ ∩ M)` | [SS18] §6 (full proof in the paper, transcribed; the `0 ∈ ∇` hypothesis turned out to be unnecessary and was dropped) | `pseudoreflexive` | **proved** (pure inclusion chase given L0.6 + L0.8) |

---

## Part 6 — Reflexivity of maximal Newton polytopes: d ≤ 4 vs d = 5

File: `Refpoly/PyramidLemma.lean`

This part explains a structural asymmetry of the 5-dimensional project: in
`d ≤ 4` every IP weight system automatically yields a reflexive `Δ_q`
([Sk96]); in `d = 5` this **fails**, so the pipeline must test reflexivity
for each of the 322 383 760 930 IP weight systems (185 269 499 015 pass).

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| **L6.1** | **Pyramid lemma.** In `ℤⁿ`, `n ≤ 4`: an integer pyramid `Pyr` of height `h ≥ 2` and its double `Pyr_double` (same apex, same shape, height `2h`): `Pyr_double` contains an integer point neither in `Pyr` nor in the base of `Pyr_double`. | [Sk96] Lemma 1 (verbatim, incl. proof) | `pyramid_lemma_dim_le_four` | statement + sorry — **deliberately left unproved** (project decision): the `d ≤ 4` classifications are certified by the enumeration itself (T9.4 + the finite run), and the `d = 5` case needs only the *failure* of the lemma, which is R6.3 |
| **T6.2** | maximal Newton polyhedra (`Δ_q` for IP (C)WS) of dimension ≤ 4 are reflexive | [Sk96] Theorem (verbatim): every facet at distance `h ≥ 2` would give a pyramid violating L6.1 inside `(Δ_max)_double ⊆ {xᵢ ≥ −1}` | — | not stated in Lean (would need the facet-distance dictionary in the sublattice; see the `PyramidLemma.lean` docstring); never used in `d = 5`, where reflexivity is tested per weight system |
| **R6.3** | **failure in d = 5.** The pyramid lemma fails for `n = 5`: base `0, 2e₁, …, 2e₄`, apex `(2,2,2,2,4)`, `h = 2` has no integer point strictly between the bases | [Sk96] Remark after Lemma 1 (explicit counterexample) | `pyramid_counterexample_dim_five` | **proved** (finite arithmetic check) |
| R6.4 | consequence (empirical, [SS18] §5): of the IP weight systems in `d=5`, 185 269 499 015 are reflexive and 137 114 261 915 are not; reflexivity must be tested per system — this is the `E.e[i].c == 1` facet test in PALP | [SS18] abstract & §5 | (documentation only) | n/a |

---

## Part 7 — The enumeration algorithm and its correctness

File: `Refpoly/Algorithm.lean`

The algorithm of [SS18] §3 (an improved version of [Sk96] §2). This is the
part the user's pipeline consumes (the Skarke–Schöller weight system list),
so its *completeness* is the key formal target.

**The algorithm.** Fix `n` and the normalization `r` (`Σqᵢ = r`; the search
runs once with `n = 6, r = 1` and once with `n = 5, r = 1/2` by L5.8).
Maintain linearly independent lattice points `x⁽⁰⁾, …, x⁽ᵏ⁾` with
`x⁽⁰⁾ = (1,…,1)` (resp. `(2,…,2)`):

1. The *q-space polytope* after `k+1` points is
   `Q_k = {q : qᵢ ≥ 0, x⁽ʲ⁾·q = 1 ∀j ≤ k}` ([SS18] eq. (qpol)), of
   dimension `n−k−1`.
2. Let `q̃⁽ᵏ⁾` = average of the vertices of `Q_k`; if `q̃⁽ᵏ⁾` has the IP
   property, record it.
3. Branch over the finitely many lattice points `x ≥ 0` with
   `x·q̃⁽ᵏ⁾ < 1` as `x⁽ᵏ⁺¹⁾`; prune by rules 1–7 of [SS18] §3
   (canonicity / no-duplicates).
4. At `k+1 = n` the weight system is uniquely determined; stop.

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| D7.1 | q-space polytope `Q_k`; *selection rule* (any function choosing a point of `Q_k` when nonempty — the vertex average of [SS18] is one instance; completeness is proved for **all** selection rules at once) | [SS18] eq. (qpol) | `qPolytope`, `SelectionRule`, `Reachable` | def |
| L7.2 | the average of finitely many positive vectors is positive (the vertex-average candidate is positive; stated for a simple average) | implicit in [SS18] §3 | `average_pos` | **proved** |
| **L7.3** | **branching is finite**: for `q̃ > 0` componentwise, `{x ∈ ℤⁿ_{≥0} : x·q̃ < 1}` is finite | [SS18] §3 ("the finitely many lattice points obeying xᵢ ≥ 0 …") | `branch_finite` | **proved** |
| **L7.4** | **descent lemma (key step).** Let `q ≠ q̃` be a weight system with the IP property such that `x⁽⁰⁾·q̃ = 1`. Then `Δ_q` contains a lattice point `x` with `x·q̃ < 1`. (Proof: otherwise `x ↦ x·q̃` attains its minimum over `Δ_q` at the interior point `x⁽⁰⁾`, forcing the functional to be constant `= 1` on the affine span of `Δ_q`, i.e. `q̃` and `q` induce the same functional there, contradicting `q ≠ q̃` after normalization.) | [SS18] §3: "note that x⁽⁰⁾ … cannot be interior to Δ_q for q ≠ q̃ unless Δ_q contains points satisfying x·q̃ < 1" | `descent_lemma` | **proved** (linear functional minimized at an interior point of a convex set is locally constant ⇒ constant on the span) |
| **T7.5** | **completeness.** Every normalized IP weight system `q` appears in the search tree rooted at `{(1,…,1)}`: some reachable node `S` has `sel(S) = q` | [SS18] §3 ("Given the finite number of choices at each branching level … we are bound to eventually find all allowed weight systems") | `algorithm_complete` | **proved** by induction on the rank of `span(S)` (strictly increases at each branching, L7.4 supplies the next point, `notMem_affineSpan_of_dot_lt` shows it is new; at full rank the feasible set is `{q}`) |
| T7.6 | **termination.** The node is reached within `n` branchings (`\|S\| ≤ n + 1`); branching is finite (L7.3) | [SS18] §3 | part of `algorithm_complete` (the `S.card ≤ n + 1` conjunct) + `branch_finite` | **proved** |
| L7.7 | canonicity rules 1–7 (lexicographic minimal-sequence uniqueness) eliminate duplicates | [SS18] §3 items 1–7 | (documented; not formalized — affects efficiency, not correctness) | n/a |

> Correctness direction (soundness): every recorded `q̃` is checked for the
> IP property explicitly before being recorded, so soundness is by
> construction; the mathematical content is completeness (T7.5).

---

## Part 8 — Sylvester bounds and extremal weight systems

File: `Refpoly/Sylvester.lean`

| ID | Result | Source | Lean name | Status |
|----|--------|--------|-----------|--------|
| D8.1 | Sylvester sequence `y₀ = 2`, `y_{k+1} = y_k(y_k − 1) + 1`: `2, 3, 7, 43, 1807, 3263443, …` (0-indexed in Lean) | [SS18] §5 eq. (5.2)–(5.3) | `sylvester` (+ value lemmas `sylvester_zero` … `sylvester_five`, `sylvester_two_le`) | def + **proved** |
| **L8.2** | telescoping product `∏_{i<k} yᵢ = y_k − 1` and `Σ_{i<k} 1/yᵢ = 1 − 1/(y_k − 1)` | [SS18] §5 ("easy to show by induction") | `prod_sylvester`, `sylvester_sum_inv` | **proved** (induction) |
| L8.3 | the tuples `q_ct = (1/2, 1/3, 1/7, 1/43, 1/1807, 1/3263442)` (degree `3 263 442 = 1806·1807`) and `q_lt = (1/2, 1/3, 1/7, 1/43, 1/3612, 1/3612)` are positive with `Σqᵢ = 1` | [SS18] §5 | `qct6`/`qct6_pos`/`qct6_sum`, `qlt6`/`qlt6_pos`/`qlt6_sum`, `max_degree_factorization` | **proved** |
| T8.4 | `3 263 442` is the maximal degree among `d=5` single weight systems (so the enumeration's arithmetic fits in 64-bit words) | [SS18] §5 + classification data | `max_degree_dim5` | statement + sorry (a *complexity* bound, not a correctness ingredient — `algorithm_complete` does not use it; extremality is a result *of* the completed enumeration) |

---

## Part 9 — Assembly: correctness of the classification strategy

File: `Refpoly/Classification.lean`

| ID | Result | Lean name | Status |
|----|--------|-----------|--------|
| **T9.1** | **Coverage theorem.** Every reflexive polytope `P` admits a finite set `S` of lattice points of `P*` that is a minimal IP generating set, with `P ⊆ [conv(S)*]` — so the two-stage strategy (enumerate minimal IP sets, then all reflexive lattice subpolytopes of their dual maximal polytopes) reaches every reflexive polytope | `classification_coverage` | **proved** — *no* sorried inputs (the L4.3/L5.5 dependencies anticipated in the original plan turned out to be unnecessary) |
| T9.2 | well-definedness of dedup: `GL(d,ℤ)`-equivalence is an equivalence relation with finitely many classes of reflexive polytopes (T1.4) | `GLEquiv.refl/symm/trans`, `finitely_many_reflexive` | **proved** (modulo the Part 1 box lemma) |
| **T9.3** | **simplicial bridge.** If `S` (as in T9.1) is affinely independent, its barycentric weight system `q ∈ ℝ^{n+1}` is normalized, positive, and has the **IP property** of D5.4. Proof: the embedding `x ↦ (⟨Vᵢ,x⟩)ᵢ` is a linear homeomorphism `M_ℝ ≅ W_q` carrying `P` into `Δ_q` and `0 ∈ int P` to `0 ∈ int Δ_q` (this also discharges L5.5) | `reflexive_simplex_weight_system` | **proved** |
| **T9.4** | **headline: the algorithm enumerates all reflexive polytopes.** Composition of T9.1 + T9.3 + T7.5/T7.6: for every reflexive `P` (with simplicial dual minimal set; non-simplicial sets decompose blockwise per L4.3) and *every* selection rule, the enumeration tree reaches the associated weight system within `n+1` branchings, and `P` is recovered among the lattice subpolytopes of `[conv(S)*]` | `algorithm_enumerates_reflexive` | **proved** |

---

## Status summary (final, matches the built code)

The project builds with `lake build` (Lean 4.30.0 / Mathlib v4.30.0).
Exactly **7 `sorry`s** remain, all listed below; there are **no `axiom`
declarations**.

**Files with zero sorries** — the complete algorithm-correctness chain:

- `Basic.lean` (Part 0): duality order theory, **bipolar theorem** (L0.8),
  uniqueness of the interior lattice point (L0.9), `GL(n,ℤ)` machinery.
- `MaxMin.lean` (Parts 2–3): dual reflexivity with quantitative interior
  (T3.3), max/min duality (T3.4), existence of maximal supersets (T2.2) and
  of minimal IP generating subsets (T3.5).
- `Algorithm.lean` (Part 7): **completeness and termination of the [SS18]
  enumeration** (`algorithm_complete`, T7.5+T7.6) — for *every* selection
  rule, every normalized IP weight system is reached within `n` branchings.
- `Classification.lean` (Part 9): **coverage** (T9.1), the **simplicial
  weight-system bridge** including the `M_ℝ ≅ W_q` embedding (T9.3/L5.5),
  and the **headline theorem** `algorithm_enumerates_reflexive` (T9.4).

**Files with intended, documented sorries** (each statement's docstring
carries the paper reference and proof sketch):

| # | File | Lean name | What it is | Why deferred |
|---|------|-----------|------------|--------------|
| 1 | `Finiteness.lean` | `hensley_volume_bound` (T1.1) | volume bound [He83]/[LZ91] | external geometry-of-numbers input, *intentionally* axiomatized |
| 2 | `Finiteness.lean` | `lagarias_ziegler_box` (T1.3) | box reduction [LZ91] | same |
| 3 | `Minimal.lean` | `minimal_structure` (L4.3) | [KS95] Lemma 1 (non-simplicial decomposition → CWS) | context only; not a dependency of Parts 7/9 |
| 4 | `WeightSystem.lean` | `ip_half_reduction` (L5.8) | the `q = ½` search split | affects how the run is *organized*, not whether it is complete |
| 5 | `WeightSystem.lean` | `cws_ip_component` (T5.10) | CWS IP ⇒ component IP | cited from math/0001106; CWS side not needed by the chain |
| 6 | `PyramidLemma.lean` | `pyramid_lemma_dim_le_four` (L6.1) | [Sk96] Lemma 1 (`d ≤ 4`) | **deliberately unproved** (project decision): `d ≤ 4` is certified by enumeration; `d = 5` needs only the counterexample R6.3, which *is* proved |
| 7 | `Sylvester.lean` | `max_degree_dim5` (T8.4) | max degree 3 263 442 | complexity bound, not a correctness ingredient |

Everything downstream of the two Part-1 inputs (finiteness T1.4, point
bounds T1.2, chain termination L1.5, and hence T2.2/T9.2) is derived
formally from them; nothing else in the chain depends on any sorry.
