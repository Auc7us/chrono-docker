# Apptainer container with Chrono-main with ROS2 Humble and PyChrono on AMD GPUs (ROCm/HIP)

For HPC clusters without Docker (e.g. AMD HPC Fund). Builds the full module set except Chrono::Sensor. Docker workflow: [README.md](./README.md).

## Installation
---
### Pre-requisites:
#### 1. Clone the repository
```
git clone https://github.com/Auc7us/chrono-docker/
```
#### 2. `apptainer` on PATH and `$WORK` set (both default on HPC Fund)

### Setup
- __Build the Apptainer image (login node):__
    ```
    cd chrono-docker/chrono-docker
    ./build_chrono_sif.sh
    ```

- __Build Chrono in an interactive GPU job:__
    ```
    salloc -N 1 -p mi2101x -A dannegrut -t 02:00:00
    cd chrono-docker/chrono-docker
    ./run_chrono_build.sh
    ```

## Usage Instructions
---

- __Enter the container__ (`--home` makes `~` the build area on `$WORK`)
    ```
    apptainer shell --rocm \
      --home $WORK/chrono-build-area --bind $WORK $WORK/chrono.sif
    ```

- __Run Demos (inside the container)__
    ```
    source ~/mountdir/chrono_env.sh
    cd ~/mountdir/lib/chrono-build/share/chrono/bin
    ./demo_FSI-SPH_DamBreak
    ```
    - Python: `python -c "import pychrono.fsi"`
    - One-off without entering: `./chrono_exec.sh demo_FSI-SPH_DamBreak`

- __Note:__ demos must run inside the container; GUI demos (`demo_IRR_*`, `demo_VSG_*`) need an X display (VNC / X-forwarding).

- __Interactive Irrlicht visualization with VNC + VirtualGL__

    This is the preferred path if you are OK with `demo_IRR_*` instead of VSG.
    The compute node renders OpenGL on the GPU, while VNC streams compressed
    pixels back to your laptop.

    1. Start an interactive GPU job:
        ```
        salloc -N 1 -p mi2101x -A dannegrut -t 02:00:00
        cd chrono-docker/chrono-docker
        ```

    2. Start or connect to a VNC/desktop session using the cluster's normal
       mechanism. If your site uses modules, also check whether VirtualGL is
       available:
        ```
        module avail virtualgl
        module load VirtualGL
        ```

    3. Check the session:
        ```
        ./chrono_vgl_check.sh
        ```
       You want `DISPLAY` set, the X display reachable, and `vglrun` available
       for GPU-backed OpenGL. If `vglrun` is missing, the wrapper still runs
       through the VNC display, but rendering may fall back to software Mesa.

    4. Run an Irrlicht demo:
        ```
        ./chrono_vgl_exec.sh demo_IRR_HelloWorld
        ```
       or open a container shell with the Chrono environment ready:
        ```
        ./chrono_vgl_exec.sh bash
        ```

    Useful overrides:
    ```
    VGL=0 ./chrono_vgl_exec.sh demo_IRR_HelloWorld       # VNC/X11 only
    VGL_DISPLAY=:0 ./chrono_vgl_exec.sh demo_IRR_HelloWorld
    ```

    Notes:
    - `Xvfb`/VNC alone gives a visible display, but usually not GPU rendering.
    - `VirtualGL` is what makes Irrlicht/OpenGL render on the GPU and stream to
      VNC.
    - VSG/Vulkan needs a different display path; this section is specifically
      for Irrlicht/OpenGL demos.

### Advanced Users

- __Different GPU arch__ (default `gfx90a` for MI210; `gfx942` for MI300X):
    ```
    CHRONO_HIP_ARCHITECTURES=gfx942 ./run_chrono_build.sh
    ```
- __Modules / ROCm version__: edit CMake flags in [buildChronoInMount.sh](./chrono-docker/mountdir/buildChronoInMount.sh) and `ROCM_VERSION` in [chrono.def](./chrono-docker/docker/chrono/chrono.def)
- __Note:__ `$WORK` is not backed up — keep the repo in `/home1`, builds on `$WORK`

## Background
---

### Why Apptainer instead of Docker
Docker needs a root daemon (`dockerd`), and membership in the `docker` group is effectively root on the host — a non-starter on a shared multi-user cluster, so HPC centers don't install it. Apptainer (and Podman) are rootless and daemonless: they run as your user with no privileged service. Apptainer is the HPC-standard one — images are a single `.sif` file, it integrates with SLURM, and `--rocm` injects the AMD GPU devices/libraries at run time. The image is built unprivileged with `--fakeroot` (root-mapped namespace), so `apt` works inside `%post` even though you have no `sudo` on the host.

### Why `/home1` and `$WORK` are separate
They're different filesystems for different jobs, and you can't merge them. `/home1` is small (~24 GB quota) but **backed up** — for code, scripts, configs. `$WORK` is huge (a shared multi-hundred-TB parallel filesystem) and tuned for throughput, but **not backed up** — for builds, container images, and simulation output. That's why the repo (the recipe) lives in `/home1` while the regenerable Chrono build and the `.sif` live on `$WORK`. The cluster even pre-points `APPTAINER_CACHEDIR` at `$WORK`.

### What makes the AMD build work
Getting Chrono's HIP backend to compile the full module set on AMD came down to a few non-obvious things:

1. **Host compiler must be g++-13**, not Ubuntu 22.04's default g++-11. ROCm 7.x's rocThrust headers use `_Float16`, which only exists in g++ ≥ 12. The image installs g++-13 (via the toolchain PPA) for this reason. This was the key insight from a dev who had built Chrono on AMD.

2. **ROCm 7.2.4, not 6.x.** ROCm 6.x's rocPRIM has a header bug that no g++ can parse. Staying on the Ubuntu 22.04 base (rather than 24.04) keeps ROS 2 Humble packages available.

3. **Two FSI "bridge" files are compiled with the ROCm clang instead of g++.** `Chrono::DEM` exports `__HIP_PLATFORM_AMD__` as a *public* compile definition, so it leaks into host `.cpp` files that link it. Combined with the HIP device-thrust path, rocThrust then pulls in AMD GPU builtins (`__builtin_amdgcn_wavefrontsize`) that g++ has no equivalent for. The two files that hit this — `ChSphVisualizationVSG.cpp` (FSI↔VSG) and `ChVehicleCosimTerrainNodeGranularSPH.cpp` (FSI↔vehicle co-sim) — are marked `LANGUAGE HIP` so CMake builds just them with clang. (See `patch_hip_language_sources` in [buildChronoInMount.sh](./chrono-docker/mountdir/buildChronoInMount.sh).)

4. **HIP backend wiring**: `CHRONO_GPU_BACKEND=HIP`, `CHRONO_HIP_ARCHITECTURES=gfx90a`, and `CMAKE_HIP_COMPILER` pointed straight at the ROCm `clang++` — CMake 3.22 rejects the `hipcc` wrapper.

5. **Chrono::Sensor is OFF** — it relies on NVIDIA OptiX, which has no AMD/HIP equivalent.

The build itself doesn't need a GPU: `hipcc` cross-compiles device code for `gfx90a`, so any node with enough cores works. The MI210 is only needed at run time. Match the `CHRONO_HIP_ARCHITECTURES` flag to the GPU you'll actually *run* on, not the one you build on.
