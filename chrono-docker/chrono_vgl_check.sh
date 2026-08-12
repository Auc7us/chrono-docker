#!/usr/bin/env bash
# Check whether the current node/session is ready for the Irrlicht + VNC +
# VirtualGL path. Run this after starting an interactive GPU allocation and
# after connecting to a VNC/desktop session, if your site provides one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Host: $(hostname)"
echo "DISPLAY: ${DISPLAY:-<unset>}"
echo

check_cmd() {
    local name=$1
    if command -v "${name}" >/dev/null 2>&1; then
        echo "OK   ${name}: $(command -v "${name}")"
    else
        echo "MISS ${name}"
    fi
}

check_path() {
    local path=$1
    if [ -e "${path}" ]; then
        echo "OK   ${path}"
    else
        echo "MISS ${path}"
    fi
}

echo "Host tools:"
check_cmd apptainer
check_cmd vncserver
check_cmd Xvnc
check_cmd vglrun
check_cmd glxinfo
check_cmd xdpyinfo
echo

echo "GPU/display devices:"
check_path /dev/dri
if [ -d /dev/dri ]; then
    find /dev/dri -maxdepth 1 -type c -printf '  %p\n' 2>/dev/null || true
fi
echo

if [ -n "${DISPLAY:-}" ] && command -v xdpyinfo >/dev/null 2>&1; then
    echo "X display probe:"
    if xdpyinfo >/dev/null 2>&1; then
        echo "OK   X display is reachable"
    else
        echo "FAIL X display is not reachable from this shell"
    fi
    echo
fi

if [ -n "${DISPLAY:-}" ] && command -v glxinfo >/dev/null 2>&1; then
    echo "Host OpenGL renderer:"
    glxinfo -B 2>/dev/null | sed -n '/OpenGL vendor/,+4p' || echo "FAIL glxinfo could not query GLX"
    echo
fi

if command -v vglrun >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ] && command -v glxinfo >/dev/null 2>&1; then
    echo "VirtualGL OpenGL renderer:"
    if vglrun glxinfo -B >/tmp/chrono-vgl-glxinfo.$$ 2>/tmp/chrono-vgl-glxinfo.err.$$; then
        sed -n '/OpenGL vendor/,+4p' /tmp/chrono-vgl-glxinfo.$$
    else
        echo "FAIL vglrun glxinfo failed"
        sed -n '1,8p' /tmp/chrono-vgl-glxinfo.err.$$ || true
    fi
    rm -f /tmp/chrono-vgl-glxinfo.$$ /tmp/chrono-vgl-glxinfo.err.$$
    echo
fi

echo "Container sanity:"
if [ -z "${WORK:-}" ]; then
    echo "MISS WORK is not set"
    exit 0
fi

SIF="${SIF_PATH:-${WORK}/chrono.sif}"
WORKAREA="${WORKAREA:-${WORK}/chrono-build-area}"

check_path "${SIF}"
check_path "${WORKAREA}/mountdir/chrono_env.sh"

if [ -z "${DISPLAY:-}" ]; then
    echo
    echo "SKIP container display probe because DISPLAY is not set."
    echo "     Start/connect to VNC, Open OnDemand, or SSH X forwarding first."
    exit 0
fi

if [ -f "${SIF}" ] && [ -f "${WORKAREA}/mountdir/chrono_env.sh" ]; then
    "${SCRIPT_DIR}/chrono_vgl_exec.sh" bash -lc 'echo "container DISPLAY=${DISPLAY:-<unset>}"; command -v demo_IRR_HelloWorld >/dev/null 2>&1 && echo "OK   Irrlicht demos are on PATH" || { echo "MISS demo_IRR_HelloWorld"; ls "$HOME"/mountdir/lib/chrono-build/share/chrono/bin/demo_IRR_* 2>/dev/null | head; }'
fi
