#!/usr/bin/env bash
# k8s.sh -- Smart k8s polling, health checks (replaces all sleeps)
#
# Why This Exists:
#   Fixed `sleep N` calls are fragile — too short and you hit race conditions,
#   too long and deploys waste time. This module replaces all sleeps with
#   state-based polling that returns as soon as the condition is met.
#
# How It Works:
#   1. Health checks:   release_exists → pods_ready → svc_healthy
#   2. Smart waits:     poll Kubernetes state in a $SECONDS-based loop with
#                       configurable timeouts. Each returns 0 (met) or 1 (timeout).
#   3. Tiered strategy: wait_healthy_smart chains pod-phase → container-ready
#                       for a single "deploy and wait" call
#
#   Health Check Decision Tree (svc_healthy / get_health_status):
#
#     release_exists?
#       ├─ NO  → "not-installed"
#       └─ YES → pods_ready?
#                  ├─ YES → "healthy"
#                  └─ NO  → helm status?
#                             ├─ deployed → "starting"
#                             ├─ failed   → "failed"
#                             └─ other    → "unknown"
#
#   wait_healthy_smart Shared Timeout:
#
#     ┌──────── total timeout ───────────────────────────┐
#     │ Phase 1: pod Running │ Phase 2: containers Ready │
#     │  (polls pod phase)   │  (remaining = total - p1) │
#     └──────────────────────┴───────────────────────────┘
#     If Phase 1 exceeds budget, Phase 2 gets 0 time → immediate fail
#
# Dependencies: log.sh, ui.sh, constants.sh

# =============================================================================
# 1. Check Service Health
# =============================================================================
# Quick, non-blocking checks used to skip deploys (already healthy) and to
# build the status table. No waiting — just a point-in-time snapshot.

# Check if helm release exists
release_exists() {
    local name=$1 ns=$2
    helm status "$name" -n "$ns" &>/dev/null
}

# Get helm release status: deployed, failed, pending-install, etc.
release_status() {
    local name=$1 ns=$2
    helm status "$name" -n "$ns" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4
}

# Check if pods for a release are actually ready (not just Running)
pods_ready() {
    local name=$1 ns=$2

    local total ready
    total=$(kubectl get pods -n "$ns" -l "app.kubernetes.io/instance=$name" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    ready=$(kubectl get pods -n "$ns" -l "app.kubernetes.io/instance=$name" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | tr ' ' '\n' | grep -c "True" || echo "0")

    [[ "$total" -gt 0 && "$total" == "$ready" ]]
}

# Combined health check: release exists AND all pods ready.
# Used as a gate at the top of deploy functions to skip redundant work.
svc_healthy() {
    local name=$1 ns=$2
    release_exists "$name" "$ns" && pods_ready "$name" "$ns"
}

# Get health status string for display
get_health_status() {
    local name=$1 ns=$2

    if ! release_exists "$name" "$ns"; then
        echo "not-installed"
    elif pods_ready "$name" "$ns"; then
        echo "healthy"
    else
        local status
        status=$(release_status "$name" "$ns")
        case "$status" in
            deployed) echo "starting" ;;
            failed) echo "failed" ;;
            pending*) echo "pending" ;;
            *) echo "unknown" ;;
        esac
    fi
}

# Wait for service to become healthy (with timeout)
wait_healthy() {
    local name=$1 ns=$2 timeout=${3:-60}
    local start=$SECONDS

    log_file "DEBUG" "wait_healthy: $name in $ns (timeout=${timeout}s)"
    while (( SECONDS - start < timeout )); do
        if pods_ready "$name" "$ns"; then
            log_file "DEBUG" "wait_healthy: $name ready after $((SECONDS - start))s"
            return 0
        fi
        sleep 2
    done
    log_file "WARN" "wait_healthy: $name timed out after ${timeout}s"
    return 1
}

# Get vault root token from Kubernetes secret
get_vault_token() {
    kubectl get secret vault-init-creds -n vault -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d 2>/dev/null
}

# Get grafana admin password from Kubernetes secret
get_grafana_password() {
    kubectl get secret grafana -n observability -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null
}

# =============================================================================
# 2. Wait for Kubernetes State Changes
# =============================================================================
# State-based polling that replaces fixed `sleep N`. Each function polls
# Kubernetes API in a $SECONDS-based loop (never integer countdown — that
# breaks with `set -e` when the counter hits 0).

