/**
 * harness_simd_transpose.c — CBMC memory-safety harness for the AVX-512
 * SoA-transpose hull scan (Plan 2.7, refpoly-5d PALP 44cb7e5, Vertex.c).
 *
 * The shipping (default-on) SIMD path added new heap + pointer surface that the
 * original Frama-C Eva run never saw:
 *   - palp_xt_begin:      g_xt = malloc(sizeof(Long)*5*np); writes g_xt[k*np+j].
 *   - eval_eq_block8_xt:  loads 8 lanes at g_xt[k*np+j0]; needs j0+8 <= np.
 *   - FE_Search_Bad_Eq:   for(jb=0; jb+8<=np; jb+=8) block; scalar tail [jb,np).
 *
 * We reproduce the exact index arithmetic and loop bounds with scalar-equivalent
 * accesses (the _mm512 load of 8 int64 touches exactly g_xt[k*np+j0 .. +7]) and
 * let CBMC's --bounds-check / --pointer-check prove NO out-of-bounds access to
 * the malloc'd g_xt buffer or the point list, for every np in [1, NP_MAX] and
 * every reachable j0.  Value-equivalence of the SIMD vs scalar arithmetic is a
 * separate concern, covered bit-for-bit by the golden NF regression.
 *
 * We enumerate representative concrete np covering every block/tail shape:
 *   1  (below MIN, pure tail),  7 (no full block),  8 (one block, no tail),
 *   9  (block + tail),  16 (two blocks),  17 (two blocks + tail).
 * Concrete np keeps the malloc sizes concrete (fast + sound for those shapes);
 * the fully-general "for all np" bound is discharged by WP on palp_xt_begin.
 *
 * Run: cbmc harness_simd_transpose.c --function harness \
 *      --bounds-check --pointer-check --unwind 18 --unwinding-assertions
 */
#include <stdint.h>
#include <stdlib.h>

typedef long Long;
#define DIM 5

Long nondet_Long(void);

/* One (concrete-np) instance of transpose-build + block/tail scan. */
static void check_np(long np) {
    /* Point list _P->x : np points of DIM contiguous coords (AoS). */
    Long (*X)[DIM] = malloc(sizeof(Long[DIM]) * (size_t)np);
    __CPROVER_assume(X != 0);

    /* ── palp_xt_begin: build the SoA transpose into a 5*np buffer ──────── */
    Long *g_xt = malloc(sizeof(Long) * (size_t)(DIM * np));
    __CPROVER_assume(g_xt != 0);
    for (long j = 0; j < np; j++)
        for (int k = 0; k < DIM; k++)
            g_xt[k * np + j] = X[j][k];          /* write @ k*np+j < 5*np */

    /* ── FE_Search_Bad_Eq block loop: guard jb+8<=np == block precondition ─
       Memory safety depends only on indices, not values, so we merely *touch*
       each address the SIMD load/store would; --bounds-check fires on the
       access itself.  (Arithmetic on symbolic values is irrelevant here and
       only inflates the solver.) */
    volatile Long sink = 0;
    long jb = 0;
    for (; jb + 8 <= np; jb += 8) {
        for (int lane = 0; lane < 8; lane++)     /* eval_eq_block8_xt lanes */
            for (int k = 0; k < DIM; k++)
                sink = g_xt[k * np + jb + lane];  /* load @ k*np+jb+lane */
        for (int m = (jb == 0 ? 1 : 0); m < 8; m++)
            sink = X[jb + m][0];                 /* AoS read @ jb+m < np */
    }

    /* ── scalar tail: remaining points [jb, np) via the AoS list ─────────── */
    for (long i = (jb == 0 ? 1 : jb); i < np; i++)
        sink = X[i][0];                          /* AoS read @ i < np */
    (void)sink;

    free(g_xt);
    free(X);
}

void harness() {
    static const long NPS[] = {1, 7, 8, 9, 16, 17};
    for (int t = 0; t < (int)(sizeof(NPS) / sizeof(NPS[0])); t++)
        check_np(NPS[t]);
}
