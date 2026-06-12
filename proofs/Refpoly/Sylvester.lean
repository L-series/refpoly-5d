/-
# The Sylvester sequence and the degree bound (Part 8 of PROOF_PLAN.md)

The running time of the Kreuzer–Skarke enumeration in dimension 5 is governed
by the maximal *degree* `d = ∑ᵢ wᵢ` of an IP weight system on `n = 6` weights.
[SS18] §2 states that this maximum is

  `d_max = 2·3·7·43·1807 · (2·3·7·43·1807 − 1) / something` — concretely
  `d_max = 1806 · 1807 = 3263442`,

attained by the weight system

  `(w₁,…,w₆) = d_max · (1/2, 1/3, 1/7, 1/43, 1/1807, 1/3263442)`

built from the **Sylvester sequence** `y₀ = 2, y_{k+1} = y_k(y_k − 1) + 1`:
`2, 3, 7, 43, 1807, 3263443, …`, whose reciprocals form the greedy Egyptian
fraction expansion of `1`:

  `1/2 + 1/3 + 1/7 + 1/43 + 1/1807 + 1/3263442 = 1`     (note: 3263442 = 1806·1807)

This file proves the arithmetic facts about the Sylvester sequence
(`prod_sylvester`, `sylvester_sum_inv`) and verifies the two extremal
candidate weight systems of [SS18] (the maximal-degree one, `qct6`, and the
two-equal-last-weights variant `qlt6`) sum to 1 with positive entries.

The actual extremality statement (T8.4: *every* IP weight system in
dimension 5 has degree ≤ 3263442) is recorded with `sorry`: its paper proof
([SS18] §2, going back to [Sk96] Prop. 4.2) is a careful induction on the
"allowed denominators" of unit-fraction decompositions and is independent of
the rest of the development (it is a *complexity bound*, not a correctness
ingredient — the completeness of the algorithm in `Algorithm.lean` does not
use it).
-/
import Refpoly.WeightSystem

open Finset

namespace Refpoly

/-! ## The Sylvester sequence -/

/-- **D8.1: the Sylvester sequence** `2, 3, 7, 43, 1807, 3263443, …`,
`y₀ = 2`, `y_{k+1} = y_k (y_k − 1) + 1` (equivalently `y_{k+1} = y_k² − y_k + 1`).
[Sk96] §4, [SS18] §2. -/
def sylvester : ℕ → ℕ
  | 0 => 2
  | k + 1 => sylvester k * (sylvester k - 1) + 1

@[simp] theorem sylvester_zero : sylvester 0 = 2 := rfl
theorem sylvester_one : sylvester 1 = 3 := rfl
theorem sylvester_two : sylvester 2 = 7 := rfl
theorem sylvester_three : sylvester 3 = 43 := rfl
theorem sylvester_four : sylvester 4 = 1807 := rfl
theorem sylvester_five : sylvester 5 = 3263443 := rfl

/-- Every Sylvester number is at least 2 (so in particular positive, and
subtraction of 1 is well-behaved). -/
theorem sylvester_two_le (k : ℕ) : 2 ≤ sylvester k := by
  induction k with
  | zero => simp [sylvester]
  | succ k ih =>
    have h1 : 1 ≤ sylvester k - 1 := by omega
    have : 2 * 1 ≤ sylvester k * (sylvester k - 1) :=
      Nat.mul_le_mul ih h1
    simp only [sylvester]
    omega

theorem sylvester_pos (k : ℕ) : 0 < sylvester k :=
  lt_of_lt_of_le (by norm_num) (sylvester_two_le k)

/-- **L8.2 (telescoping product):** `y₀ y₁ ⋯ y_{k−1} = y_k − 1`.
This is the key identity behind the Egyptian-fraction property; it follows
since `y_{k+1} − 1 = y_k (y_k − 1)`. -/
theorem prod_sylvester (k : ℕ) :
    ∏ i ∈ Finset.range k, sylvester i = sylvester k - 1 := by
  induction k with
  | zero => simp [sylvester]
  | succ k ih =>
    rw [Finset.prod_range_succ, ih]
    show (sylvester k - 1) * sylvester k = sylvester (k + 1) - 1
    simp only [sylvester]
    rw [Nat.add_sub_cancel]
    exact Nat.mul_comm _ _

