/**
 * palp_maxcheck.h — r-maximality test for a reflexive polytope, via PALP.
 *
 * Theory (Kreuzer–Skarke; see latex/notes/ks_classification.tex):
 *   A reflexive polytope P (lattice M) is *r-maximal* iff it is not a proper
 *   reflexive subpolytope of any other reflexive polytope on M.  By max/min
 *   duality this is equivalent to: the polar dual P* is *r-minimal*, i.e. P*
 *   has no proper reflexive subpolytope.  PALP's `Poly_Max_check` implements
 *   exactly this: it dualizes P and runs `Start_Find_Ref_Subpoly` on P*,
 *   returning true iff no proper reflexive subpolytope of P* exists.
 *
 * Input is the primal normal-form vertex matrix as stored in
 * `unique_polytopes_clean.parquet` (`nf`): a row-major int32 matrix of shape
 * [d x nv], so vertex j has coordinates (nf[0*nv+j], .., nf[(d-1)*nv+j]).
 *
 * Compile the PALP sources (incl. Subpoly.c) with the same flags as the
 * classifier: -DPOLY_Dmax=5 -DPALP_FAST_ASSERT -DPALP_THREADSAFE.
 *
 * NOTE: PALP's Subpoly.c uses process-global scratch; this API is intended
 * for single-threaded use (the production run is process-per-core).
 */
#ifndef PALP_MAXCHECK_H
#define PALP_MAXCHECK_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

#include "../../PALP/Global.h"

/* PALP functions we call (Vertex.c / Subpoly.c). */
int  IP_Check(PolyPointList *P, VertexNumList *V, EqList *E);
int  Poly_Max_check(PolyPointList *P, VertexNumList *V, EqList *E);

/* Abort guard armed around Poly_Max_check (Global.h / palp_globals.c). */
extern
#ifdef PALP_THREADSAFE
    __thread
#endif
    jmp_buf palp_max_abort_env;
extern
#ifdef PALP_THREADSAFE
    __thread
#endif
    int palp_max_abort_armed;

/* Result codes for palp_max_check(). */
enum {
    MAXCHK_OVERFLOW    = -3,  /* arrays too small: DEFER, re-run bigger.      *
                              * NOT a classification — must be reprocessed.  */
    MAXCHK_ERR         = -2,  /* bad input (dim/nv out of range)             */
    MAXCHK_NOT_IP      = -1,  /* IP_Check failed: 0 not interior             */
    MAXCHK_NONREF      =  0,  /* IP but not reflexive (some facet c != 1)    */
    MAXCHK_REF_NONMAX  =  1,  /* reflexive, NOT r-maximal                    */
    MAXCHK_REF_MAX     =  2,  /* reflexive AND r-maximal                     */
};

/* Per-process workspace: one PolyPointList reused across calls. */
typedef struct {
    PolyPointList *P;
    VertexNumList  V;
    EqList         E;
    /* geometry read back from the last successful IP_Check, for cross-checks */
    int last_nv;   /* # vertices of P              */
    int last_ne;   /* # facets of P               */
} MaxWorkspace;

static inline MaxWorkspace *maxws_alloc(void) {
    MaxWorkspace *w = (MaxWorkspace *)calloc(1, sizeof(MaxWorkspace));
    if (!w) return NULL;
    w->P = (PolyPointList *)malloc(sizeof(PolyPointList));
    if (!w->P) { free(w); return NULL; }
    return w;
}

static inline void maxws_free(MaxWorkspace *w) {
    if (!w) return;
    free(w->P);
    free(w);
}

/**
 * Test r-maximality of the reflexive polytope whose primal NF vertex matrix
 * is `nf` (row-major, shape [dim x nv]).  Returns one of the MAXCHK_* codes.
 */
static inline int palp_max_check(MaxWorkspace *w, const int *nf, int dim, int nv)
{
    if (dim < 1 || dim > POLY_Dmax || nv < dim + 1 || nv > VERT_Nmax)
        return MAXCHK_ERR;

    PolyPointList *P = w->P;
    P->n  = dim;
    P->np = nv;
    for (int j = 0; j < nv; j++)
        for (int c = 0; c < dim; c++)
            P->x[j][c] = (Long)nf[c * nv + j];   /* row-major [dim x nv] */

    if (!IP_Check(P, &w->V, &w->E))
        return MAXCHK_NOT_IP;

    w->last_nv = w->V.nv;
    w->last_ne = w->E.ne;

    /* Reflexivity: every facet at lattice distance 1 from the interior 0. */
    for (int i = 0; i < w->E.ne; i++)
        if (w->E.e[i].c != 1)
            return MAXCHK_NONREF;

    /* Arm the abort guard: if the dual-subpolytope search overflows PALP's
       arrays, longjmp back here and DEFER (MAXCHK_OVERFLOW) rather than
       returning a (possibly wrong) classification.  Deferred polytopes are
       re-run with larger arrays until the test completes — no polytope is
       ever decided from an overflow. */
    palp_max_abort_armed = 1;
    if (setjmp(palp_max_abort_env)) {
        palp_max_abort_armed = 0;
        return MAXCHK_OVERFLOW;
    }
    int rmax = Poly_Max_check(P, &w->V, &w->E);
    palp_max_abort_armed = 0;
    return rmax ? MAXCHK_REF_MAX : MAXCHK_REF_NONMAX;
}

static inline void maxchk_init_io(void) {
    extern FILE *inFILE, *outFILE;
    inFILE  = fopen("/dev/null", "r");
    outFILE = fopen("/dev/null", "w");
}

#ifdef __cplusplus
}
#endif
#endif /* PALP_MAXCHECK_H */
