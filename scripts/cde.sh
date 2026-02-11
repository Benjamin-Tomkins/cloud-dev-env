#!/usr/bin/env bash
#
# CDE - Cloud Developer Experience
# Simple local Kubernetes development environment manager
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Source library modules
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/timing.sh"
source "${LIB_DIR}/ui.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/helm.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/tls.sh"
source "${LIB_DIR}/vault.sh"
source "${LIB_DIR}/services.sh"
source "${LIB_DIR}/portforward.sh"

# Cleanup trap - kill background port-forwards on exit
cleanup() {
    local exit_code=$?
    # Kill any spinner that might be running
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
    fi
    [[ -n "${_SPINNER_LABEL_FILE:-}" ]] && rm -f "$_SPINNER_LABEL_FILE" 2>/dev/null || true
    pkill -f "kubectl port-forward.*cde" 2>/dev/null || true
    log_file "INFO" "CDE session ended (exit_code=$exit_code)"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Open in Browser
# ─────────────────────────────────────────────────────────────────────────────

open_browser() {
    local url=$1
    log_file "INFO" "open_browser: $url"
    echo -e "  Opening ${CYAN}$url${NC}"

    case "$(uname -s)" in
        Darwin)  open "$url" ;;
        Linux)   xdg-open "$url" 2>/dev/null || sensible-browser "$url" 2>/dev/null || echo "  Please open manually: $url" ;;
        MINGW*|CYGWIN*|MSYS*) start "$url" ;;
        *)       echo "  Please open manually: $url" ;;
    esac
}

cmd_open() {
    local svc="${1:-}"

    if [[ -z "$svc" && "$NONINTERACTIVE" == "true" ]]; then
        err "Specify a service: dashboard, vault, grafana, jaeger"
        exit 1
    fi

    if [[ -z "$svc" ]]; then
        require_cluster
        echo -e "\n${PURPLE}◆ CDE${NC} Open Dashboard\n"

        local -a available=()
        local -a names=()

        if release_exists headlamp headlamp; then
            available+=("dashboard")
            names+=("Dashboard (Headlamp) https://dashboard.localhost:8443 (via Ingress)")
        fi
        if release_exists vault vault; then
            available+=("vault")
            names+=("Vault        https://vault.localhost:8443  (via Ingress)")
        fi
        if release_exists grafana observability; then
            available+=("grafana")
            names+=("Grafana      https://grafana.localhost:8443 (via Ingress)")
        fi
        if release_exists jaeger observability; then
            available+=("jaeger")
            names+=("Jaeger       https://jaeger.localhost:8443 (via Ingress)")
        fi

        if [[ ${#available[@]} -eq 0 ]]; then
            echo -e "  ${YELLOW}No services deployed yet${NC}"
            echo -e "  Run: ${CYAN}./cde.sh deploy all${NC}"
            exit 0
        fi

        echo -e "  ${BLUE}Available dashboards:${NC}\n"
        for i in "${!available[@]}"; do
            echo -e "    ${CYAN}$((i+1))${NC}) ${names[$i]}"
        done
        echo ""

        read -rp "  Select [1-${#available[@]}]: " choice

        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#available[@]} ]]; then
            err "Invalid selection"
            exit 1
        fi

        svc="${available[$((choice-1))]}"
        echo ""
    fi

    case "$svc" in
        vault)
            require_cluster
            if ! release_exists vault vault; then
                err "Vault is not deployed"
                exit 1
            fi
            open_browser "https://vault.localhost:8443"
            local vault_token
            vault_token=$(get_vault_token)
            if [[ -n "$vault_token" ]]; then
                echo -e "  ${DIM}Token: ${vault_token}${NC}"
            else
                echo -e "  ${DIM}Token: (run ./cde.sh status to see)${NC}"
            fi
            ;;
        grafana)
            require_cluster
            if ! release_exists grafana observability; then
                err "Grafana is not deployed"
                exit 1
            fi
            open_browser "https://grafana.localhost:8443"
            local gf_pw
            gf_pw=$(get_grafana_password)
            echo -e "  ${DIM}Credentials: admin / ${gf_pw:-unknown}${NC}"
            ;;
        jaeger)
            require_cluster
            if ! release_exists jaeger observability; then
                err "Jaeger is not deployed"
                exit 1
            fi
            open_browser "https://jaeger.localhost:8443"
            ;;
        dashboard|k8s)
            require_cluster
            if ! release_exists headlamp headlamp; then
                err "Dashboard (Headlamp) is not deployed"
                exit 1
            fi
            local token
            token=$(kubectl -n headlamp create token admin-user 2>/dev/null || echo "")
            open_browser "https://dashboard.localhost:8443"
            if [[ -n "$token" ]]; then
                echo -e "  ${DIM}Token (copied to clipboard if pbcopy available):${NC}"
                echo "$token" | pbcopy 2>/dev/null || true
                echo -e "  ${DIM}${token:0:50}...${NC}"
            fi
            ;;
        *)
            err "Unknown service: $svc"
            echo -e "  Available: dashboard, vault, grafana, jaeger"
            exit 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Status
