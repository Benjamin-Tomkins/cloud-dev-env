#!/usr/bin/env bash
# timing.sh -- Stage timer functions (bash 3.x compatible, uses $SECONDS)
#
# Uses parallel indexed arrays instead of associative arrays for bash 3.x compat.

_TIMER_NAMES=()
_TIMER_STARTS=()
_TIMER_DURATIONS=()

# Start a named timer
timer_start() {
    local name="$1"
    _TIMER_NAMES+=("$name")
    _TIMER_STARTS+=("$SECONDS")
}

# Stop a named timer, record duration
timer_stop() {
    local name="$1"
    local now="$SECONDS"
    local i
    for i in "${!_TIMER_NAMES[@]}"; do
        if [[ "${_TIMER_NAMES[$i]}" == "$name" ]]; then
            local elapsed=$(( now - _TIMER_STARTS[$i] ))
            _TIMER_DURATIONS+=("${name}:${elapsed}")
            log_file "INFO" "TIMER: ${name} completed in $(format_duration "$elapsed") (${elapsed}s)"
            return 0
        fi
    done
    log_file "WARN" "TIMER: timer_stop called for unknown timer: $name"
}

# Format seconds into human-readable duration
format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 60 ]]; then
        local mins=$(( secs / 60 ))
        local rem=$(( secs % 60 ))
        if [[ "$rem" -gt 0 ]]; then
            echo "${mins}m ${rem}s"
        else
            echo "${mins}m"
        fi
    else
        echo "${secs}s"
    fi
}

# Get duration for a named timer (returns formatted string)
timer_show() {
    local name="$1"
    local entry
    for entry in "${_TIMER_DURATIONS[@]}"; do
        local entry_name="${entry%%:*}"
        local entry_secs="${entry#*:}"
        if [[ "$entry_name" == "$name" ]]; then
            format_duration "$entry_secs"
            return 0
        fi
    done
    echo "?"
}

# Get raw seconds for a named timer
timer_raw() {
    local name="$1"
    local entry
    for entry in "${_TIMER_DURATIONS[@]}"; do
        local entry_name="${entry%%:*}"
        local entry_secs="${entry#*:}"
        if [[ "$entry_name" == "$name" ]]; then
            echo "$entry_secs"
            return 0
        fi
    done
    echo "0"
}

# Show timing summary table
show_timing_summary() {
    [[ ${#_TIMER_DURATIONS[@]} -eq 0 ]] && return 0

    echo -e "\n  ${BLUE}Timing:${NC}"
    echo -e "  ${DIM}─────────────────────────────────${NC}"

    local total=0
    local entry
    for entry in "${_TIMER_DURATIONS[@]}"; do
        local name="${entry%%:*}"
        local secs="${entry#*:}"
        total=$(( total + secs ))
        printf "  %-22s %s\n" "$name" "$(format_duration "$secs")"
    done

    echo -e "  ${DIM}─────────────────────────────────${NC}"
    printf "  ${BOLD}%-22s %s${NC}\n" "Total" "$(format_duration "$total")"
}
