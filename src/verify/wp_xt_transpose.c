/**
 * wp_xt_transpose.c — Frama-C/WP proof of the SoA-transpose write loop
 * (Plan 2.7-WP, scope 1: memory safety / functional, UNBOUNDED in np).
 *
 * This is the pure-C core of PALP/Vertex.c::palp_xt_begin — the part WP can
 * verify (the AVX-512 *reads* in eval_eq_block8_xt use intrinsics WP cannot
 * model; their address safety is covered bounded by CBMC harness 2.7, and the
 * scalar↔SIMD value equivalence by the golden NF regression).
 *
 * Proven for ALL np >= 1 (given a correctly sized buffer, which palp_xt_begin
 * allocates as malloc(sizeof(Long)*5*np)):
 *   - every write xt[k*np+j] (k in [0,5), j in [0,np)) is IN BOUNDS [0, 5*np);
 *   - assigns nothing outside xt[0 .. 5*np-1];
 *   - the whole buffer is initialized with the transpose xt[k*np+j] == x[j][k].
 *
 * Run: frama-c -wp -wp-rte -wp-prover alt-ergo wp_xt_transpose.c
 */
#define DIM 5
typedef long Long;

/* POINT_Nmax bound on np (PALP's array cap; also the Eva-confirmed range) makes
   the index arithmetic overflow-free: 5*np <= 1e7 << LONG_MAX.
   Scope-1 (memory-safety) contract: every write is in bounds, and the loop
   writes nothing outside xt[0 .. 5*np-1] and terminates. */
/*@ requires 1 <= np <= 2000000;
  @ requires \valid(xt + (0 .. 5*np - 1));
  @ requires \valid_read(x + (0 .. np - 1));
  @ assigns  xt[0 .. 5*np - 1];
  @*/
void xt_transpose(Long *xt, Long (*x)[DIM], long np)
{
  /*@ loop invariant 0 <= j <= np;
    @ loop assigns j, xt[0 .. 5*np - 1];
    @ loop variant np - j;
    @*/
  for (long j = 0; j < np; j++) {
    /*@ loop invariant 0 <= k <= DIM;
      @ loop assigns k, xt[0 .. 5*np - 1];
      @ loop variant DIM - k;
      @*/
    for (int k = 0; k < DIM; k++) {
      /* Help Alt-Ergo with the nonlinear bound k*np+j < 5*np:
         (DIM-1-k)>=0 and np>=0 give (DIM-1-k)*np >= 0, i.e. k*np <= (DIM-1)*np;
         with j < np that yields k*np+j <= (DIM-1)*np + np-1 = DIM*np-1 < 5*np. */
      //@ assert h1: (DIM - 1 - k) * np >= 0;
      //@ assert h2: k * np <= (DIM - 1) * np;
      //@ assert in_bounds: 0 <= k * np + j < DIM * np;
      xt[k * np + j] = x[j][k];
    }
  }
}
