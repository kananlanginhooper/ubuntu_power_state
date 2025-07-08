#!/bin/bash

# Filename: power_state.sh
# Description: Control and report low-power mode on Ubuntu 20.04
# Usage: ./power_state.sh [sleep|wake|up]

set -e

ACTION="${1,,}"  # Normalize to lowercase
LOG_PREFIX="[PowerMode]"

function check_status() {
    echo "$LOG_PREFIX Current system power state:"
    
    echo -n " - CPU governor: "
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "Unknown"

    echo -n " - pm-powersave active: "
    pgrep -fa pm-powersave >/dev/null && echo "Likely" || echo "Not active"

    echo -n " - Disk spindown timers: "
    for disk in /dev/sd[a-z]; do
        if hdparm -I "$disk" &>/dev/null; then
            echo -n "$disk → "
            hdparm -I "$disk" | grep level | grep -o 'level.*' || echo "unknown"
        fi
    done

    echo " - Powertop autotune status: No persistent state, rerun to apply."
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
