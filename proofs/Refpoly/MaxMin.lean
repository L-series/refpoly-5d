/-
# Maximal and minimal reflexive polytopes; max/min duality
(Parts 2 and 3 of PROOF_PLAN.md)

This file implements the two structural reductions of the classification:

* **(S) Subpolytope reduction** ([SS18] §2.2, [KS95] §1): every reflexive
  polytope embeds in a *maximal* reflexive polytope (`exists_maximal_superset`,
  T2.2).  This is the statement "look for a set S = {Δ₁, Δ₂, …} of polytopes
  such that any reflexive polytope Δ is contained in at least one of the Δᵢ".

* **(D) Max/min duality** ([SS18] §2.2): "Since duality inverts subset
  relations, Δ ⊆ Δ̃ ⇔ Δ* ⊇ Δ̃*, every reflexive polytope must then contain at
  least one of Δ₁*, Δ₂*, …" — formalized as `subset_iff_polarDual_subset`
  (L3.2), `IsReflexive.polarDual_reflexive` (T3.3),
  `maximal_iff_dual_minimal` (T3.4), `exists_minimal_subset` (dual of T2.2).

* The bridge to weight systems: every IP polytope's generating set contains a
  *minimal IP* generating subset (`exists_minimalIPGen_subset`, T3.5); the
  minimal IP polytopes are the objects classified by (combined) weight
  systems in [KS95] §2 / Part 4.

All results in this file are fully proved (no sorry); they depend on the two
axiomatized geometry-of-numbers inputs through `Refpoly/Finiteness.lean`.
-/
import Refpoly.Finiteness

open Set Matrix

namespace Refpoly

variable {n : ℕ}

/-! ## Reflexive polytopes are closed under duality (T3.3) -/

/-- For a reflexive polytope, `P** = P`. -/
theorem IsReflexive.bipolar_eq {P : Set (V n)} (hP : IsReflexive P) :
    polarDual (polarDual P) = P :=
  bipolar hP.latticePolytope.convex hP.latticePolytope.isClosed
    (interior_subset hP.ip)

/-- The polar dual of a reflexive polytope is reflexive ([SS18] §2.1:
"the dual of an IP polytope is itself an IP polytope with Δ** = Δ"). -/
theorem IsReflexive.polarDual_reflexive {P : Set (V n)} (hP : IsReflexive P) :
    IsReflexive (polarDual P) where
  latticePolytope := hP.dual_latticePolytope
  ip := by
    -- 0 is interior to P*: P is bounded, so a small ball pairs ≥ -1 with P.
    obtain ⟨R, hR⟩ := hP.latticePolytope.isCompact.isBounded.exists_norm_le
    have hR0 : (0 : ℝ) ≤ R := by
      simpa using hR 0 (interior_subset hP.ip)
    set ε : ℝ := 1 / (n * R + 1) with hε
    have hεpos : 0 < ε := by positivity
    have hball : Metric.ball (0 : V n) ε ⊆ polarDual P := by
      intro y hy x hx
      rw [Metric.mem_ball, dist_zero_right] at hy
      have hbound : |y ⬝ᵥ x| ≤ n * (ε * R) := by
        calc |y ⬝ᵥ x| ≤ ∑ i, |y i * x i| := Finset.abs_sum_le_sum_abs _ _
          _ ≤ ∑ _i : Fin n, ε * R := by
              apply Finset.sum_le_sum
              intro i _
              rw [abs_mul]
              have hy1 : |y i| ≤ ε := by
                calc |y i| = ‖y i‖ := (Real.norm_eq_abs _).symm
                  _ ≤ ‖y‖ := norm_le_pi_norm y i
                  _ ≤ ε := hy.le
              have hx1 : |x i| ≤ R := by
                calc |x i| = ‖x i‖ := (Real.norm_eq_abs _).symm
                  _ ≤ ‖x‖ := norm_le_pi_norm x i
                  _ ≤ R := hR x hx
              exact mul_le_mul hy1 hx1 (abs_nonneg _) hεpos.le
          _ = n * (ε * R) := by simp [Finset.sum_const, mul_comm]
      have hlt : n * (ε * R) < 1 := by
        rw [hε]
        rw [show (n : ℝ) * (1 / (n * R + 1) * R) = n * R / (n * R + 1) by ring]
        rw [div_lt_one (by positivity)]
        linarith
      have := abs_le.1 hbound
      linarith
    exact interior_maximal hball Metric.isOpen_ball (Metric.mem_ball_self hεpos)
  dual_latticePolytope := by
    rw [hP.bipolar_eq]
    exact hP.latticePolytope

