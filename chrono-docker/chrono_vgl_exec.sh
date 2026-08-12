#!/usr/bin/env bash
# Run a Chrono command inside Apptainer with X11/VNC-friendly binds. If VGL=1
# and vglrun is available on the host, the Apptainer command is launched through
# VirtualGL so Irrlicht/OpenGL rendering can happen on the GPU and stream to VNC.
set -euo pipefail

: "${WORK:?WORK is not set}"
SIF="${SIF_PATH:-${WORK}/chrono.sif}"
WORKAREA="${WORKAREA:-${WORK}/chrono-build-area}"
BINDIR="${WORKAREA}/mountdir/lib/chrono-build/share/chrono/bin"
VGL="${VGL:-1}"
VGL_DISPLAY="${VGL_DISPLAY:-}"
VGLRUN=""

[ -f "${SIF}" ] || { echo "ERROR: ${SIF} not found (run ./build_chrono_sif.sh)"; exit 1; }
[ -f "${WORKAREA}/mountdir/chrono_env.sh" ] || { echo "ERROR: chrono_env.sh not found (run ./run_chrono_build.sh)"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "ERROR: DISPLAY is not set. Start/connect to a VNC or X session first."; exit 1; }

apptainer_args=(
    exec
    --rocm
    --home "${WORKAREA}"
    --bind "${WORK}"
    --bind /tmp/.X11-unix:/tmp/.X11-unix
    --env "DISPLAY=${DISPLAY}"
)

if [ -n "${XAUTHORITY:-}" ] && [ -f "${XAUTHORITY}" ]; then
    apptainer_args+=(--bind "${XAUTHORITY}:${XAUTHORITY}" --env "XAUTHORITY=${XAUTHORITY}")
fi

if [ -d /dev/dri ]; then
    apptainer_args+=(--bind /dev/dri:/dev/dri)
fi

if [ "${VGL}" = "1" ] && command -v vglrun >/dev/null 2>&1; then
    VGLRUN="$(command -v vglrun)"
    vglrun_real="$(readlink -f "${VGLRUN}")"
    case "${vglrun_real}" in
        /opt/VirtualGL/*)
            apptainer_args+=(--bind /opt/VirtualGL:/opt/VirtualGL)
            ;;
    esac
    for vgl_dir in \
        /usr/lib64/VirtualGL \
        /usr/lib/VirtualGL \
        /usr/lib/x86_64-linux-gnu/VirtualGL \
        /usr/lib64/virtualgl \
        /usr/lib/virtualgl \
        /usr/lib/x86_64-linux-gnu/virtualgl
    do
        if [ -d "${vgl_dir}" ]; then
            apptainer_args+=(--bind "${vgl_dir}:${vgl_dir}")
        fi
    done
fi

apptainer_args+=(
    "${SIF}"
    bash -lc 'source "$HOME/mountdir/chrono_env.sh"; export PATH="'"${BINDIR}"':$PATH"; exec "$@"' _
)

if [ -n "${VGLRUN}" ]; then
    if [ -n "${VGL_DISPLAY}" ]; then
        exec "${VGLRUN}" -d "${VGL_DISPLAY}" apptainer "${apptainer_args[@]}" "$@"
    fi
    exec "${VGLRUN}" apptainer "${apptainer_args[@]}" "$@"
fi

if [ "${VGL}" = "1" ]; then
    echo "WARN: vglrun is not on PATH; running without VirtualGL." >&2
    echo "      Try: module avail virtualgl; module load VirtualGL" >&2
fi

exec apptainer "${apptainer_args[@]}" "$@"
