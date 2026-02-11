#!/usr/bin/env bash
# timing.sh -- Stage timer functions (bash 3.x compatible, uses $SECONDS)
#
# How It Works:
#   1. timer_start() records a name and the current $SECONDS value
#   2. timer_stop() computes elapsed time and logs the duration to file
#   3. timer_show()/timer_raw() retrieve durations for display or computation
#   4. show_timing_summary() prints a formatted table of all recorded stages
#
# Why parallel indexed arrays: bash 3.x (macOS default) has no associative
# arrays. Three parallel arrays (_NAMES, _STARTS, _DURATIONS) simulate a
# name→value map using linear search. This is fine for the ~15 timers we track.
#
# Dependencies: log.sh (log_file), constants.sh (colors)

_TIMER_NAMES=()
_TIMER_STARTS=()
_TIMER_DURATIONS=()

# Start a named timer. Call timer_stop() with the same name to record duration.
timer_start() {
    local name="$1"
    _TIMER_NAMES+=("$name")
    _TIMER_STARTS+=("$SECONDS")
}

# Stop a named timer, record duration, and log it to file.
# Returns: 0 on success, logs warning if timer name not found.
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

# Get duration for a named timer (returns formatted string like "1m 12s")
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

# Get raw seconds for a named timer (for arithmetic, not display)
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
