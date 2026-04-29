COLMAP
======

About
-----

COLMAP is a general-purpose Structure-from-Motion (SfM) and Multi-View Stereo
(MVS) pipeline with a graphical and command-line interface. It offers a wide
range of features for reconstruction of ordered and unordered image collections.
The software is licensed under the new BSD license.

The latest source code is available at https://github.com/colmap/colmap. COLMAP
builds on top of existing works and when using specific algorithms within
COLMAP, please also cite the original authors, as specified in the source code,
and consider citing relevant third-party dependencies (most notably
ceres-solver, poselib, sift-gpu, vlfeat).

Download
--------

* Binaries for **Windows** and other resources can be downloaded
  from https://github.com/colmap/colmap/releases.
* Binaries for **Linux/Unix/BSD** are available at
  https://repology.org/metapackage/colmap/versions.
* Pre-built **Docker** images are available at
  https://hub.docker.com/r/colmap/colmap.
* Conda packages are available at https://anaconda.org/conda-forge/colmap and
  can be installed with `conda install colmap`
* **Python bindings** are available at https://pypi.org/project/pycolmap.
  CUDA-enabled wheels are available at https://pypi.org/project/pycolmap-cuda12.
* To **build from source**, please see https://colmap.github.io/install.html.

Getting Started
---------------

