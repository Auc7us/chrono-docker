#!/usr/bin/env bash
# Run a command inside the Chrono Apptainer container with the PyChrono runtime
# environment sourced and the demo bin/ on PATH. Use on a GPU node (salloc).
#
# Examples:
#   ./chrono_exec.sh python -c "import pychrono.fsi as f; print('fsi ok')"
#   ./chrono_exec.sh demo_FSI-SPH_AngleRepose
#   ./chrono_exec.sh bash          # interactive shell with everything set up
#
# Why a wrapper: Apptainer evaluates %environment before --env is visible, so the
# image can't auto-source the runtime env file (its paths live on $WORK and are
# only known at run time). Sourcing it explicitly here is the reliable fix.
set -euo pipefail

: "${WORK:?WORK is not set}"
SIF="${SIF_PATH:-${WORK}/chrono.sif}"
WORKAREA="${WORKAREA:-${WORK}/chrono-build-area}"
BINDIR="${WORKAREA}/mountdir/lib/chrono-build/share/chrono/bin"

[ -f "${SIF}" ] || { echo "ERROR: ${SIF} not found (run ./build_chrono_sif.sh)"; exit 1; }
[ -f "${WORKAREA}/mountdir/chrono_env.sh" ] || { echo "ERROR: chrono_env.sh not found (run ./run_chrono_build.sh)"; exit 1; }

exec apptainer exec --rocm --home "${WORKAREA}" --bind "${WORK}" "${SIF}" \
    bash -lc 'source "$HOME/mountdir/chrono_env.sh"; export PATH="'"${BINDIR}"':$PATH"; exec "$@"' _ "$@"
