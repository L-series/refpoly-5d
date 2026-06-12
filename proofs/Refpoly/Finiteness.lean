/-
# Finiteness of reflexive polytopes (Part 1 of PROOF_PLAN.md)

The classification is well-posed because, in each dimension, there are only
finitely many reflexive polytopes up to `GL(n,ℤ)`.  All three source papers
*cite* this fact ([KS95] §1: "It is known that the total number of reflexive
polyhedra is finite in any given dimension, because various bounds on the
volume and the number of points have been derived as a function of the
dimension and the number of interior lattice points", citing Batyrev '82,
Hensley '83, Borisov–Borisov '92).

Following the plan, the two geometry-of-numbers inputs are **axiomatized**
(stated with `sorry` and full documentation):

* `hensley_volume_bound` (T1.1) — [He83] Theorem; [LZ91] Theorem 1.
* `lagarias_ziegler_box` (T1.3) — [LZ91] Theorem 2.

Everything else in this file is **fully proved** from them:

* `latticePoint_count_bound` (T1.2) — the number of lattice points of a
  reflexive polytope is bounded by a constant depending only on `n`.
* `finitely_many_reflexive` (T1.4) — finiteness up to `GL(n,ℤ)`.
* `ncard_lt_of_ssubset` (L1.5) — a lattice polytope properly containing
  another has strictly more lattice points; with T1.2 this terminates all
  ascending chains of reflexive polytopes (used for Part 2).
-/
import Refpoly.Basic

open Set

namespace Refpoly

variable {n : ℕ}

/-- **T1.1 (Hensley / Lagarias–Ziegler volume bound) — external input.**

[He83]: a `d`-dimensional lattice polytope with `k ≥ 1` interior lattice
points has volume bounded by a constant `c(d,k)`.  [LZ91] Theorem 1 sharpens
this to `Vol(P) ≤ k · (8d)^d · 15^(d·2^(2d+1))`.  A reflexive polytope has
exactly one interior lattice point (`interior_latticePoint_unique`), so its
volume is bounded by a constant depending only on the dimension.