# ─────────────────────────────────────────────────────────────────────────────

status() {
    echo -e "\n${PURPLE}${BOLD}◆ CDE${NC} Cloud Developer Experience\n"
    show_color_legend
    echo ""

    # Cluster status
    echo -e "${BLUE}Cluster${NC}"
    if cluster_exists; then
        if cluster_running; then
            ok "${CLUSTER_NAME} ${GREEN}running${NC}"
            local nodes
            nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
            dim "   Nodes: $nodes | Context: $(kubectl config current-context 2>/dev/null)"
        else
            warn "${CLUSTER_NAME} ${YELLOW}stopped${NC}"
            echo -e "\n  Run: ${CYAN}./cde.sh up${NC} to start"
            return 0
        fi
    else
        err "${CLUSTER_NAME} ${RED}not found${NC}"
        echo -e "\n  Run: ${CYAN}./cde.sh deploy all${NC} to create"
        return 0
    fi

    # Services table
    echo -e "\n${BLUE}Services${NC}"
    echo -e "  ${DIM}┌──────────────────────┬───────────┬──────────────────────────┐${NC}"
    echo -e "  ${DIM}│${NC} Service              ${DIM}│${NC} Status    ${DIM}│${NC} Access                   ${DIM}│${NC}"
    echo -e "  ${DIM}├──────────────────────┼───────────┼──────────────────────────┤${NC}"

    for svc in headlamp vault grafana jaeger opentelemetry-operator redis postgresql; do
        local ns display_name port access health status_icon status_text
        ns=$(get_svc_ns "$svc")
        display_name="$svc"
        port=$(get_svc_port "$svc")
        access=""

        [[ "$svc" == "opentelemetry-operator" ]] && display_name="otel-operator"
        [[ "$svc" == "headlamp" ]] && display_name="dashboard (headlamp)"

        health=$(get_health_status "$svc" "$ns")
        case "$health" in
            healthy)    status_icon="${CHECK}"; status_text="healthy" ;;
            starting)   status_icon="${YELLOW}◐${NC}"; status_text="starting" ;;
            failed)     status_icon="${CROSS}"; status_text="failed" ;;
            pending)    status_icon="${YELLOW}◌${NC}"; status_text="pending" ;;
            not-installed) status_icon="${DOT}"; status_text="-----" ;;
            *)          status_icon="${YELLOW}?${NC}"; status_text="unknown" ;;
        esac

        if [[ "$health" != "not-installed" && -n "$port" ]]; then
            case "$svc" in
                headlamp) access="dashboard.localhost:$port" ;;
                vault)    access="vault.localhost:$port" ;;
                grafana)  access="grafana.localhost:$port" ;;
                jaeger)   access="jaeger.localhost:$port" ;;
                *)        access="cluster:$port" ;;
            esac
        elif [[ "$health" != "not-installed" ]]; then
            access="(operator)"
        else
            access="-"
        fi

        printf "  ${DIM}│${NC} %-20s ${DIM}│${NC} %b %-7s ${DIM}│${NC} %-24s ${DIM}│${NC}\n" "$display_name" "$status_icon" "$status_text" "$access"
    done

    echo -e "  ${DIM}└──────────────────────┴───────────┴──────────────────────────┘${NC}"

    # Endpoint verification
    if [[ -f "$CDE_ACTIVE_FILE" ]]; then
        verify_endpoints 2>/dev/null || true
    fi

    # Apps
    echo -e "\n${BLUE}Apps${NC} ${DIM}(namespace: ${APPS_NS})${NC}"
    local pods
    pods=$(kubectl get pods -n "${APPS_NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$pods" -gt 0 ]]; then
        kubectl get pods -n "${APPS_NS}" --no-headers 2>/dev/null | while read -r line; do
            local name status
            name=$(echo "$line" | awk '{print $1}')
            status=$(echo "$line" | awk '{print $3}')
            if [[ "$status" == "Running" ]]; then
                ok "$name"
            else
                warn "$name ($status)"
            fi
        done
    else
        dim "   No apps deployed"
    fi

    # Quick actions
    echo -e "\n${BLUE}Quick Actions${NC}"
    dim "   ./cde.sh open vault      Open Vault UI in browser"
    dim "   ./cde.sh open grafana    Open Grafana in browser"
    dim "   ./cde.sh forward <svc>   Port-forward to service"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Post-Deploy Summary
