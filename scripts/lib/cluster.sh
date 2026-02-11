#!/usr/bin/env bash
# cluster.sh -- k3d lifecycle + prereqs
#
# How It Works:
#   1. Cluster state: cluster_exists/cluster_running check k3d JSON output
#   2. Prerequisites: check_prereqs verifies docker/kubectl/k3d/helm are
#      installed, and optionally mkcert (for browser-trusted TLS certs)
#   3. Lifecycle:
#      create_cluster  → k3d cluster create from infra/k3d-config.yaml
#      stop_cluster    → k3d cluster stop (preserves state)
#      delete_cluster  → k3d cluster delete + CA cleanup
#
#   Cluster Lifecycle State Machine:
#
#     (not found)──── create_cluster ────►(Running)
#                                          │    ▲
#                                    stop  │    │ start
#                                          ▼    │
#                                        (Stopped)
#                                          │
#                                    delete │
#                                          ▼
#                                       (not found)
#
# Dependencies: log.sh, ui.sh, timing.sh, constants.sh, tls.sh (remove_trusted_ca),
#               portforward.sh (stop_port_forwards)

# =============================================================================
# 1. Determine Cluster State
# =============================================================================

cluster_exists() {
    if command -v jq &>/dev/null; then
        k3d cluster list -o json 2>/dev/null | jq -e --arg name "$CLUSTER_NAME" '.[] | select(.name == $name)' &>/dev/null
    else
        k3d cluster list -o json 2>/dev/null | grep -qE "\"name\"[[:space:]]*:[[:space:]]*\"${CLUSTER_NAME}\""
    fi
}

cluster_running() {
    if command -v jq &>/dev/null; then
        k3d cluster list -o json 2>/dev/null | jq -e --arg name "$CLUSTER_NAME" \
            '.[] | select(.name == $name) | select(.serversRunning > 0)' &>/dev/null
    else
        local info
        info=$(k3d cluster list -o json 2>/dev/null)
        echo "$info" | grep -qE "\"name\"[[:space:]]*:[[:space:]]*\"${CLUSTER_NAME}\"" && \
        echo "$info" | grep -qE "\"serversRunning\"[[:space:]]*:[[:space:]]*[1-9]"
    fi
}

debug_cluster() {
    echo -e "  ${DIM}k3d cluster list output:${NC}"
    k3d cluster list 2>/dev/null | sed 's/^/    /' || echo "    (no output)"
    echo ""
}

# Guard: exit with helpful message if cluster doesn't exist or isn't running.
# Called before any command that needs a live cluster (deploy, status, etc.)
require_cluster() {
    log_file "DEBUG" "require_cluster: checking cluster=${CLUSTER_NAME}"
    if ! cluster_exists; then
        echo -e "\n${RED}Error:${NC} Cluster '${CLUSTER_NAME}' not found"
        local clusters
        clusters=$(k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}')
        if [[ -n "$clusters" ]]; then
            echo -e "${DIM}Available clusters:${NC}"
            k3d cluster list 2>/dev/null | sed 's/^/  /'
            echo -e "\nRun with: ${CYAN}CDE_CLUSTER=<name> ./cde.sh <command>${NC}"
        else
            echo -e "Run: ${CYAN}./cde.sh deploy all${NC} to create it"
        fi
        echo ""
        log_file "ERROR" "require_cluster: cluster '${CLUSTER_NAME}' not found"
        exit 1
    fi
    if ! cluster_running; then
        echo -e "\n${RED}Error:${NC} Cluster '${CLUSTER_NAME}' is stopped"
        echo -e "Run: ${CYAN}./cde.sh up${NC} to start it\n"
        log_file "ERROR" "require_cluster: cluster '${CLUSTER_NAME}' is stopped"
        exit 1
    fi
}

show_context() {
    local ctx
    ctx=$(kubectl config current-context 2>/dev/null || echo "none")
    echo -e "  ${DIM}cluster:${NC} ${CLUSTER_NAME}"
    echo -e "  ${DIM}context:${NC} ${ctx}"
    echo ""
}

# =============================================================================
# 2. Verify Prerequisites
# =============================================================================

# Verify required tools (docker, kubectl, k3d, helm) and optional mkcert.
# mkcert is optional — without it tls.sh falls back to self-signed CAs which
# work fine but cause browser security warnings.
check_prereqs() {
    log_file "INFO" "check_prereqs: verifying required tools"
    local missing=0

    for cmd in docker kubectl k3d helm; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd"
        else
            err "$cmd not found"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        echo ""
        err "Install missing tools before continuing"
        exit 1
    fi

    # mkcert is optional — enables browser-trusted certs; tls.sh falls back to self-signed
    if command -v mkcert &>/dev/null; then
        if mkcert -CAROOT &>/dev/null && [[ -f "$(mkcert -CAROOT)/rootCA.pem" ]]; then
            ok "mkcert (browser-trusted certs)"
        else
            warn "mkcert installed but CA not initialized"
            echo -e "  ${DIM}Run: mkcert -install${NC}"
        fi
    else
        warn "mkcert not found (will use self-signed certs — browsers will show warnings)"
        echo -e "  ${DIM}Install: brew install mkcert && mkcert -install${NC}"
    fi

    if ! docker info &>/dev/null; then
        err "Docker is not running"
        exit 1
    fi

    log_file "INFO" "check_prereqs: all prerequisites satisfied"
}

