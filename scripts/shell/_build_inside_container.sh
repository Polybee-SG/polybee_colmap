#!/bin/bash
# Build pycolmap wheel(s) inside the manylinux+CUDA container.
#
# This is the "actual build" step. It is not meant to be invoked from the
# host directly; the host orchestrator (build_wheels_python312.sh) launches
# it via `docker run`. It assumes:
#   - $REPO_ROOT          → bind-mounted source repo (default /src)
#   - $DIST_DIR           → bind-mounted output dir (default /dist)
#   - The container is the polybee-pycolmap-build image (see
#     scripts/docker/Dockerfile.manylinux-cuda).
#
# Environment knobs (all optional, sane defaults):
#   CUDA_ARCH       — CMAKE_CUDA_ARCHITECTURES value (default 89, RTX 40xx)
#   BLA_VENDOR      — CMake BLAS vendor (default Intel10_64lp / MKL)
#   MANYLINUX_PLAT  — auditwheel target platform tag
#                     (default manylinux_2_34_x86_64)

set -euo pipefail

CUDA_ARCH="${CUDA_ARCH:-89}"
BLA_VENDOR="${BLA_VENDOR:-Intel10_64lp}"
MANYLINUX_PLAT="${MANYLINUX_PLAT:-manylinux_2_34_x86_64}"
PYTHON="${PYTHON:-python3.12}"
REPO_ROOT="${REPO_ROOT:-/src}"
DIST_DIR="${DIST_DIR:-/dist}"

# Build artefacts go into /work (the image WORKDIR), not the bind-mounted
# source tree. Keeps the host repo clean and avoids permission issues from
# Docker writing as root into a user-owned dir.
WORK_ROOT="${WORK_ROOT:-/work}"

mkdir -p "$DIST_DIR" "$WORK_ROOT"

# CUDA libraries that must be excluded from the bundled wheel — they will
# be provided by the consumer image's CUDA runtime. Auditwheel's --exclude
# matches against the soname; we list common ones here. Add more if a
# future COLMAP/CUDA version pulls in additional CUDA libs.
CUDA_EXCLUDES=(
    libcuda.so.1
    libcudart.so
    libcublas.so
    libcublasLt.so
    libcusparse.so
    libcusolver.so
    libcusolverMg.so
    libcurand.so
    libcufft.so
    libcufftw.so
    libnvrtc.so
    libnvrtc-builtins.so
    libnvJitLink.so
    libnvToolsExt.so
    libnppc.so
    libnppial.so
    libnppicc.so
    libnppidei.so
    libnppif.so
    libnppig.so
    libnppim.so
    libnppist.so
    libnppisu.so
    libnppitc.so
    libnpps.so
)

# Read the base version once.
BASE_VERSION=$(
    "$PYTHON" -c "
import tomllib
with open('${REPO_ROOT}/pyproject.toml', 'rb') as f:
    print(tomllib.load(f)['project']['version'])
"
)

build_for_cuda() {
    local CUDA_VERSION="$1"           # e.g. "13.0"
    local NVCC_PATH="$2"              # e.g. /usr/local/cuda-13.0/bin/nvcc

    if [ ! -x "$NVCC_PATH" ]; then
        echo "[SKIP] nvcc not found at $NVCC_PATH — skipping CUDA $CUDA_VERSION"
        return
    fi

    local CUDA_LABEL="cuda${CUDA_VERSION}"
    local STAGE_DIR="$WORK_ROOT/$CUDA_LABEL"
    local CMAKE_BUILD_DIR="$STAGE_DIR/cmake"
    local INSTALL_DIR="$STAGE_DIR/install"
    local WHEEL_DIR="$STAGE_DIR/wheel"
    local REPAIR_DIR="$STAGE_DIR/repaired"
    mkdir -p "$CMAKE_BUILD_DIR" "$INSTALL_DIR" "$WHEEL_DIR" "$REPAIR_DIR"

    echo ""
    echo "========================================================"
    echo " [${CUDA_LABEL}] Building COLMAP C++"
    echo "========================================================"
    cmake -S "$REPO_ROOT" -B "$CMAKE_BUILD_DIR" \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_CUDA_COMPILER="$NVCC_PATH" \
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
        ${BLA_VENDOR:+-DBLA_VENDOR="$BLA_VENDOR"}
    ninja -j"$(nproc)" -C "$CMAKE_BUILD_DIR" install

    echo ""
    echo "========================================================"
    echo " [${CUDA_LABEL}] Building pycolmap wheel"
    echo "========================================================"
    CMAKE_ARGS="\
-Dcolmap_DIR=$INSTALL_DIR/share/colmap \
-DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCH \
-DCMAKE_CUDA_COMPILER=$NVCC_PATH" \
    SKBUILD_BUILD_DIR="$STAGE_DIR/scikit" \
    SKBUILD_PROJECT_VERSION="${BASE_VERSION}+${CUDA_LABEL}" \
    LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}" \
    "$PYTHON" -m pip wheel \
        --no-deps \
        --wheel-dir "$WHEEL_DIR" \
        "$REPO_ROOT"

    local RAW_WHEEL
    RAW_WHEEL=$(ls "$WHEEL_DIR"/*.whl | head -1)
    echo "Raw wheel: $RAW_WHEEL"

    echo ""
    echo "========================================================"
    echo " [${CUDA_LABEL}] auditwheel repair → ${MANYLINUX_PLAT}"
    echo "========================================================"
    local EXCLUDE_ARGS=()
    local lib
    for lib in "${CUDA_EXCLUDES[@]}"; do
        EXCLUDE_ARGS+=(--exclude "$lib")
    done

    LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}" \
        "$PYTHON" -m auditwheel repair \
            --plat "$MANYLINUX_PLAT" \
            "${EXCLUDE_ARGS[@]}" \
            -w "$REPAIR_DIR" \
            "$RAW_WHEEL"

    local REPAIRED
    REPAIRED=$(ls "$REPAIR_DIR"/*.whl | head -1)
    cp "$REPAIRED" "$DIST_DIR/"
    chmod a+r "$DIST_DIR/$(basename "$REPAIRED")"

    echo ""
    echo "Compliant wheel written: $DIST_DIR/$(basename "$REPAIRED")"
    echo ""
    echo "auditwheel show:"
    "$PYTHON" -m auditwheel show "$REPAIRED" || true
}

build_for_cuda "13.0" "/usr/local/cuda-13.0/bin/nvcc"
# build_for_cuda "12.8" "/usr/local/cuda-12.8/bin/nvcc"

echo ""
echo "========================================================"
echo " Done. Wheels in $DIST_DIR:"
ls "$DIST_DIR"/*.whl 2>/dev/null || echo "  (none found)"
echo "========================================================"
