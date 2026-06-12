/-
# Structure of minimal IP polytopes (Part 4 of PROOF_PLAN.md)

The combinatorial heart of [KS95] §2: a *minimal* IP generating set (D3.1,
`IsMinimalIPGen` in `MaxMin.lean`) is either a simplex or decomposes into
lower-dimensional simplicial pieces.  In the simplicial case the polytope is
*uniquely determined by a weight system* — the barycentric coordinates of the
origin — which is the object the enumeration algorithm of `Algorithm.lean`
searches for.

Fully proved here (everything the algorithm-correctness chain needs):

* `minimalIPGen_card_lower` (C4.5, lower bound) — an IP generating set has at
  least `n + 1` points (it must affinely span `ℝⁿ`).
* `simplex_card` — an affinely independent IP generating set has *exactly*
  `n + 1` points (it is a non-degenerate simplex with `0` inside).
* `simplex_weights` (L4.2′/D5.1 bridge, [KS95] §3: "the weights `qᵢ` are the
  barycentric coordinates of the origin") — an affinely independent IP
  generating set carries a unique normalized positive weight system `q` with
  `Σ qᵢ Vᵢ = 0`.  This is the input to `Classification.lean`, where `q` is
  shown to be an IP weight system reachable by the algorithm.

Stated with `sorry` (context only — **not** used by the algorithm chain):

* `minimal_structure` (L4.3, [KS95] Lemma 1) — the non-simplicial case:
  a minimal polytope decomposes into a lower-dimensional minimal polytope
  plus a good simplex.  Iterating it (KS95 Cor. 1) produces the *combined*
  weight systems (`CWS` of `WeightSystem.lean`).  Per the project decision,
  the d = 5 pipeline treats CWS enumeration through the same algorithm run
  blockwise, so this structure theorem is documentation, not a dependency.

Not formalized (documentation in PROOF_PLAN.md): C4.4 (block decomposition),
the C4.5 upper bound `≤ 2n`, L4.6 (no lonely vertices), C4.7 (finitely many
combinatorial types) — all downstream of L4.3 and likewise not needed for
the correctness theorems.
-/
import Refpoly.MaxMin

open Set Module

namespace Refpoly

variable {n : ℕ}

/-! ## D4.1: good simplices -/

/-- **D4.1 (good simplex, [KS95] §2).**  A finite point set is a *good
simplex* if it is affinely independent and the origin lies in the *relative*
(intrinsic) interior of its hull.  The faces appearing in the decomposition
of a non-simplicial minimal polytope are good simplices. -/
def IsGoodSimplex (T : Finset (V n)) : Prop :=
  AffineIndependent ℝ ((↑) : ↥T → V n) ∧
    (0 : V n) ∈ intrinsicInterior ℝ (convexHull ℝ (T : Set (V n)))

/-- Relative (intrinsic-interior) variant of `IsMinimalIPGen`, the notion of
minimality appropriate for the lower-dimensional pieces `M'` in [KS95]
Lemma 1. -/
def IsMinimalIPRel (S : Finset (V n)) : Prop :=
  (0 : V n) ∈ intrinsicInterior ℝ (convexHull ℝ (S : Set (V n))) ∧
    ∀ S' ⊂ S, (0 : V n) ∉ intrinsicInterior ℝ (convexHull ℝ (S' : Set (V n)))

/-! ## C4.5 (lower bound): an IP generating set has ≥ n + 1 points -/

/-- **C4.5, lower bound ([KS95] Corollary 2).**  A set whose hull has the
origin as a (full-dimensional) interior point must affinely span `ℝⁿ`, so it
has at least `n + 1` elements.  (The upper bound `≤ 2n` for *minimal* sets
needs L4.3 and is not formalized.) -/
theorem minimalIPGen_card_lower {S : Finset (V n)}
    (h0 : (0 : V n) ∈ interior (convexHull ℝ (S : Set (V n)))) :
    n + 1 ≤ S.card := by
  classical
  have hspan : affineSpan ℝ (S : Set (V n)) = ⊤ :=
    interior_convexHull_nonempty_iff_affineSpan_eq_top.mp ⟨0, h0⟩
  have hne : S.Nonempty := by
    rcases S.eq_empty_or_nonempty with rfl | h
    · simp at h0
    · exact h
  have hpos : 0 < S.card := Finset.card_pos.mpr hne
  obtain ⟨m, hm⟩ : ∃ m, S.card = m + 1 := ⟨S.card - 1, by omega⟩
  have hbound := finrank_vectorSpan_image_finset_le (k := ℝ) id S hm
  rw [Finset.image_id] at hbound
  have htop : vectorSpan ℝ (S : Set (V n)) = ⊤ := by
    rw [← direction_affineSpan, hspan]
    exact AffineSubspace.direction_top ℝ _ _
  have hfr : finrank ℝ (vectorSpan ℝ (S : Set (V n))) = n := by
    rw [htop, finrank_top]
    exact Module.finrank_fin_fun ℝ
  omega

/-- An *affinely independent* IP generating set has exactly `n + 1` points:
it is the vertex set of a non-degenerate `n`-simplex containing `0` in its
interior. -/
theorem simplex_card {S : Finset (V n)}
    (hind : AffineIndependent ℝ ((↑) : ↥S → V n))
    (h0 : (0 : V n) ∈ interior (convexHull ℝ (S : Set (V n)))) :
    S.card = n + 1 := by
  have hlower := minimalIPGen_card_lower h0
  have hupper := hind.card_le_finrank_succ
  rw [Fintype.card_coe, Subtype.range_coe_subtype, Finset.setOf_mem] at hupper
  have hle : finrank ℝ (vectorSpan ℝ (S : Set (V n))) ≤ n := by
    have h1 : finrank ℝ (vectorSpan ℝ (S : Set (V n)))
        ≤ finrank ℝ (V n) := Submodule.finrank_le _
    have h2 : finrank ℝ (V n) = n := Module.finrank_fin_fun ℝ
    omega
  omega

