#!/usr/bin/env bash
# build.sh — Build the CPU-only polytope classifier.
#
# Usage:
#   ./build.sh            # optimised cmake build -> build/classifier
#   ./build.sh clean      # remove build artefacts
#
# Requires Arrow + Parquet C++ (e.g. `conda install -c conda-forge arrow-cpp
# parquet` or a system libarrow-dev/libparquet-dev) discoverable by CMake, and
# the PALP submodule checked out at the repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

if [[ "${1:-build}" == "clean" ]]; then
    rm -rf "$BUILD_DIR"
    echo "removed $BUILD_DIR"
    exit 0
fi

GEN=()
command -v ninja >/dev/null 2>&1 && GEN=(-GNinja)

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${GEN[@]}"
cmake --build "$BUILD_DIR" --parallel "$(nproc)"

echo ""
echo "Binary: $BUILD_DIR/classifier"
echo ""
echo "Examples:"
echo "  # benchmark on 100k rows from a parquet dir"
echo "  $BUILD_DIR/classifier --input ./data/ws-5d --output ./results --benchmark 100000"
echo "  # process a file range across runners"
echo "  $BUILD_DIR/classifier --input ./data/ws-5d --output ./results --start 0 --end 999 --threads 32"
