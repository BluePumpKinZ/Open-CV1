#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="${HOME}/.local/share/Steam/config/steamvr.vrsettings"

usage() {
    cat <<'EOF'
Usage:
  set-pose-offset.sh [--x meters] [--y meters] [--z meters] [--yaw degrees]

Examples:
  set-pose-offset.sh --y 0.18
  set-pose-offset.sh --x 0.05 --z -0.10 --yaw 15
  set-pose-offset.sh --x 0 --y 0 --z 0 --yaw 0
EOF
}

x=""
y=""
z=""
yaw=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --x)
            x="$2"
            shift 2
            ;;
        --y)
            y="$2"
            shift 2
            ;;
        --z)
            z="$2"
            shift 2
            ;;
        --yaw)
            yaw="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

python3 - "$CONFIG_FILE" "$x" "$y" "$z" "$yaw" <<'PY'
import json
import os
import sys

config_path, x, y, z, yaw = sys.argv[1:]

if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
else:
    data = {}

driver = data.setdefault("driver_openhmd", {})

if x:
    driver["poseOffsetX"] = float(x)
if y:
    driver["poseOffsetY"] = float(y)
if z:
    driver["poseOffsetZ"] = float(z)
if yaw:
    driver["poseYawDegrees"] = float(yaw)

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=3, sort_keys=True)
    handle.write("\n")
PY

echo "Updated ${CONFIG_FILE}"