/-! ## The weight system of a minimal simplex (L4.2′ / [KS95] §3) -/

/-- **The barycentric weight system of an IP simplex.**  If `S` is affinely
independent and its hull contains `0` in its interior, then — enumerating
`S` as `v : Fin (n+1) → V n` — there is a weight vector `q` with

* `qᵢ > 0` (positivity: `0` is *interior*, L5.2),
* `Σ qᵢ = 1` (normalization), and
* `Σ qᵢ • vᵢ = 0` (the circuit relation `Σ qᵢ Vᵢ = 0` of [KS95] §3 /
  [SS18] §2.2: the weights are the barycentric coordinates of the origin).

This is the object handed to the enumeration algorithm; `Classification.lean`
upgrades it to an `IsIPWeightSystem` when `S` supports a reflexive polytope. -/
theorem simplex_weights {S : Finset (V n)}
    (hind : AffineIndependent ℝ ((↑) : ↥S → V n))
    (h0 : (0 : V n) ∈ interior (convexHull ℝ (S : Set (V n)))) :
    ∃ (v : Fin (n + 1) → V n) (q : V (n + 1)),
      Set.range v = (S : Set (V n)) ∧ (∀ i, 0 < q i) ∧ (∑ i, q i = 1) ∧
      ∑ i, q i • v i = 0 := by
  classical
  have hcard := simplex_card hind h0
  have hScard : Fintype.card (↥S) = n + 1 := by
    rw [Fintype.card_coe]; exact hcard
  -- enumerate the vertices
  let e : ↥S ≃ Fin (n + 1) := Fintype.equivFinOfCardEq hScard
  let v : Fin (n + 1) → V n := fun i => ((e.symm i : ↥S) : V n)
  have hrange : Set.range v = (S : Set (V n)) := by
    have hcomp : v = ((↑) : ↥S → V n) ∘ e.symm := rfl
    rw [hcomp, Set.range_comp, Equiv.range_eq_univ, Set.image_univ,
      Subtype.range_coe_subtype, Finset.setOf_mem]
  -- the vertices form an affine basis
  have hv_ind : AffineIndependent ℝ v := hind.comp_embedding e.symm.toEmbedding
  have hspan : affineSpan ℝ (Set.range v) = ⊤ := by
    rw [hrange]
    exact interior_convexHull_nonempty_iff_affineSpan_eq_top.mp ⟨0, h0⟩
  let b : AffineBasis (Fin (n + 1)) ℝ (V n) := ⟨v, hv_ind, hspan⟩
  have hb_coe : ⇑b = v := rfl
  refine ⟨v, fun i => b.coord i 0, hrange, ?_, b.sum_coord_apply_eq_one 0, ?_⟩
  · -- positivity: barycentric coordinates of an interior point (L5.2)
    have h0' : (0 : V n) ∈ interior (convexHull ℝ (Set.range ⇑b)) := by
      rw [hb_coe, hrange]; exact h0
    rw [b.interior_convexHull] at h0'
    exact h0'
  · -- the circuit relation: the affine combination with these weights is 0
    have hself := b.affineCombination_coord_eq_self (0 : V n)
    rwa [Finset.univ.affineCombination_eq_linear_combination _ _
      (b.sum_coord_apply_eq_one 0), hb_coe] at hself

/-! ## L4.3: the non-simplicial case ([KS95] Lemma 1) — statement only -/

/-- **L4.3 ([KS95] Lemma 1) — stated, deliberately not proved.**

A minimal IP generating set that is *not* a simplex splits: there are
`S' ⊂ S` and `T ⊆ S` with `S' ∪ T = S` such that `S'` generates a
lower-dimensional minimal polytope (relative minimality, in its own span),
`T` is a good simplex, and the cardinalities satisfy [KS95]'s
`k̄ − k̄' = n − n' + 1` with `dim T ≤ n'` (`n' = dim span S'`).

*Paper proof sketch ([KS95]):* choose `S'` maximal among proper subsets whose
hull still has `0` in its relative interior; pass to the quotient
`ℝⁿ / span(S')`; the image of `S` is a minimal IP set in the quotient with
trivial proper sub-minimal sets, hence a simplex by the maximality of `S'`;
pulling back its vertices and adjoining suitable points `R ⊆ S'` yields the
good simplex `T`; minimality forces the cardinality identity.

This statement is what generates *combined* weight systems (`CWS`): iterating
it gives the block decomposition (KS95 Cor. 1), one weight system per block.
**It is not used by the algorithm-correctness chain** (Parts 5, 7, 9): the
enumeration is complete for every weight system regardless of how minimal
polytopes decompose, so we record the statement for context only. -/
theorem minimal_structure {S : Finset (V n)} (hS : IsMinimalIPGen S)
    (hns : ¬ AffineIndependent ℝ ((↑) : ↥S → V n)) :
    ∃ S' T : Finset (V n), S' ⊂ S ∧ T ⊆ S ∧ S' ∪ T = S ∧
      IsMinimalIPRel S' ∧ IsGoodSimplex T ∧
      S.card = S'.card + (n - finrank ℝ (vectorSpan ℝ ((S' : Set (V n))))) + 1 ∧
      finrank ℝ (vectorSpan ℝ ((T : Set (V n))))
        ≤ finrank ℝ (vectorSpan ℝ ((S' : Set (V n)))) := by
  sorry

end Refpoly
