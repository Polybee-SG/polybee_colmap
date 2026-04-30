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
#   BUILD_JOBS      — override ninja parallelism (default: min(nproc, mem_gb/3))
#   HOST_UID/GID    — chown the produced wheels to this UID:GID before exit
#                     so they don't appear root-owned on the host bind mount

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

# Pick a parallelism that won't OOM. Heavy templated TUs in COLMAP (notably
# PoissonRecon.cpp) peak at ~3 GB per cc1plus invocation, so naively using
# $(nproc) blows up RAM on machines with many cores and modest memory
# (e.g. 22 cores / 15 GB). Cap jobs at min(nproc, mem_gb / 3). Override
# with $BUILD_JOBS to force a specific value.
if [ -n "${BUILD_JOBS:-}" ]; then
    NJOBS="$BUILD_JOBS"
else
    NCPU=$(nproc)
    MEM_GB=$(awk '/MemTotal/ {print int($2 / 1024 / 1024)}' /proc/meminfo)
    MEM_JOBS=$(( MEM_GB / 3 ))
    [ "$MEM_JOBS" -lt 1 ] && MEM_JOBS=1
    if [ "$MEM_JOBS" -lt "$NCPU" ]; then
        NJOBS="$MEM_JOBS"
    else
        NJOBS="$NCPU"
    fi
fi
echo "Using NJOBS=$NJOBS (nproc=$(nproc), mem=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo) GB)"

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
    # CMAKE_FIND_PACKAGE_PREFER_CONFIG=TRUE makes transitive find_package()
    # calls (notably find_dependency(glog) inside CeresConfig.cmake) prefer
    # *-config.cmake over Module-mode finders. Belt-and-suspenders: the image
    # already builds glog from source so CeresConfig.cmake records modern
    # Config-mode discovery, but this flag also protects COLMAP's own
    # transitive dependency resolution from any future Module-mode finders
    # that re-import the glog::glog target.
    cmake -S "$REPO_ROOT" -B "$CMAKE_BUILD_DIR" \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_CUDA_COMPILER="$NVCC_PATH" \
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
        -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=TRUE \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        ${BLA_VENDOR:+-DBLA_VENDOR="$BLA_VENDOR"}
    ninja -j"$NJOBS" -C "$CMAKE_BUILD_DIR" install

    # Recreate libonnxruntime SONAME symlinks. CMake's install(FILES) on the
    # globbed onnxruntime libs (cmake/FindDependencies.cmake) dereferences
    # symlinks, so $INSTALL_DIR/lib* ends up with the versioned regular file
    # (libonnxruntime.so.X.Y.Z) and the bare alias, but NOT the SONAME
    # (libonnxruntime.so.1) that pycolmap's _core.so DT_NEEDEDs. auditwheel
    # resolves DT_NEEDED by literal filename on LD_LIBRARY_PATH, so without
    # this symlink it silently skips bundling and the consumer image fails
    # at `import pycolmap` with: libonnxruntime.so.1: cannot open shared
    # object file. Same fix applies to libonnxruntime_providers_shared.so.
    for libdir in "$INSTALL_DIR/lib64" "$INSTALL_DIR/lib"; do
        [ -d "$libdir" ] || continue
        for ort_full in "$libdir"/libonnxruntime*.so.[0-9]*.[0-9]*.[0-9]*; do
            [ -e "$ort_full" ] || continue
            soname=$(patchelf --print-soname "$ort_full" 2>/dev/null || true)
            if [ -n "$soname" ] && [ ! -e "$libdir/$soname" ]; then
                ln -sf "$(basename "$ort_full")" "$libdir/$soname"
                echo "[onnx-soname] $libdir/$soname -> $(basename "$ort_full")"
            fi
        done
    done

    echo ""
    echo "========================================================"
    echo " [${CUDA_LABEL}] Building pycolmap wheel"
    echo "========================================================"
    CMAKE_ARGS="\
-Dcolmap_DIR=$INSTALL_DIR/share/colmap \
-DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCH \
-DCMAKE_CUDA_COMPILER=$NVCC_PATH \
-DCMAKE_FIND_PACKAGE_PREFER_CONFIG=TRUE \
-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON" \
    SKBUILD_BUILD_DIR="$STAGE_DIR/scikit" \
    SKBUILD_PROJECT_VERSION="${BASE_VERSION}+${CUDA_LABEL}" \
    LD_LIBRARY_PATH="$INSTALL_DIR/lib64:$INSTALL_DIR/lib:/usr/local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
    CMAKE_BUILD_PARALLEL_LEVEL="$NJOBS" \
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

    LD_LIBRARY_PATH="$INSTALL_DIR/lib64:$INSTALL_DIR/lib:/usr/local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
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

# Hand the produced wheels back to the host user. The container runs as root,
# so anything it writes to the bind-mounted /dist appears root-owned on the
# host. The orchestrator passes HOST_UID/HOST_GID; if absent, leave as-is.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "$HOST_UID:$HOST_GID" "$DIST_DIR"
fi

echo ""
echo "========================================================"
echo " Done. Wheels in $DIST_DIR:"
ls "$DIST_DIR"/*.whl 2>/dev/null || echo "  (none found)"
echo "========================================================"
