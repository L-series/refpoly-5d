/**
 * palp_globals.c — Definitions for PALP's global I/O symbols.
 *
 * When PALP is compiled as a library (no main() from poly.c etc.),
 * the `inFILE` and `outFILE` symbols have no definition.  This file
 * provides them.  They are set to valid file pointers by palp_init()
 * in palp_api.h.
 */
#include <stdio.h>
#include <setjmp.h>

FILE *inFILE  = NULL;
FILE *outFILE = NULL;

/* r-maximality abort guard (declared extern in Global.h).  Defined here so the
   palp/palp_max libraries and the tools share one definition.  __thread to
   match PALP_THREADSAFE; harmless for single-threaded use. */
#ifdef PALP_THREADSAFE
__thread jmp_buf palp_max_abort_env;
__thread int     palp_max_abort_armed = 0;
#else
jmp_buf palp_max_abort_env;
int     palp_max_abort_armed = 0;
#endif
