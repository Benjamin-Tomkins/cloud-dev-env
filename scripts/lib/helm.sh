#!/usr/bin/env bash
# helm.sh -- Helm repo/release management
#
# How It Works:
#   1. ensure_helm_repo() adds individual repos with a required/optional flag:
#      - Required repos (ingress-nginx, jetstack, open-telemetry, hashicorp)
#        cause a hard stop on failure — these are needed for core infrastructure.
#      - Optional repos (headlamp, grafana, jaeger, bitnami) warn and continue
#        on failure — the environment works without them.
#   2. setup_helm_repos() adds all repos, runs helm repo update, and reports
#      overall status via spinner.
#
# Dependencies: log.sh, timing.sh, ui.sh

# Check if a helm repo exists
helm_repo_exists() {
    helm repo list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"
}

# Add a helm repo with verification.
# Usage: ensure_helm_repo <name> <url> [required=true]
# Returns: 0 on success, 1 on failure (only for required repos)
ensure_helm_repo() {
    local name="$1" url="$2" required="${3:-true}"

    log_file "DEBUG" "ensure_helm_repo: name=$name url=$url required=$required"

    if ! helm repo add "$name" "$url" --force-update 2>&1 | verbose_or_log; then
        if [[ "$required" == "true" ]]; then
            printf "\n"
            err "Failed to add required helm repo: $name ($url)"
            helm repo add "$name" "$url" --force-update 2>&1 || true
            return 1
        else
            log_file "WARN" "Failed to add optional repo: $name"
            [[ "$VERBOSE" == "true" ]] && warn "Failed to add optional repo: $name"
        fi
    fi

    if [[ "$required" == "true" ]] && ! helm_repo_exists "$name"; then
        printf "\n"
        err "Helm repo '$name' not present after add attempt"
        return 1
    fi

    return 0
}

# Add all required + optional repos, update, and report status.
# Exits on failure if any required repo cannot be added.
setup_helm_repos() {
    log_file "INFO" "setup_helm_repos: starting"
    timer_start "Helm repos"
    spinner_start "Updating Helm repos..."
    local failed=0

    # Required repos
    ensure_helm_repo ingress-nginx https://kubernetes.github.io/ingress-nginx true || ((failed++))
    ensure_helm_repo jetstack https://charts.jetstack.io true || ((failed++))
    ensure_helm_repo open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts true || ((failed++))
    ensure_helm_repo hashicorp https://helm.releases.hashicorp.com true || ((failed++))

    # Optional repos
    ensure_helm_repo headlamp https://kubernetes-sigs.github.io/headlamp/ false || true
    ensure_helm_repo grafana https://grafana.github.io/helm-charts false || true
    ensure_helm_repo jaegertracing https://jaegertracing.github.io/helm-charts false || true
    ensure_helm_repo bitnami https://charts.bitnami.com/bitnami false || true

    # Update all repos
    if ! helm repo update 2>&1 | verbose_or_log; then
        warn "helm repo update had issues"
    fi

    timer_stop "Helm repos"

    if [[ $failed -gt 0 ]]; then
        spinner_stop "error" "Helm repos setup failed"
        err "Failed to add $failed required repos. Check network connectivity."
        exit 1
    fi

    log_file "INFO" "setup_helm_repos: completed successfully"
    spinner_stop "success" "Helm repos ready" "$(timer_show 'Helm repos')"
}