/-- **L8.3 (Egyptian fractions / unit-fraction identity):**
`∑_{i<k} 1/yᵢ = 1 − 1/(y_k − 1)`.  In particular the reciprocals of the
Sylvester numbers greedily approach 1 from below, and replacing the last term
`1/y_{k}` by `1/(y_k − 1)` gives exactly 1.  [Sk96] §4. -/
theorem sylvester_sum_inv (k : ℕ) :
    ∑ i ∈ Finset.range k, (1 : ℚ) / sylvester i
      = 1 - 1 / ((sylvester k : ℚ) - 1) := by
  induction k with
  | zero => norm_num [sylvester]
  | succ k ih =>
    rw [Finset.sum_range_succ, ih]
    have h2 : 2 ≤ sylvester k := sylvester_two_le k
    have hcast : ((sylvester (k + 1) : ℚ)) - 1
        = (sylvester k : ℚ) * ((sylvester k : ℚ) - 1) := by
      simp only [sylvester]
      push_cast [Nat.cast_sub (by omega : 1 ≤ sylvester k)]
      ring
    rw [hcast]
    have hy : (1 : ℚ) < (sylvester k : ℚ) := by
      exact_mod_cast (by omega : 1 < sylvester k)
    have hne : (sylvester k : ℚ) ≠ 0 := by linarith
    have hne1 : (sylvester k : ℚ) - 1 ≠ 0 := by linarith
    field_simp
    ring

/-! ## The extremal weight systems in dimension 5 ([SS18] §2) -/

/-- The maximal-degree IP weight system for `n = 6`, in normalized
(`∑ qᵢ = 1`) form: `q = (1/2, 1/3, 1/7, 1/43, 1/1807, 1/3263442)`.
Note the *last* entry is `1/(y₅ − 1) = 1/3263442`, not `1/y₅`: the identity
L8.3 with `k = 5` makes the sum exactly 1.  Clearing denominators gives the
integer weight system of degree `d = lcm = 3263442 = 1806·1807`. -/
noncomputable def qct6 : V 6 :=
  ![1/2, 1/3, 1/7, 1/43, 1/1807, 1/3263442]

/-- `3263442 = 1806 · 1807` — the maximal degree factors through the
Sylvester sequence (`1806 = y₄ − 1 = 2·3·7·43`, `1807 = y₄`). -/
theorem max_degree_factorization : 3263442 = 1806 * 1807 := by norm_num

theorem qct6_pos : ∀ i, 0 < qct6 i := by
  intro i; fin_cases i <;> norm_num [qct6]

/-- **L8.5: the candidate weight system is normalized**, `∑ qᵢ = 1`
(this is L8.3 with `k = 5`, verified directly by rational arithmetic). -/
theorem qct6_sum : ∑ i, qct6 i = 1 := by
  norm_num [qct6, Fin.sum_univ_succ, Matrix.cons_val_zero, Matrix.cons_val_succ]

/-- The second extremal weight system of [SS18] (maximal degree among weight
systems with the last two weights equal): `(1/2, 1/3, 1/7, 1/43, 1/3612, 1/3612)`,
of degree `3612 = 2·1806`. -/
noncomputable def qlt6 : V 6 :=
  ![1/2, 1/3, 1/7, 1/43, 1/3612, 1/3612]

theorem qlt6_pos : ∀ i, 0 < qlt6 i := by
  intro i; fin_cases i <;> norm_num [qlt6]

theorem qlt6_sum : ∑ i, qlt6 i = 1 := by
  norm_num [qlt6, Fin.sum_univ_succ, Matrix.cons_val_zero, Matrix.cons_val_succ]

/-- **T8.4 (maximal degree in dimension 5) — stated, not formalized.**

Every IP weight system with 6 positive integer weights `wᵢ` (gcd 1) has
degree `∑ wᵢ ≤ 3263442`, with equality for
`w = (1631721, 1087814, 466206, 75894, 1806, 1)`.

Paper proof ([Sk96] Prop. 4.2 / [SS18] §2): for an IP weight system the
normalized weights `qᵢ = wᵢ/d` satisfy `qᵢ ≥ 1/yᵢ`-type constraints coming
from the existence of interior lattice points; the worst case is the greedy
Egyptian fraction decomposition of 1, i.e. the Sylvester sequence.  This is a
complexity bound on the enumeration, *not* a correctness ingredient —
`algorithm_complete` does not depend on it — so we record it as a documented
gap rather than formalize the (intricate, purely arithmetic) induction. -/
theorem max_degree_dim5 (w : Fin 6 → ℕ) (hw : ∀ i, 0 < w i)
    (hgcd : Finset.univ.gcd w = 1)
    (hIP : IsIPWeightSystem (fun i => (w i : ℝ))) :
    ∑ i, w i ≤ 3263442 := by
  sorry

end Refpoly
