#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Compile Project Chrono (AMD ROCm/HIP) inside the Apptainer image, writing all
# sources/artifacts to a $WORK build area (NOT the small home quota).
#
# Runtime-agnostic: run it INSIDE an interactive GPU session (preferred), or via
# sbatch through build_chrono.slurm.
#
# Interactive use:
#   ./build_chrono_sif.sh                                  # once, on the login node
#   srun -p mi2101x -A dannegrut --time=08:00:00 --pty bash
#   cd /home1/auc7us/chrono-docker/chrono-docker
#   ./run_chrono_build.sh
#
# NOTE ON NETWORK: buildChronoInMount.sh fetches Blaze and builds VSG/URDF (git
# clones) and inits Chrono submodules — this needs outbound internet on whatever
# node you run it. The egress check below warns early; if your GPU node is walled
# off, do this clone/build step where egress exists (login node or `devel`).
set -euo pipefail

: "${WORK:?WORK is not set — expected your /work1/<group>/<user> area}"

SIF_PATH="${SIF_PATH:-${WORK}/chrono.sif}"
WORKAREA="${WORKAREA:-${WORK}/chrono-build-area}"
MOUNTDIR="${WORKAREA}/mountdir"
CHRONO_BRANCH="${CHRONO_BRANCH:-main}"
CHRONO_HIP_ARCHITECTURES="${CHRONO_HIP_ARCHITECTURES:-gfx90a}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "${SIF_PATH}" ] || { echo "ERROR: ${SIF_PATH} not found — run ./build_chrono_sif.sh first."; exit 1; }
command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not on PATH on this node."; exit 1; }

# Confirm a GPU is actually visible (you want this running where the MI210 is).
if [ -e /dev/kfd ]; then
    echo "GPU device /dev/kfd present on $(hostname)."
else
    echo "WARNING: /dev/kfd not present on $(hostname) — you may be on a non-GPU node."
fi

# --- Stage the build area on $WORK (mirrors the repo's mountdir layout) -------
mkdir -p "${MOUNTDIR}/lib/chrono-build"
cp "${REPO_DIR}/mountdir/buildChronoInMount.sh" "${MOUNTDIR}/buildChronoInMount.sh"
chmod +x "${MOUNTDIR}/buildChronoInMount.sh"

if [ ! -d "${MOUNTDIR}/chrono/.git" ]; then
    echo "Cloning Chrono (${CHRONO_BRANCH}) into ${MOUNTDIR}/chrono ..."
    git clone -b "${CHRONO_BRANCH}" https://github.com/projectchrono/chrono.git "${MOUNTDIR}/chrono"
else
    echo "Chrono source already present at ${MOUNTDIR}/chrono"
fi

echo "Egress check (build needs github/bitbucket/lunarg) ..."
if ! timeout 10 wget -q --spider https://github.com; then
    echo "WARNING: no outbound internet from $(hostname). The dependency-fetch"
    echo "         steps in buildChronoInMount.sh will fail. See the header note."
fi

# --- Compile inside the container --------------------------------------------
# --home ${WORKAREA}: makes \$HOME=${WORKAREA} inside the container, so the
#   script's \$HOME/mountdir defaults (packages, lib/chrono-build, chrono_env.sh)
#   all land on $WORK instead of the 24 GB home quota.
# --rocm: injects the host AMD GPU devices/libraries (MI210, gfx90a).
echo "Starting Chrono build in container (gfx90a) on $(hostname) ..."
apptainer exec --rocm \
    --home "${WORKAREA}" \
    --bind "${WORK}" \
    --env CHRONO_HIP_ARCHITECTURES="${CHRONO_HIP_ARCHITECTURES}" \
    "${SIF_PATH}" \
    bash "${MOUNTDIR}/buildChronoInMount.sh"

echo
echo "Build finished. Chrono installed under ${MOUNTDIR}/lib/chrono-build"
echo "Runtime env file: ${MOUNTDIR}/chrono_env.sh"
echo
echo "To use it on a GPU node, use the chrono_exec.sh wrapper (sources the env):"
echo "  ./chrono_exec.sh python -c 'import pychrono.fsi; print(\"fsi ok\")'"
echo "  ./chrono_exec.sh demo_FSI-SPH_AngleRepose"
echo "  ./chrono_exec.sh bash      # interactive shell with PyChrono + demos ready"
