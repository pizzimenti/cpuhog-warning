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

# Plasmashell-specific monitoring (uses real-time delta CPU, not ps lifetime average)
PLASMA_THRESHOLD=10   # % of one core to trigger tracking
PLASMA_SUSTAIN=30     # seconds before alerting

STATE_DIR="$HOME/.local/share/cpuhog-warning/state"
LOG_FILE="$HOME/.local/share/cpuhog-warning/log"
DBUS_ADDR="unix:path=/run/user/$(id -u)/bus"

mkdir -p "$STATE_DIR"

alert() {
    local msg="$1"
    local pid="$2"
    local state_file="$3"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
    (
        action=$(DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --app-name="cpuhog-warning" -t 0 "CPU Hog Warning" "$msg" \
            -i dialog-warning \
            --action="kill=Kill Process" \
            --action="whitelist=Whitelist" \
            --wait)
        if [[ "$action" == "kill" ]]; then
            kill "$pid" 2>/dev/null \
                && echo "$(date '+%Y-%m-%d %H:%M:%S') Killed PID $pid via notification" >> "$LOG_FILE"
        elif [[ "$action" == "whitelist" ]]; then
            # Mark as temp-whitelisted in state file (field 3)
            if [[ -f "$state_file" ]]; then
                read -r first_seen last_alerted _tw stored_cmd < "$state_file"
                echo "$first_seen $last_alerted 1 $stored_cmd" > "$state_file"
                echo "$(date '+%Y-%m-%d %H:%M:%S') Whitelisted PID $pid via notification" >> "$LOG_FILE"
            fi
        fi
    ) &
}

check() {
    local now
    now=$(date +%s)
    declare -A active_pids

    while read -r cpu pid cmd; do
        [[ "$pid" == "$$" ]] && continue

        local whitelisted=false
        for w in "${WHITELIST[@]}"; do
            [[ "$cmd" == *"$w"* ]] && whitelisted=true && break
        done
        [[ "$whitelisted" == true ]] && continue

        active_pids["$pid"]=1
        local state_file="$STATE_DIR/$pid"

        if [[ -f "$state_file" ]]; then
            local first_seen last_alerted temp_whitelisted stored_cmd
            read -r first_seen last_alerted temp_whitelisted stored_cmd < "$state_file"
            local elapsed=$(( now - first_seen ))
            local since_alerted=$(( now - last_alerted ))

            [[ "$temp_whitelisted" == "1" ]] && continue

            if [[ "$elapsed" -ge "$SUSTAIN" ]] && \
               { [[ "$last_alerted" == "0" ]] || [[ "$since_alerted" -ge "$REALERT" ]]; }; then
                alert "High CPU: $(basename "$cmd") (PID $pid) at ${cpu}% for $((elapsed/60))m" "$pid" "$state_file"
                echo "$first_seen $now 0 $stored_cmd" > "$state_file"
            fi
        else
            echo "$now 0 0 $cmd" > "$state_file"
        fi
    done < <(ps aux --no-headers | awk -v t="$THRESHOLD" '$3 >= t && $11 !~ /\/ps$/ {print $3, $2, $11}')

    # Clean up state files for processes no longer over threshold
    for state_file in "$STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        local pid
        pid=$(basename "$state_file")
        [[ -z "${active_pids[$pid]}" ]] && rm "$state_file"
    done
}

alert_plasmashell() {
    local msg="$1"
    local pid="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
    (
        action=$(DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --app-name="cpuhog-warning" -t 0 "Plasmashell CPU Spike" "$msg" \
            -i dialog-warning \
            --action="restart=Restart Plasma" \
            --action="whitelist=Whitelist" \
            --wait)
        if [[ "$action" == "restart" ]]; then
            kill "$pid" 2>/dev/null
            sleep 1
            DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" kstart plasmashell &
            echo "$(date '+%Y-%m-%d %H:%M:%S') Restarted plasmashell (killed PID $pid) via notification" >> "$LOG_FILE"
        elif [[ "$action" == "whitelist" ]]; then
            echo "$pid" > "$STATE_DIR/plasmashell_whitelist"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Whitelisted plasmashell PID $pid via notification" >> "$LOG_FILE"
        fi
    ) &
}

check_plasmashell() {
    local pid
    pid=$(pgrep -x plasmashell 2>/dev/null | head -1)
    [[ -z "$pid" ]] && return

    # Clear whitelist if plasmashell has been restarted (new PID)
    local wl_file="$STATE_DIR/plasmashell_whitelist"
    if [[ -f "$wl_file" ]]; then
        local wl_pid; wl_pid=$(cat "$wl_file")
        [[ "$wl_pid" == "$pid" ]] && return
        rm -f "$wl_file"
    fi

    local now; now=$(date +%s)
    local tick_file="$STATE_DIR/plasmashell_ticks"
    local sustain_file="$STATE_DIR/plasmashell_sustain"
    local ncpus; ncpus=$(nproc)

    local cur_proc
    cur_proc=$(awk '{print $14+$15}' /proc/"$pid"/stat 2>/dev/null) || return
    local cur_total
    cur_total=$(awk 'NR==1{for(i=2;i<=11;i++) sum+=$i; print sum}' /proc/stat)

    if [[ -f "$tick_file" ]]; then
        local prev_proc prev_total
        read -r prev_proc prev_total < "$tick_file"
        local delta_proc=$(( cur_proc - prev_proc ))
        local delta_total=$(( cur_total - prev_total ))

        if [[ "$delta_total" -gt 0 ]]; then
            local cpu_pct
            cpu_pct=$(awk "BEGIN {printf \"%.1f\", 100*$delta_proc/$delta_total*$ncpus}")

            if awk "BEGIN {exit ($cpu_pct >= $PLASMA_THRESHOLD) ? 0 : 1}"; then
                if [[ -f "$sustain_file" ]]; then
                    local first_seen last_alerted
                    read -r first_seen last_alerted < "$sustain_file"
                    local elapsed=$(( now - first_seen ))
                    local since_alerted=$(( now - last_alerted ))
                    if [[ "$elapsed" -ge "$PLASMA_SUSTAIN" ]] && \
                       { [[ "$last_alerted" == "0" ]] || [[ "$since_alerted" -ge "$REALERT" ]]; }; then
                        alert_plasmashell "plasmashell spiking at ${cpu_pct}% (PID $pid)" "$pid"
                        echo "$first_seen $now" > "$sustain_file"
                    fi
                else
                    echo "$now 0" > "$sustain_file"
                fi
            else
                rm -f "$sustain_file"
            fi
        fi
    fi

    echo "$cur_proc $cur_total" > "$tick_file"
}

while true; do
    check
    check_plasmashell
    sleep "$INTERVAL"
done
