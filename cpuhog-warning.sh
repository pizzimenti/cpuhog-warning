#!/bin/bash

# Processes allowed to consume high CPU (substring match on command name)
WHITELIST=("lm-studio" "lm_studio" "plasmashell")

# Alert threshold (% CPU for a single process)
THRESHOLD=20

# How long a process must sustain high CPU before alerting (seconds)
SUSTAIN=120

# How often to re-alert if a process stays above threshold (seconds)
REALERT=300

# Check interval (seconds)
INTERVAL=30

# Plasmashell-specific monitoring (uses the unified /proc scan, but lower thresholds)
PLASMA_THRESHOLD=10
PLASMA_SUSTAIN=30

STATE_BASE="$HOME/.local/share/cpuhog-warning"
LOG_FILE="$STATE_BASE/log"
ACTIONS_FILE="$STATE_BASE/actions"
DBUS_ADDR="unix:path=/run/user/$(id -u)/bus"

mkdir -p "$STATE_BASE"
touch "$LOG_FILE" "$ACTIONS_FILE"

declare -A FIRST_SEEN
declare -A LAST_ALERTED
declare -A TEMP_WHITELIST
declare -A PREV_PROC_TICKS
declare -A CMD_BY_PID
declare -A SEEN_GEN

PREV_TOTAL_TICKS=0
NCPUS="$(nproc)"
SCAN_GEN=0

log_line() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

queue_action() {
    local action="$1"
    local pid="$2"
    printf '%s %s\n' "$action" "$pid" >> "$ACTIONS_FILE"
}

is_name_whitelisted() {
    local cmd="$1"
    local item
    for item in "${WHITELIST[@]}"; do
        [[ "$cmd" == *"$item"* ]] && return 0
    done
    return 1
}

format_cpu_pct() {
    local tenths="$1"
    printf '%d.%d' "$(( tenths / 10 ))" "$(( tenths % 10 ))"
}

handle_pending_actions() {
    [[ -s "$ACTIONS_FILE" ]] || return

    while read -r action pid; do
        [[ -n "$action" && -n "$pid" ]] || continue
        case "$action" in
            whitelist)
                TEMP_WHITELIST["$pid"]=1
                log_line "Whitelisted PID $pid via notification"
                ;;
        esac
    done < "$ACTIONS_FILE"

    : > "$ACTIONS_FILE"
}

alert_process() {
    local title="$1"
    local msg="$2"
    local pid="$3"
    local action_primary="$4"
    local action_label="$5"

    log_line "$msg"
    (
        local action
        action=$(DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --app-name="cpuhog-warning" -t 0 "$title" "$msg" \
            -i dialog-warning \
            --action="${action_primary}=${action_label}" \
            --action="whitelist=Whitelist" \
            --wait)

        if [[ "$action" == "$action_primary" ]]; then
            if [[ "$action_primary" == "kill" ]]; then
                kill "$pid" 2>/dev/null \
                    && log_line "Killed PID $pid via notification"
            elif [[ "$action_primary" == "restart" ]]; then
                kill "$pid" 2>/dev/null
                sleep 1
                DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" kstart plasmashell &
                log_line "Restarted plasmashell (killed PID $pid) via notification"
            fi
        elif [[ "$action" == "whitelist" ]]; then
            queue_action whitelist "$pid"
        fi
    ) &
}

read_total_ticks() {
    local _cpu user nice system idle iowait irq softirq steal guest guest_nice
    read -r _cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    printf '%s\n' $(( user + nice + system + idle + iowait + irq + softirq + steal ))
}

cleanup_missing_pids() {
    local current_gen="$1"
    local pid
    for pid in "${!SEEN_GEN[@]}"; do
        if (( current_gen - ${SEEN_GEN[$pid]} > 1 )); then
            unset SEEN_GEN["$pid"]
            unset PREV_PROC_TICKS["$pid"]
            unset FIRST_SEEN["$pid"]
            unset LAST_ALERTED["$pid"]
            unset TEMP_WHITELIST["$pid"]
            unset CMD_BY_PID["$pid"]
        fi
    done
}

