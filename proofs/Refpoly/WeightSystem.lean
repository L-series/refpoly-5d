/-
# Weight systems and the polytope Δ_q (Part 5 of PROOF_PLAN.md)

A *weight system* is a positive vector `q ∈ ℝⁿ_{>0}` (defined up to overall
rescaling).  Following the **up-to-date reconstruction** of [SS18] §3 (which
supersedes the vertex-pairing-matrix method of [KS95] §3–4, deliberately not
formalized — see PROOF_PLAN.md):

* the dual space `M_ℝ` is embedded into `ℝⁿ` as the hyperplane
  `W_q = {y | Σ qᵢ yᵢ = 0}` (the map `X ↦ yᵢ = ⟨Vᵢ, X⟩` of [SS18] eq. (3.1),
  where `Vᵢ` are the vertices of the simplex with `Σ qᵢVᵢ = 0`);
* the lattice `M_finest` becomes `ℤⁿ ∩ W_q`;
* the polytope of the weight system is
  `Δ_q = conv(ℤⁿ ∩ {y ∈ W_q : yᵢ ≥ -1})` ([SS18] eq. (3.2));
* `q` has the **IP property** iff `0` is interior to `Δ_q` *within* `W_q`
  ([SS18] §3).  Working inside the subspace `W_q` (a Lean `Submodule`) makes
  "interior" automatically mean the interior relative to `M_ℝ`, exactly as in
  the paper.

In shifted coordinates `xᵢ = yᵢ + 1` the lattice points of `Δ_q` are the
nonnegative integer solutions of `Σ xᵢqᵢ = Σᵢ qᵢ` ([SS18] eq. (ipws), with
`r = Σ qᵢ`); these are `Refpoly.wsPoints`, the objects the enumeration
algorithm of Part 7 manipulates.

Main results:

* `ip_simplex_iff_weights_pos` (**L5.2**, [KS95] §3 / [Sk96] §2): a simplex
  with vertices `v i` and affine dependence `Σ wᵢvᵢ = 0`, `Σ wᵢ = 1`, has `0`
  in its interior iff all `wᵢ > 0` — the weights are the barycentric
  coordinates of the origin.
* `not_ip_of_weight_gt_half` (**L5.6**, [SS18] §3): an IP weight system has
  `qᵢ ≤ (Σq)/2` for every `i`.
* `at_most_one_half` (**L5.7**, [SS18] §3).
* `pseudoreflexive` (**T5.11**, [SS18] §6): `Δ_q = [Δ_q] = [[Δ_q*]*]`,
  formalized abstractly: for any lattice polytope `∇ ∋ 0`,
  `[[ [∇*]* ]*]... ` — see the precise statement below.

Deferred (`sorry`, with the paper proofs transcribed):

* `ip_half_reduction` (**L5.8**, [SS18] §3): the `q_n = ½` reduction that
  splits the `d = 5` search into the `n = 6, r = 1` and `n = 5, r = ½` runs.
* `cws_ip_component` (**T5.10**, [SS18] §2.2, citing math/0001106).
-/
import Refpoly.MaxMin

open Set Matrix

namespace Refpoly

variable {n : ℕ}

/-! ## The hyperplane of a weight system -/

/-- The linear functional `y ↦ q ⬝ᵥ y`. -/
def dotLin (q : V n) : V n →ₗ[ℝ] ℝ where
  toFun y := q ⬝ᵥ y
  map_add' x y := by simp [dotProduct_add]
  map_smul' c x := by simp [dotProduct_smul]

@[simp] theorem dotLin_apply (q y : V n) : dotLin q y = q ⬝ᵥ y := rfl

/-- `W_q = {y | Σ qᵢyᵢ = 0}`: the image of `M_ℝ` inside `ℝⁿ` under the
embedding `X ↦ (⟨Vᵢ,X⟩)ᵢ` of [SS18] eq. (3.1). -/
def wsHyperplane (q : V n) : Submodule ℝ (V n) := LinearMap.ker (dotLin q)

theorem mem_wsHyperplane {q y : V n} : y ∈ wsHyperplane q ↔ q ⬝ᵥ y = 0 :=
  LinearMap.mem_ker

