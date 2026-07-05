# Formal Verification Ledger — refpoly-5d

**Purpose.** A living record of *what is proven*, *by which tool*, *against which
version of the code*, and *what remains to be proved*, across all verification
layers of the pipeline. Updated as proofs are discharged.

- **Scope of "the code":** the classifier that actually shipped and produced the
  catalogue — `src/classify/classifier.cpp`, `src/classify/palp_api.h`, and PALP
  at submodule commit **44cb7e5** (AVX-512 hull scan, default-on).
- **Toolchain (local, no-root):** CBMC 6.10.0 (`~/.local/bin/cbmc`); Frama-C
  (Eva + WP) + Alt-Ergo/Why3 via a user opam switch `framac` (`~/.opam`).
- **Status legend:** ✅ proven · 🟡 partial / bounded · ⏳ in progress ·
  ❌ not yet · ⚠️ stale (verified against older code).

Last updated: 2026-07-05.

---

## 0. Summary dashboard

| Layer | Tool | Proven | Remaining |
|---|---|---|---|
| Classification **theory** | Lean 4 / Mathlib 4.30.0 | headline `algorithm_enumerates_reflexive` + backbone (0 sorries) | 6 documented sorries (2 axiomatized GoN inputs, 4 deferred) |
| **Record / merge** invariants | CBMC | 1.1–1.7, 1.9 (all pass) | absolute size moved to `static_assert` (real ABI) |
| **PALP determinism** | CBMC | 2.5 `Sort_VL` no-ties total order | — |
| **PALP wrapper** | CBMC | 2.6 struct population + **2.6b abort/skip path** ✅ | — |
| **SIMD hull scan (new code)** | CBMC | **2.7 SoA transpose + block/tail bounds** ✅ | fully-general `np` → WP |
| **PALP memory safety** | Frama-C Eva | runs on 44cb7e5 (626 alarms @ prec-1, over-approx) | 🟡 higher-precision sure-alarm audit |
| **SIMD transpose, unbounded** | Frama-C **WP** + ACSL | **30/30 goals proved** (mem-safety, no-overflow, terminating) ✅ | functional content invariants (scope 2) |
| **NF functional correctness** | Frama-C WP / Lean | — | scope-2 contracts (research-grade) ❌ |

---

## 1. Lean layer — classification theory  ✅ (backbone) + 6 sorries

Built clean: `lake build` → **8485 jobs, 0 errors** (Lean/Mathlib v4.30.0).
**0 `axiom` declarations. Exactly 6 `sorry`s**, all off the algorithm-correctness
backbone:

| Sorry (file:decl-line) | Theorem | Kind |
|---|---|---|
| Finiteness.lean:48 | `hensley_volume_bound` | axiomatized geometry-of-numbers input |
| Finiteness.lean:64 | `lagarias_ziegler_box` | axiomatized geometry-of-numbers input |
| Minimal.lean:211 | `minimal_structure` (KS Lemma 1) | **genuine theoretical gap** |
| PyramidLemma.lean:93 | `pyramid_lemma_dim_le_four` | deferred (not needed; d=5 uses the proved counterexample) |
| Sylvester.lean:157 | `max_degree_dim5` | complexity bound, not a correctness ingredient |
| WeightSystem.lean:362 | `ip_half_reduction` | search-structuring, off critical path |

**Sorry-free & building:** `Basic`, `MaxMin`, `Algorithm`, `Classification`.
Headline results present and proved: `algorithm_enumerates_reflexive`,
`classification_coverage`, `maximal_reflexive_covered_by_minimalIP_container`,
`algorithm_complete`, `branch_finite`.

*Paper delta:* the Lean section is accurate; only the `[link to lean project]`
citation placeholder is unfilled.

---

## 2. CBMC layer — implementation invariants

Harnesses live in `src/verify/`, run via `run_verification.sh` (needs `cbmc`
on `PATH`). Each harness is self-contained (copies the routine under test);
shared types are in `classifier_types.h`, kept byte-for-byte in sync with
`classifier.cpp`.

