#!/usr/bin/env bash
set -euo pipefail

# tbw.sh
# Show TBW / wear / health for all SSD/NVMe drives.
#
# Usage:
#   sudo ./tbw.sh

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: this script must be run as root."
    echo "Example:"
    echo "  sudo $0"
    exit 1
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: missing required command: $1"
        exit 1
    }
}

need_cmd smartctl
need_cmd lsblk
need_cmd awk
need_cmd sed
need_cmd tr
need_cmd grep

trim() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Keep only ASCII digits from a string.
# This makes parsing robust against Unicode separators like:
# 64 464 943
digits_only() {
    tr -cd '0-9'
}

calc_tb_decimal_from_bytes() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN { printf "%.2f", b/1000/1000/1000/1000 }'
}

list_ssd_devices() {
    lsblk -dn -o NAME,TYPE,ROTA | awk '$2=="disk" && $3==0 { print "/dev/" $1 }'
}

get_model() {
    local dev="$1"
    lsblk -dn -o MODEL "$dev" 2>/dev/null | trim
}

get_health() {
    local smart="$1"
    awk -F: '
        /SMART overall-health self-assessment test result/ {
            gsub(/^[[:space:]]+/, "", $2)
            print $2
            exit
        }
        /SMART Health Status/ {
            gsub(/^[[:space:]]+/, "", $2)
            print $2
            exit
        }
    ' <<< "$smart"
}

get_temp() {
    local smart="$1"
    local temp=""

    temp="$(
        awk -F: '
            /^[[:space:]]*Temperature:[[:space:]]/ {
                gsub(/^[[:space:]]+/, "", $2)
                print $2
                exit
            }
        ' <<< "$smart" | digits_only
    )"

    if [[ "$temp" =~ ^[0-9]+$ ]]; then
        echo "${temp}C"
        return
    fi

    temp="$(awk '$1 == 194 || $1 == 190 { print $10; exit }' <<< "$smart" | digits_only)"
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
        echo "${temp}C"
    else
        echo "-"
    fi
}

get_power_on() {
    local smart="$1"
    local raw=""

    raw="$(
        awk -F: '
            /^[[:space:]]*Power On Hours:[[:space:]]/ {
                gsub(/^[[:space:]]+/, "", $2)
                print $2
                exit
            }
        ' <<< "$smart" | digits_only
    )"

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "${raw}h"
        return
    fi

    raw="$(
        awk '
            /Power_On_Hours_and_Msec/ || /Power_On_Hours/ {
                print $10
                exit
            }
        ' <<< "$smart"
    )"

    raw="${raw%%+*}"
    raw="$(printf '%s' "$raw" | digits_only)"

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "${raw}h"
    else
        echo "-"
    fi
}

get_wear() {
    local smart="$1"
    local val="" mwi="" left=""

    # NVMe: Percentage Used
    val="$(
        awk -F: '
            /^[[:space:]]*Percentage Used:[[:space:]]/ {
                gsub(/^[[:space:]]+/, "", $2)
                print $2
                exit
            }
        ' <<< "$smart" | digits_only
    )"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "${val}%"
        return
    fi

    # Intel SATA: Media_Wearout_Indicator (100=new, 0=end)
    mwi="$(awk '/Media_Wearout_Indicator/ { print $10; exit }' <<< "$smart" | digits_only)"
    if [[ "$mwi" =~ ^[0-9]+$ ]] && (( mwi >= 0 && mwi <= 100 )); then
        echo "$((100 - mwi))%"
        return
    fi

    # Some SATA drives expose life left directly
    left="$(
        awk '
            /SSD_Life_Left/ || /Percent_Lifetime_Remain/ || /Remaining_Lifetime_Perc/ {
                print $10
                exit
            }
        ' <<< "$smart" | digits_only
    )"
    if [[ "$left" =~ ^[0-9]+$ ]] && (( left >= 0 && left <= 100 )); then
        echo "$((100 - left))%"
        return
    fi

    echo "-"
}