The proof is a pigeonhole/convexity argument in the geometry of numbers
("a long thin polytope around an interior point must swallow another lattice
point"); it is *not* re-proved in the papers and we import it as a documented
gap.  Discharging this `sorry` is a self-contained formalization project in
the geometry of numbers (Blichfeldt/Minkowski-type arguments). -/
theorem hensley_volume_bound (n : ℕ) :
    ∃ C : ℝ, ∀ P : Set (V n), IsReflexive P →
      (MeasureTheory.volume P).toReal ≤ C := by
  sorry

/-- **T1.3 (Lagarias–Ziegler box lemma) — external input.**

[LZ91] Theorem 2: a lattice polytope of volume `≤ V` with an interior lattice
point (placed at the origin) is mapped by some `GL(n,ℤ)` transformation into
the cube `[-R, R]ⁿ` where `R = R(n, V)` is explicit.  Combined with T1.1 this
puts every reflexive polytope, up to `GL(n,ℤ)`, inside one fixed finite box.

The proof uses successive minima / a Minkowski-type reduction; we import it
as a documented gap, stated here directly for reflexive polytopes (i.e. with
T1.1 already folded in, so that this file's downstream results depend on a
single constant `R`). -/
theorem lagarias_ziegler_box (n : ℕ) :
    ∃ R : ℕ, ∀ P : Set (V n), IsReflexive P →
      ∃ Q : Set (V n), GLEquiv P Q ∧ Q ⊆ {x | ∀ i, |x i| ≤ (R : ℝ)} := by
  sorry

/-- The box `[-R,R]ⁿ` is bounded. -/
theorem isBounded_box (R : ℕ) :
    Bornology.IsBounded {x : V n | ∀ i, |x i| ≤ (R : ℝ)} := by
  apply Bornology.IsBounded.subset
    (Metric.isBounded_closedBall (x := (0 : V n)) (r := R))
  intro x hx
  rw [Metric.mem_closedBall, dist_zero_right,
    pi_norm_le_iff_of_nonneg (by positivity)]
  intro i
  rw [Real.norm_eq_abs]
  exact hx i

/-- **T1.2 (lattice point count bound)** — *derived* from the box lemma: the
number of lattice points of a reflexive polytope is bounded by the number of
lattice points of the box `[-R,R]ⁿ`, since unimodular maps biject lattice
points (`GLEquiv.ncard_lattice_eq`). -/
theorem latticePoint_count_bound (n : ℕ) :
    ∃ N : ℕ, ∀ P : Set (V n), IsReflexive P →
      (P ∩ latticePoints n).ncard ≤ N := by
  obtain ⟨R, hR⟩ := lagarias_ziegler_box n
  set B : Set (V n) := {x | ∀ i, |x i| ≤ (R : ℝ)} with hB
  have hBfin : (B ∩ latticePoints n).Finite :=
    finite_latticePoints_of_isBounded (isBounded_box R)
  refine ⟨(B ∩ latticePoints n).ncard, fun P hP => ?_⟩
  obtain ⟨Q, hgl, hsub⟩ := hR P hP
  rw [hgl.ncard_lattice_eq]
  exact Set.ncard_le_ncard (inter_subset_inter_left _ hsub) hBfin

/-- **L1.5 (strict monotonicity of the lattice point count).**  A lattice
polytope properly containing another has strictly more lattice points.  Key
step: a lattice polytope is the hull of its lattice points
(`IsLatticePolytope.eq_latticeHull`), so equal lattice point sets force equal
polytopes. -/
theorem ncard_lt_of_ssubset {P Q : Set (V n)} (hP : IsLatticePolytope P)
    (hQ : IsLatticePolytope Q) (h : P ⊂ Q) :
    (P ∩ latticePoints n).ncard < (Q ∩ latticePoints n).ncard := by
  have hsub : P ∩ latticePoints n ⊆ Q ∩ latticePoints n :=
    inter_subset_inter_left _ h.subset
  have hne : P ∩ latticePoints n ≠ Q ∩ latticePoints n := by
    intro he
    have hQP : Q = P := by
      rw [hQ.eq_latticeHull, hP.eq_latticeHull]
      unfold latticeHull
      rw [he]
    exact h.ne hQP.symm
  exact Set.ncard_lt_ncard (hsub.ssubset_of_ne hne) hQ.finite_latticePoints

/-- **T1.4 (Finiteness; Lagarias–Ziegler).**  Up to `GL(n,ℤ)`, there are only
finitely many reflexive polytopes in each dimension: there is a *finite* set
`T` of polytopes such that every reflexive polytope is `GL(n,ℤ)`-equivalent
to a member of `T`.

Derivation: by the box lemma, every reflexive polytope is equivalent to a
lattice polytope inside `[-R,R]ⁿ`; lattice polytopes inside the box are
determined by their lattice point sets, which are subsets of the *finite* set
`[-R,R]ⁿ ∩ ℤⁿ`. -/
theorem finitely_many_reflexive (n : ℕ) :
    ∃ T : Set (Set (V n)), T.Finite ∧
      ∀ P : Set (V n), IsReflexive P → ∃ Q ∈ T, GLEquiv P Q := by
  obtain ⟨R, hR⟩ := lagarias_ziegler_box n
  set B : Set (V n) := {x | ∀ i, |x i| ≤ (R : ℝ)} with hB
  have hBfin : (B ∩ latticePoints n).Finite :=
    finite_latticePoints_of_isBounded (isBounded_box R)
  set T : Set (Set (V n)) := {Q | IsLatticePolytope Q ∧ Q ⊆ B} with hT
  refine ⟨T, ?_, ?_⟩
  · -- T is finite: `Q ↦ Q ∩ ℤⁿ` is injective on lattice polytopes and lands
    -- in the (finite) powerset of the finite set `B ∩ ℤⁿ`.
    have hinj : Set.InjOn (fun Q => Q ∩ latticePoints n) T := by
      rintro Q₁ ⟨h₁, -⟩ Q₂ ⟨h₂, -⟩ he
      dsimp only at he
      rw [h₁.eq_latticeHull, h₂.eq_latticeHull]
      unfold latticeHull
      rw [he]
    apply Set.Finite.of_finite_image ?_ hinj
    apply Set.Finite.subset hBfin.finite_subsets
    rintro s ⟨Q, ⟨-, hQB⟩, rfl⟩
    exact inter_subset_inter_left _ hQB
  · intro P hP
    obtain ⟨Q, hgl, hsub⟩ := hR P hP
    exact ⟨Q, ⟨hgl.isLatticePolytope hP.latticePolytope, hsub⟩, hgl⟩

end Refpoly
