#!/usr/bin/env bash
# ui.sh -- Spinners, color legend, format helpers

_SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
_SPINNER_PID=""
_SPINNER_LABEL_FILE=""

# Start a spinner with a label
# Usage: spinner_start "Deploying Vault..."
spinner_start() {
    local label="$1"

    # Use a regular temp file for label updates (FIFOs block on open)
    _SPINNER_LABEL_FILE=$(mktemp /tmp/cde-spinner.XXXXXX)
    echo "$label" > "$_SPINNER_LABEL_FILE"

    (
        trap 'exit 0' TERM HUP
        local i=0
        local len=${#_SPINNER_CHARS}

        while true; do
            local current_label
            current_label=$(cat "$_SPINNER_LABEL_FILE" 2>/dev/null || echo "$label")
            local char="${_SPINNER_CHARS:$i:1}"
            printf "\r  \033[0;35m%s\033[0m %s    " "$char" "$current_label"
            i=$(( (i + 1) % len ))
            sleep 0.15
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
}

# Update the spinner label mid-operation
spinner_update() {
    [[ -z "$_SPINNER_LABEL_FILE" ]] && return 0
    echo "$1" > "$_SPINNER_LABEL_FILE" 2>/dev/null || true
}

# Stop the spinner and show final status
# Usage: spinner_stop "success" "Vault" "1m 12s"
#        spinner_stop "error" "Vault"
#        spinner_stop "warn" "Vault (starting...)"
spinner_stop() {
    local status="$1"
    local label="$2"
    local duration="${3:-}"

    # Kill spinner process
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
    fi

    # Clean up label file
    [[ -n "$_SPINNER_LABEL_FILE" ]] && rm -f "$_SPINNER_LABEL_FILE" 2>/dev/null
    _SPINNER_LABEL_FILE=""

    # Build duration suffix
    local dur_str=""
    [[ -n "$duration" ]] && dur_str=" ${DIM}(${duration})${NC}"

    # Print final line (\033[K clears to end of line to remove spinner remnants)
    case "$status" in
        success)
            printf "\r\033[K  ${CHECK} %-30s%b\n" "$label" "$dur_str"
            ;;
        error)
            printf "\r\033[K  ${CROSS} %-30s%b\n" "$label" "$dur_str"
            ;;
        warn)
            printf "\r\033[K  ${YELLOW}◐${NC} %-30s%b\n" "$label" "$dur_str"
            ;;
        skip)
            printf "\r\033[K  ${CHECK} %-30s\n" "$label (already running)"
            ;;
        *)
            printf "\r\033[K  %-32s%b\n" "$label" "$dur_str"
            ;;
    esac
}

# Show color legend after header
show_color_legend() {
    echo -e "  ${DIM}${CHECK} healthy  ${YELLOW}◐${NC}${DIM} starting  ${CROSS} failed  ${DOT} not installed${NC}"
}
