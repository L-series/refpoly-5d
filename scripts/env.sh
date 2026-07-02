#!/usr/bin/env bash
# Source this to put the Arrow/Parquet C++ toolchain used to build the
# classifier on PATH/PKG_CONFIG_PATH. Point CONDA_PREFIX at an environment that
# provides arrow-cpp + parquet (e.g. `micromamba create -n refpoly-5d -c
# conda-forge arrow-cpp parquet cmake ninja`). CPU-only; no CUDA vars.
#
#   source scripts/env.sh
#   ./src/classify/build.sh

: "${CONDA_PREFIX:=$HOME/.local/share/micromamba/envs/process-polytopes}"
export CONDA_PREFIX
export PATH="$CONDA_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$CONDA_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "refpoly-5d env: CONDA_PREFIX=$CONDA_PREFIX"
