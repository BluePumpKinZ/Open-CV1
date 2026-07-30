#!/usr/bin/env bash

set -euo pipefail

CONFIG_DIR="${HOME}/.config/openhmd"
LAUNCHER="${HOME}/bin/start-steamvr-openhmd.sh"

cache_files() {
    shopt -s nullglob
    local files=("${CONFIG_DIR}"/rift-sensor-pose-*.txt)
    shopt -u nullglob
    printf '%s\n' "${files[@]}"
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
        rm -f "${files[@]}"
    fi
    echo "Cleared cached CV1 sensor poses from ${CONFIG_DIR}."
}

launch_and_relearn() {
    pkill -TERM -x vrserver 2>/dev/null || true
    pkill -TERM -x vrcompositor 2>/dev/null || true
    pkill -TERM -x vrmonitor 2>/dev/null || true
    pkill -TERM -x vrdashboard 2>/dev/null || true
    nohup "${LAUNCHER}" >/tmp/open-cv1-calibration-launch.log 2>&1 &

    echo "SteamVR relaunched. Wear the headset and slowly move it through the tracked volume for 15-20 seconds."
    echo "Waiting for sensor pose caches to appear..."

    for _ in $(seq 1 30); do
        mapfile -t files < <(cache_files)
        if [[ ${#files[@]} -gt 0 ]]; then
            echo "Detected saved sensor poses:"
            show_cache
            return 0
        fi
        sleep 1
    done

    echo "No sensor pose caches appeared within 30 seconds."
    echo "Check ~/.local/share/Steam/logs/vrserver.txt for 'Loaded sensor' or 'Saved sensor' log lines."
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

usage() {
    cat <<'EOF'
Usage:
  calibrate-cv1-sensors.sh --show
  calibrate-cv1-sensors.sh --reset
  calibrate-cv1-sensors.sh --relearn
  calibrate-cv1-sensors.sh --set SERIAL QX QY QZ QW PX PY PZ
  calibrate-cv1-sensors.sh --set-pos SERIAL PX PY PZ
  calibrate-cv1-sensors.sh --offset DX DY DZ

Actions:
  --show                Print saved CV1 sensor pose caches.
  --reset               Remove saved CV1 sensor pose caches.
  --relearn             Remove saved caches, restart SteamVR, and wait for new sensor poses to be learned.
  --set                 Write a full sensor pose cache for one sensor serial.
  --set-pos             Update only a sensor position and keep its saved orientation.
  --offset              Apply a uniform translation to every saved sensor position.

Notes:
  Cached poses are stored as quaternion + position in:
    ~/.config/openhmd/rift-sensor-pose-<serial>.txt
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
    --relearn)
        reset_cache
        launch_and_relearn
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
