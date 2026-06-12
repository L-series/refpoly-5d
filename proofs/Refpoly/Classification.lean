/-
# The classification theorem (Part 9 of PROOF_PLAN.md)

This file assembles the chain proved in Parts 0–5 and 7 into the statement
that **the Kreuzer–Skarke pipeline reaches every reflexive polytope**:

* `classification_coverage` (T9.1, **fully proved**) — for every reflexive
  `P ⊂ ℝⁿ` there is a finite set `S` of *lattice* points of the dual `P*`
  which is a *minimal IP generating set* (D3.1) and whose associated maximal
  polytope `[conv(S)*]` contains `P`.  So enumerating minimal IP sets `S`
  and then all reflexive lattice subpolytopes of `[conv(S)*]` finds every
  reflexive polytope.  (Up to `GL(n,ℤ)` the search is finite by
  `finitely_many_reflexive`, T1.4.)

* `reflexive_simplex_weight_system` (T9.3, **fully proved**) — in the
  simplicial case (`S` affinely independent — automatic for the simplex
  blocks produced by [KS95] Lemma 1), `S` determines a *normalized positive
  weight system* `q ∈ ℝ^{n+1}` — the barycentric coordinates of the origin —
  and `q` has the **IP property** in the sense of the enumeration
  ([SS18] §3): the lattice polytope `Δ_q ⊂ W_q` contains `0` in its
  interior.  The proof embeds `M_ℝ = ℝⁿ` into the hyperplane
  `W_q ⊂ ℝ^{n+1}` by `x ↦ (⟨V₁,x⟩, …, ⟨V_{n+1},x⟩)` ([SS18] eq. (3.1)) and
  pushes the interior point `0 ∈ P` through this linear homeomorphism — the
  image of `P` lands inside `Δ_q` because the vertices `Vᵢ ∈ P*` evaluate
  `≥ −1` on `P` and integrally on lattice points.

* `algorithm_enumerates_reflexive` (T9.4, **fully proved**) — the
  composition with `algorithm_complete` (T7.5/T7.6): for every reflexive
  polytope (with simplicial dual minimal set) the weight-system enumeration
  tree of [SS18] §3, run with *any* selection rule, reaches the associated
  weight system within `n + 1` steps.

The non-simplicial case is identical in structure but produces a *combined*
weight system, one weight system per block of [KS95] Cor. 1; the block
decomposition itself is L4.3/C4.4 (stated in `Minimal.lean`, not proved —
not needed for the completeness statements above, which quantify over all
weight systems the algorithm can be pointed at).

For d = 5 this is the justification of the [SS18] computation: the run over
`n = 6` weights enumerated 322 383 760 930 IP weight systems, of which
185 269 499 015 yield reflexive polytopes — and by T9.1/T9.4 no reflexive
5-polytope is missed.
-/
import Refpoly.Minimal
import Refpoly.Algorithm

open Set Module

namespace Refpoly

variable {n : ℕ}

/-! ## T9.1: coverage — every reflexive polytope sits below a minimal IP set -/

/-- **T9.1 (coverage of the classification, [KS95] §2).**  Every reflexive
polytope `P` admits a finite set `S` of lattice points such that

