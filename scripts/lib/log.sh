#!/usr/bin/env bash
# log.sh -- Dual-output logging (console + timestamped file)
#
# Log format: [YYYY-MM-DDTHH:MM:SS] [PID] [LEVEL] message
# File name:  cde-YYYYMMDD-HHMMSS-PID.log

CDE_LOG_DIR=""
CDE_LOG_FILE=""
CDE_PID=$$

# Initialize logging -- creates log dir, timestamped log file, and latest symlink
init_log() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
    CDE_LOG_DIR="${script_dir}/../log"
    mkdir -p "$CDE_LOG_DIR"

    local timestamp
    timestamp=$(date +"%Y%m%d-%H%M%S")
    CDE_LOG_FILE="${CDE_LOG_DIR}/cde-${timestamp}-${CDE_PID}.log"
    : > "$CDE_LOG_FILE"

    # Symlink latest.log
    ln -sf "$(basename "$CDE_LOG_FILE")" "${CDE_LOG_DIR}/latest.log"

    # Rotate logs older than 7 days
    find "$CDE_LOG_DIR" -name "cde-*.log" -mtime +7 -delete 2>/dev/null || true
}

# Write a timestamped, leveled line to the log file (strips ANSI codes)
log_file() {
    [[ -z "$CDE_LOG_FILE" ]] && return 0
    local level="${1:-INFO}"
    shift
    # Strip ANSI escape sequences for clean log output
    local msg="$*"
    msg=$(printf '%s' "$msg" | sed $'s/\033\\[[0-9;]*m//g' | sed 's/\\033\[[0-9;]*m//g')
    echo "[$(date +"%Y-%m-%dT%H:%M:%S")] [${CDE_PID}] [${level}] ${msg}" >> "$CDE_LOG_FILE"
}

# Console logging helpers -- each also writes to the log file
log() {
    echo -e "${BLUE}[cde]${NC} $*"
    log_file "INFO" "$*"
}

ok() {
    echo -e "  ${CHECK} $*"
    log_file "INFO" "OK: $*"
}

err() {
    echo -e "  ${CROSS} $*" >&2
    log_file "ERROR" "$*"
}

warn() {
    echo -e "  ${YELLOW}!${NC} $*"
    log_file "WARN" "$*"
}

dim() {
    echo -e "  ${DIM}$*${NC}"
}

# Verbose output helper -- pipes to console if verbose, always to log file (strips ANSI for log)
verbose_or_log() {
    if [[ "$VERBOSE" == "true" ]]; then
        if [[ -n "$CDE_LOG_FILE" ]]; then
            tee >(sed $'s/\033\\[[0-9;]*m//g' >> "$CDE_LOG_FILE")
        else
            cat
        fi
    else
        if [[ -n "$CDE_LOG_FILE" ]]; then
            sed $'s/\033\\[[0-9;]*m//g' >> "$CDE_LOG_FILE"
        else
            cat >/dev/null
        fi
    fi
}

# Legacy compat
verbose() {
    verbose_or_log
}

# Capture a command's output to the log file, show on console only if verbose
capture_cmd() {
    "$@" 2>&1 | verbose_or_log
}
