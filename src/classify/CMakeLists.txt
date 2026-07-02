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
    -O3 -march=native -flto -funroll-loops -fomit-frame-pointer -w)
target_compile_definitions(palp PRIVATE ${PALP_DEFINES})
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
    ${PALP_DEFINES}
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

# ── nf_dump diagnostic ─────────────────────────────────────────────────────
# Prints the NF the classifier computes per row, for the golden regression gate
# (tests/test_nf_golden.py --classifier). Same PALP-library path, no Arrow dep.
add_executable(nf_dump nf_dump.cpp)
target_compile_options(nf_dump PRIVATE
    -O3 -march=native -flto -funroll-loops
    ${PALP_DEFINES}
)
target_include_directories(nf_dump PRIVATE ${PALP_DIR} ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(nf_dump PRIVATE palp -flto)

install(TARGETS classifier nf_dump RUNTIME DESTINATION bin)
