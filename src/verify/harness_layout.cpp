/**
 * harness_layout.cpp — CBMC harness for MergeRecord binary layout (Plan 1.4)
 *
 * Verifies struct layout assumptions that the checkpoint I/O relies on.
 *
 * Run: cbmc harness_layout.cpp --function harness --cpp11
 *
 * Note: Uses __CPROVER_assert directly instead of cassert to avoid
 * CBMC issues with __builtin_FILE/__builtin_LINE in libstdc++ assert.
 *
 * Assumptions: x86-64 Linux with standard alignment rules.
 */
#include <cstddef>
#include <cstdint>
#include "classifier_types.h"

void harness() {
    /* NOTE ON ABSOLUTE SIZE: the exact 80-byte size (PolytopeInfo == 64) is a
       tail-padding fact of the real GCC ABI.  CBMC's C++ frontend under-models
       tail padding (it computes sizeof(PolytopeInfo)==58, MergeRecord==74), so
       the absolute size is proved instead by a compile-time static_assert in
       classifier.cpp against the *real* compiler.  Here we verify the
       model-independent invariants: field order and inter-member offsets. */
    __CPROVER_assert(sizeof(Hash128) == 16, "Hash128 is 16 bytes");
    __CPROVER_assert(sizeof(MergeRecord) == sizeof(Hash128) + sizeof(PolytopeInfo),
        "MergeRecord has no inter-member padding");

    /* Offset checks via pointer arithmetic */
    MergeRecord r;
    char *base = (char *)&r;
    char *key_ptr  = (char *)&r.key;
    char *info_ptr = (char *)&r.info;

    __CPROVER_assert(key_ptr == base,          "MergeRecord::key is at offset 0");
    __CPROVER_assert(info_ptr == base + 16,    "MergeRecord::info is at offset 16");
    __CPROVER_assert(info_ptr - key_ptr == 16, "info follows key with no gap");

    /* count is the first info field (offset 16) — the merge sums it in place,
       and the k-way/merge harnesses assume it lives at info offset 0. */
    __CPROVER_assert((char *)&r.info.count == info_ptr,
        "PolytopeInfo::count is the first info field");
    /* source_index (the field that grew the record 72->80) sits right after. */
    __CPROVER_assert((char *)&r.info.source_index == info_ptr + 8,
        "PolytopeInfo::source_index at info offset 8");
}