# ─────────────────────────────────────────────────────────────────────────────

show_summary() {
    echo -e "\n${GREEN}${BOLD}◆ CDE Ready!${NC}\n"

    echo -e "  ${BLUE}Services:${NC}"
    echo -e "  ─────────────────────────────────────────────────────"

    for svc in headlamp vault grafana jaeger opentelemetry-operator postgresql redis; do
        local ns port health icon
        ns=$(get_svc_ns "$svc")
        port=$(get_svc_port "$svc")
        health=$(get_health_status "$svc" "$ns")

        [[ "$health" == "not-installed" ]] && continue

        case "$health" in
            healthy) icon="${CHECK}" ;;
            starting) icon="${YELLOW}◐${NC}" ;;
            failed) icon="${CROSS}" ;;
            *) icon="${YELLOW}?${NC}" ;;
        esac

        local line="  ${icon} "
        case "$svc" in
            headlamp) line+="Dashboard (Headlamp) ${CYAN}https://dashboard.localhost:${port}${NC}   ${DIM}(via Ingress)${NC}" ;;
            vault)    line+="Vault         ${CYAN}https://vault.localhost:${port}${NC}   ${DIM}(via Ingress)${NC}" ;;
            opentelemetry-operator)
                if [[ "$health" == "healthy" ]]; then
                    line+="OTel Operator ${DIM}(cluster-internal)${NC}"
                else
                    line+="OTel Operator ${DIM}(${health})${NC}"
                fi ;;
            grafana)  line+="Grafana       ${CYAN}https://grafana.localhost:${port}${NC}   ${DIM}(via Ingress)${NC}" ;;
            jaeger)   line+="Jaeger        ${CYAN}https://jaeger.localhost:${port}${NC}   ${DIM}(via Ingress)${NC}" ;;
            postgresql) line+="PostgreSQL    cluster:${port}            ${DIM}(TLS, cluster-internal)${NC}" ;;
            redis)    line+="Redis         cluster:${port}            ${DIM}(TLS, cluster-internal)${NC}" ;;
        esac
        echo -e "$line"
    done

    echo -e "  ─────────────────────────────────────────────────────"

    # Timing summary
    show_timing_summary

    # Credentials
    echo -e "\n  ${BLUE}Credentials:${NC}"

    if release_exists headlamp headlamp; then
        local dashboard_token
        dashboard_token=$(kubectl -n headlamp create token admin-user 2>/dev/null || echo "")
        if [[ -n "$dashboard_token" ]]; then
            echo -e "  Dashboard: ${BOLD}${dashboard_token}${NC}"
            echo "$dashboard_token" | pbcopy 2>/dev/null && echo -e "             ${DIM}(copied to clipboard)${NC}" || true
        fi
    fi

    if release_exists vault vault; then
        local vault_token="${VAULT_ROOT_TOKEN:-}"
        [[ -z "$vault_token" ]] && vault_token=$(get_vault_token)
        if [[ -n "$vault_token" ]]; then
            echo -e "  Vault:     ${BOLD}${vault_token}${NC}"
        fi
    fi

    if release_exists grafana observability; then
        local grafana_pw
        grafana_pw=$(get_grafana_password)
        echo -e "  Grafana:   ${BOLD}admin${NC} / ${BOLD}${grafana_pw:-unknown}${NC}"
    fi

    if release_exists postgresql data; then
        echo -e "  PostgreSQL: ${BOLD}postgres${NC} / ${BOLD}postgres${NC}"
    fi

    # Endpoint verification
    verify_endpoints 2>/dev/null || true

    echo -e "\n  ${DIM}All services accessible via Ingress at *.localhost:8443${NC}"

    # Log file hint
    if [[ -n "${CDE_LOG_FILE:-}" ]]; then
        echo -e "  ${DIM}Log file: ${CDE_LOG_FILE}${NC}"
    fi

    echo -e "\n  ${BLUE}Commands:${NC}"
    echo -e "  ${CYAN}./cde.sh open dashboard${NC}  Open Dashboard (Headlamp)"
    echo -e "  ${CYAN}./cde.sh status${NC}          Check service health"
    echo -e "  ${CYAN}./cde.sh teardown${NC}        Stop services and port-forwards"

    # Auto-trust CA certificate on macOS
    auto_trust_ca
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Status Header (quick snapshot for no-arg invocation)
# ─────────────────────────────────────────────────────────────────────────────

