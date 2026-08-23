#!/usr/bin/env bash

set -euo pipefail

CONFIG_DIR="${HOME}/.config/openhmd"
HEIGHT_REQUEST="${CONFIG_DIR}/rift-height-calibration-request"
HEIGHT_RESULT="${CONFIG_DIR}/rift-height-calibration-result.txt"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
OFFSET_SCRIPT="$(dirname "${SCRIPT_PATH}")/set-pose-offset.sh"
CHAPERONE_CONFIG="${HOME}/.local/share/Steam/config/chaperone_info.vrchap"
HEAD_TO_EYES_CM=12

cache_files() {
    shopt -s nullglob
    local files=("${CONFIG_DIR}"/rift-sensor-pose-*.txt)
    shopt -u nullglob
    if [[ ${#files[@]} -gt 0 ]]; then
        printf '%s\n' "${files[@]}"
    fi
}

cache_path_for_serial() {
    local serial="${1//[^[:alnum:]]/_}"
    printf '%s/rift-sensor-pose-%s.txt\n' "${CONFIG_DIR}" "${serial}"
}

read_pose() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        echo "Missing sensor pose cache: ${file}" >&2
        return 1
    fi
    read -r QX QY QZ QW PX PY PZ < "${file}"
}

write_pose() {
    local file="$1"
    local qx="$2"
    local qy="$3"
    local qz="$4"
    local qw="$5"
    local px="$6"
    local py="$7"
    local pz="$8"
    mkdir -p "${CONFIG_DIR}"
    printf '%s %s %s %s %s %s %s\n' \
        "${qx}" "${qy}" "${qz}" "${qw}" "${px}" "${py}" "${pz}" > "${file}"
}

show_cache() {
    mapfile -t files < <(cache_files)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No cached CV1 sensor poses found in ${CONFIG_DIR}."
        return 0
    fi

    for file in "${files[@]}"; do
        read_pose "${file}"
        printf '%s\n' "${file##*/}"
        printf '  quat: %s %s %s %s\n' "${QX}" "${QY}" "${QZ}" "${QW}"
        printf '  pos : %s %s %s\n' "${PX}" "${PY}" "${PZ}"
    done
}

reset_cache() {
    mkdir -p "${CONFIG_DIR}"
    mapfile -t files < <(cache_files)
    if [[ ${#files[@]} -gt 0 ]]; then
        local backup_dir="${CONFIG_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${backup_dir}"
        cp -a "${files[@]}" "${backup_dir}/"
        echo "Backed up cached CV1 sensor poses to ${backup_dir}."
        rm -f "${files[@]}"
    fi
    echo "Cleared cached CV1 sensor poses from ${CONFIG_DIR}."
}

wait_for_relearn() {
    local max_wait_seconds=30
    local elapsed=0
    local expected_cache_count=2
    local last_cache_count=-1

    echo "Start SteamVR manually now with the headset on your head."
    echo "Stand upright at the center of the play area, face forward, and keep your head and both sensors still."
    echo "Waiting for ${expected_cache_count} sensor pose caches to appear..."

    while (( elapsed < max_wait_seconds )); do
        mapfile -t files < <(cache_files)
        if (( ${#files[@]} != last_cache_count )); then
            echo "Detected ${#files[@]}/${expected_cache_count} saved sensor pose caches."
            last_cache_count=${#files[@]}
        fi

        if (( ${#files[@]} >= expected_cache_count )); then
            echo "Both sensor poses are saved. Calibration complete:"
            show_cache
            return 0
        fi
        sleep 1
        ((elapsed += 1))
    done

    echo "Only ${last_cache_count}/${expected_cache_count} sensor pose caches appeared within 30 seconds."
    echo "Check ~/.local/share/Steam/logs/vrserver.txt for 'Loaded sensor' or 'Saved sensor' log lines."
    return 1
}

validate_height_cm() {
    local height_cm="$1"
    awk -v value="${height_cm}" 'BEGIN {
        if (value !~ /^[0-9]+([.][0-9]+)?$/ || value < 100 || value > 250)
            exit 1
    }'
}

prompt_for_height_cm() {
    local height_cm=""
    if [[ ! -t 0 ]]; then
        echo "Pass your height with --height-cm when running non-interactively." >&2
        return 1
    fi

    read -r -p "Enter the height Beat Saber should report, in cm: " height_cm
    if ! validate_height_cm "${height_cm}"; then
        echo "Height must be a number from 100 to 250 cm." >&2
        return 1
    fi
    printf '%s\n' "${height_cm}"
}

calibrate_height() {
    local height_cm="$1"
    local max_wait_seconds=20
    local elapsed=0

    if [[ ! -r "${CHAPERONE_CONFIG}" ]]; then
        echo "Cannot read SteamVR standing-space calibration: ${CHAPERONE_CONFIG}" >&2
        return 1
    fi

    rm -f "${HEIGHT_REQUEST}" "${HEIGHT_RESULT}"
    echo "Put on the headset, stand upright, and keep your head still. Sampling starts in 5 seconds..."
    sleep 5
    printf 'capture\n' > "${HEIGHT_REQUEST}"
    echo "Sampling headset height for two seconds. Stand upright and keep your head still..."

    while (( elapsed < max_wait_seconds )); do
        if [[ -s "${HEIGHT_RESULT}" ]]; then
            local measured_height standing_y target_eye_height new_offset
            read -r measured_height < "${HEIGHT_RESULT}"
            if ! awk -v value="${measured_height}" 'BEGIN { exit !(value ~ /^-?[0-9]+([.][0-9]+)?$/) }'; then
                echo "The driver returned an invalid height sample: ${measured_height}" >&2
                return 1
            fi

            standing_y="$(python3 - "${CHAPERONE_CONFIG}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

universes = data.get("universes", [])
universe = next((item for item in universes if str(item.get("universeID")) == "2"), None)
if universe is None and len(universes) == 1:
    universe = universes[0]
if universe is None:
    raise SystemExit("Could not find SteamVR standing universe 2")

print(float(universe["standing"]["translation"][1]))
PY
            )"
            target_eye_height="$(awk -v cm="${height_cm}" -v eye="${HEAD_TO_EYES_CM}" \
                'BEGIN { printf "%.6f", (cm - eye) / 100.0 }')"
            new_offset="$(awk -v target="${target_eye_height}" -v measured="${measured_height}" \
                -v standing="${standing_y}" 'BEGIN { printf "%.6f", target - measured - standing }')"
            if ! awk -v value="${new_offset}" 'BEGIN { exit !(value >= -0.5 && value <= 1.0) }'; then
                echo "Refusing implausible poseOffsetY ${new_offset} m; the current setting was not changed." >&2
                return 1
            fi
            "${OFFSET_SCRIPT}" --y "${new_offset}"
            rm -f "${HEIGHT_RESULT}"

            echo "Raw driver height: ${measured_height} m"
            echo "SteamVR standing translation: ${standing_y} m"
            echo "Target eye height: ${target_eye_height} m (${height_cm} cm body height minus ${HEAD_TO_EYES_CM} cm)"
            echo "Set poseOffsetY to ${new_offset} m. Restart SteamVR for it to take effect."
            return 0
        fi
        sleep 1
        ((elapsed += 1))
    done

    rm -f "${HEIGHT_REQUEST}"
    echo "The driver did not return a stable headset height within ${max_wait_seconds} seconds." >&2
    echo "Keep the headset still and check that SteamVR is using the newly built Open-CV1 driver." >&2
    return 1
}

set_pose() {
    local serial="$1"
    local file
    file="$(cache_path_for_serial "${serial}")"
    write_pose "${file}" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    echo "Wrote ${file##*/}."
}

set_position() {
    local serial="$1"
    local file
    file="$(cache_path_for_serial "${serial}")"
    if [[ -f "${file}" ]]; then
        read_pose "${file}"
    else
        QX=0
        QY=0
        QZ=0
        QW=1
    fi
    write_pose "${file}" "${QX}" "${QY}" "${QZ}" "${QW}" "$2" "$3" "$4"
    echo "Updated position for ${file##*/}."
}

offset_positions() {
    local dx="$1"
    local dy="$2"
    local dz="$3"
    mapfile -t files < <(cache_files)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No cached CV1 sensor poses found in ${CONFIG_DIR}."
        return 1
    fi

    for file in "${files[@]}"; do
        read_pose "${file}"
        local new_px new_py new_pz
        new_px="$(awk -v a="${PX}" -v b="${dx}" 'BEGIN { printf "%.6f", a + b }')"
        new_py="$(awk -v a="${PY}" -v b="${dy}" 'BEGIN { printf "%.6f", a + b }')"
        new_pz="$(awk -v a="${PZ}" -v b="${dz}" 'BEGIN { printf "%.6f", a + b }')"
        write_pose "${file}" "${QX}" "${QY}" "${QZ}" "${QW}" "${new_px}" "${new_py}" "${new_pz}"
        printf 'Offset %s to pos %s %s %s\n' "${file##*/}" "${new_px}" "${new_py}" "${new_pz}"
    done
}

align_standing_yaw_to_sensors() {
    if [[ ! -r "${CHAPERONE_CONFIG}" ]]; then
        echo "Cannot read SteamVR standing-space calibration: ${CHAPERONE_CONFIG}" >&2
        return 1
    fi

    mapfile -t files < <(cache_files)
    if [[ ${#files[@]} -lt 2 ]]; then
        echo "Need at least two cached CV1 sensor poses to average their forward directions." >&2
        return 1
    fi

    local backup_path="${CHAPERONE_CONFIG}.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a "${CHAPERONE_CONFIG}" "${backup_path}"

    python3 - "${CHAPERONE_CONFIG}" "${files[@]}" <<'PY'
import json
import math
import os
import sys
import tempfile

config_path = sys.argv[1]
pose_paths = sys.argv[2:]
forward_x = 0.0
forward_z = 0.0

for pose_path in pose_paths:
    values = [float(value) for value in open(pose_path, "r", encoding="utf-8").read().split()]
    if len(values) != 7:
        raise SystemExit(f"Invalid sensor pose cache: {pose_path}")

    qx, qy, qz, qw = values[:4]
    q_length = math.sqrt(qx*qx + qy*qy + qz*qz + qw*qw)
    if q_length < 1e-6:
        raise SystemExit(f"Invalid zero-length sensor quaternion: {pose_path}")
    qx, qy, qz, qw = (value / q_length for value in (qx, qy, qz, qw))

    # Camera poses transform camera space to world space. Rotate the camera's
    # optical +Z axis into world space and average only its horizontal heading.
    x = 2.0 * (qx*qz + qw*qy)
    z = 1.0 - 2.0 * (qx*qx + qy*qy)
    horizontal_length = math.hypot(x, z)
    if horizontal_length < 1e-6:
        raise SystemExit(f"Sensor forward direction is vertical: {pose_path}")
    forward_x += x / horizontal_length
    forward_z += z / horizontal_length

if math.hypot(forward_x, forward_z) < 0.25:
    raise SystemExit("Sensor forward directions cancel; cannot choose a stable average yaw")

average_yaw = math.atan2(forward_x, forward_z)

with open(config_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

universes = data.get("universes", [])
universe = next((item for item in universes if str(item.get("universeID")) == "2"), None)
if universe is None and len(universes) == 1:
    universe = universes[0]
if universe is None or "standing" not in universe:
    raise SystemExit("Could not find SteamVR standing universe 2")

old_yaw = float(universe["standing"].get("yaw", 0.0))
universe["standing"]["yaw"] = average_yaw

config_dir = os.path.dirname(config_path)
fd, temporary_path = tempfile.mkstemp(prefix=".chaperone_info.", dir=config_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=3, sort_keys=True)
        handle.write("\n")
    os.chmod(temporary_path, os.stat(config_path).st_mode)
    os.replace(temporary_path, config_path)
except Exception:
    try:
        os.unlink(temporary_path)
    except FileNotFoundError:
        pass
    raise

print(f"SteamVR standing yaw: {math.degrees(old_yaw):.3f} -> {math.degrees(average_yaw):.3f} degrees")
PY

    echo "Backed up the previous SteamVR chaperone calibration to ${backup_path}."
    echo "Aligned standing forward to the average direction of ${#files[@]} sensors."
    echo "Restart SteamVR for the new standing yaw to take effect."
}

usage() {
    cat <<'EOF'
Usage:
  calibrate-cv1-sensors.sh --show
  calibrate-cv1-sensors.sh --reset
  calibrate-cv1-sensors.sh --height-cm CM
  calibrate-cv1-sensors.sh --relearn [--height-cm CM]
  calibrate-cv1-sensors.sh --align-forward
  calibrate-cv1-sensors.sh --set SERIAL QX QY QZ QW PX PY PZ
  calibrate-cv1-sensors.sh --set-pos SERIAL PX PY PZ
  calibrate-cv1-sensors.sh --offset DX DY DZ

Actions:
  --show                Print saved CV1 sensor pose caches.
  --reset               Remove saved CV1 sensor pose caches.
  --height-cm           Measure worn headset height without relearning sensors.
  --relearn             Relearn sensors, then set height while the headset is worn.
  --align-forward       Set SteamVR forward from the average sensor direction.
  --set                 Write a full sensor pose cache for one sensor serial.
  --set-pos             Update only a sensor position and keep its saved orientation.
  --offset              Apply a uniform translation to every saved sensor position.

Notes:
  Cached poses are stored as quaternion + position in:
    ~/.config/openhmd/rift-sensor-pose-<serial>.txt
  --relearn requires SteamVR to be closed first. It backs up and clears existing
  caches, then waits for you to start SteamVR manually. Wear the headset, stand
  upright, and keep your head and sensors still until calibration completes.
  The driver measures raw headset height, accounts for SteamVR's standing-space
  transform and a 12 cm head-to-eye distance, then updates poseOffsetY. Restart
  SteamVR afterward to load the new offset.
  --align-forward preserves sensor poses and averages their horizontal optical
  axes, handling sensors that are turned inward toward the play area.
  Stand upright with SteamVR running before using --height-cm by itself.
  Use --offset 0 0.10 0 to raise all saved sensors by 10 cm.
EOF
}

case "${1:-}" in
    --show)
        show_cache
        ;;
    --reset)
        reset_cache
        ;;
    --height-cm)
        [[ $# -eq 2 ]] || { usage; exit 1; }
        if ! validate_height_cm "$2"; then
            echo "Height must be a number from 100 to 250 cm." >&2
            exit 1
        fi
        if ! pgrep -x vrserver >/dev/null 2>&1; then
            echo "Start SteamVR and wear the headset before measuring height." >&2
            exit 1
        fi
        calibrate_height "$2"
        ;;
    --relearn)
        if [[ $# -eq 3 && "$2" == "--height-cm" ]]; then
            height_cm="$3"
            if ! validate_height_cm "${height_cm}"; then
                echo "Height must be a number from 100 to 250 cm." >&2
                exit 1
            fi
        elif [[ $# -eq 1 ]]; then
            height_cm="$(prompt_for_height_cm)"
        else
            usage >&2
            exit 1
        fi
        if pgrep -x vrserver >/dev/null 2>&1; then
            echo "Close SteamVR before relearning sensor poses, then run this command again." >&2
            exit 1
        fi
        reset_cache
        wait_for_relearn
        align_standing_yaw_to_sensors
        calibrate_height "${height_cm}"
        ;;
    --align-forward)
        [[ $# -eq 1 ]] || { usage; exit 1; }
        align_standing_yaw_to_sensors
        ;;
    --set)
        [[ $# -eq 9 ]] || { usage; exit 1; }
        set_pose "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
        ;;
    --set-pos)
        [[ $# -eq 5 ]] || { usage; exit 1; }
        set_position "$2" "$3" "$4" "$5"
        ;;
    --offset)
        [[ $# -eq 4 ]] || { usage; exit 1; }
        offset_positions "$2" "$3" "$4"
        ;;
    *)
        usage
        exit 1
        ;;
esac