# Wait for a pod to reach a given phase (Running, Succeeded, etc.)
#
# Usage: wait_for_pod_phase <ns> <label-selector> <phase> [timeout_secs]
# Returns: 0 when phase reached, 1 on timeout
wait_for_pod_phase() {
    local ns="$1" selector="$2" phase="$3" timeout="${4:-60}"
    local start=$SECONDS

    log_file "DEBUG" "wait_for_pod_phase: ns=$ns selector=$selector phase=$phase timeout=${timeout}s"
    while (( SECONDS - start < timeout )); do
        local current
        current=$(kubectl get pods -n "$ns" -l "$selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [[ "$current" == "$phase" ]]; then
            log_file "DEBUG" "wait_for_pod_phase: reached $phase after $((SECONDS - start))s"
            return 0
        fi
        sleep 0.5
    done
    log_file "WARN" "wait_for_pod_phase: timed out waiting for $phase in $ns (last=$current) after ${timeout}s"
    return 1
}

# Wait for a specific pod to have all containers ready
# Usage: wait_for_container_ready <ns> <pod-name> [timeout_secs]
wait_for_container_ready() {
    local ns="$1" pod="$2" timeout="${3:-60}"
    local start=$SECONDS

    log_file "DEBUG" "wait_for_container_ready: pod=$pod ns=$ns timeout=${timeout}s"
    while (( SECONDS - start < timeout )); do
        local ready
        ready=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$ready" == "True" ]]; then
            log_file "DEBUG" "wait_for_container_ready: $pod ready after $((SECONDS - start))s"
            return 0
        fi

        # Check for CrashLoopBackOff
        local waiting_reason
        waiting_reason=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
        if [[ "$waiting_reason" == "CrashLoopBackOff" ]]; then
            log_file "ERROR" "wait_for_container_ready: $pod in CrashLoopBackOff"
            return 1
        fi

        sleep 0.5
    done
    log_file "WARN" "wait_for_container_ready: $pod timed out after ${timeout}s"
    return 1
}

# Wait for an endpoint to become reachable
# Usage: wait_for_endpoint <host> <port> <protocol> [timeout_secs]
#   protocol: tcp, https, http
wait_for_endpoint() {
    local host="$1" port="$2" protocol="${3:-tcp}" timeout="${4:-10}"
    local start=$SECONDS

    log_file "DEBUG" "wait_for_endpoint: ${protocol}://${host}:${port} timeout=${timeout}s"
    while (( SECONDS - start < timeout )); do
        case "$protocol" in
            tcp)
                if nc -z "$host" "$port" 2>/dev/null; then
                    log_file "DEBUG" "wait_for_endpoint: ${host}:${port} reachable after $((SECONDS - start))s"
                    return 0
                fi
                ;;
            https)
                if curl -sk --connect-timeout 1 --max-time 2 "https://${host}:${port}" &>/dev/null; then
                    log_file "DEBUG" "wait_for_endpoint: https://${host}:${port} reachable after $((SECONDS - start))s"
                    return 0
                fi
                ;;
            http)
                if curl -s --connect-timeout 1 --max-time 2 "http://${host}:${port}" &>/dev/null; then
                    log_file "DEBUG" "wait_for_endpoint: http://${host}:${port} reachable after $((SECONDS - start))s"
                    return 0
                fi
                ;;
        esac
        sleep 0.2
    done
    log_file "WARN" "wait_for_endpoint: ${protocol}://${host}:${port} timed out after ${timeout}s"
    return 1
}

# Two-phase smart health check: pod phase → container readiness.
# Chains wait_for_pod_phase and wait_healthy with a shared timeout,
# so total wait never exceeds the specified limit.
#
# Usage: wait_healthy_smart <name> <ns> [timeout]
# Returns: 0 when healthy, 1 on timeout
wait_healthy_smart() {
    local name="$1" ns="$2" timeout="${3:-90}"
    local start_seconds=$SECONDS

    log_file "INFO" "wait_healthy_smart: $name in $ns (timeout=${timeout}s)"

    # Phase 1: Wait for pod to be scheduled and running
    spinner_update "Waiting for pod..."
    if ! wait_for_pod_phase "$ns" "app.kubernetes.io/instance=$name" "Running" "$timeout"; then
        log_file "WARN" "wait_healthy_smart: $name pod never reached Running"
        return 1
    fi

    local remaining=$(( timeout - (SECONDS - start_seconds) ))
    [[ $remaining -le 0 ]] && return 1

    # Phase 2: Wait for container readiness
    spinner_update "Waiting for readiness..."
    if ! wait_healthy "$name" "$ns" "$remaining"; then
        log_file "WARN" "wait_healthy_smart: $name containers not ready"
        return 1
    fi

    log_file "INFO" "wait_healthy_smart: $name healthy after $((SECONDS - start_seconds))s"
    return 0
}

# Wait for EndpointSlice to have addresses (used for webhook readiness).
# Webhooks can fail with "connection refused" even after the pod is Ready,
# because the EndpointSlice hasn't propagated yet.
#
# Usage: wait_for_endpoint_slice <ns> <service-name> [timeout_secs]
# Returns: 0 when addresses found, 1 on timeout
wait_for_endpoint_slice() {
    local ns="$1" svc="$2" timeout="${3:-30}"
    local start=$SECONDS

    log_file "DEBUG" "wait_for_endpoint_slice: $svc in $ns (timeout=${timeout}s)"
    while (( SECONDS - start < timeout )); do
        local addrs
        addrs=$(kubectl get endpointslice -n "$ns" -l "kubernetes.io/service-name=$svc" \
            -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || echo "")
        if [[ -n "$addrs" ]]; then
            log_file "DEBUG" "wait_for_endpoint_slice: $svc has addresses after $((SECONDS - start))s"
            return 0
        fi
        sleep 0.5
    done
    log_file "WARN" "wait_for_endpoint_slice: $svc timed out after ${timeout}s"
    return 1
}
