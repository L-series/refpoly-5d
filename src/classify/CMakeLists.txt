cmake_minimum_required(VERSION 3.20)
project(refpoly5d_classifier C CXX)

set(CMAKE_C_STANDARD   11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# CPU-only port. The CUDA geometry backend from the source repo is intentionally
# not built here (see memory: CPU-only focus); the classifier's CUDA paths are
# compiled out via CLASSIFIER_ENABLE_CUDA=0 and fall back to the CPU backend.

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# ── Optional optimizations (both off by default) ───────────────────────────
#
#  Profile-guided optimization. Two-phase: configure with PGO=generate, build,
#  run a representative workload (writes .gcda into PGO_DIR), then reconfigure
#  the SAME build dir with PGO=use and rebuild. build.sh --pgo drives this.
#  The single-thread hot path is branchy (Find_Equations' early-exit point
#  scans), so real branch frequencies help block layout/inlining/unrolling.
set(PGO "" CACHE STRING "PGO stage: '' (off), 'generate', or 'use'")
set(PGO_DIR "${CMAKE_BINARY_DIR}/pgo-data" CACHE PATH "PGO profile data directory")
set(PGO_FLAGS "")
if(PGO STREQUAL "generate")
  set(PGO_FLAGS -fprofile-generate=${PGO_DIR})
elseif(PGO STREQUAL "use")
  # -fprofile-correction/-Wno-missing-profile tolerate LTO inlining reshaping.
  set(PGO_FLAGS -fprofile-use=${PGO_DIR} -fprofile-partial-training
                -fprofile-correction -Wno-missing-profile -Wno-coverage-mismatch)
elseif(NOT PGO STREQUAL "")
  message(FATAL_ERROR "PGO must be '', 'generate', or 'use' (got '${PGO}')")
endif()

#  LLL + Fincke-Pohst dim-5 point walk (PALP fork; Coord.c #ifdef LLLFP_WALK).
#  Replaces the triangular lattice-point enumeration on heavy candidates; falls
#  back to the (proven, finite) triangular walk past a node cap. Off by default;
#  correctness is gated by `make test` (nf_dump vs golden NFs).
option(ENABLE_LLLFP "Enable PALP's LLL+Fincke-Pohst dim-5 point walk" OFF)

#  SIMD (AVX-512) the dim-5 convex-hull point scans (Vertex.c, PALP_SIMD_SCAN).
#  Vectorises only the dot-product arithmetic in FE_Search_Bad_Eq /
#  Search_New_Vertex; the arg-min/early-exit decision logic is unchanged, so the
#  normal form is bit-identical (gated by `make test`). Auto-falls back to scalar
#  where AVX-512F+DQ are unavailable. ON by default; -march=native must supply
#  the ISA (it does on the Zen4 target).
option(ENABLE_SIMD_SCAN "SIMD-vectorise the dim-5 convex-hull point scans" ON)

# ── PALP as a static library ──────────────────────────────────────────────
# Compile only the sources needed for the NF computation path. The tools with
# their own main() (poly.c / cws.c / nef.c / mori.c / class.c) are excluded.
set(PALP_DIR "${CMAKE_SOURCE_DIR}/../../PALP")

set(PALP_SOURCES
    ${PALP_DIR}/Coord.c
    ${PALP_DIR}/Rat.c
    ${PALP_DIR}/Vertex.c
    ${PALP_DIR}/Polynf.c
    ${PALP_DIR}/LG.c
)

# PALP build defines for the 5D classification envelope:
#  POLY_Dmax=5        → 5-dimensional polytopes
#  PALP_FAST_ASSERT   → keep side effects in assert() without aborting
#  PALP_THREADSAFE    → use __thread for static scratch buffers
#  CEQ_Nmax=2048      → candidate equation list; default 64 is too small for 5D
set(PALP_DEFINES
    -DPOLY_Dmax=5
    -DPALP_FAST_ASSERT
    -DPALP_THREADSAFE
    -DCEQ_Nmax=2048
)

add_library(palp STATIC ${PALP_SOURCES})
target_compile_options(palp PRIVATE
    -O3 -march=native -flto -funroll-loops -fomit-frame-pointer -w ${PGO_FLAGS})
target_compile_definitions(palp PRIVATE ${PALP_DEFINES}
    $<$<BOOL:${ENABLE_LLLFP}>:LLLFP_WALK>
    $<$<BOOL:${ENABLE_SIMD_SCAN}>:PALP_SIMD_SCAN>)
target_include_directories(palp PUBLIC ${PALP_DIR})

# PALP's global I/O symbols (inFILE, outFILE) need a definition when it is used
# as a library rather than via one of the tool main()s.
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/palp_globals.c"
    "${CMAKE_BINARY_DIR}/palp_globals.c"
    COPYONLY
)
target_sources(palp PRIVATE "${CMAKE_BINARY_DIR}/palp_globals.c")

# ── Dependencies ───────────────────────────────────────────────────────────
find_package(Arrow   REQUIRED)
find_package(Parquet REQUIRED)
find_package(Threads REQUIRED)

# ── Main executable ────────────────────────────────────────────────────────
add_executable(classifier classifier.cpp geometry_backend.cpp)

target_compile_options(classifier PRIVATE
    -O3 -march=native -flto -funroll-loops
    ${PALP_DEFINES} ${PGO_FLAGS}
)
target_compile_definitions(classifier PRIVATE CLASSIFIER_ENABLE_CUDA=0)

target_include_directories(classifier PRIVATE
    ${PALP_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(classifier PRIVATE
    palp
    Arrow::arrow_shared
    Parquet::parquet_shared
    Threads::Threads
    -flto
)
target_link_options(classifier PRIVATE ${PGO_FLAGS})

# ── nf_dump diagnostic ─────────────────────────────────────────────────────
# Prints the NF the classifier computes per row, for the golden regression gate
# (tests/test_nf_golden.py --classifier). Same PALP-library path, no Arrow dep.
add_executable(nf_dump nf_dump.cpp)
target_compile_options(nf_dump PRIVATE
    -O3 -march=native -flto -funroll-loops
    ${PALP_DEFINES} ${PGO_FLAGS}
)
target_include_directories(nf_dump PRIVATE ${PALP_DIR} ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(nf_dump PRIVATE palp -flto)
target_link_options(nf_dump PRIVATE ${PGO_FLAGS})

# ── add_nf enrichment tool ─────────────────────────────────────────────────
# Re-runs the PALP NF for each unique polytope and appends an nf_vertices column
# to unique_polytopes.parquet. Schema-agnostic (AddColumn on the input table),
# so it works on both reflexive and --non-reflexive classifier output.
add_executable(add_nf add_nf.cpp)
target_compile_options(add_nf PRIVATE
    -O3 -march=native -flto -funroll-loops
    ${PALP_DEFINES} ${PGO_FLAGS}
)
target_include_directories(add_nf PRIVATE ${PALP_DIR} ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(add_nf PRIVATE
    palp
    Arrow::arrow_shared
    Parquet::parquet_shared
    Threads::Threads
    -flto
)
target_link_options(add_nf PRIVATE ${PGO_FLAGS})

install(TARGETS classifier nf_dump add_nf RUNTIME DESTINATION bin)