/-! ## Duality reverses inclusion (L3.2) -/

/-- **L3.2.**  For closed convex `Q ∋ 0`, inclusion of polytopes is equivalent
to the reversed inclusion of their duals.  [SS18] §2.2: "duality inverts
subset relations, Δ ⊆ Δ̃ ⇔ Δ* ⊇ Δ̃*". -/
theorem subset_iff_polarDual_subset {P Q : Set (V n)} (hQconv : Convex ℝ Q)
    (hQcl : IsClosed Q) (hQ0 : (0 : V n) ∈ Q) :
    P ⊆ Q ↔ polarDual Q ⊆ polarDual P := by
  constructor
  · exact polarDual_antitone
  · intro h
    calc P ⊆ polarDual (polarDual P) := subset_bipolar P
      _ ⊆ polarDual (polarDual Q) := polarDual_antitone h
      _ = Q := bipolar hQconv hQcl hQ0

/-! ## Maximal and minimal reflexive polytopes (D2.1, D3.1) -/

/-- **D2.1.**  A reflexive polytope is *maximal* if it is not properly
contained in another reflexive polytope on the same lattice. -/
def IsMaximalReflexive (P : Set (V n)) : Prop :=
  IsReflexive P ∧ ∀ Q, IsReflexive Q → P ⊆ Q → Q = P

/-- A reflexive polytope is *minimal* (order-dual of D2.1) if it contains no
proper reflexive subpolytope.  (This is the order-theoretic notion; for the
vertex-economical notion `IsMinimalIPGen` see below and Part 4.) -/
def IsMinimalReflexive (P : Set (V n)) : Prop :=
  IsReflexive P ∧ ∀ Q, IsReflexive Q → Q ⊆ P → Q = P

/-! ## Every reflexive polytope embeds in a maximal one (T2.2) -/

/-- **T2.2.**  Every reflexive polytope is contained in a *maximal* reflexive
polytope.  Proof: among reflexive polytopes containing `P`, the lattice point
count takes values in a finite range (T1.2); pick one realizing the maximal
count; strict inclusion would force a strictly larger count (L1.5). -/
theorem exists_maximal_superset {P : Set (V n)} (hP : IsReflexive P) :
    ∃ Δ : Set (V n), P ⊆ Δ ∧ IsMaximalReflexive Δ := by
  obtain ⟨N, hN⟩ := latticePoint_count_bound n
  set A : Set ℕ :=
    {m | ∃ Q : Set (V n), IsReflexive Q ∧ P ⊆ Q ∧ (Q ∩ latticePoints n).ncard = m}
    with hA
  have hAne : A.Nonempty := ⟨_, P, hP, subset_rfl, rfl⟩
  have hAbdd : BddAbove A := by
    refine ⟨N, ?_⟩
    rintro m ⟨Q, hQ, -, rfl⟩
    exact hN Q hQ
  obtain ⟨Δ, hΔ, hPΔ, hcard⟩ : sSup A ∈ A := Nat.sSup_mem hAne hAbdd
  refine ⟨Δ, hPΔ, hΔ, fun Q hQ hΔQ => ?_⟩
  by_contra hne
  have hss : Δ ⊂ Q := hΔQ.ssubset_of_ne (fun h => hne h.symm)
  have hlt : (Δ ∩ latticePoints n).ncard < (Q ∩ latticePoints n).ncard :=
    ncard_lt_of_ssubset hΔ.latticePolytope hQ.latticePolytope hss
  have hmem : (Q ∩ latticePoints n).ncard ∈ A :=
    ⟨Q, hQ, hPΔ.trans hΔQ, rfl⟩
  have hle : (Q ∩ latticePoints n).ncard ≤ sSup A := le_csSup hAbdd hmem
  omega

/-! ## Max/min duality (T3.4) -/

