#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
STEAM_DIR="${HOME}/.local/share/Steam"
STEAMVR_DIR="${STEAM_DIR}/steamapps/common/SteamVR"
SNIPER_RUN="${STEAM_DIR}/steamapps/common/SteamLinuxRuntime_sniper/run"
VRPATHREG="${STEAMVR_DIR}/bin/linux64/vrpathreg"
OPENHMD_DRIVER_DIR="${ROOT_DIR}/driver_openhmd"
LIB_SHIM_DIR="${HOME}/.local/lib/steamvr-openhmd"
CONFIG_FILE="${HOME}/.ohmd_config.txt"
STEAM_CMD="${STEAM_CMD:-$(command -v steam || true)}"

if [[ -z "${STEAM_CMD}" && -x "${STEAM_DIR}/steam.sh" ]]; then
    STEAM_CMD="${STEAM_DIR}/steam.sh"
fi

if [[ ! -x "${VRPATHREG}" ]]; then
    echo "SteamVR vrpathreg not found at ${VRPATHREG}" >&2
    exit 1
fi

if [[ ! -x "${SNIPER_RUN}" ]]; then
    echo "Steam Linux Runtime sniper launcher not found at ${SNIPER_RUN}" >&2
    exit 1
fi

if [[ -z "${STEAM_CMD}" || ! -x "${STEAM_CMD}" ]]; then
    echo "Steam launcher not found. Expected 'steam' in PATH or ${STEAM_DIR}/steam.sh" >&2
    exit 1
fi

if [[ ! -f "${OPENHMD_DRIVER_DIR}/driver.vrdrivermanifest" ]]; then
    echo "Built Open-CV1 driver manifest not found at ${OPENHMD_DRIVER_DIR}" >&2
    echo "Run ./install.sh from the repository root first." >&2
    exit 1
fi

mkdir -p "${LIB_SHIM_DIR}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    cp "${ROOT_DIR}/config/ohmd_config.txt.example" "${CONFIG_FILE}"
fi

if [[ -e /lib64/libdrm.so.2 && ! -e "${LIB_SHIM_DIR}/libdrm.so" ]]; then
    ln -s /lib64/libdrm.so.2 "${LIB_SHIM_DIR}/libdrm.so"
fi

VRPATHREG_OUTPUT="$(LD_LIBRARY_PATH="${STEAMVR_DIR}/bin/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "${VRPATHREG}")"
if ! grep -Fq "${OPENHMD_DRIVER_DIR}" <<<"${VRPATHREG_OUTPUT}"; then
    LD_LIBRARY_PATH="${STEAMVR_DIR}/bin/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        "${VRPATHREG}" adddriver "${OPENHMD_DRIVER_DIR}"
fi

export OHMD_VENDOR_OVERRIDE="${OHMD_VENDOR_OVERRIDE:-Oculus}"
export LD_LIBRARY_PATH="${LIB_SHIM_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/${UID}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/${UID}"
fi

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "${XDG_RUNTIME_DIR:-/run/user/${UID}}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/${UID}}/bus"
fi

steam_is_running() {
    pgrep -u "${UID}" -f "${STEAM_DIR}/ubuntu12_32/steam" >/dev/null || \
        pgrep -u "${UID}" -f "${STEAM_DIR}/steamrt64/steam" >/dev/null
}

if steam_is_running; then
    cd "${LIB_SHIM_DIR}"
    exec "${SNIPER_RUN}" -- "${STEAMVR_DIR}/bin/vrstartup.sh" "$@"
fi

exec "${STEAM_CMD}" "steam://rungameid/250820"
