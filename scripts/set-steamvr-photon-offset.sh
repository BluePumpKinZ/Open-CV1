#!/usr/bin/env bash

set -euo pipefail

STEAM_DIR="${HOME}/.local/share/Steam"
STEAMVR_DIR="${STEAM_DIR}/steamapps/common/SteamVR"
VRCMD="${STEAMVR_DIR}/bin/linux64/vrcmd"

usage() {
    cat <<'EOF'
Usage:
  set-steamvr-photon-offset.sh --offset MILLISECONDS
  set-steamvr-photon-offset.sh --reset

Applies SteamVR's compositor-only prediction timing offset. It is not written
to steamvr.vrsettings and resets when SteamVR exits.

Use small A/B trials only: 0, +0.5, and -0.5 ms. Do not exceed +/-3 ms.
EOF
}

offset=""

case "${1:-}" in
    --offset)
        [[ $# -eq 2 ]] || { usage >&2; exit 1; }
        offset="$2"
        ;;
    --reset)
        [[ $# -eq 1 ]] || { usage >&2; exit 1; }
        offset="0"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac

if [[ ! -x "${VRCMD}" ]]; then
    echo "SteamVR vrcmd was not found at ${VRCMD}." >&2
    exit 1
fi

if ! pgrep -x vrcompositor >/dev/null 2>&1; then
    echo "SteamVR is not running." >&2
    exit 1
fi

if ! [[ "${offset}" =~ ^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
    echo "Offset must be a number of milliseconds." >&2
    exit 1
fi

if ! awk -v value="${offset}" 'BEGIN { exit !(value >= -3.0 && value <= 3.0) }'; then
    echo "Offset must be between -3 and +3 milliseconds." >&2
    exit 1
fi

LD_LIBRARY_PATH="${STEAMVR_DIR}/bin/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${VRCMD}" --set-vsync-to-photons-offset-ms "${offset}"

echo "Applied runtime-only vsync-to-photon offset: ${offset} ms."
echo "It resets when SteamVR exits; use --reset to return to the 0 ms baseline now."
