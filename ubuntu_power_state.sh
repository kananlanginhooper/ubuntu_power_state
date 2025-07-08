#!/bin/bash

# Filename: power_state.sh
# Description: Control and report low-power mode on Ubuntu 20.04
# Usage: ./power_state.sh [sleep|wake|up]

set -e


# Check for sudo/root privileges
function require_sudo() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "\n❌ ${RED}This script must be run as root. Please use 'sudo'.${RESET}\n"
        exit 1
    fi
}


ACTION="${1,,}"  # Normalize to lowercase
LOG_PREFIX="[PowerMode]"


# ──────────────────────── Colors ─────────────────────────
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"


# check that sudo
require_sudo


check_status() {
    echo -e "\n🔋 ${GREEN}[PowerMode] Current System Power Status${RESET}"
    echo "───────────────────────────────────────────────"
    echo ""
    echo "Commands: sleep, up, wake, (blank for status)"
    echo ""

    # CPU Governor
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "Unknown")
    echo -e "🧠 CPU Governor     : ${YELLOW}$gov${RESET}"

    # pm-powersave
    if pgrep -fa pm-powersave >/dev/null; then
        echo -e "🌙 pm-powersave     : ${GREEN}Active${RESET}"
    else
        echo -e "🌙 pm-powersave     : ${RED}Not active${RESET}"
    fi

    # Disk Spindown
    echo -e "💽 Disk Spindown    :"
    for disk in /dev/sd[a-z]; do
        if hdparm -I "$disk" &>/dev/null; then
            level=$(hdparm -I "$disk" | grep -o 'Advanced power.*level.*' || echo "Unknown")
            echo -e "   └─ $disk → ${CYAN}${level}${RESET}"
        fi
    done

    # Powertop
    echo -e "⚡ Powertop Tune    : ${YELLOW}Transient only – rerun to apply persistently${RESET}"
    echo
}


function enter_sleep_mode() {
    echo "$LOG_PREFIX Enabling low-power settings..."

    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        cpuid="${cpu##*/cpu}"
        cpufreq-set -c "$cpuid" -g powersave
    done

    pm-powersave true || true

    for disk in /dev/sd[a-z]; do
        hdparm -S 120 "$disk" &>/dev/null && echo "   ⏳ $disk spindown set"
    done

    powertop --auto-tune &>/dev/null || echo "   ⚠️ powertop failed to run"

    echo "$LOG_PREFIX Low-power mode applied."
}

function exit_sleep_mode() {
    echo "$LOG_PREFIX Restoring system to normal performance..."

    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        cpuid="${cpu##*/cpu}"
        cpufreq-set -c "$cpuid" -g ondemand
    done

    pm-powersave false || true

    for disk in /dev/sd[a-z]; do
        hdparm -S 0 "$disk" &>/dev/null && echo "   🔁 $disk spindown disabled"
    done

    echo "$LOG_PREFIX System performance settings restored."
}

case "$ACTION" in
    sleep)
        enter_sleep_mode
        ;;
    wake|up)
        exit_sleep_mode
        ;;
    "")
        check_status
        ;;
    *)
        echo "Usage: $0 [sleep|wake|up]"
        ;;
esac