/-- **T3.4.**  A reflexive polytope is maximal iff its polar dual is minimal.
This is the strategic pivot of the classification ([SS18] §2.2): instead of
hunting for the big maximal polytopes one classifies the small minimal ones
and dualizes. -/
theorem maximal_iff_dual_minimal {P : Set (V n)} (hP : IsReflexive P) :
    IsMaximalReflexive P ↔ IsMinimalReflexive (polarDual P) := by
  constructor
  · rintro ⟨-, hmax⟩
    refine ⟨hP.polarDual_reflexive, fun Q hQ hQsub => ?_⟩
    -- Q ⊆ P* ⇒ P = P** ⊆ Q*, so by maximality Q* = P, hence Q = Q** = P*.
    have h1 : P ⊆ polarDual Q := by
      rw [← hP.bipolar_eq]
      exact polarDual_antitone hQsub
    have h2 : polarDual Q = P := hmax _ hQ.polarDual_reflexive h1
    calc Q = polarDual (polarDual Q) := hQ.bipolar_eq.symm
      _ = polarDual P := by rw [h2]
  · rintro ⟨-, hmin⟩
    refine ⟨hP, fun Q hQ hPQ => ?_⟩
    have h1 : polarDual Q ⊆ polarDual P := polarDual_antitone hPQ
    have h2 : polarDual Q = polarDual P := hmin _ hQ.polarDual_reflexive h1
    calc Q = polarDual (polarDual Q) := hQ.bipolar_eq.symm
      _ = polarDual (polarDual P) := by rw [h2]
      _ = P := hP.bipolar_eq

/-- Dual form of T2.2: every reflexive polytope *contains* a minimal reflexive
polytope.  [SS18] §2.2: "every reflexive polytope must then contain at least
one of Δ₁*, Δ₂*, …". -/
theorem exists_minimal_subset {P : Set (V n)} (hP : IsReflexive P) :
    ∃ Nb : Set (V n), Nb ⊆ P ∧ IsMinimalReflexive Nb := by
  obtain ⟨Δ, hsub, hmax⟩ := exists_maximal_superset hP.polarDual_reflexive
  refine ⟨polarDual Δ, ?_, ?_⟩
  · calc polarDual Δ ⊆ polarDual (polarDual P) := polarDual_antitone hsub
      _ = P := hP.bipolar_eq
  · exact (maximal_iff_dual_minimal hmax.1).1 hmax

/-! ## Minimal IP generating sets (T3.5)

The bridge to Part 4: the *vertex-economical* notion of minimality, which is
the one classified by weight systems.  [SS18] §2.2: "a minimal polytope
∇ ⊂ N_ℝ [is] a polytope that has the IP property, whereas the convex hull of
any proper subset of the set of its vertices fails to have it."  We work
with finite generating sets instead of vertex sets; an inclusion-minimal
generating set consists exactly of the vertices. -/

/-- **D3.1 (vertex-economical minimality).**  A finite set `S` is a *minimal
IP generating set* if its hull contains the origin in its interior while the
hull of every proper subset does not. -/
def IsMinimalIPGen (S : Finset (V n)) : Prop :=
  ((0 : V n) ∈ interior (convexHull ℝ (S : Set (V n)))) ∧
    ∀ S' ⊂ S, (0 : V n) ∉ interior (convexHull ℝ (S' : Set (V n)))

/-- **T3.5.**  Every finite IP generating set contains a minimal IP generating
subset.  (Finite descent; this is how [KS95] §2 passes from the vertex set of
`Q*` to a minimal polytope `M`.) -/
theorem exists_minimalIPGen_subset (S : Finset (V n))
    (h : (0 : V n) ∈ interior (convexHull ℝ (S : Set (V n)))) :
    ∃ S' ⊆ S, IsMinimalIPGen S' := by
  classical
  induction S using Finset.strongInduction with
  | _ S ih =>
    by_cases hall : ∀ S' ⊂ S, (0 : V n) ∉ interior (convexHull ℝ (S' : Set (V n)))
    · exact ⟨S, subset_rfl, h, hall⟩
    · push Not at hall
      obtain ⟨S', hS', hint⟩ := hall
      obtain ⟨S'', hsub, hmin⟩ := ih S' hS' hint
      exact ⟨S'', hsub.trans hS'.subset, hmin⟩

end Refpoly
