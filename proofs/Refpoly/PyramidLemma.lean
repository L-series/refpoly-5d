/-
# The pyramid lemma: `d ≤ 4` vs `d = 5` (Part 6 of PROOF_PLAN.md)

In dimensions `≤ 4`, every IP weight system automatically yields a *reflexive*
polytope `Δ_q` ([Sk96]).  In dimension 5 this **fails**, which is why the
classification pipeline must test reflexivity separately for each of the
322 383 760 930 IP weight systems (185 269 499 015 pass, 137 114 261 915
fail, [SS18]).  The geometric heart of the asymmetry is [Sk96] Lemma 1, the
**pyramid lemma**, and the explicit counterexample to it in dimension 5.

Contents:

* `pyramid_lemma_dim_le_four` (L6.1) — [Sk96] Lemma 1, stated in its
  normalized form; recorded with `sorry` (elementary but fiddly integer
  arithmetic; the paper proof is transcribed in the docstring).
* `pyramid_counterexample_dim_five` (R6.3) — **fully proved**: the height-4
  pyramid over the doubled 4-simplex base with apex `(2,2,2,2,4)` contains
  *no* lattice point at height 1.  The proof exhibits explicit separating
  linear functionals and uses only `le_dotProduct_of_mem_convexHull` /
  `dotProduct_le_of_mem_convexHull` from `Basic.lean` — a finite,
  certificate-checked computation.

### On T6.2 (`Δ_q` reflexive for `d ≤ 4`) — deliberately not stated here

[Sk96]'s Theorem ("maximal Newton polyhedra of dimension ≤ 4 are reflexive")
derives from L6.1 as follows: if a facet of `Δ_max` had integral distance
`h ≥ 2` from the origin, the cone over that facet would contain an integer
pyramid of height `h` whose double still fits inside `{xᵢ ≥ −1} ⊇ Δ_max`'s
defining region; the intermediate lattice point provided by L6.1 would then
contradict maximality of `Δ_max`.  Stating this *faithfully* in Lean requires
the sublattice-relative reflexivity machinery for `Δ_q ⊂ W_q ≅ M_ℝ`
(`wsHyperplane` of `WeightSystem.lean`) plus the facet-distance dictionary,
none of which is needed by the main chain (Parts 1–5, 7, 9): for the `d = 5`
classification one *cannot* use T6.2 anyway — that is exactly the content of
R6.3 — so we document it here rather than formalize it.  This mirrors the
papers: [SS18] never invokes T6.2 in dimension 5; reflexivity is checked
per weight system (the `E.e[i].c == 1` facet test in PALP).
-/
import Refpoly.Basic

open Set

namespace Refpoly

/-! ## Vector notation helpers

Evaluating `![a,b,c,d,e] ⬝ᵥ x` against an *arbitrary* vector `x` needs the
`Matrix.cons_val_*` simp lemmas; we package the expansion once for each of
the two dimensions used in this file. -/

/-- Expand a dot product with an explicit 5-vector of coefficients. -/
theorem dot_lit₅ (a b c d e : ℝ) (x : V 5) :
    ![a, b, c, d, e] ⬝ᵥ x
      = a * x 0 + b * x 1 + c * x 2 + d * x 3 + e * x 4 := by
  unfold dotProduct
  rw [Fin.sum_univ_five]
  simp only [Matrix.cons_val_zero, Matrix.cons_val_one, Matrix.cons_val_two,
    Matrix.cons_val_three, Matrix.cons_val_four, Matrix.head_cons,
    Matrix.tail_cons]

