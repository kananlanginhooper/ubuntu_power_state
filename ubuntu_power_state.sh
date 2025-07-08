#!/bin/bash
# Filename: power_state.sh
# Description: Control and report low-power mode on Ubuntu 20.04+
# Usage: sudo ./power_state.sh [install|sleep|wake|up]

set -e

# ─────────────────────── Colors ─────────────────────────
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

LOG_PREFIX="[PowerMode]"
ACTION="${1,,}"  # Normalize input

# 🔐 Require sudo
function require_sudo() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "\n❌ ${RED}This script must be run as root. Please use 'sudo'.${RESET}\n"
        exit 1
    fi
}
require_sudo

# 🧪 Power status readout
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

    # CPU Governor
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "Unknown")
    echo -e "🧠 CPU Governor     : ${YELLOW}$gov${RESET}"

    # CPU Frequency (average MHz)
    cpu_freqs=()
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [[ -f "$cpu/cpufreq/scaling_cur_freq" ]] && f=$(< "$cpu/cpufreq/scaling_cur_freq") && cpu_freqs+=($((f / 1000)))
    done
    if ((${#cpu_freqs[@]} > 0)); then
        sum=0; for f in "${cpu_freqs[@]}"; do ((sum+=f)); done
        avg=$((sum / ${#cpu_freqs[@]}))
        echo -e "⏱️  CPU Frequency    : ${YELLOW}${avg} MHz (avg)${RESET}"
    fi

    # RAM Speed
    if command -v dmidecode &>/dev/null; then
        ram_speed=$(dmidecode --type 17 | grep "Configured Memory Speed" | awk '{print $4, $5}' | sort -u)
        [[ -n "$ram_speed" ]] && echo -e "🧬 RAM Speed        : ${CYAN}${ram_speed}${RESET}"
    fi

    echo -e "💽 Disk Devices     :"
    for disk in /dev/sd[a-z]; do
        dev=$(basename "$disk")
        [[ -f /sys/block/$dev/queue/rotational ]] && rot=$(< /sys/block/$dev/queue/rotational)
        type=$([[ "$rot" == "0" ]] && echo "SSD" || echo "HDD")
        if [[ "$type" == "HDD" ]]; then
            level=$(hdparm -I "$disk" 2>/dev/null | grep -o 'Advanced power.*level.*' || echo "Unknown")
            echo -e "   └─ $disk → ${CYAN}$level${RESET}"
        else
            echo -e "   └─ $disk → ${YELLOW}Spindown N/A ($type)${RESET}"
        fi
    done
    for nvme in /dev/nvme*n1; do
        [[ -e "$nvme" ]] && echo -e "   └─ $nvme → ${YELLOW}Spindown N/A (NVMe)${RESET}"
    done

    echo -e "⚡ Powertop Tune    : ${YELLOW}Transient only${RESET}"
    echo
}

# 📦 Install dependencies
function install_dependencies() {
    echo -e "\n📦 ${GREEN}[PowerMode] Installing required packages...${RESET}"
    REQUIRED=(cpufrequtils pm-utils powertop hdparm fancontrol lm-sensors x11-utils alsa-utils dmidecode)
    apt-get update -qq
    for pkg in "${REQUIRED[@]}"; do
        dpkg -s "$pkg" &>/dev/null && echo -e "   ✅ $pkg already installed" || {
            echo -e "   📥 Installing ${YELLOW}$pkg${RESET}..."
            apt-get install -y "$pkg"
        }
    done
    echo -e "\n🎉 ${GREEN}All dependencies installed.${RESET}\n"
}

# 🎮 NVIDIA GPU control
function gpu_sleep_mode() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "🎮 ${YELLOW}nvidia-smi not found—GPU sleep skipped.${RESET}"
        return
    fi
    echo -e "🎮 ${GREEN}Attempting to unload NVIDIA GPU driver...${RESET}"
    if nvidia-smi | grep -q "No running processes"; then
        modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia && \
        echo -e "🛑 ${GREEN}NVIDIA GPU driver unloaded.${RESET}" || \
        echo -e "⚠️  ${RED}Failed to unload NVIDIA modules—still in use or locked.${RESET}"
    else
        echo -e "⚠️  ${YELLOW}GPU currently in use—skip unloading to avoid disruption.${RESET}"
    fi
}

function gpu_wake_mode() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "🎮 ${YELLOW}nvidia-smi not found—GPU wake skipped.${RESET}"
        return
    fi
    echo -e "🔁 ${GREEN}Re-inserting NVIDIA kernel modules...${RESET}"
    modprobe nvidia nvidia_uvm nvidia_modeset nvidia_drm
    echo -e "🎮 ${GREEN}NVIDIA driver reloaded (check with 'nvidia-smi').${RESET}"
}

# 🔋 Extra components
function components_sleep() {
    echo -e "\n🛠️  ${GREEN}Applying extra low-power tweaks...${RESET}"
    systemctl start fancontrol 2>/dev/null && echo "🌬️  Fancontrol started"

    SSH_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    for iface in $(ls /sys/class/net); do
        [[ "$iface" != "$SSH_IF" ]] && ip link set "$iface" down && echo "🔌 Disabled $iface"
    done

    for u in /sys/bus/usb/devices/*/power/control; do echo auto > "$u" 2>/dev/null; done
    echo "🔋 USB autosuspend set"

    amixer -q sset Master mute && echo "🔇 Sound muted"

    if pgrep X &>/dev/null && command -v xrandr &>/dev/null; then
        export DISPLAY=:0
        for output in $(xrandr | grep connected | awk '{print $1}'); do
            xrandr --output "$output" --off && echo "🖥️  Disabled $output"
        done
    fi
}

function components_wake() {
    echo -e "\n🔧 ${GREEN}Restoring components to normal state...${RESET}"
    systemctl stop fancontrol 2>/dev/null && echo "🌬️  Fancontrol stopped"
    for iface in $(ls /sys/class/net); do ip link set "$iface" up 2>/dev/null && echo "🔌 Enabled $iface"; done
    amixer -q sset Master unmute && echo "🔊 Sound unmuted"
}

# 💤 Sleep mode
function enter_sleep_mode() {
    echo "$LOG_PREFIX Enabling low-power settings..."

    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        cpufreq-set -c "${cpu##*/cpu}" -g powersave
    done

    pm-powersave true || true

    for disk in /dev/sd[a-z]; do
        if [[ -f /sys/block/${disk#/dev/}/queue/rotational ]] && \
           [[ $(< /sys/block/${disk#/dev/}/queue/rotational) == "1" ]]; then
            hdparm -S 120 "$disk" &>/dev/null && echo "   ⏳ $disk spindown set"
        else
            echo "   🚫 $disk not a rotational drive—spindown skipped"
        fi
    done

    powertop --auto-tune &>/dev/null || echo -e "⚠️  ${RED}powertop failed to run${RESET}"

    gpu_sleep_mode
    components_sleep

    echo "$LOG_PREFIX Low-power mode applied."
}

# 🌞 Wake mode
function exit_sleep_mode() {
    echo "$LOG_PREFIX Restoring system to normal performance..."

    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        cpufreq-set -c "${cpu##*/cpu}" -g ondemand
    done

    pm-powersave false || true

    for disk in /dev/sd[a-z]; do
        hdparm -S 0 "$disk" &>/dev/null && echo "   🔁 $disk spindown disabled"
    done

    gpu_wake_mode
    components_wake

    echo "$LOG_PREFIX System performance settings restored."
}

# 🚦 Command dispatcher
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
