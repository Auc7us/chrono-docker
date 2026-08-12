#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the Chrono Apptainer image (chrono.sif) from docker/chrono/chrono.def.
#
# Run this ON THE LOGIN NODE: it only downloads packages + does a light colcon
# build, and the login node is where outbound internet + unprivileged fakeroot
# are confirmed to work on HPC Fund. The heavy Chrono compile happens later in
# a GPU job (see build_chrono.slurm).
set -euo pipefail

: "${WORK:?WORK is not set — expected your /work1/<group>/<user> area}"

ROCM_VERSION="${ROCM_VERSION:-7.2.4}"   # 7.x rocPRIM fixes a g++ parse error hit by Chrono FSI on 6.x
ROS_DISTRO="${ROS_DISTRO:-humble}"
SIF_PATH="${SIF_PATH:-${WORK}/chrono.sif}"

# Keep Apptainer's cache and build scratch on the big $WORK filesystem, not the
# small home quota. APPTAINER_CACHEDIR is already exported on HPC Fund; pin the
# tmp dir too so layer extraction of the large ROCm base image has room.
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-${WORK}/.apptainer}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-${WORK}/.apptainer/tmp}"
mkdir -p "${APPTAINER_CACHEDIR}" "${APPTAINER_TMPDIR}"

DEF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/docker/chrono" && pwd)"

echo "Building ${SIF_PATH}"
echo "  def           : ${DEF_DIR}/chrono.def"
echo "  ROCM_VERSION  : ${ROCM_VERSION}"
echo "  ROS_DISTRO    : ${ROS_DISTRO}"
echo "  cache/tmp     : ${APPTAINER_CACHEDIR} | ${APPTAINER_TMPDIR}"

cd "${DEF_DIR}"
apptainer build --fakeroot --force \
    --build-arg ROCM_VERSION="${ROCM_VERSION}" \
    --build-arg ROS_DISTRO="${ROS_DISTRO}" \
    "${SIF_PATH}" chrono.def

echo
echo "Done: ${SIF_PATH}"
echo "Next: compile Chrono in a GPU job with"
echo "  sbatch build_chrono.slurm"