1. Download pre-built binaries or build from source.
2. Download one of the provided [sample datasets](https://demuc.de/colmap/datasets/)
   or use your own images.
3. Use the **automatic reconstruction** to easily build models
   with a single click or command.

Building Python Wheels (polybee_colmap)
---------------------------------------

The build produces a PEP 600-compliant `manylinux_2_34_x86_64` wheel that
bundles every non-CUDA shared library it links against (COLMAP, MKL, ceres,
suitesparse, glog, gflags, freeimage, OpenGL/Qt5, …). The CUDA runtime is
deliberately *not* bundled — the consumer image is expected to provide it,
e.g. `nvidia/cuda:13.0.x-runtime-*` or any image with CUDA 13 installed.

### Requirements (host)

- Docker (build runs inside a Rocky Linux 9 + CUDA 13 container)
- About 8 GB of free disk for the build image and intermediate artefacts
- A GPU is **not** required at build time — only at consumer install/runtime

### Quick start

```bash
./scripts/shell/build_wheels_python312.sh [CUDA_ARCH]
```

`CUDA_ARCH` is the numeric CUDA compute capability (default: `89` for
Ada Lovelace / RTX 40xx). Common values:

| GPU family              | CUDA_ARCH |
|-------------------------|-----------|
| Ada Lovelace (RTX 40xx) | 89        |
| Ampere (RTX 30xx)       | 86        |
| Turing (RTX 20xx)       | 75        |

On the first run the script builds the `polybee-pycolmap-build:cuda13-py312`
Docker image (~10 minutes — installs Rocky 9 + CUDA 13 toolkit + Python 3.12
+ Intel oneAPI MKL + COLMAP system deps). Subsequent runs reuse the cached
image. Force a rebuild with `REBUILD_IMAGE=1 ./scripts/shell/build_wheels_python312.sh`.

### Output

The compliant wheel is written to `dist/` and tagged for `manylinux_2_34_x86_64`:

```
dist/
└── pycolmap-4.1.0.dev0+cuda13.0-cp312-cp312-manylinux_2_34_x86_64.whl
```

It pip-installs cleanly on any Linux image with glibc ≥ 2.34 (RHEL/Rocky/Alma
9, Ubuntu 22.04+, Debian 12+, …) plus a matching CUDA runtime.

### How it works

| File                                             | Role |
|--------------------------------------------------|------|
| `scripts/docker/Dockerfile.manylinux-cuda`       | Defines the Rocky 9 + CUDA 13 + MKL + COLMAP-deps build image. |
| `scripts/shell/build_wheels_python312.sh`        | Host orchestrator. Builds (or reuses) the image, then `docker run`s the inner script. |
| `scripts/shell/_build_inside_container.sh`       | Runs inside the container: cmake → ninja → `pip wheel` → `auditwheel repair --plat manylinux_2_34_x86_64` with CUDA-only excludes. |

Intermediate C++ build trees live under `/work` *inside the container* and
do not pollute the host repo.

### Configuration

Environment overrides (all optional):

| Variable          | Default                   | Purpose                                                                 |
|-------------------|---------------------------|-------------------------------------------------------------------------|
| `BLA_VENDOR`      | `Intel10_64lp`            | CMake `find_package(BLAS)` vendor. Set to `OpenBLAS` to skip MKL.       |
| `MANYLINUX_PLAT`  | `manylinux_2_34_x86_64`   | `auditwheel` target tag. Lower it (e.g. `manylinux_2_28_x86_64`) only if you also rebuild the image on a matching glibc base. |
| `IMAGE_TAG`       | `polybee-pycolmap-build:cuda13-py312` | Docker image name. |
| `REBUILD_IMAGE`   | (unset)                   | Set to `1` to force `docker build` even if the image already exists.    |

### Verifying the wheel

After a build, the script prints the output of `auditwheel show`. Check that:

- The platform tag is `manylinux_2_34_x86_64` (not `linux_x86_64`).
- No CUDA library appears in `pycolmap.libs/` — only CUDA libs should remain
  unbundled. If a CUDA lib was accidentally bundled, add its soname to the
  `CUDA_EXCLUDES` array in `_build_inside_container.sh`.

To smoke-test the wheel inside a clean container:

```bash
docker run --rm --gpus all \
    -v "$PWD/dist:/dist:ro" \
    nvidia/cuda:13.0.0-runtime-rockylinux9 \
    bash -c '
        dnf install -y python3.12 python3-pip > /dev/null 2>&1
        python3.12 -m pip install /dist/pycolmap-*.whl
        python3.12 -c "import pycolmap; print(pycolmap.__version__)"
    '
```

Documentation
-------------

The documentation is available [here](https://colmap.github.io/).

To build and update the documentation at the documentation website,
follow [these steps](https://colmap.github.io/install.html#documentation).

Support
-------

Please, use [GitHub Discussions](https://github.com/colmap/colmap/discussions)
for questions and the [GitHub issue tracker](https://github.com/colmap/colmap)
for bug reports, feature requests/additions, etc.

Acknowledgments
---------------

COLMAP was originally written by [Johannes Schönberger](https://demuc.de/) with
funding provided by his PhD advisors Jan-Michael Frahm and Marc Pollefeys.
The team of core project maintainers currently includes
[Johannes Schönberger](https://github.com/ahojnnes),
[Paul-Edouard Sarlin](https://github.com/sarlinpe),
[Shaohui Liu](https://github.com/B1ueber2y), and
[Linfei Pan](https://lpanaf.github.io/).

The Python bindings in PyCOLMAP were originally added by
[Mihai Dusmanu](https://github.com/mihaidusmanu),
[Philipp Lindenberger](https://github.com/Phil26AT), and
[Paul-Edouard Sarlin](https://github.com/sarlinpe).

The project has also benefitted from countless community contributions, including
bug fixes, improvements, new features, third-party tooling, and community
support (special credits to [Torsten Sattler](https://tsattler.github.io)).

Citation
--------

If you use this project for your research, please cite:

    @inproceedings{schoenberger2016sfm,
        author={Sch\"{o}nberger, Johannes Lutz and Frahm, Jan-Michael},
        title={Structure-from-Motion Revisited},
        booktitle={Conference on Computer Vision and Pattern Recognition (CVPR)},
        year={2016},
    }

    @inproceedings{schoenberger2016mvs,
        author={Sch\"{o}nberger, Johannes Lutz and Zheng, Enliang and Pollefeys, Marc and Frahm, Jan-Michael},
        title={Pixelwise View Selection for Unstructured Multi-View Stereo},
        booktitle={European Conference on Computer Vision (ECCV)},
        year={2016},
    }

If you use the global SfM pipeline (GLOMAP), please cite:

    @inproceedings{pan2024glomap,
        author={Pan, Linfei and Barath, Daniel and Pollefeys, Marc and Sch\"{o}nberger, Johannes Lutz},
        title={{Global Structure-from-Motion Revisited}},
        booktitle={European Conference on Computer Vision (ECCV)},
        year={2024},
    }

If you use the image retrieval / vocabulary tree engine, please cite:

    @inproceedings{schoenberger2016vote,
        author={Sch\"{o}nberger, Johannes Lutz and Price, True and Sattler, Torsten and Frahm, Jan-Michael and Pollefeys, Marc},
        title={A Vote-and-Verify Strategy for Fast Spatial Verification in Image Retrieval},
        booktitle={Asian Conference on Computer Vision (ACCV)},
        year={2016},
    }

Contribution
------------

Contributions (bug reports, bug fixes, improvements, etc.) are very welcome and
should be submitted in the form of new issues and/or pull requests on GitHub.

License
-------

The COLMAP library is licensed under the new BSD license. Note that this text
refers only to the license for COLMAP itself, independent of its thirdparty
dependencies, which are separately licensed. Building COLMAP with these
dependencies may affect the resulting COLMAP license.

    Copyright (c), ETH Zurich and UNC Chapel Hill.
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.

        * Redistributions in binary form must reproduce the above copyright
          notice, this list of conditions and the following disclaimer in the
          documentation and/or other materials provided with the distribution.

        * Neither the name of ETH Zurich and UNC Chapel Hill nor the names of
          its contributors may be used to endorse or promote products derived
          from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
    CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
