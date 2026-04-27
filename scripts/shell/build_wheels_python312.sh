#!/bin/bash
# Build pycolmap wheels for Python 3.12 against CUDA 13.0 and CUDA 12.8.
#
# Each CUDA variant gets its own COLMAP C++ build + install tree, then a
# separate Python wheel.  The CUDA version is embedded in both the wheel
# filename and the package metadata version (PEP 440 local segment), e.g.:
#   pycolmap-4.1.0.dev0+cuda13.0-cp312-cp312-linux_x86_64.whl
#   pip show pycolmap  →  Version: 4.1.0.dev0+cuda13.0
#
# Usage:
#   ./scripts/shell/build_wheels_python312.sh [CUDA_ARCH]
#
# CUDA_ARCH defaults to 89 (Ada Lovelace / RTX 40xx).
# Override for other GPUs, e.g. 80 (Ampere), 86, 75 (Turing).

set -euo pipefail

CUDA_ARCH="${1:-89}"
# Set to empty string to let CMake auto-detect BLAS (e.g. on non-MKL machines).
BLA_VENDOR="${BLA_VENDOR:-Intel10_64lp}"
PYTHON="python3.12"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
BASE_VERSION=$("$PYTHON" -c "import tomllib; d=tomllib.load(open('$REPO_ROOT/pyproject.toml','rb')); print(d['project']['version'])")

mkdir -p "$DIST_DIR"

# ---------------------------------------------------------------------------
# Helper: build COLMAP C++ and then the Python wheel for one CUDA version.
# ---------------------------------------------------------------------------
build_for_cuda() {
    local CUDA_VERSION="$1"           # e.g. "13.0" or "12.8"
    local NVCC_PATH="$2"              # e.g. /usr/local/cuda-13.0/bin/nvcc

    if [ ! -x "$NVCC_PATH" ]; then
        echo "[SKIP] nvcc not found at $NVCC_PATH — skipping CUDA $CUDA_VERSION"
        return
    fi

    local CUDA_LABEL="cuda${CUDA_VERSION}"
    local BUILD_DIR="$REPO_ROOT/build/$CUDA_LABEL"
    local INSTALL_DIR="$REPO_ROOT/install/$CUDA_LABEL"

    echo ""
    echo "========================================================"
    echo " Building COLMAP C++ for CUDA $CUDA_VERSION"
    echo "========================================================"
    mkdir -p "$BUILD_DIR"
    cmake -S "$REPO_ROOT" -B "$BUILD_DIR" \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_CUDA_COMPILER="$NVCC_PATH" \
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
        ${BLA_VENDOR:+-DBLA_VENDOR="$BLA_VENDOR"}
    ninja -j1 -C "$BUILD_DIR" install

    echo ""
    echo "========================================================"
    echo " Building pycolmap wheel for CUDA $CUDA_VERSION / Python 3.12"
    echo "========================================================"
    local WHEEL_BUILD_DIR="$REPO_ROOT/build/wheel-$CUDA_LABEL"
    mkdir -p "$WHEEL_BUILD_DIR"

    CMAKE_ARGS="\
-Dcolmap_DIR=$INSTALL_DIR/share/colmap \
-DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCH \
-DCMAKE_CUDA_COMPILER=$NVCC_PATH" \
    SKBUILD_BUILD_DIR="$REPO_ROOT/build/scikit-$CUDA_LABEL" \
    SKBUILD_PROJECT_VERSION="${BASE_VERSION}+${CUDA_LABEL}" \
    LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}" \
    "$PYTHON" -m pip wheel \
        --no-deps \
        --wheel-dir "$WHEEL_BUILD_DIR" \
        "$REPO_ROOT"

    local WHEEL
    WHEEL=$(ls "$WHEEL_BUILD_DIR"/*.whl | head -1)
    cp "$WHEEL" "$DIST_DIR/"
    echo ""
    echo "Wheel written to: $DIST_DIR/$(basename "$WHEEL")"
}

# ---------------------------------------------------------------------------
# Build for each CUDA version.
# ---------------------------------------------------------------------------
build_for_cuda "13.0" "/usr/local/cuda-13.0/bin/nvcc"
# build_for_cuda "12.8" "/usr/local/cuda-12.8/bin/nvcc"

echo ""
echo "========================================================"
echo " Done. Wheels in $DIST_DIR:"
ls "$DIST_DIR"/*.whl 2>/dev/null || echo "  (none found)"
echo "========================================================"
