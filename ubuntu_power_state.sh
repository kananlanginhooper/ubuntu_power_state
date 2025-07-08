check_status() {
    echo -e "\n🔋 ${GREEN}[PowerMode] Current System Power Status${RESET}"
    echo "───────────────────────────────────────────────"

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
