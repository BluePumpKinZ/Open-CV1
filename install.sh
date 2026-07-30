#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
OUTPUT_DIR="${ROOT_DIR}/driver_openhmd"
STEAM_DIR="${HOME}/.local/share/Steam"
STEAMVR_DIR="${STEAM_DIR}/steamapps/common/SteamVR"
VRPATHREG="${STEAMVR_DIR}/bin/linux64/vrpathreg"
CONFIG_FILE="${HOME}/.ohmd_config.txt"
STEAMVR_SETTINGS="${STEAM_DIR}/config/steamvr.vrsettings"
LIB_SHIM_DIR="${HOME}/.local/lib/steamvr-openhmd"
BIN_DIR="${HOME}/bin"
APP_DIR="${HOME}/.local/share/applications"
LAUNCHER_LINK="${BIN_DIR}/start-steamvr-openhmd.sh"
OFFSET_LINK="${BIN_DIR}/set-open-cv1-pose-offset.sh"
CALIBRATION_LINK="${BIN_DIR}/calibrate-open-cv1-sensors.sh"
DESKTOP_FILE="${APP_DIR}/SteamVR-OpenHMD.desktop"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_cmd meson
need_cmd ninja
need_cmd python3

if [[ ! -x "${VRPATHREG}" ]]; then
    echo "SteamVR vrpathreg not found at ${VRPATHREG}" >&2
    echo "Install Steam and SteamVR first." >&2
    exit 1
fi

if [[ ! -d "${BUILD_DIR}" ]]; then
    meson setup "${BUILD_DIR}" "${ROOT_DIR}"
fi

meson compile -C "${BUILD_DIR}"

mkdir -p "${LIB_SHIM_DIR}" "${BIN_DIR}" "${APP_DIR}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    cp "${ROOT_DIR}/config/ohmd_config.txt.example" "${CONFIG_FILE}"
fi

if [[ -e /lib64/libdrm.so.2 && ! -e "${LIB_SHIM_DIR}/libdrm.so" ]]; then
    ln -s /lib64/libdrm.so.2 "${LIB_SHIM_DIR}/libdrm.so"
fi

python3 - "${STEAMVR_SETTINGS}" <<'PY'
import json
import os
import sys

config_path = sys.argv[1]

if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
else:
    data = {}

driver_openhmd = data.setdefault("driver_openhmd", {})
driver_openhmd["enable"] = True
driver_openhmd["displayFrequency"] = 90
driver_openhmd.setdefault("secondsFromVsyncToPhotons", 0.011)
driver_openhmd.setdefault("poseOffsetX", 0.0)
driver_openhmd.setdefault("poseOffsetY", 0.0)
driver_openhmd.setdefault("poseOffsetZ", 0.0)
driver_openhmd.setdefault("poseYawDegrees", 0.0)
driver_openhmd.pop("blocked_by_safe_mode", None)

data.setdefault("driver_oculus", {})["enable"] = False
data.setdefault("driver_oculus_legacy", {})["enable"] = False
data.setdefault("driver_lighthouse", {})["enable"] = False
data.setdefault("driver_vrlink", {})["enable"] = False

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=3, sort_keys=True)
    handle.write("\n")
PY

VRPATHREG_OUTPUT="$(LD_LIBRARY_PATH="${STEAMVR_DIR}/bin/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "${VRPATHREG}")"
if ! grep -Fq "${OUTPUT_DIR}" <<<"${VRPATHREG_OUTPUT}"; then
    LD_LIBRARY_PATH="${STEAMVR_DIR}/bin/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        "${VRPATHREG}" adddriver "${OUTPUT_DIR}"
fi

ln -sfn "${ROOT_DIR}/scripts/start-steamvr-openhmd.sh" "${LAUNCHER_LINK}"
ln -sfn "${ROOT_DIR}/scripts/set-pose-offset.sh" "${OFFSET_LINK}"
ln -sfn "${ROOT_DIR}/scripts/calibrate-cv1-sensors.sh" "${CALIBRATION_LINK}"

cat > "${DESKTOP_FILE}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=SteamVR OpenHMD
Comment=Launch SteamVR with the Open-CV1 OpenHMD driver
Exec=${ROOT_DIR}/scripts/start-steamvr-openhmd.sh
Icon=steam
Terminal=false
Categories=Game;
EOF

echo "Open-CV1 installed."
echo "Launcher: ${LAUNCHER_LINK}"
echo "Pose offset helper: ${OFFSET_LINK}"
echo "Sensor calibration helper: ${CALIBRATION_LINK}"
echo "Config file: ${CONFIG_FILE}"
echo "SteamVR settings: ${STEAMVR_SETTINGS}"
