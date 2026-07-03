#!/usr/bin/env bash
# build.sh — Build the CPU-only polytope classifier.
#
# Usage:
#   ./build.sh                 # optimised cmake build -> build/classifier
#   ./build.sh clean           # remove build artefacts
#   ./build.sh --lllfp         # enable PALP's LLL+Fincke-Pohst dim-5 point walk
#   ./build.sh --pgo           # two-phase profile-guided build (generate->train->use)
#   ./build.sh --pgo --lllfp   # flags compose
#
# Requires Arrow + Parquet C++ (e.g. `conda install -c conda-forge arrow-cpp
# parquet` or a system libarrow-dev/libparquet-dev) discoverable by CMake, and
# the PALP submodule checked out at the repo root.
#
# --pgo trains on bench/corpus/corpus_100k.txt by default; override the training
# workload with REFPOLY_PGO_TRAIN=/path/to/parquet-dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

if [[ "${1:-build}" == "clean" ]]; then
    rm -rf "$BUILD_DIR"
    echo "removed $BUILD_DIR"
    exit 0
fi

PGO=0
CMAKE_EXTRA=()
for arg in "$@"; do
    case "$arg" in
        --pgo)     PGO=1 ;;
        --lllfp)   CMAKE_EXTRA+=(-DENABLE_LLLFP=ON) ;;
        --no-simd) CMAKE_EXTRA+=(-DENABLE_SIMD_SCAN=OFF) ;;
        build)     ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

GEN=()
command -v ninja >/dev/null 2>&1 && GEN=(-GNinja)

# The classifier links Arrow/Parquet shared libs from the conda env; point CMake
# at its config packages and make sure the loader can find them at runtime
# (needed for the PGO training run below).
PREFIX_ARGS=()
if [[ -n "${CONDA_PREFIX:-}" ]]; then
    export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
    PREFIX_ARGS=(-DCMAKE_PREFIX_PATH="$CONDA_PREFIX")
fi

configure() {  # $1 = PGO stage ('', generate, use)
    cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release -DPGO="$1" \
        "${PREFIX_ARGS[@]}" "${CMAKE_EXTRA[@]}" "${GEN[@]}"
}
compile() { cmake --build "$BUILD_DIR" --parallel "$(nproc)"; }

if [[ "$PGO" == "0" ]]; then
    configure ""
    compile
else
    echo "=== PGO phase 1/3: build instrumented (generate) ==="
    configure generate
    compile

    echo "=== PGO phase 2/3: train ==="
    TRAIN="${REFPOLY_PGO_TRAIN:-}"
    if [[ -z "$TRAIN" ]]; then
        TRAIN="$BUILD_DIR/pgo-train"
        mkdir -p "$TRAIN"
        if [[ ! -f "$TRAIN/train.parquet" ]]; then
            python3 - "$REPO_ROOT/bench/corpus/corpus_100k.txt" "$TRAIN/train.parquet" <<'PY'
import sys, pyarrow as pa, pyarrow.parquet as pq
rows = [[int(x) for x in l.split()] for l in open(sys.argv[1]) if l.strip()]
cols = {f"weight{c}": pa.array([r[1 + c] for r in rows], pa.int32()) for c in range(6)}
pq.write_table(pa.table(cols), sys.argv[2])
PY
        fi
    fi
    "$BUILD_DIR/classifier" --input "$TRAIN" --output "$BUILD_DIR/pgo-out" --threads 1
    rm -rf "$BUILD_DIR/pgo-out"

    echo "=== PGO phase 3/3: rebuild optimised (use) ==="
    configure use
    compile
fi

echo ""
echo "Binary: $BUILD_DIR/classifier"
