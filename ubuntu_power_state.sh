#!/bin/bash
# Filename: power_state.sh
# Description: Control and report low-power mode on Ubuntu 20.04
# Usage: ./power_state.sh [install|sleep|wake|up]

set -e

# ──────────────────────── Colors ─────────────────────────
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

LOG_PREFIX="[PowerMode]"
ACTION="${1,,}"  # Normalize to lowercase

# 🔐 Check for sudo/root privileges
function require_sudo() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "\n❌ ${RED}This script must be run as root. Please use 'sudo'.${RESET}\n"
        exit 1
    fi
}
require_sudo

# ──────────────────────── Status ─────────────────────────
function check_status() {
    echo -e "\n🔋 ${GREEN}Current System Power Status${RESET}"
    if pgrep -fa pm-powersave >/dev/null; then
        echo -e "🌙 PowerMode     : ${YELLOW}powersave${RESET}"
    else
        echo -e "🚀 PowerMode     : ${GREEN}System Ready${RESET}"
    fi

    echo "───────────────────────────────────────────────"
    echo ""
    echo "Commands: install, sleep, wake, up, (blank for status)"
    echo ""

    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "Unknown")
    echo -e "🧠 CPU Governor     : ${YELLOW}$gov${RESET}"

    echo -e "💽 Disk Spindown    :"
    for disk in /dev/sd[a-z]; do
        if hdparm -I "$disk" &>/dev/null; then
            level=$(hdparm -I "$disk" | grep -o 'Advanced power.*level.*' || echo "Unknown")
            echo -e "   └─ $disk → ${CYAN}${level}${RESET}"
        fi
    done

    echo -e "⚡ Powertop Tune    : ${YELLOW}Transient only${RESET}"
    echo
}

# ──────────────────────── Install ────────────────────────
function install_dependencies() {
    echo -e "\n📦 ${GREEN}[PowerMode] Installing required packages...${RESET}"
    REQUIRED=("cpufrequtils" "pm-utils" "powertop" "hdparm" "fancontrol" "lm-sensors" "x11-utils" "alsa-utils")
    apt-get update -qq
    for pkg in "${REQUIRED[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            echo -e "   ✅ $pkg already installed"
        else
            echo -e "   📥 Installing ${YELLOW}$pkg${RESET}..."
            apt-get install -y "$pkg"
        fi
    done
    echo -e "\n🎉 ${GREEN}All dependencies installed.${RESET}\n"
}

# ──────────────────────── GPU Power ──────────────────────
function gpu_sleep_mode() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "🎮 ${YELLOW}nvidia-smi not found—GPU sleep skipped.${RESET}"
        return
    fi
    echo -e "🎮 ${GREEN}Attempting to unload NVIDIA GPU driver...${RESET}"
    if nvidia-smi | grep -q "No running processes"; then
        modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia && \
        echo -e "🛑 ${GREEN}NVIDIA GPU driver unloaded.${RESET}" || \
        echo -e "⚠️ ${RED}Failed to unload NVIDIA modules—still in use or locked.${RESET}"
    else
        echo -e "⚠️ ${YELLOW}GPU currently in use—skip unloading to avoid disruption.${RESET}"
    fi
}

function gpu_wake_mode() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "🎮 ${YELLOW}nvidia-smi not found—GPU wake skipped.${RESET}"
        return
    fi
    echo -e "🔁 ${GREEN}Re-inserting NVIDIA kernel modules...${RESET}"
    modprobe nvidia
    modprobe nvidia_uvm
    modprobe nvidia_modeset
    modprobe nvidia_drm
    echo -e "🎮 ${GREEN}NVIDIA driver reloaded (check with 'nvidia-smi').${RESET}"
}

# ──────────────── Components: Fan, Net, USB, Sound ───────
function components_sleep() {
    echo -e "\n🛠️ ${GREEN}Applying extra low-power tweaks...${RESET}"

    # Fan (assumes pwmconfig was already run)
    systemctl start fancontrol 2>/dev/null && echo "🌬️ Fancontrol started"

    # Network - keep SSH interface up
    SSH_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    for iface in $(ls /sys/class/net); do
        [[ "$iface" != "$SSH_IF" ]] && ip link set "$iface" down && echo "🔌 Disabled $iface"
    done

    # USB autosuspend
    for u in /sys/bus/usb/devices/*/power/control; do
        echo auto > "$u"
    done
    echo "🔋 USB autosuspend set"

    # Audio
    amixer -q sset Master mute && echo "🔇 Sound muted"

    # Display off (only if X is running)
    if pgrep X &>/dev/null && command -v xrandr &>/dev/null; then
        DISPLAY=$(who | awk '{print $5}' | tr -d '()' | head -n1)
        export DISPLAY=:0
        for output in $(xrandr | grep connected | cut -d' ' -f1); do
            xrandr --output "$output" --off && echo "🖥️ Disabled $output"
        done
    fi
}

function components_wake() {
    echo -e "\n🔧 ${GREEN}Restoring components to normal state...${RESET}"

    systemctl stop fancontrol 2>/dev/null && echo "🌬️ Fancontrol stopped"

    for iface in $(ls /sys/class/net); do
        ip link set "$iface" up 2>/dev/null && echo "🔌 Brought up $iface"
    done

    amixer -q sset Master unmute && echo "🔊 Sound unmuted"
}

# ──────────────────────── Power Actions ───────────────────
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
    gpu_sleep_mode
    components_sleep
    echo "$LOG_PREFIX Low-power mode applied."
}

function exit_sleep_mode() {
    echo "$LOG_PREFIX Restoring system to normal performance..."
    pm-powersave false || true
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        cpuid="${cpu##*/cpu}"
        cpufreq-set -c "$cpuid" -g ondemand
    done
    for disk in /dev/sd[a-z]; do
        hdparm -S 0 "$disk" &>/dev/null && echo "   🔁 $disk spindown disabled"
    done
    gpu_wake_mode
    components_wake
    echo "$LOG_PREFIX System performance settings restored."
}

# ──────────────────────── Command Dispatch ────────────────
case "$ACTION" in
    sleep) enter_sleep_mode ;;
    wake|up) exit_sleep_mode ;;
    install) install_dependencies ;;
    "") check_status ;;
    *)
        echo -e "\n❌ ${RED}Invalid input: '$ACTION'${RESET}"
        echo -e "Usage: sudo $0 [${CYAN}sleep${RESET}|${CYAN}wake${RESET}|${CYAN}up${RESET}|${CYAN}install${RESET}]\n"
        exit 1
        ;;
esac