/-- The generating lattice points of `Δ_q` at depth `c` (in `y`-coordinates):
integer points of `W_q` with all coordinates `≥ -c`.  The standard case is
`c = 1` ([SS18] eq. (3.2)); `c = 2` arises in the `q_n = ½` reduction. -/
def wsLatticeGensAt (q : V n) (c : ℝ) : Set (wsHyperplane q) :=
  {y | IsLatticePoint (y : V n) ∧ ∀ i, -c ≤ (y : V n) i}

/-- `Δ_q` (at depth `c`) as a subset of the hyperplane `W_q`. -/
def wsPolytopeAt (q : V n) (c : ℝ) : Set (wsHyperplane q) :=
  convexHull ℝ (wsLatticeGensAt q c)

/-- Generalized IP property at depth `c`.  (Positivity of the weights is part
of the definition of a weight system, [SS18] §2.2.) -/
def IsIPWeightSystemAt (q : V n) (c : ℝ) : Prop :=
  (∀ i, 0 < q i) ∧ (0 : wsHyperplane q) ∈ interior (wsPolytopeAt q c)

/-- **D5.4: the IP property of a weight system** ([SS18] §3): `0` is in the
interior — within the hyperplane `W_q`, i.e. within `M_ℝ` — of the convex
hull of the lattice points `y ∈ ℤⁿ ∩ W_q` with `yᵢ ≥ -1`. -/
def IsIPWeightSystem (q : V n) : Prop := IsIPWeightSystemAt q 1

/-! ## Shifted (`x`-space) coordinates -/

/-- The all-ones vector: the interior point `𝟙` of [KS95]/[Sk96], the
`x⁽⁰⁾ = (1,…,1)` of [SS18] §3. -/
def ones (n : ℕ) : V n := fun _ => 1

theorem isLatticePoint_ones : IsLatticePoint (ones n) := fun _ => ⟨1, by simp [ones]⟩

@[simp] theorem dotProduct_ones (q : V n) : q ⬝ᵥ ones n = ∑ i, q i := by
  simp [dotProduct, ones]

/-- The lattice points of `Δ_q` in shifted coordinates ([SS18] eq. (ipws)):
nonnegative integer vectors `x` with `Σ xᵢqᵢ = Σ qᵢ` (i.e. `x·q` equals its
value at the all-ones point; for normalized `Σq = 1` this is `x·q = 1`). -/
def wsPoints (q : V n) : Set (V n) :=
  {x | IsLatticePoint x ∧ (∀ i, 0 ≤ x i) ∧ x ⬝ᵥ q = ∑ i, q i}

theorem ones_mem_wsPoints (q : V n) : ones n ∈ wsPoints q :=
  ⟨isLatticePoint_ones, fun _ => by norm_num [ones],
    by rw [dotProduct_comm]; exact dotProduct_ones q⟩

