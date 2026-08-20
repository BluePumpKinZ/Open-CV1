#!/usr/bin/env bash

set -euo pipefail

CONFIG_DIR="${HOME}/.config/openhmd"
HEIGHT_REQUEST="${CONFIG_DIR}/rift-height-calibration-request"
HEIGHT_RESULT="${CONFIG_DIR}/rift-height-calibration-result.txt"
OFFSET_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/set-pose-offset.sh"

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

    rm -f "${HEIGHT_REQUEST}" "${HEIGHT_RESULT}"
    echo "Put on the headset, stand upright, and keep your head still. Sampling starts in 5 seconds..."
    sleep 5
    printf 'capture\n' > "${HEIGHT_REQUEST}"
    echo "Sampling headset height for two seconds. Stand upright and keep your head still..."

    while (( elapsed < max_wait_seconds )); do
        if [[ -s "${HEIGHT_RESULT}" ]]; then
            local measured_height target_height new_offset
            read -r measured_height < "${HEIGHT_RESULT}"
            if ! awk -v value="${measured_height}" 'BEGIN { exit !(value ~ /^-?[0-9]+([.][0-9]+)?$/) }'; then
                echo "The driver returned an invalid height sample: ${measured_height}" >&2
                return 1
            fi

            target_height="$(awk -v cm="${height_cm}" 'BEGIN { printf "%.6f", cm / 100.0 }')"
            new_offset="$(awk -v target="${target_height}" -v measured="${measured_height}" \
                'BEGIN { printf "%.6f", target - measured }')"
            "${OFFSET_SCRIPT}" --y "${new_offset}"
            rm -f "${HEIGHT_RESULT}"

            echo "Raw headset height: ${measured_height} m"
            echo "Target height: ${target_height} m"
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

usage() {
    cat <<'EOF'
Usage:
  calibrate-cv1-sensors.sh --show
  calibrate-cv1-sensors.sh --reset
  calibrate-cv1-sensors.sh --height-cm CM
  calibrate-cv1-sensors.sh --relearn [--height-cm CM]
  calibrate-cv1-sensors.sh --set SERIAL QX QY QZ QW PX PY PZ
  calibrate-cv1-sensors.sh --set-pos SERIAL PX PY PZ
  calibrate-cv1-sensors.sh --offset DX DY DZ

Actions:
  --show                Print saved CV1 sensor pose caches.
  --reset               Remove saved CV1 sensor pose caches.
  --height-cm           Measure worn headset height without relearning sensors.
  --relearn             Relearn sensors, then set height while the headset is worn.
  --set                 Write a full sensor pose cache for one sensor serial.
  --set-pos             Update only a sensor position and keep its saved orientation.
  --offset              Apply a uniform translation to every saved sensor position.

Notes:
  Cached poses are stored as quaternion + position in:
    ~/.config/openhmd/rift-sensor-pose-<serial>.txt
  --relearn requires SteamVR to be closed first. It backs up and clears existing
  caches, then waits for you to start SteamVR manually. Wear the headset, stand
  upright, and keep your head and sensors still until calibration completes.
  The driver measures raw headset height and updates poseOffsetY. Restart
  SteamVR afterward to load the new offset.
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
        calibrate_height "${height_cm}"
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
