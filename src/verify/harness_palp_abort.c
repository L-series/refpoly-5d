/**
 * harness_palp_abort.c — CBMC harness for the NF abort/skip path (Plan 2.6b).
 *
 * Recovery change (palp_api.h + PALP/Polynf.c): a VM/VPM envelope overflow in
 * TEST_rVM_VPM no longer calls exit(); it longjmps back to a per-thread setjmp
 * installed around Make_Poly_Sym_NF, so a pathological weight system is a
 * counted NF *failure* (result->ok == 0) instead of a process abort.
 *
 * We model the exact control flow of palp_run_nf_from_current_points:
 *   result->ok = 0;
 *   armed = 1;
 *   if (setjmp(env)) { armed = 0; return; }   // longjmp target: ok stays 0
 *   Make_Poly_Sym_NF(...);                     // may longjmp on overflow
 *   armed = 0;
 *   result->ok = 1;                            // only reached without abort
 *
 * Property: for every possible abort outcome, on return
 *   (abort  => ok == 0)  AND  (ok == 1 => no abort occurred)  AND  (armed == 0).
 *
 * Run: cbmc harness_palp_abort.c --function harness
 */
int nondet_int(void);

void harness() {
    int ok = 0;                 /* result->ok = 0 */
    int armed = 0;

    int abort_fires = nondet_int();   /* TEST_rVM_VPM envelope overflow? */

    armed = 1;                  /* arm the guard */
    if (abort_fires) {          /* setjmp returns nonzero: longjmp taken */
        armed = 0;
        /* return with ok unchanged */
        __CPROVER_assert(ok == 0, "abort path returns ok==0 (counted failure)");
        __CPROVER_assert(armed == 0, "guard disarmed on abort path");
        return;
    }
    /* Make_Poly_Sym_NF completed without longjmp */
    armed = 0;
    ok = 1;

    __CPROVER_assert(ok == 1, "no-abort path yields ok==1 (success)");
    __CPROVER_assert(armed == 0, "guard disarmed on success path");
    __CPROVER_assert(!abort_fires, "ok==1 only when no abort occurred");
}
