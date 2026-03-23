#!/bin/bash
set -e

if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    mkdir -p "${XDG_RUNTIME_DIR}"
    chmod 700 "${XDG_RUNTIME_DIR}" || true
fi

# Normalize the host Xauthority cookie into a writable per-container file.
# This makes SSH-forwarded displays like localhost:10.0 work even when the
# host cookie is stored against a different hostname.
if [ -f /tmp/host.XAuthority ]; then
    HOST_XAUTH=/tmp/host.XAuthority
elif [ -f /tmp/host.Xauthority ]; then
    HOST_XAUTH=/tmp/host.Xauthority
else
    HOST_XAUTH=""
fi

if [ -n "${XAUTHORITY:-}" ] && [ -n "${HOST_XAUTH}" ]; then
    mkdir -p "$(dirname "${XAUTHORITY}")"
    touch "${XAUTHORITY}"
    chmod 600 "${XAUTHORITY}"

    if command -v xauth >/dev/null 2>&1; then
        xauth -f "${XAUTHORITY}" nmerge - >/dev/null 2>&1 <<EOF || true
$(xauth -f "${HOST_XAUTH}" nlist 2>/dev/null | sed 's/^..../ffff/')
EOF
    else
        cp "${HOST_XAUTH}" "${XAUTHORITY}"
    fi
fi

exec "$@"