get_tbw() {
    local smart="$1"
    local raw="" bytes="" line="" attr_name=""

    # NVMe: Data Units Written
    # 1 data unit = 1000 * 512 bytes = 512000 bytes
    raw="$(
        awk -F: '
            /^[[:space:]]*Data Units Written:[[:space:]]/ {
                gsub(/^[[:space:]]+/, "", $2)
                sub(/[[:space:]]*\[.*/, "", $2)
                print $2
                exit
            }
        ' <<< "$smart" | digits_only
    )"

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        bytes="$(awk -v v="$raw" 'BEGIN { printf "%.0f", v * 512000 }')"
        calc_tb_decimal_from_bytes "$bytes"
        return
    fi

    # Intel SATA: Host_Writes_32MiB
    raw="$(awk '/Host_Writes_32MiB/ { print $10; exit }' <<< "$smart" | digits_only)"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        bytes="$(awk -v v="$raw" 'BEGIN { printf "%.0f", v * 32 * 1024 * 1024 }')"
        calc_tb_decimal_from_bytes "$bytes"
        return
    fi

    # Generic SATA attr 241
    line="$(awk '$1 == 241 { print; exit }' <<< "$smart" || true)"
    if [[ -n "$line" ]]; then
        attr_name="$(awk '{print $2}' <<< "$line")"
        raw="$(awk '{print $10}' <<< "$line" | digits_only)"
        if [[ "$raw" =~ ^[0-9]+$ ]] && [[ "$attr_name" =~ LBA|LBAs|Total_LBAs_Written|LBAs_Written ]]; then
            bytes="$(awk -v v="$raw" 'BEGIN { printf "%.0f", v * 512 }')"
            calc_tb_decimal_from_bytes "$bytes"
            return
        fi
    fi

    # Generic SATA attr 242
    line="$(awk '$1 == 242 { print; exit }' <<< "$smart" || true)"
    if [[ -n "$line" ]]; then
        attr_name="$(awk '{print $2}' <<< "$line")"
        raw="$(awk '{print $10}' <<< "$line" | digits_only)"
        if [[ "$raw" =~ ^[0-9]+$ ]] && [[ "$attr_name" =~ LBA|LBAs|Total_LBAs_Written|LBAs_Written ]]; then
            bytes="$(awk -v v="$raw" 'BEGIN { printf "%.0f", v * 512 }')"
            calc_tb_decimal_from_bytes "$bytes"
            return
        fi
    fi

    echo "-"
}

get_disk_usage() {

    local dev="$1"
    local size size_gb used_bytes used_gb percent part_path mp u src
    local -A seen_sources=()

    size=$(lsblk -dn -b -o SIZE "$dev")
    size_gb=$(awk -v s="$size" 'BEGIN{printf "%.0f", s/1000/1000/1000}')

    used_bytes=0

    # Iterate partitions first, then inspect mountpoints per partition.
    while IFS= read -r part_path; do
        [[ -n "$part_path" ]] || continue

        while IFS= read -r mp; do
            [[ -n "$mp" ]] || continue
            [[ "$mp" == "[SWAP]" ]] && continue

            read -r src u < <(df -B1 --output=source,used "$mp" 2>/dev/null | awk 'NR==2 {print $1, $2}')
            [[ -n "$src" ]] || continue
            [[ -n "${seen_sources[$src]:-}" ]] && continue
            [[ "$u" =~ ^[0-9]+$ ]] || continue

            seen_sources["$src"]=1
            used_bytes=$((used_bytes + u))
        done < <(lsblk -ln -o MOUNTPOINTS "$part_path")
    done < <(lsblk -ln -o PATH,TYPE "$dev" | awk '$2=="part" {print $1}')

    used_gb=$(awk -v s="$used_bytes" 'BEGIN{printf "%.0f", s/1000/1000/1000}')

    percent=$(awk -v u="$used_bytes" -v s="$size" 'BEGIN{
        if(s>0) printf "%.0f", (u/s)*100;
        else print 0
    }')

    echo "${size_gb}GB ${used_gb}GB ${percent}%"
}

main() {
    mapfile -t devices < <(list_ssd_devices)

    if [[ "${#devices[@]}" -eq 0 ]]; then
        echo "No SSD/NVMe disks found."
        exit 1
    fi

    #printf "%-12s %-26s %10s %6s %-8s %6s %10s\n" \
    #    "DEVICE" "MODEL" "TBW" "WEAR" "HEALTH" "TEMP" "POWER_ON"
    #printf "%-12s %-26s %10s %6s %-8s %6s %10s\n" \
    #    "------" "-----" "----------" "----" "------" "----" "--------"
    printf "%-12s %-26s %6s %11s %10s %6s %-8s %6s %10s\n" \
	   "DEVICE" "MODEL" "SIZE" "USED" "TBW" "WEAR" "HEALTH" "TEMP" "POWER_ON"

    local dev smart model tbw wear health temp power_on

    for dev in "${devices[@]}"; do
        [[ -b "$dev" ]] || continue

        smart="$(smartctl -a "$dev" 2>/dev/null || true)"
        [[ -n "$smart" ]] || continue

        model="$(get_model "$dev")"
        [[ -n "$model" ]] || model="-"

        tbw="$(get_tbw "$smart")"
        wear="$(get_wear "$smart")"
        health="$(get_health "$smart")"
        temp="$(get_temp "$smart")"
        power_on="$(get_power_on "$smart")"

        [[ -n "$health" ]] || health="-"

	read size used percent <<< $(get_disk_usage "$dev")

	printf "%-12s %-26.26s %6s %7s %3s %10s %6s %-8s %6s %10s\n" \
	       "$dev" "$model" "$size" "$used" "$percent" \
	       "${tbw}TB" "$wear" "$health" "$temp" "$power_on"

        #printf "%-12s %-26.26s %10s %6s %-8s %6s %10s\n" \
        #    "$dev" "$model" "${tbw} TB" "$wear" "$health" "$temp" "$power_on"
    done
}

main "$@"