/-- The change of variables `y = x - 𝟙` identifies `x`-space lattice points
with the depth-1 generators of `Δ_q` ([SS18] §3: "Upon passing to new
coordinates xᵢ = yᵢ + 1 …"). -/
theorem wsPoints_shift {q x : V n} :
    x ∈ wsPoints q ↔
      ∃ hy : x - ones n ∈ wsHyperplane q,
        (⟨x - ones n, hy⟩ : wsHyperplane q) ∈ wsLatticeGensAt q 1 := by
  constructor
  · rintro ⟨hlat, hpos, hdeg⟩
    have hy : x - ones n ∈ wsHyperplane q := by
      rw [mem_wsHyperplane, dotProduct_sub, dotProduct_ones,
        dotProduct_comm q x, hdeg, sub_self]
    refine ⟨hy, ?_, ?_⟩
    · intro i
      obtain ⟨m, hm⟩ := hlat i
      exact ⟨m - 1, by simp [ones, hm]⟩
    · intro i
      have := hpos i
      simp only [Pi.sub_apply, ones]
      linarith
  · rintro ⟨hy, hlat, hge⟩
    refine ⟨?_, ?_, ?_⟩
    · intro i
      obtain ⟨m, hm⟩ := hlat i
      simp only [Pi.sub_apply, ones] at hm
      exact ⟨m + 1, by push_cast; linarith⟩
    · intro i
      have := hge i
      simp only [Pi.sub_apply, ones] at this
      linarith
    · have h0 : q ⬝ᵥ (x - ones n) = 0 := mem_wsHyperplane.1 hy
      rw [dotProduct_sub, dotProduct_ones, sub_eq_zero] at h0
      rw [dotProduct_comm]
      exact h0

/-! ## The IP criterion for simplices (L5.2)

[KS95] §3: "We denote by the weights qᵢ … the barycentric coordinates of 𝟙̄";
[Sk96] §2: "If all of the barycentric coordinates are positive … 𝟙 is in the
interior of the simplex."  The Mathlib form: the interior of the hull of an
affine basis is the locus of positive barycentric coordinates. -/

/-- **L5.2 (interior point criterion for simplices).**  Let `b` be an affine
basis (a non-degenerate simplex's vertex family) of `ℝⁿ` and `w` weights with
`Σ wᵢ = 1` and `Σ wᵢ • b i = 0` (the circuit relation `Σ qᵢVᵢ = 0` of
[SS18] §2.2 in normalized form).  Then `0` is interior to the simplex iff all
weights are positive.  The `wᵢ` are exactly the barycentric coordinates of
the origin. -/
theorem ip_simplex_iff_weights_pos {ι : Type*} [Fintype ι]
    (b : AffineBasis ι ℝ (V n)) (w : ι → ℝ) (hw : ∑ i, w i = 1)
    (hcomb : ∑ i, w i • b i = (0 : V n)) :
    (0 : V n) ∈ interior (convexHull ℝ (Set.range b)) ↔ ∀ i, 0 < w i := by
  have hbar : ∀ i, b.coord i 0 = w i := by
    intro i
    have hac : Finset.univ.affineCombination ℝ b w = (0 : V n) := by
      rw [Finset.univ.affineCombination_eq_linear_combination b w hw]
      exact hcomb
    rw [← hac]
    exact b.coord_apply_combination_of_mem (Finset.mem_univ i) hw
  rw [b.interior_convexHull]
  simp only [mem_setOf_eq, hbar]

/-! ## Necessary bounds on IP weight systems (L5.6, L5.7) -/

/-- Generators of `Δ_q` have `j`-th coordinate `≤ 0` when `q j` exceeds half
the total weight: from `q·y = 0`, `yᵢ ≥ -1` one gets
`qⱼyⱼ = -Σ_{i≠j} qᵢyᵢ ≤ Σ_{i≠j} qᵢ < qⱼ`, so `yⱼ < 1`, and integrality gives
`yⱼ ≤ 0`.  ([SS18] §3: "if qᵢ > 1/2 then xᵢ ∈ {0,1} for all x ∈ Δ_q".) -/
theorem gens_coord_nonpos_of_gt_half {q : V n} (hq : ∀ i, 0 < q i)
    {j : Fin n} (hj : ∑ i, q i < 2 * q j) {y : wsHyperplane q}
    (hy : y ∈ wsLatticeGensAt q 1) : (y : V n) j ≤ 0 := by
  classical
  obtain ⟨hlat, hge⟩ := hy
  have h0 : q ⬝ᵥ (y : V n) = 0 := mem_wsHyperplane.1 y.2
  have h0' : ∑ i, q i * (y : V n) i = 0 := by simpa [dotProduct] using h0
  -- split the sum at j
  have hsplit : q j * (y : V n) j +
      ∑ i ∈ Finset.univ.erase j, q i * (y : V n) i = 0 := by
    have h := Finset.add_sum_erase Finset.univ
      (fun i => q i * (y : V n) i) (Finset.mem_univ j)
    rw [h]
    exact h0'
  have hbound : ∀ i ∈ Finset.univ.erase j, -(q i) ≤ q i * (y : V n) i := by
    intro i _
    have h1 := hge i
    nlinarith [hq i]
  have hsum : -(∑ i ∈ Finset.univ.erase j, q i) ≤
      ∑ i ∈ Finset.univ.erase j, q i * (y : V n) i := by
    rw [← Finset.sum_neg_distrib]
    exact Finset.sum_le_sum hbound
  have herase : ∑ i ∈ Finset.univ.erase j, q i = (∑ i, q i) - q j := by
    have h := Finset.add_sum_erase Finset.univ q (Finset.mem_univ j)
    linarith
  have hylt : (y : V n) j < 1 := by
    have hqj := hq j
    nlinarith
  obtain ⟨m, hm⟩ := hlat j
  rw [hm] at hylt ⊢
  have hm1 : m < 1 := by exact_mod_cast hylt
  have hm0 : m ≤ 0 := by omega
  exact_mod_cast hm0

/-- **L5.6.**  An IP weight system satisfies `2 qⱼ ≤ Σᵢ qᵢ` for every `j`
(in normalized form: `qⱼ ≤ ½`).  [SS18] §3: "This can hold only if all
weights obey qᵢ ≤ 1/2."

Proof: if `2qⱼ > Σq`, the linear functional `y ↦ yⱼ` is `≤ 0` on `Δ_q` and
`= 0` at the origin, so the origin maximizes it; since the origin is interior
this forces the functional to vanish on all of `W_q`
(`eq_zero_of_le_on_interior`), which is false because `W_q` contains a vector
with `j`-th coordinate `q k > 0` (any `k ≠ j`). -/
theorem not_ip_of_weight_gt_half (hn : 2 ≤ n) {q : V n} {j : Fin n}
    (hj : ∑ i, q i < 2 * q j) : ¬ IsIPWeightSystem q := by
  rintro ⟨hq, hint⟩
  -- the coordinate functional on the hyperplane
  set f : wsHyperplane q →L[ℝ] ℝ :=
    (ContinuousLinearMap.proj j).comp (wsHyperplane q).subtypeL with hf
  have hf_apply : ∀ y : wsHyperplane q, f y = (y : V n) j := fun _ => rfl
  -- f ≤ 0 on Δ_q
  have hmax : ∀ z ∈ wsPolytopeAt q 1, f z ≤ f 0 := by
    intro z hz
    have h0 : f (0 : wsHyperplane q) = 0 := by simp
    rw [h0]
    have hsub : wsPolytopeAt q 1 ⊆ {w : wsHyperplane q | f w ≤ 0} := by
      refine convexHull_min ?_ ?_
      · intro y hy
        rw [mem_setOf_eq, hf_apply]
        exact gens_coord_nonpos_of_gt_half hq hj hy
      · exact convex_halfSpace_le (f.toLinearMap.isLinear) 0
    exact hsub hz
  -- so f vanishes identically …
  have hzero : f = 0 := eq_zero_of_le_on_interior f hint hmax
  -- … but W_q contains a vector with nonzero j-th coordinate.
  obtain ⟨k, hk⟩ : ∃ k : Fin n, k ≠ j := by
    haveI : Nontrivial (Fin n) := Fin.nontrivial_iff_two_le.mpr hn
    exact exists_ne j
  set w : V n := q k • Pi.single j 1 - q j • Pi.single k 1 with hw
  have hwmem : w ∈ wsHyperplane q := by
    rw [mem_wsHyperplane, hw, dotProduct_sub, dotProduct_smul, dotProduct_smul,
      dotProduct_single, dotProduct_single]
    simp [mul_comm]
  have hwj : w j = q k := by
    rw [hw]
    simp only [Pi.sub_apply, Pi.smul_apply, smul_eq_mul]
    rw [Pi.single_eq_same, Pi.single_eq_of_ne hk.symm]
    ring
  have := congrFun (congrArg DFunLike.coe hzero) ⟨w, hwmem⟩
  rw [hf_apply] at this
  simp only [ContinuousLinearMap.zero_apply] at this
  rw [hwj] at this
  exact absurd this (ne_of_gt (hq k))

/-- **L5.7.**  For `n ≥ 3`, at most one weight can equal half the total
weight ([SS18] §3: "For n > 2 at most one of the qᵢ can be equal to 1/2
(otherwise Σᵢ qᵢ > 1)"). -/
theorem at_most_one_half (hn : 3 ≤ n) {q : V n} (hq : ∀ i, 0 < q i)
    {j k : Fin n} (hjk : j ≠ k) (hj : 2 * q j = ∑ i, q i)
    (hk : 2 * q k = ∑ i, q i) : False := by
  classical
  -- a third coordinate exists and contributes positively
  have hcard : ({j, k} : Finset (Fin n)).card ≤ 2 := by
    apply Finset.card_insert_le _ _ |>.trans
    simp
  obtain ⟨m, hm⟩ : ∃ m, m ∈ (Finset.univ : Finset (Fin n)) \ {j, k} := by
    apply Finset.Nonempty.exists_mem
    rw [← Finset.card_pos, Finset.card_sdiff, Finset.inter_univ,
      Finset.card_univ, Fintype.card_fin]
    omega
  rw [Finset.mem_sdiff, Finset.mem_insert, Finset.mem_singleton] at hm
  push Not at hm
  obtain ⟨-, hmj, hmk⟩ := hm
  have hsub : ({j, k, m} : Finset (Fin n)) ⊆ Finset.univ := Finset.subset_univ _
  have hsum : q j + q k + q m ≤ ∑ i, q i := by
    have hsum' : ∑ i ∈ ({j, k, m} : Finset (Fin n)), q i ≤ ∑ i, q i := by
      apply Finset.sum_le_sum_of_subset_of_nonneg hsub
      intro i _ _
      exact (hq i).le
    rw [Finset.sum_insert (by simp [hjk, hmj.symm]),
      Finset.sum_insert (by simp [hmk.symm]), Finset.sum_singleton] at hsum'
    linarith
  have := hq m
  linarith

/-! ## Pseudoreflexivity of `Δ_q` (T5.11)

[SS18] §6 shows that the polytope of any IP weight system satisfies
`Δ = [Δ] = [[Δ*]*]` ("pseudoreflexive" / "almost reflexive"), even when it is
not reflexive — which for `d = 5` happens for 137 114 261 915 of the
322 383 760 930 IP weight systems.  We formalize the inclusion-chasing proof
verbatim, abstractly in `ℝⁿ`: `∇` is any lattice polytope containing the
origin and `Δ_q := [∇*]`. -/

/-- `[·]` is idempotent. -/
theorem latticeHull_idem (P : Set (V n)) :
    latticeHull (latticeHull P) = latticeHull P := by
  apply Subset.antisymm
  · exact latticeHull_subset_of_convex (convex_convexHull ℝ _)
  · apply convexHull_mono
    intro x hx
    exact ⟨subset_convexHull ℝ _ hx, hx.2⟩

/-- **T5.11 (pseudoreflexivity, [SS18] §6).**  For a lattice polytope `∇`
containing the origin, the polytope `Δ := [∇*]` satisfies `[[Δ*]*] = Δ`.

Paper proof (transcribed): `Δ = [∇*] ⊆ ∇*` hence `Δ* ⊇ ∇** ⊇ ∇`; since `∇`
is a lattice polytope this implies `[Δ*] ⊇ [∇] = ∇` and therefore
`[[Δ*]*] ⊆ [∇*] = Δ`.  Conversely `[Δ*] ⊆ Δ*` gives `[Δ*]* ⊇ Δ** ⊇ Δ`,
which implies `[[Δ*]*] ⊇ [Δ] = Δ` because `Δ` is (the hull of) lattice
points. -/
theorem pseudoreflexive {Nbl : Set (V n)} (hNbl : IsLatticePolytope Nbl) :
    latticeHull (polarDual (latticeHull (polarDual (latticeHull (polarDual Nbl))))) =
      latticeHull (polarDual Nbl) := by
  set Δ : Set (V n) := latticeHull (polarDual Nbl) with hΔ
  -- Δ ⊆ ∇*
  have h1 : Δ ⊆ polarDual Nbl := latticeHull_subset_of_convex (polarDual_convex Nbl)
  -- ∇ ⊆ Δ*
  have h2 : Nbl ⊆ polarDual Δ :=
    (subset_bipolar Nbl).trans (polarDual_antitone h1)
  -- ∇ = [∇] ⊆ [Δ*]
  have h3 : Nbl ⊆ latticeHull (polarDual Δ) := by
    rw [hNbl.eq_latticeHull]
    exact latticeHull_mono h2
  -- [[Δ*]*] ⊆ [∇*] = Δ
  have h4 : latticeHull (polarDual (latticeHull (polarDual Δ))) ⊆ Δ :=
    latticeHull_mono (polarDual_antitone h3)
  -- Δ ⊆ [Δ*]* :  [Δ*] ⊆ Δ* gives Δ ⊆ Δ** ⊆ [Δ*]*
  have h5 : Δ ⊆ polarDual (latticeHull (polarDual Δ)) :=
    (subset_bipolar Δ).trans
      (polarDual_antitone (latticeHull_subset_of_convex (polarDual_convex Δ)))
  -- Δ = [Δ] ⊆ [[Δ*]*]
  have h6 : Δ ⊆ latticeHull (polarDual (latticeHull (polarDual Δ))) := by
    conv_lhs => rw [hΔ, ← latticeHull_idem (polarDual Nbl)]
    exact latticeHull_mono h5
  exact Subset.antisymm h4 h6

/-! ## The `q_n = ½` reduction (L5.8) — deferred -/

/-- **L5.8 ([SS18] §3) — deferred.**  Appending a weight equal to half the
total degree:  `(q₁,…,q_m, ½)` (normalized `Σ = 1`) has the IP property iff
the truncated system `(q₁,…,q_m)` (with `Σ = ½`) satisfies the *depth-2* IP
condition `(2,…,2) ∈ int Δ_{(q₁,…,q_m)}`.

This is what splits the `d = 5` enumeration into a `n = 6, r = 1` run and a
`n = 5, r = ½` run ([SS18] §3, §4).  Paper argument: if `q_{m+1} = ½` then
every lattice point has `x_{m+1} ∈ {0,1}`; the polytope is a "double
pyramid" over the slice `x_{m+1} = 1`, and `(1,…,1)` is interior iff
`(2,…,2)` is interior to the doubled slice.  Formalizing requires the slice
projection `V (m+1) → V m`; deferred. -/
theorem ip_half_reduction {m : ℕ} (q' : V m) (hq' : ∀ i, 0 < q' i)
    (hsum : ∑ i, q' i = 1 / 2) :
    IsIPWeightSystem (Fin.snoc q' (1 / 2) : V (m + 1)) ↔
      IsIPWeightSystemAt q' 2 := by
  sorry

/-! ## Combined weight systems (D5.9, T5.10) -/

/-- **D5.9: combined weight system** ([SS18] §2.2: "Minimal polytopes
consisting of more than one IP simplex are described by combined weight
systems (matrices of weights)").  `k` weight systems on a common coordinate
set `Fin n`; each row is nonnegative, supported on its block, and every
coordinate is used by some row ([KS95] Corollary 1: the blocks cover all
directions).  The associated subspace is the joint kernel — for a single
system (`k = 1`) this recovers `wsHyperplane`; in general `n = d + k`
([SS18] §3). -/
structure CWS (k n : ℕ) where
  /-- the weight matrix: row `a` is the `a`-th weight system, zero-padded -/
  W : Fin k → V n
  nonneg : ∀ a i, 0 ≤ W a i
  /-- every coordinate carries a nonzero weight of at least one system -/
  cover : ∀ i, ∃ a, 0 < W a i
  /-- the rows are linearly independent (the `k` defining equations of
  [SS18] §3 are independent) -/
  indep : LinearIndependent ℝ W

/-- The joint kernel `{y | W a ⬝ᵥ y = 0 ∀ a} ≅ M_ℝ`, of dimension `n - k`. -/
def CWS.subspace {k : ℕ} (C : CWS k n) : Submodule ℝ (V n) :=
  ⨅ a, LinearMap.ker (dotLin (C.W a))

/-- The IP property for a CWS: `0` interior (within the joint kernel) to the
hull of the integer points with all coordinates `≥ -1`. -/
def CWS.IsIP {k : ℕ} (C : CWS k n) : Prop :=
  (0 : C.subspace) ∈ interior (convexHull ℝ
    {y : C.subspace | IsLatticePoint (y : V n) ∧ ∀ i, -1 ≤ (y : V n) i})

/-- **T5.10 ([SS18] §2.2, citing math/0001106) — deferred.**  "For a combined
weight system to have the IP property, it is necessary that every single
weight system occurring in it has this property."  Stated via the
block-restriction `e`: an injection of the support of row `a` into `Fin m`
carrying `W a` to a positive weight system `q'`.  The paper proof projects
the joint polytope onto the block coordinates and observes that the image of
an interior point is interior. -/
theorem cws_ip_component {k m : ℕ} (C : CWS k n) (hC : C.IsIP) (a : Fin k)
    (e : Fin m → Fin n) (he : Function.Injective e)
    (hsupp : ∀ i, 0 < C.W a i ↔ ∃ b, e b = i) (q' : V m)
    (hq' : ∀ b, q' b = C.W a (e b)) :
    IsIPWeightSystem q' := by
  sorry

end Refpoly