show_status_header() {
    echo -e "\n${PURPLE}${BOLD}◆ CDE${NC} - Cloud Developer Experience\n"

    if ! command -v k3d &>/dev/null || ! command -v kubectl &>/dev/null; then
        echo -e "  ${DOT} Prerequisites not installed"
        echo -e "  ${DIM}Run: ./cde.sh prereqs${NC}"
        return
    fi

    if cluster_exists && cluster_running; then
        echo -e "  ${CHECK} Cluster ${GREEN}running${NC} (${CLUSTER_NAME})"

        local -a running=()
        for svc in headlamp vault grafana jaeger opentelemetry-operator redis postgresql; do
            local ns
            ns=$(get_svc_ns "$svc")
            if helm status "$svc" -n "$ns" &>/dev/null 2>&1; then
                case "$svc" in
                    opentelemetry-operator) running+=("otel-operator") ;;
                    *) running+=("$svc") ;;
                esac
            fi
        done

        if [[ ${#running[@]} -gt 0 ]]; then
            echo -e "  ${CHECK} Services: ${running[*]}"
        else
            echo -e "  ${DOT} No services deployed"
        fi
    elif cluster_exists; then
        echo -e "  ${DOT} Cluster ${YELLOW}stopped${NC} (${CLUSTER_NAME})"
    else
        echo -e "  ${DOT} No cluster found"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    local name
    name=$(basename "$0")
    echo -e "
${BLUE}Usage:${NC} $name [options] <command> [args]

${BLUE}Options:${NC}
  -v, --verbose     Show detailed output
  -h, --help        Show this help

${BLUE}Cluster:${NC}
  up                Create/start cluster with core services
  down              Stop cluster (preserves data)
  destroy           Delete cluster entirely
  status            Show cluster and services status

${BLUE}Services:${NC}
  deploy <svc>      Deploy: dashboard, vault, otel, jaeger, grafana, redis, postgres
  deploy all        Deploy everything (creates cluster if needed)
  remove <svc>      Remove a service
  teardown          Remove all services

${BLUE}Access:${NC}
  open <svc>        Open in browser: dashboard, vault, grafana, jaeger
  forward <svc>     Port-forward: dashboard, vault, grafana, jaeger
  serve             Start all port-forwards (keeps dashboards accessible)

${BLUE}Other:${NC}
  prereqs           Check prerequisites
  token             Generate and copy dashboard token to clipboard
  trust-ca          Export and trust the CDE CA certificate (macOS)

${BLUE}Examples:${NC}
  $name deploy all          # Full setup in one command
  $name status              # See what's running
  $name open vault          # Open Vault in browser
  $name -v deploy postgres  # Deploy with verbose output
"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -h|--help)
                echo -e "\n${PURPLE}${BOLD}◆ CDE${NC} - Cloud Developer Experience"
                usage
                exit 0
                ;;
            -*)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done

    local cmd="${1:-}"
    shift || true

    # Initialize logging for commands that do work
    if [[ -n "$cmd" && "$cmd" != "help" && "$cmd" != "--help" ]]; then
        init_log
        log_file "INFO" "Command: $cmd $*"
        log_file "INFO" "Cluster: ${CLUSTER_NAME}, Verbose: ${VERBOSE}, Non-interactive: ${NONINTERACTIVE}"
        clear
    fi

    case "$cmd" in
        "")
            show_status_header
            usage
            ;;
        up)
            echo -e "\n${PURPLE}◆ CDE${NC} Starting...\n"
            show_color_legend
            echo ""
            check_prereqs
            echo ""
            create_cluster
            deploy_ingress
            deploy_cert_manager
            echo -e "\n${GREEN}Ready!${NC} Deploy services: ${CYAN}./cde.sh deploy <service>${NC}\n"
            ;;
        down)
            echo -e "\n${PURPLE}◆ CDE${NC} Stopping...\n"
            stop_cluster
            echo ""
            ;;
        destroy)
            echo -e "\n${PURPLE}◆ CDE${NC} Destroying...\n"
            delete_cluster
            echo ""
            ;;
        status)
            status
            ;;
        prereqs)
            echo -e "\n${PURPLE}◆ CDE${NC} Prerequisites\n"
            check_prereqs
            echo ""
            ;;
        token)
            require_cluster
            if ! release_exists headlamp headlamp; then
                err "Dashboard not deployed. Run: ./cde.sh deploy dashboard"
                exit 1
            fi
            local token
            token=$(kubectl -n headlamp create token admin-user 2>/dev/null)
            if [[ -n "$token" ]]; then
                echo "$token" | pbcopy 2>/dev/null && echo -e "\n${GREEN}✓${NC} Dashboard token copied to clipboard\n" || echo "$token"
            else
                err "Failed to generate token"
                exit 1
            fi
            ;;
        trust-ca)
            echo -e "\n${PURPLE}◆ CDE${NC} Trust CA Certificate\n"
            if ! kubectl get secret cde-ca-secret -n cert-manager &>/dev/null; then
                err "CDE CA not found. Deploy dashboard first: ./cde.sh deploy dashboard"
                exit 1
            fi

            local script_dir ca_file
            script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            ca_file="${script_dir}/../cde-ca.crt"

            kubectl get secret cde-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca_file"
            ok "CA certificate exported to: ${ca_file}"

            echo ""
            echo -e "  ${BLUE}To trust the CA on macOS, run:${NC}"
            echo -e "  ${CYAN}sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${ca_file}${NC}"
            echo ""
            echo -e "  ${DIM}Or double-click the file and set it to 'Always Trust' in Keychain Access${NC}"
            echo ""

            read -rp "  Trust the CA now? (requires sudo) [y/N]: " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca_file"; then
                    ok "CA certificate trusted! Restart your browser to apply."
                else
                    err "Failed to trust CA certificate"
                fi
            fi
            echo ""
            ;;
        open)
            cmd_open "$@"
            ;;
        deploy)
            local svc="${1:-}"
            case "$svc" in
                dashboard|vault|otel|jaeger|grafana|redis|postgres)
                    require_cluster
                    echo -e "\n${PURPLE}◆ CDE${NC} Deploy\n"
                    show_context
                    setup_helm_repos
                    # Ensure infrastructure prerequisites (skips if already healthy)
                    deploy_ingress
                    deploy_cert_manager
                    VERBOSE="true"
                    case "$svc" in
                        dashboard) deploy_dashboard ;;
                        vault) deploy_vault ;;
                        otel) deploy_otel ;;
                        jaeger) deploy_jaeger ;;
                        grafana) deploy_grafana ;;
                        redis) deploy_redis ;;
                        postgres) deploy_postgres ;;
                    esac
                    echo ""
                    ;;
                all)
                    echo -e "\n${PURPLE}◆ CDE${NC} Deploy All\n"
                    show_color_legend
                    echo ""

                    if [[ "$VERBOSE" == "true" ]]; then
                        debug_cluster
                    fi

                    if cluster_exists && cluster_running; then
                        ok "Cluster '${CLUSTER_NAME}' running"
                        show_context
                        setup_helm_repos
                    elif cluster_exists; then
                        spinner_start "Cluster exists but stopped, starting..."
                        if k3d cluster start "${CLUSTER_NAME}" 2>&1 | verbose_or_log; then
                            spinner_stop "success" "Cluster started"
                        else
                            spinner_stop "error" "Failed to start cluster"
                            exit 1
                        fi
                        show_context
                        setup_helm_repos
                    else
                        local other_clusters
                        other_clusters=$(k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -v "^${CLUSTER_NAME}$" || true)
                        if [[ -n "$other_clusters" ]]; then
                            echo -e "  ${YELLOW}!${NC} Other k3d clusters detected:"
                            k3d cluster list 2>/dev/null | sed 's/^/    /'
                            echo ""
                            echo -e "  ${DIM}If ports 80/443/6550 are in use, cluster creation will fail.${NC}"
                            echo -e "  ${DIM}To use existing cluster: ${CYAN}CDE_CLUSTER=<name> ./cde.sh deploy all${NC}"
                            echo ""
                        fi

                        check_prereqs
                        echo ""
                        create_cluster
                        setup_helm_repos
                    fi

                    # Deploy infrastructure (required)
                    deploy_ingress
                    deploy_cert_manager

                    # Deploy all services (continue on failure)
                    deploy_dashboard || true
                    deploy_vault || true
                    deploy_otel || true
                    deploy_jaeger || true
                    deploy_grafana || true
                    deploy_redis || true
                    deploy_postgres || true

                    start_port_forwards
                    show_summary
                    ;;
                "")
                    err "Specify a service: dashboard, vault, otel, jaeger, grafana, redis, postgres, all"
                    exit 1
                    ;;
                *)
                    err "Unknown service: $svc"
                    exit 1
                    ;;
            esac
            ;;
        remove)
            require_cluster
            echo -e "\n${PURPLE}◆ CDE${NC} Remove\n"
            show_context
            local svc="${1:-}"
            case "$svc" in
                dashboard) remove_service headlamp headlamp ;;
                vault) remove_service vault vault ;;
                otel)
                    if kubectl delete instrumentation --all -n otel-apps 2>&1 | verbose_or_log; then
                        ok "otel instrumentation removed"
                    else
                        err "otel instrumentation removal failed"
                    fi
                    remove_service opentelemetry-operator opentelemetry-operator-system
                    ;;
                jaeger) remove_service jaeger observability ;;
                grafana) remove_service grafana observability ;;
                redis) remove_service redis data ;;
                postgres) remove_service postgresql data ;;
                "")
                    err "Specify a service to remove"
                    exit 1
                    ;;
                *)
                    err "Unknown service: $svc"
                    exit 1
                    ;;
            esac
            echo ""
            ;;
        teardown)
            require_cluster
            teardown_services
            ;;
        forward)
            require_cluster
            local svc="${1:-}"
            if [[ -z "$svc" && "$NONINTERACTIVE" == "true" ]]; then
                err "Specify a service: dashboard, vault, grafana, jaeger"
                exit 1
            elif [[ -z "$svc" ]]; then
                select_forward
            else
                echo -e "\n${PURPLE}◆ CDE${NC} Port Forward\n"
                case "$svc" in
                    dashboard) forward_dashboard ;;
                    vault) forward_vault ;;
                    grafana) forward_grafana ;;
                    jaeger) forward_jaeger ;;
                    *)
                        err "Unknown service: $svc"
                        echo -e "  Available: dashboard, vault, grafana, jaeger"
                        exit 1
                        ;;
                esac
            fi
            ;;
        serve)
            require_cluster
            echo -e "\n${PURPLE}◆ CDE${NC} Serve - Starting all port-forwards\n"

            start_port_forwards

            if release_exists headlamp headlamp; then
                echo -e "  ${CHECK} Dashboard  ${CYAN}https://dashboard.localhost:8443${NC}  ${DIM}(via Ingress)${NC}"
            fi
            if release_exists vault vault; then
                local vault_token
                vault_token=$(get_vault_token)
                if [[ -n "$vault_token" ]]; then
                    echo -e "  ${CHECK} Vault      ${CYAN}https://vault.localhost:8443${NC}  Token: ${vault_token}  ${DIM}(via Ingress)${NC}"
                else
                    echo -e "  ${CHECK} Vault      ${CYAN}https://vault.localhost:8443${NC}  ${DIM}(via Ingress)${NC}"
                fi
            fi
            if release_exists grafana observability; then
                local gf_pw
                gf_pw=$(get_grafana_password)
                echo -e "  ${CHECK} Grafana    ${CYAN}https://grafana.localhost:8443${NC}  admin / ${gf_pw:-unknown}  ${DIM}(via Ingress)${NC}"
            fi
            if release_exists jaeger observability; then
                echo -e "  ${CHECK} Jaeger     ${CYAN}https://jaeger.localhost:8443${NC}  ${DIM}(via Ingress)${NC}"
            fi

            if [[ ! -f "$CDE_ACTIVE_FILE" ]]; then
                warn "No services deployed. Run: ./cde.sh deploy all"
                exit 0
            fi

            echo ""
            echo -e "  ${DIM}Port-forwards running. Press Ctrl+C to stop.${NC}"
            echo ""

            trap "stop_port_forwards; exit 0" INT TERM
            while [[ -f "$CDE_ACTIVE_FILE" ]]; do sleep 1; done
            ;;
        help)
            echo -e "\n${PURPLE}${BOLD}◆ CDE${NC} - Cloud Developer Experience"
            usage
            ;;
        *)
            err "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