scan_processes() {
    local now total_ticks delta_total

    handle_pending_actions
    (( SCAN_GEN += 1 ))

    now="$(date +%s)"
    total_ticks="$(read_total_ticks)"
    delta_total=$(( total_ticks - PREV_TOTAL_TICKS ))

    local proc_dir pid stat_line comm rest utime stime proc_ticks delta_proc
    local cmd cpu_tenths threshold sustain title msg elapsed since_alert

    for proc_dir in /proc/[0-9]*; do
        [[ -r "$proc_dir/stat" ]] || continue
        pid="${proc_dir##*/}"
        [[ "$pid" == "$$" ]] && continue

        stat_line="$(<"$proc_dir/stat")" || continue
        [[ "$stat_line" =~ ^([0-9]+)\ \((.*)\)\ ([A-Z])\ (.*)$ ]] || continue
        comm="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[4]}"
        read -r -a fields <<< "$rest"
        (( ${#fields[@]} >= 12 )) || continue
        utime="${fields[10]}"
        stime="${fields[11]}"
        proc_ticks=$(( utime + stime ))

        SEEN_GEN["$pid"]="$SCAN_GEN"
        CMD_BY_PID["$pid"]="$comm"

        if [[ -z "${PREV_PROC_TICKS[$pid]:-}" ]]; then
            PREV_PROC_TICKS["$pid"]="$proc_ticks"
            continue
        fi

        delta_proc=$(( proc_ticks - PREV_PROC_TICKS[$pid] ))
        PREV_PROC_TICKS["$pid"]="$proc_ticks"

        if (( delta_total <= 0 || delta_proc < 0 )); then
            continue
        fi

        cpu_tenths=$(( 1000 * delta_proc * NCPUS / delta_total ))
        cmd="${CMD_BY_PID[$pid]}"

        if [[ "$cmd" == "plasmashell" ]]; then
            threshold=$(( PLASMA_THRESHOLD * 10 ))
            sustain="$PLASMA_SUSTAIN"
        else
            is_name_whitelisted "$cmd" && continue
            threshold=$(( THRESHOLD * 10 ))
            sustain="$SUSTAIN"
        fi

        if [[ -n "${TEMP_WHITELIST[$pid]:-}" ]]; then
            continue
        fi

        if (( cpu_tenths >= threshold )); then
            if [[ -z "${FIRST_SEEN[$pid]:-}" ]]; then
                FIRST_SEEN["$pid"]="$now"
                LAST_ALERTED["$pid"]=0
                continue
            fi

            elapsed=$(( now - FIRST_SEEN[$pid] ))
            since_alert=$(( now - ${LAST_ALERTED[$pid]:-0} ))
            if (( elapsed >= sustain )) && { (( ${LAST_ALERTED[$pid]:-0} == 0 )) || (( since_alert >= REALERT )); }; then
                if [[ "$cmd" == "plasmashell" ]]; then
                    title="Plasmashell CPU Spike"
                    msg="plasmashell spiking at $(format_cpu_pct "$cpu_tenths")% (PID $pid)"
                    alert_process "$title" "$msg" "$pid" restart "Restart Plasma"
                else
                    title="CPU Hog Warning"
                    msg="High CPU: $cmd (PID $pid) at $(format_cpu_pct "$cpu_tenths")% for $(( elapsed / 60 ))m"
                    alert_process "$title" "$msg" "$pid" kill "Kill Process"
                fi
                LAST_ALERTED["$pid"]="$now"
            fi
        else
            unset FIRST_SEEN["$pid"]
            unset LAST_ALERTED["$pid"]
        fi
    done

    PREV_TOTAL_TICKS="$total_ticks"
    cleanup_missing_pids "$SCAN_GEN"
}

while true; do
    scan_processes
    sleep "$INTERVAL"
done
