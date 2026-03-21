#!/bin/bash

# Processes allowed to consume high CPU (substring match on command name)
WHITELIST=("lm-studio" "lm_studio")

# Alert threshold (% CPU for a single process)
THRESHOLD=20

# How long a process must sustain high CPU before alerting (seconds)
SUSTAIN=120

# How often to re-alert if a process stays above threshold (seconds)
REALERT=300

# Check interval (seconds)
INTERVAL=30

STATE_DIR="$HOME/.local/share/cpu-monitor/state"
LOG_FILE="$HOME/.local/share/cpu-monitor/log"
DBUS_ADDR="unix:path=/run/user/$(id -u)/bus"

mkdir -p "$STATE_DIR"

alert() {
    local msg="$1"
    local pid="$2"
    local state_file="$3"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
    (
        action=$(DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --app-name="cpu-hog-warning" -t 0 "CPU Hog Warning" "$msg" \
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

while true; do
    check
    sleep "$INTERVAL"
done