| ID | Harness | Property | vs current code | CBMC 6.10.0 |
|---|---|---|---|---|
| 1.1 | `harness_key_less` | strict weak order on Hash128 | identical | ✅ PASS |
| 1.2 | `harness_hasher` | hasher consistent with `==` | identical | ✅ PASS |
| 1.3 | `harness_hash_nf` | NF byte layout / bounds | identical | ✅ PASS |
| 1.4 | `harness_layout` | record field order & offsets | **updated to slim 80 B** | ✅ PASS |
| 1.5 | `harness_merge_dedup` | 2-way merge count preservation | coalescing identical | ✅ PASS |
| 1.6 | `harness_kway_merge` | k-way merge count preservation | coalescing identical | ✅ PASS |
| 1.7 | `harness_sorted_reader` | reader visits each record once, in order | identical | ✅ PASS |
| 1.9 | `harness_accounting` | processed = unique + dup + failed | identity enforced at runtime | ✅ PASS |
| 2.5 | `harness_sort_vl` | `Sort_VL` comparator: total order, no ties | identical | ✅ PASS |
| 2.6 | `harness_palp_wrapper` | wrapper WS-struct population | struct-pop identical | ✅ PASS |
| 2.6b | `harness_palp_abort` | abort path → `ok==0`; `ok==1` ⇒ no abort | **new (recovery)** | ✅ PASS |
| 2.7 | `harness_simd_transpose` | AVX-512 SoA transpose + block/tail: no OOB | **new (SIMD)** | ✅ PASS |