# =============================================================================
# 3. Manage Cluster Lifecycle
# =============================================================================

# Create a new k3d cluster from infra/k3d-config.yaml, or start an existing
# stopped cluster. Handles common failure modes with targeted error messages:
#   - Port conflict (another service on 80/443/6550)
#   - Docker not running or out of resources
#   - Cluster already exists (advises delete first)
create_cluster() {
    log_file "INFO" "create_cluster: cluster=${CLUSTER_NAME}"
    if cluster_exists; then
        if cluster_running; then
            ok "Cluster '${CLUSTER_NAME}' already running"
            return 0
        else
            log_file "INFO" "create_cluster: cluster exists but stopped, starting"
            spinner_start "Starting cluster..."
            k3d cluster start "${CLUSTER_NAME}" 2>&1 | verbose_or_log
            spinner_stop "success" "Cluster started"
            log_file "INFO" "create_cluster: cluster started"
            return 0
        fi
    fi

    log_file "INFO" "create_cluster: creating new cluster"
    timer_start "Cluster"
    spinner_start "Creating cluster..."

    local templog
    templog=$(mktemp)

    local script_dir config_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    config_file="${script_dir}/../../infra/k3d-config.yaml"

    if [[ ! -f "$config_file" ]]; then
        err "Cluster config not found: $config_file"
        exit 1
    fi
    log_file "INFO" "Using config: $config_file"

    local k3d_cmd="k3d cluster create --config \"$config_file\""

    if [[ "$VERBOSE" == "true" ]]; then
        spinner_stop "" ""
        echo ""
        if ! eval "$k3d_cmd" 2>&1 | tee "$templog" | verbose_or_log; then
            err "Cluster creation failed"
            rm -f "$templog"
            exit 1
        fi
    else
        eval "$k3d_cmd" >"$templog" 2>&1 &
        local k3d_pid=$!
        trap "kill $k3d_pid 2>/dev/null; rm -f '$templog'" INT TERM

        wait "$k3d_pid"
        local exit_code=$?
        trap - INT TERM

        if [[ $exit_code -ne 0 ]]; then
            spinner_stop "error" "Cluster creation failed"
            echo ""
            if grep -qi "already exists" "$templog"; then
                echo -e "  ${YELLOW}Cluster already exists.${NC}"
                echo -e "  Run: ${CYAN}k3d cluster delete ${CLUSTER_NAME}${NC} first"
            elif grep -qi "port.*already" "$templog"; then
                echo -e "  ${YELLOW}Port conflict - another service is using required ports.${NC}"
                echo -e "  Check ports: 8080, 8443, 6550, ${REGISTRY_PORT}"
            elif grep -qi "docker" "$templog"; then
                echo -e "  ${YELLOW}Docker issue:${NC}"
                grep -i docker "$templog" | head -3 | sed 's/^/  /'
            else
                echo -e "  ${DIM}Error output:${NC}"
                tail -5 "$templog" | sed 's/^/  /'
            fi
            log_file "ERROR" "Cluster creation failed: $(cat "$templog")"
            rm -f "$templog"
            echo ""
            exit 1
        fi
    fi

    # Log cluster creation output
    [[ -f "$templog" ]] && log_file "INFO" "Cluster creation output: $(cat "$templog")"
    rm -f "$templog"
    spinner_stop "success" "Cluster created"

    # Wait for API server
    spinner_start "Waiting for API server..."
    local retries=30
    while ! kubectl cluster-info &>/dev/null && [[ $retries -gt 0 ]]; do
        sleep 1
        retries=$((retries - 1))
    done

    if [[ $retries -eq 0 ]]; then
        spinner_stop "error" "API server not responding"
        exit 1
    fi
    spinner_stop "success" "API server ready"

    kubectl create namespace "${APPS_NS}" --dry-run=client -o yaml | kubectl apply -f - 2>&1 | verbose_or_log

    timer_stop "Cluster"
}

delete_cluster() {
    log_file "INFO" "delete_cluster: cluster=${CLUSTER_NAME}"
    if ! cluster_exists; then
        warn "Cluster '${CLUSTER_NAME}' does not exist"
        return 0
    fi

    stop_port_forwards
    spinner_start "Deleting cluster..."
    if k3d cluster delete "${CLUSTER_NAME}" 2>&1 | verbose_or_log; then
        spinner_stop "success" "Cluster deleted"
        log_file "INFO" "delete_cluster: done"
    else
        spinner_stop "error" "Cluster deletion failed"
        log_file "ERROR" "delete_cluster: failed"
    fi
    remove_trusted_ca
}

stop_cluster() {
    log_file "INFO" "stop_cluster: cluster=${CLUSTER_NAME}"
    if ! cluster_exists; then
        warn "Cluster '${CLUSTER_NAME}' does not exist"
        return 0
    fi

    spinner_start "Stopping cluster..."
    if k3d cluster stop "${CLUSTER_NAME}" 2>&1 | verbose_or_log; then
        spinner_stop "success" "Cluster stopped"
        log_file "INFO" "stop_cluster: done"
    else
        spinner_stop "error" "Cluster stop failed"
        log_file "ERROR" "stop_cluster: failed"
    fi
}