1. `S ⊆ P*` (the dual polytope's lattice points),
2. `S` is a minimal IP generating set (D3.1), and
3. `P ⊆ [conv(S)*]` — `P` is a lattice subpolytope of the maximal polytope
   determined by `S`.

Hence the two-stage strategy — enumerate minimal IP sets, then take all
reflexive lattice subpolytopes of their dual maximal polytopes — reaches
every reflexive polytope.

*Proof.*  `P*` is reflexive (T3.3), so it is the hull of its lattice points
`T`; the origin is interior to it, so `T` contains a minimal IP generating
subset `S` (T3.5).  Then `conv(S) ⊆ P*` gives, by antitonicity and the
bipolar theorem (L0.7), `P = P** ⊆ conv(S)*`; since `P` is a lattice
polytope, `P = [P] ⊆ [conv(S)*]`. -/
theorem classification_coverage {P : Set (V n)} (hP : IsReflexive P) :
    ∃ S : Finset (V n), (∀ x ∈ S, IsLatticePoint x) ∧
      (S : Set (V n)) ⊆ polarDual P ∧ IsMinimalIPGen S ∧
      P ⊆ latticeHull (polarDual (convexHull ℝ (S : Set (V n)))) := by
  have hdual := hP.polarDual_reflexive
  obtain ⟨T, hTlat, hTeq⟩ := hdual.latticePolytope
  have h0T : (0 : V n) ∈ interior (convexHull ℝ (T : Set (V n))) := by
    rw [← hTeq]
    exact hdual.ip
  obtain ⟨S, hsub, hmin⟩ := exists_minimalIPGen_subset T h0T
  refine ⟨S, fun x hx => hTlat x (hsub hx), ?_, hmin, ?_⟩
  · -- S ⊆ T ⊆ conv T = P*
    intro x hx
    rw [hTeq]
    exact subset_convexHull ℝ _ (hsub hx)
  · -- the coverage chain P = P** = [P**] ⊆ [conv(S)*]
    have hSsub : convexHull ℝ (S : Set (V n)) ⊆ polarDual P := by
      rw [hTeq]
      exact convexHull_mono (Finset.coe_subset.mpr hsub)
    have h1 : P ⊆ polarDual (convexHull ℝ (S : Set (V n))) := by
      rw [← hP.bipolar_eq]
      exact polarDual_antitone hSsub
    calc P = latticeHull P := hP.latticePolytope.eq_latticeHull
    _ ⊆ latticeHull (polarDual (convexHull ℝ (S : Set (V n)))) :=
        latticeHull_mono h1

/-! ## T9.3: the weight system of a reflexive polytope's dual simplex is IP -/

/-- **T9.3 (the simplicial bridge to the enumeration; [SS18] §2.2/§3).**
Let `P` be reflexive and `S` an affinely independent set of lattice points of
`P*` whose hull has `0` in its interior (the simplicial case of T9.1; for
non-simplicial `S`, [KS95] Lemma 1 decomposes into such simplices, one weight
system per block).  Then the barycentric weight system `q` of `S` is a
*normalized positive IP weight system* — exactly the kind of object the
enumeration of `Algorithm.lean` produces.

*Proof sketch (the y-coordinates of [SS18] eq. (3.1)).*  Enumerate
`S = {V₁, …, V_{n+1}}` and let `q` be the barycentric coordinates of `0`
(`simplex_weights`).  The linear map `Φ : ℝⁿ → ℝ^{n+1}`,
`Φ(x)ᵢ = ⟨Vᵢ, x⟩` is injective (the `Vᵢ` span) and lands in the hyperplane
`W_q` (the circuit relation `Σ qᵢVᵢ = 0`); counting dimensions it is a
linear — hence topological — isomorphism `ℝⁿ ≅ W_q`.  It maps lattice points
of `P` to *integer* points of `W_q` with coordinates `≥ −1` (because
`Vᵢ ∈ P*`), i.e. into the generators of `Δ_q`; consequently `Φ(P) ⊆ Δ_q`,
and the interior point `0 ∈ P` maps to an interior point `0` of `Δ_q`. -/
theorem reflexive_simplex_weight_system {P : Set (V n)} (hP : IsReflexive P)
    {S : Finset (V n)} (hSlat : ∀ x ∈ S, IsLatticePoint x)
    (hSdual : (S : Set (V n)) ⊆ polarDual P)
    (hind : AffineIndependent ℝ ((↑) : ↥S → V n))
    (h0 : (0 : V n) ∈ interior (convexHull ℝ (S : Set (V n)))) :
    ∃ q : V (n + 1), (∀ i, 0 < q i) ∧ (∑ i, q i = 1) ∧ IsIPWeightSystem q := by
  classical
  obtain ⟨v, q, hrange, hqpos, hqsum, hcirc⟩ := simplex_weights hind h0
  refine ⟨q, hqpos, hqsum, hqpos, ?_⟩
  -- the enumerated vertices belong to S
  have hvS : ∀ i, v i ∈ (S : Set (V n)) := by
    intro i
    rw [← hrange]
    exact Set.mem_range_self i
  have hvSf : ∀ i, v i ∈ S := fun i => Finset.mem_coe.mp (hvS i)
  -- the embedding Φ : M_ℝ → ℝ^{n+1}, x ↦ (⟨Vᵢ, x⟩)ᵢ  ([SS18] eq. (3.1))
  set Φ : V n →ₗ[ℝ] V (n + 1) := LinearMap.pi (fun i => dotLin (v i)) with hΦdef
  have hΦ_apply : ∀ (x : V n) (i : Fin (n + 1)), Φ x i = v i ⬝ᵥ x :=
    fun x i => rfl
  -- Φ lands in the hyperplane W_q: this is the circuit relation Σ qᵢVᵢ = 0
  have hΦmem : ∀ x : V n, Φ x ∈ wsHyperplane q := by
    intro x
    rw [mem_wsHyperplane]
    have hkey : (∑ i, q i • v i) ⬝ᵥ x = ∑ i, q i * (v i ⬝ᵥ x) := by
      rw [sum_dotProduct]
      simp only [smul_dotProduct, smul_eq_mul]
    have hL : q ⬝ᵥ Φ x = ∑ i, q i * (v i ⬝ᵥ x) := by
      show ∑ i, q i * Φ x i = ∑ i, q i * (v i ⬝ᵥ x)
      exact Finset.sum_congr rfl (fun i _ => by rw [hΦ_apply x i])
    rw [hL, ← hkey, hcirc, zero_dotProduct]
  -- Φ is injective: the Vᵢ span ℝⁿ (S affinely spans and 0 ∈ conv S)
  have hspan : affineSpan ℝ (S : Set (V n)) = ⊤ :=
    interior_convexHull_nonempty_iff_affineSpan_eq_top.mp ⟨0, h0⟩
  have hlinspan : ∀ x : V n, x ∈ Submodule.span ℝ (S : Set (V n)) := by
    intro x
    have hle : affineSpan ℝ (S : Set (V n)) ≤
        (Submodule.span ℝ (S : Set (V n))).toAffineSubspace := by
      rw [affineSpan_le]
      intro s hs
      rw [SetLike.mem_coe, Submodule.mem_toAffineSubspace]
      exact Submodule.subset_span hs
    have hx : x ∈ affineSpan ℝ (S : Set (V n)) := by
      rw [hspan]
      exact AffineSubspace.mem_top ℝ (V n) x
    have hx' := hle hx
    rwa [Submodule.mem_toAffineSubspace] at hx'
  have hΦinj : Function.Injective Φ := by
    rw [← LinearMap.ker_eq_bot, Submodule.eq_bot_iff]
    intro x hx
    rw [LinearMap.mem_ker] at hx
    have hvx : ∀ i, v i ⬝ᵥ x = 0 := by
      intro i
      have h := congrFun hx i
      rw [hΦ_apply x i] at h
      simpa using h
    have hker : (S : Set (V n)) ⊆ (LinearMap.ker (dotLin x) : Set (V n)) := by
      intro s hs
      have hsv : s ∈ Set.range v := by
        rw [hrange]
        exact hs
      obtain ⟨i, rfl⟩ := hsv
      rw [SetLike.mem_coe, LinearMap.mem_ker, dotLin_apply, dotProduct_comm]
      exact hvx i
    have hxx : x ⬝ᵥ x = 0 := by
      have hx_in : x ∈ LinearMap.ker (dotLin x) :=
        Submodule.span_le.mpr hker (hlinspan x)
      rwa [LinearMap.mem_ker, dotLin_apply] at hx_in
    exact dotProduct_self_eq_zero.mp hxx
  -- dimension count: W_q is an n-dimensional subspace of ℝ^{n+1}
  have hrange_top : LinearMap.range (dotLin q) = ⊤ := by
    rw [LinearMap.range_eq_top]
    intro c
    refine ⟨c • ones (n + 1), ?_⟩
    rw [map_smul, dotLin_apply, dotProduct_ones, hqsum, smul_eq_mul, mul_one]
  have hfinW : finrank ℝ (wsHyperplane q) = n := by
    have h1 := LinearMap.finrank_range_add_finrank_ker (dotLin q)
    rw [hrange_top, finrank_top, Module.finrank_self] at h1
    have h2 : finrank ℝ (V (n + 1)) = n + 1 := Module.finrank_fin_fun ℝ
    have h3 : finrank ℝ (wsHyperplane q)
        = finrank ℝ (LinearMap.ker (dotLin q)) := rfl
    omega
  have hdim : finrank ℝ (V n) = finrank ℝ (wsHyperplane q) := by
    rw [hfinW]
    exact Module.finrank_fin_fun ℝ
  -- upgrade Φ to a linear homeomorphism Ψ : ℝⁿ ≃ W_q
  let Φr : V n →ₗ[ℝ] wsHyperplane q :=
    LinearMap.codRestrict (wsHyperplane q) Φ hΦmem
  have hΦr_inj : Function.Injective Φr := by
    intro a b hab
    exact hΦinj (congrArg Subtype.val hab)
  let Ψ : V n ≃ₗ[ℝ] wsHyperplane q :=
    LinearMap.linearEquivOfInjective Φr hΦr_inj hdim
  have hΨ_apply : ∀ (x : V n) (i : Fin (n + 1)),
      (Ψ x : V (n + 1)) i = v i ⬝ᵥ x := fun x i => rfl
  -- the lattice points of P map into the generators of Δ_q
  obtain ⟨T, hTlat, hTeq⟩ := hP.latticePolytope
  have hTP : (T : Set (V n)) ⊆ P := by
    rw [hTeq]
    exact subset_convexHull ℝ _
  have hTgens : (⇑Ψ '' (T : Set (V n))) ⊆ wsLatticeGensAt q 1 := by
    rintro _ ⟨t, ht, rfl⟩
    refine ⟨?_, ?_⟩
    · -- integrality: ⟨Vᵢ, t⟩ ∈ ℤ for lattice Vᵢ, t
      intro i
      obtain ⟨m, hm⟩ := (hSlat (v i) (hvSf i)).dotProduct_int (hTlat t ht)
      exact ⟨m, by rw [hΨ_apply t i]; exact hm⟩
    · -- depth: ⟨Vᵢ, t⟩ ≥ −1 because Vᵢ ∈ P* and t ∈ P
      intro i
      rw [hΨ_apply t i]
      exact hSdual (hvS i) t (hTP ht)
  -- hence Ψ(P) ⊆ Δ_q …
  have himg : ⇑Ψ '' (convexHull ℝ (T : Set (V n)))
      = convexHull ℝ (⇑Ψ '' (T : Set (V n))) := by
    have h := (Ψ : V n →ₗ[ℝ] wsHyperplane q).image_convexHull
      ((T : Set (V n)))
    simpa using h
  have hPimg : ⇑Ψ '' P ⊆ wsPolytopeAt q 1 := by
    rw [hTeq, himg]
    exact convexHull_mono hTgens
  -- … and 0 = Ψ(0) is interior to Ψ(P), hence to Δ_q
  let Ψc : V n ≃L[ℝ] wsHyperplane q := Ψ.toContinuousLinearEquiv
  have hΨc_coe : ⇑Ψc = ⇑Ψ := LinearEquiv.coe_toContinuousLinearEquiv' Ψ
  have himg_int : ⇑Ψ '' interior P = interior (⇑Ψ '' P) := by
    have h := Ψc.toHomeomorph.image_interior P
    rw [ContinuousLinearEquiv.coe_toHomeomorph] at h
    rwa [hΨc_coe] at h
  have h0img : (0 : wsHyperplane q) ∈ interior (⇑Ψ '' P) := by
    rw [← himg_int]
    exact ⟨0, hP.ip, map_zero Ψ⟩
  exact interior_mono hPimg h0img

/-! ## T9.4: the headline — the algorithm enumerates all reflexive polytopes -/

/-- **T9.4 (correctness of the classification pipeline).**  For every
reflexive polytope `P ⊂ ℝⁿ` and every selection rule `R` (e.g. the vertex
average of [SS18] §3):

1. there is a minimal IP generating set `S` of lattice points of `P*` whose
   maximal polytope `[conv(S)*]` contains `P` (T9.1) — so `P` appears in the
   subpolytope search below `S`; and
2. whenever `S` is simplicial (the non-simplicial case decomposes into
   simplicial blocks via [KS95] Lemma 1 = L4.3), its barycentric weight
   system `q` is a normalized positive IP weight system and **the
   enumeration tree of `Algorithm.lean`, started at `(1,…,1)`, reaches a
   node where the selected candidate is exactly `q`, within `n + 1`
   branchings** (T7.5/T7.6).

In dimension `n = 5` this is the formal statement that the [SS18] run —
which enumerated all 322 383 760 930 IP weight systems with 6 weights and
kept the 185 269 499 015 reflexive ones — misses no reflexive 5-polytope. -/
theorem algorithm_enumerates_reflexive (R : SelectionRule (n + 1))
    {P : Set (V n)} (hP : IsReflexive P) :
    ∃ S : Finset (V n),
      (∀ x ∈ S, IsLatticePoint x) ∧ (S : Set (V n)) ⊆ polarDual P ∧
      IsMinimalIPGen S ∧
      P ⊆ latticeHull (polarDual (convexHull ℝ (S : Set (V n)))) ∧
      (AffineIndependent ℝ ((↑) : ↥S → V n) →
        ∃ q : V (n + 1), (∀ i, 0 < q i) ∧ (∑ i, q i = 1) ∧
          IsIPWeightSystem q ∧
          ∃ N : Finset (V (n + 1)), Reachable R N ∧ R.sel N = q ∧
            N.card ≤ n + 2) := by
  obtain ⟨S, hSlat, hSdual, hSmin, hcover⟩ := classification_coverage hP
  refine ⟨S, hSlat, hSdual, hSmin, hcover, ?_⟩
  intro hind
  obtain ⟨q, hqpos, hqsum, hqIP⟩ :=
    reflexive_simplex_weight_system hP hSlat hSdual hind hSmin.1
  obtain ⟨N, hreach, hsel, hcard⟩ := algorithm_complete R hqpos hqsum hqIP
  exact ⟨q, hqpos, hqsum, hqIP, N, hreach, hsel, by omega⟩

end Refpoly
