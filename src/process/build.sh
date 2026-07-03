#!/usr/bin/env bash
# build.sh — Build the standalone parquet post-processing tools.
#
# Usage:
#   ./build.sh          # build -> build/{concat_parquet,merge_computed}
#   ./build.sh clean    # remove build artefacts
#
# Requires Arrow + Parquet C++ discoverable by CMake (e.g. from a conda env;
# CMAKE_PREFIX_PATH is derived from CONDA_PREFIX when set).
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

PREFIX_ARGS=()
if [[ -n "${CONDA_PREFIX:-}" ]]; then
    export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
    PREFIX_ARGS=(-DCMAKE_PREFIX_PATH="$CONDA_PREFIX")
fi

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release \
    "${PREFIX_ARGS[@]}" "${GEN[@]}"
cmake --build "$BUILD_DIR" --parallel "$(nproc)"

echo ""
echo "Binaries: $BUILD_DIR/concat_parquet  $BUILD_DIR/merge_computed"