**1.4 drift fixed (this session).** `classifier_types.h` had a hand-maintained
72 B record (`first_weights[6]`, no `source_index`) — the source of the paper's
"72 bytes." Updated to the current slim record (`source_index` added,
`first_weights`→`weights`) = **80 B**. CBMC verifies field order/offsets
(model-independent); the **absolute 80 B size** is proved by a compile-time
`static_assert` in `classifier.cpp` (CBMC under-models struct tail padding —
it computes `sizeof(PolytopeInfo)==58` vs the real GCC ABI's 64).

**Extra (non-paper) `dim5_*` harnesses:** `select_weights`, `prefix_canonical`
PASS; `shard_partition`, `embed_weight`, `selection_order` FAIL under CBMC 6.10
— ⏳ triage (likely stricter 6.10 overflow/bounds checks or unwind depth; not on
the paper's critical path).

### Remaining in the CBMC layer
- ✅ **2.6b** abort/skip path — done (`harness_palp_abort`).
- ✅ **2.7** SIMD SoA transpose + block/tail memory safety — done
  (`harness_simd_transpose`, concrete `np` covering all block/tail shapes; the
  fully-general `np` bound is deferred to WP on the pure-C `palp_xt_begin`).
- Triage the 3 failing `dim5_*` harnesses (not on the paper critical path). ⏳

---

## 3. Frama-C **Eva** — PALP memory safety (abstract interpretation)  ⚠️ stale

`run_eva_palp.sh` runs Eva over `Make_CWS_Points → Find_Equations → Sort_VL →
Make_Poly_Sym_NF` via `eva_palp_driver.c`.

**Re-run on 44cb7e5 (2026-07-06).** Eva now analyzes the shipping PALP with
Frama-C 32.1, once given `-machdep gcc_x86_64` (for `__thread`/GCC extensions)
and `-kernel-warn-key parser:conditional-feature=inactive`.
Run: `frama-c -machdep gcc_x86_64 -eva -eva-precision 1 … -main eva_palp_main`
(command + summary archived in `proofs/eva_44cb7e5_summary.txt`).

- Coverage: 44 functions / 2299 statements reached (91% of reached functions).
- **626 alarms at precision 1** — these are *over-approximation* (orange) alarms
  from fully-symbolic driver inputs at low precision, **not** confirmed bugs.
- The `Vertex.c` alarm locations moved to **~1005+** (was `598`), confirming the
  +147-line SIMD insertion — the paper's `Vertex.c:598` reference is stale.
- Eva **cannot** analyze the AVX-512 path itself (`_mm512_*` intrinsics are
  opaque to it) — which is exactly why the SIMD hot path is covered instead by
  CBMC 2.7 (bounded) and WP (unbounded, §4), the stronger guarantees.

### Remaining
- 🟡 Higher-precision (`-eva-precision 2+`) run with realistically *constrained*
  driver inputs to reproduce the "zero sure (red) alarms under `PALP_FAST_ASSERT`"
  audit; update the paper's alarm counts + line reference from that run.

---

## 4. Frama-C **WP** + ACSL contracts — the new deductive layer

No ACSL contracts existed in either repo (confirmed: 0 markers; the prior
Frama-C use was Eva-only). This layer is **new work**. Two scopes:

### Scope 1 — memory-safety / termination contracts (tractable)  🟡 (core done)
Deductive `requires`/`assigns` + `loop invariant`/`loop variant`, discharged by
**WP + Alt-Ergo 2.6.3**, proving **no OOB / no overflow / termination for all
inputs** (unbounded — stronger than Eva's alarm scan).

| Target | Contract goal | Status |
|---|---|---|
| SoA transpose write loop (`wp_xt_transpose.c`) | writes `xt[k*np+j]` in `[0,5*np)`, no overflow, terminates, `assigns` bounded | ✅ **WP 30/30** |
| SIMD block loop (`_mm512` over `g_xt+k*np+j0`) + scalar tail | `j0+8 ≤ np`; tail covers `[jb,np)` | ✅ CBMC 2.7 (bounded); intrinsics opaque to WP |
| `hash_normal_form` buffer pack | `k = dim*nv ≤ POLY_Dmax*VERT_Nmax` | 🟡 CBMC 1.3; WP contract ⏳ |

The transpose proof needed only two hints for Alt-Ergo's nonlinear arithmetic
(`(DIM-1-k)*np ≥ 0` monotonicity) plus the `np ≤ POINT_Nmax` bound that makes
the index overflow-free. Reproduce: `./run_wp.sh`.

### Scope 2 — functional-correctness contracts (research-grade)  ❌
`ensures` clauses specifying *what* the routine computes:

| Target | Spec | Status / note |
|---|---|---|
| `Sort_VL` | output is a permutation, sorted, deterministic | 🟡 determinism already via CBMC 2.5; WP permutation spec ❌ |
| `Make_Poly_Sym_NF` | result is *the* GL(5,ℤ)-canonical NF (invariance + determinism) | ❌ **not tractable in WP**; the *mathematical* content is the Lean layer's job — WP would only re-prove memory safety + determinism, not canonicity |
| merge (`merge_checkpoints`) | output multiset = ⊎ inputs with counts summed | 🟡 CBMC 1.5/1.6 bound it; a full WP functional contract ❌ |

**Honest scoping.** "Prove everything" is achievable for **Scope 1** (memory
safety of the hot path, unbounded, via WP) and is **already largely covered**
for the algorithmic invariants (CBMC §2) and the *theory* (Lean §1). **Full
functional correctness of the PALP normal form in WP is not realistic** — PALP's
NF is intricate integer linear algebra, and its *correctness as a canonical
form* is a mathematical theorem that belongs in Lean (where GL(n,ℤ)-equivalence
and the classification are already formalized), not in a C deductive prover.
The defensible end-state is: **Lean** proves the math; **CBMC** proves the
discrete invariants; **WP** proves memory safety + termination of the C/SIMD
routines for all inputs; **Eva** provides a second, independent safety check;
the **golden NF regression** ties the SIMD path to the scalar reference bit-for-bit.

---

## 5. What remains — actionable checklist

1. ✅ Local **CBMC 6.10.0** + **Frama-C 32.1 / Alt-Ergo 2.6.3** installed
   user-space (no root; opam `framac` switch).
2. ✅ **Scope-1 WP**: SoA-transpose memory-safety contract discharged (30/30).
3. ✅ **CBMC 2.6b** abort/skip path; ✅ **CBMC 2.7** SoA-transpose bounds.
4. ✅ **CBMC 1.4** fixed to the 80 B record + real-ABI `static_assert`.
5. ✅ **Eva** re-runs on 44cb7e5; 🟡 higher-precision sure-alarm audit pending.
6. ✅ **Paper**: `72→80`, 12-harness table (+2.6b, +2.7), in-tree `src/verify/`
   refs, SIMD/WP paragraph, `[link]` placeholders removed.
7. ⏳ Triage 3 failing `dim5_*` harnesses (off critical path).
8. ⏳ WP contract for `hash_normal_form` buffer pack (scope-1 completion).
9. (long-term) Discharge the 6 Lean sorries — chiefly `minimal_structure`;
   scope-2 functional NF canonicity stays in Lean, not WP.
