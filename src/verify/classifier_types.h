/**
 * classifier_types.h — Extracted types and functions for formal verification.
 *
 * This header reproduces the exact definitions from classifier.cpp so that
 * verification harnesses can include them without pulling in the full
 * classifier (which depends on Arrow, Parquet, PALP, etc.).
 *
 * IMPORTANT: These definitions must be kept in sync with classifier.cpp.
 * Any change to Hash128, PolytopeInfo, MergeRecord, key_less, or
 * hash_normal_form in classifier.cpp must be mirrored here.
 */
#ifndef CLASSIFIER_TYPES_H
#define CLASSIFIER_TYPES_H

#include <cstddef>
#include <cstdint>
#include <cstring>

struct Hash128 {
    uint64_t lo, hi;

    bool operator==(const Hash128 &o) const {
        return lo == o.lo && hi == o.hi;
    }
};

struct Hash128Hasher {
    size_t operator()(const Hash128 &h) const {
        return static_cast<size_t>(h.lo);
    }
};

/* Slim per-polytope record — mirrors classifier.cpp:148 (schema v2, 80B record).
   NOTE: kept byte-for-byte in sync with classifier.cpp::PolytopeInfo.  The
   `source_index` field (added when the record was slimmed 320B->80B) is what
   grew MergeRecord from 72 to 80 bytes; the paper's "72 bytes" predates it. */
struct PolytopeInfo {
    uint64_t count;               /* @0  */
    int64_t  source_index;        /* @8  */
    int32_t  weights[6];          /* @16 */
    int16_t  vertex_count;        /* @40 */
    int16_t  facet_count;         /* @42 */
    int32_t  point_count;         /* @44 */
    int32_t  dual_point_count;    /* @48 */
    int16_t  h11, h12, h13;       /* @52 ; 2B tail pad -> sizeof 64 */
};

struct MergeRecord {
    Hash128      key;
    PolytopeInfo info;
};

static bool key_less(const Hash128 &a, const Hash128 &b) {
    if (a.hi != b.hi) return a.hi < b.hi;
    return a.lo < b.lo;
}

/* POLY_Dmax and VERT_Nmax from PALP configuration */
#ifndef POLY_Dmax
#define POLY_Dmax 5
#endif
#ifndef VERT_Nmax
#define VERT_Nmax 64
#endif

/* Long is PALP's integer type (long on x86-64) */
typedef long Long;

#endif /* CLASSIFIER_TYPES_H */
