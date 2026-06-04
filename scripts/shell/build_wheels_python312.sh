#!/bin/bash
# Build manylinux_2_34_x86_64 pycolmap wheels for Python 3.12 with CUDA 13.
#
# This script is a thin Docker orchestrator. The actual build runs inside a
# Rocky Linux 9 + CUDA 13 container that matches manylinux_2_34's glibc
# floor. Inside the container, COLMAP is built, the wheel is produced, and
# `auditwheel repair` bundles every non-CUDA shared library it links against
# (MKL, ceres, suitesparse, glog, gflags, freeimage, OpenGL/Qt5, …).
#
# Net result: a PEP 600-compliant wheel that pip-installs cleanly on any
# Linux image with glibc >= 2.34 AND a matching CUDA runtime present
# (e.g. nvidia/cuda:13.0.x-runtime-* or any image that has installed it).
#
# Usage:
#   ./scripts/shell/build_wheels_python312.sh [CUDA_ARCH]
#
#   CUDA_ARCH defaults to 89 (Ada Lovelace / RTX 40xx).
#   Override for other GPUs, e.g. 80 (Ampere), 86, 75 (Turing).
#   Pass "all" to target every architecture the installed CUDA toolkit
#   supports (nvcc-queried at build time — immune to CMake's stale tables).
#   Pass "all-major" to target only the major generation steps (60,70,80,…).
#
# Optional environment overrides:
#   BLA_VENDOR        — passed to CMake; default Intel10_64_dyn (MKL)
#   MANYLINUX_PLAT    — auditwheel platform tag; default manylinux_2_34_x86_64
#   IMAGE_TAG         — name of the build image; default polybee-pycolmap-build:cuda13-py312
#   REBUILD_IMAGE=1   — force `docker build` even if the image already exists
#   BUILD_JOBS        — override ninja parallelism (default: min(nproc, mem_gb/3))

set -euo pipefail

CUDA_ARCH="${1:-89}"
BLA_VENDOR="${BLA_VENDOR:-Intel10_64_dyn}"
MANYLINUX_PLAT="${MANYLINUX_PLAT:-manylinux_2_34_x86_64}"
IMAGE_TAG="${IMAGE_TAG:-polybee-pycolmap-build:cuda13-py312}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
DOCKERFILE="$REPO_ROOT/scripts/docker/Dockerfile.manylinux-cuda"

mkdir -p "$DIST_DIR"

# ---------------------------------------------------------------------------
# 1. Build (or reuse) the manylinux+CUDA build image.
# ---------------------------------------------------------------------------
if [ "${REBUILD_IMAGE:-0}" = "1" ] || ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "========================================================"
    echo " Building Docker image: $IMAGE_TAG"
    echo "========================================================"
    docker build \
        -f "$DOCKERFILE" \
        -t "$IMAGE_TAG" \
        "$(dirname "$DOCKERFILE")"
else
    echo "Reusing existing build image: $IMAGE_TAG  (set REBUILD_IMAGE=1 to force rebuild)"
fi

# ---------------------------------------------------------------------------
# 2. Run the actual build inside the container. We bind-mount the source
#    read-write so SKBUILD can write its caches into the user's repo (which
#    matches the pre-Docker behaviour); /dist receives the final wheel.
#    --gpus is NOT required (the build links against CUDA libraries that
#    exist purely in the toolkit; it does not execute GPU code), but is
#    harmless if present.
# ---------------------------------------------------------------------------
echo ""
echo "========================================================"
echo " Building wheel inside $IMAGE_TAG"
echo "   CUDA_ARCH=$CUDA_ARCH"
echo "   BLA_VENDOR=$BLA_VENDOR"
echo "   MANYLINUX_PLAT=$MANYLINUX_PLAT"
echo "========================================================"
docker run --rm \
    -e CUDA_ARCH="$CUDA_ARCH" \
    -e BLA_VENDOR="$BLA_VENDOR" \
    -e MANYLINUX_PLAT="$MANYLINUX_PLAT" \
    -e REPO_ROOT=/src \
    -e DIST_DIR=/dist \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$REPO_ROOT:/src" \
    -v "$DIST_DIR:/dist" \
    "$IMAGE_TAG" \
    /src/scripts/shell/_build_inside_container.sh

echo ""
echo "========================================================"
echo " Done. Compliant wheels in $DIST_DIR:"
ls "$DIST_DIR"/*.whl 2>/dev/null || echo "  (none found)"
echo "========================================================"