/-- Evaluate `![…]`-literals against `![…]`-literals (used for the finitely
many generator checks below). -/
local macro "vec_norm" : tactic =>
  `(tactic| norm_num [Matrix.cons_val_zero, Matrix.cons_val_one,
      Matrix.cons_val_two, Matrix.cons_val_three, Matrix.cons_val_four,
      Matrix.head_cons, Matrix.tail_cons])

/-! ## L6.1: the pyramid lemma in dimension ≤ 4 -/

/-- **L6.1 (pyramid lemma, [Sk96] Lemma 1) — stated, proof deferred.**

Normalized form (the general case reduces to this by a `GL(4,ℤ)` change of
coordinates and relabeling): let `Pyr_double ⊂ ℝ⁴` be the pyramid with base
`conv{0, 2e₀, 2e₁, 2e₂} × {0}` and lattice apex `a = (2x, 2y, 2z, 2h)` with
`h ≥ 2` (evenness of `a` is what makes the *half* pyramid `Pyr` — the part
above height `h` — an integer pyramid; `Pyr_double` is its double).  Then
`Pyr_double` contains a lattice point at height `t` with `1 ≤ t ≤ h − 1`,
i.e. a lattice point lying neither in `Pyr` (heights `≥ h`) nor in the base
(height `0`).

*Paper proof ([Sk96], transcribed):* write the slice of `Pyr_double` at
height `t ∈ [0, 2h]` as `(t/2h)·a + (1 − t/2h)·B` where `B` is the base.
Consider the two candidate lattice points
`p₁ = (⌈x/h⌉, ⌈y/h⌉, ⌈z/h⌉, 1)` (height 1) and
`p₂ = (x − ⌊x/h⌋·1 …)`-type point at height `h − 1`; expressing each in the
barycentric coordinates of the slice, the two defect sums (the amounts by
which the barycentric coefficients can exceed the simplex condition) add up
to at most `2`, hence at least one of the two points satisfies the simplex
condition and lies in `Pyr_double`.  The verification is elementary integer
arithmetic with `⌈·⌉`/`⌊·⌋` and is *only* used for the `d ≤ 4` theory (T6.2,
see the file docstring) — never in the `d = 5` chain — so we record it as a
documented gap. -/
theorem pyramid_lemma_dim_le_four (x y z h : ℤ) (hh : 2 ≤ h) :
    ∃ p : V 4, IsLatticePoint p ∧
      p ∈ convexHull ℝ ({0, ![2, 0, 0, 0], ![0, 2, 0, 0], ![0, 0, 2, 0],
        ![(2 * x : ℝ), 2 * y, 2 * z, 2 * h]} : Set (V 4)) ∧
      1 ≤ p 3 ∧ p 3 ≤ (h : ℝ) - 1 := by
  sorry

/-! ## R6.3: failure of the pyramid lemma in dimension 5 -/

/-- The five-dimensional pyramid witnessing the failure: base
`conv{0, 2e₀, 2e₁, 2e₂, 2e₃} × {0}`, apex `(2,2,2,2,4)` — the `n = 5`,
`h = 2` instance of the pyramid-lemma setup. -/
def pyramid5 : Set (V 5) :=
  {0, ![2, 0, 0, 0, 0], ![0, 2, 0, 0, 0], ![0, 0, 2, 0, 0],
    ![0, 0, 0, 2, 0], ![2, 2, 2, 2, 4]}

/-- **R6.3 (counterexample in dimension 5, [Sk96]) — fully proved.**

`pyramid5` contains **no** lattice point at height `1` — precisely the height
range `[1, h−1] = {1}` where L6.1 would guarantee one for `n ≤ 4`.  Hence the
pyramid lemma, and with it the automatic reflexivity of `Δ_q` (T6.2), fails
in dimension 5; reflexivity must be checked per weight system.

*Proof by separation certificates.*  Suppose `m` is a lattice point of the
pyramid with `m 4 = 1`.
1.  For each `i < 4` the functional `ψᵢ = (…, ½ at slot i, …, −¼ at slot 4)`
    is `≥ 0` on all six vertices (values `0, 1, 0, 0, 0, 0`), hence `≥ 0`
    on the hull; evaluating at `m` gives `m i ≥ m 4 / 2 = ½`, and
    integrality bumps this to `m i ≥ 1`.
2.  The functional `φ = (½, ½, ½, ½, −¾)` is `≤ 1` on all six vertices
    (values `0, 1, 1, 1, 1, 1`), hence `≤ 1` on the hull; but step 1 gives
    `φ(m) ≥ 4·½ − ¾ = 5/4 > 1`.  Contradiction. -/
theorem pyramid_counterexample_dim_five {m : V 5}
    (hm : IsLatticePoint m) (hmem : m ∈ convexHull ℝ pyramid5) :
    m 4 ≠ 1 := by
  intro h4
  -- any functional that is ≥ 0 on the six vertices is ≥ 0 at m
  have key : ∀ w : V 5, (∀ v ∈ pyramid5, 0 ≤ w ⬝ᵥ v) → 0 ≤ w ⬝ᵥ m :=
    fun w hw => le_dotProduct_of_mem_convexHull hw hmem
  -- the four side certificates ψ₀, …, ψ₃
  have hpsi0 := key ![1/2, 0, 0, 0, -(1/4)] (by
    intro v hv
    simp only [pyramid5, Set.mem_insert_iff, Set.mem_singleton_iff] at hv
    rcases hv with rfl | rfl | rfl | rfl | rfl | rfl <;>
      (rw [dot_lit₅]; vec_norm))
  have hpsi1 := key ![0, 1/2, 0, 0, -(1/4)] (by
    intro v hv
    simp only [pyramid5, Set.mem_insert_iff, Set.mem_singleton_iff] at hv
    rcases hv with rfl | rfl | rfl | rfl | rfl | rfl <;>
      (rw [dot_lit₅]; vec_norm))
  have hpsi2 := key ![0, 0, 1/2, 0, -(1/4)] (by
    intro v hv
    simp only [pyramid5, Set.mem_insert_iff, Set.mem_singleton_iff] at hv
    rcases hv with rfl | rfl | rfl | rfl | rfl | rfl <;>
      (rw [dot_lit₅]; vec_norm))
  have hpsi3 := key ![0, 0, 0, 1/2, -(1/4)] (by
    intro v hv
    simp only [pyramid5, Set.mem_insert_iff, Set.mem_singleton_iff] at hv
    rcases hv with rfl | rfl | rfl | rfl | rfl | rfl <;>
      (rw [dot_lit₅]; vec_norm))
  rw [dot_lit₅, h4] at hpsi0 hpsi1 hpsi2 hpsi3
  -- integrality: a coordinate that is ≥ ½ is ≥ 1
  have hint : ∀ i : Fin 5, (1 : ℝ) / 2 ≤ m i → 1 ≤ m i := by
    intro i hi
    obtain ⟨z, hz⟩ := hm i
    rw [hz] at hi ⊢
    have hz1 : (1 : ℤ) ≤ z := by
      have : (0 : ℝ) < (z : ℝ) := by linarith
      have : (0 : ℤ) < z := by exact_mod_cast this
      omega
    exact_mod_cast hz1
  have hm0 : (1 : ℝ) ≤ m 0 := hint 0 (by linarith)
  have hm1 : (1 : ℝ) ≤ m 1 := hint 1 (by linarith)
  have hm2 : (1 : ℝ) ≤ m 2 := hint 2 (by linarith)
  have hm3 : (1 : ℝ) ≤ m 3 := hint 3 (by linarith)
  -- the cap certificate φ
  have hcap : (![1/2, 1/2, 1/2, 1/2, -(3/4)] : V 5) ⬝ᵥ m ≤ 1 := by
    apply dotProduct_le_of_mem_convexHull ?_ hmem
    intro v hv
    simp only [pyramid5, Set.mem_insert_iff, Set.mem_singleton_iff] at hv
    rcases hv with rfl | rfl | rfl | rfl | rfl | rfl <;>
      (rw [dot_lit₅]; vec_norm)
  rw [dot_lit₅, h4] at hcap
  linarith

end Refpoly
