#!/usr/bin/env bash
# portforward.sh -- Port-forward lifecycle

# Start all port-forwards in background and save PIDs
start_port_forwards() {
    log_file "INFO" "start_port_forwards: setting up background port-forwards"
    stop_port_forwards 2>/dev/null

    # All services are served via Ingress — no port-forwards needed
    # Headlamp:  dashboard.localhost:8443
    # Vault:     vault.localhost:8443
    # Grafana:   grafana.localhost:8443
    # Jaeger:    jaeger.localhost:8443

    # Create marker file so serve command knows we ran
    touch "$CDE_ACTIVE_FILE"
    log_file "INFO" "start_port_forwards: all services via Ingress, no port-forwards needed"
}

# Stop all port-forwards
stop_port_forwards() {
    log_file "INFO" "stop_port_forwards: cleaning up"
    if [[ -f "$CDE_ACTIVE_FILE" ]]; then
        while read -r pid; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done < "$CDE_ACTIVE_FILE"
        rm -f "$CDE_ACTIVE_FILE"
    fi
}

# Individual forward functions
forward_vault() {
    log_file "INFO" "forward_vault: vault available via Ingress"
    local token
    token=$(get_vault_token)
    echo -e "  ${CYAN}Vault UI:${NC} https://vault.localhost:8443"
    echo -e "  ${DIM}(served via Ingress - no port-forward needed)${NC}"
    if [[ -n "$token" ]]; then
        echo -e "  ${DIM}Token: ${token}${NC}"
    else
        echo -e "  ${DIM}Token: (not available - vault may need initialization)${NC}"
    fi
}

forward_grafana() {
    log_file "INFO" "forward_grafana: grafana available via Ingress"
    local pw
    pw=$(get_grafana_password)
    echo -e "  ${CYAN}Grafana:${NC} https://grafana.localhost:8443"
    echo -e "  ${DIM}(served via Ingress - no port-forward needed)${NC}"
    if [[ -n "$pw" ]]; then
        echo -e "  ${DIM}Credentials: admin / ${pw}${NC}"
    fi
}

forward_jaeger() {
    log_file "INFO" "forward_jaeger: jaeger available via Ingress"
    echo -e "  ${CYAN}Jaeger UI:${NC} https://jaeger.localhost:8443"
    echo -e "  ${DIM}(served via Ingress - no port-forward needed)${NC}"
}

forward_dashboard() {
    log_file "INFO" "forward_dashboard: dashboard available via Ingress"
    local token
    token=$(kubectl -n headlamp create token admin-user 2>/dev/null || echo "")
    echo -e "  ${CYAN}Dashboard (Headlamp):${NC} https://dashboard.localhost:8443"
    echo -e "  ${DIM}(served via Ingress - no port-forward needed)${NC}"
    if [[ -n "$token" ]]; then
        echo -e "  ${DIM}Token: ${token:0:50}...${NC}"
        echo "$token" | pbcopy 2>/dev/null && echo -e "  ${DIM}(copied to clipboard)${NC}" || true
    fi
}

# Interactive forward selection
select_forward() {
    echo -e "\n${PURPLE}◆ CDE${NC} Port Forward\n"

    local -a available=()
    local -a names=()

    if release_exists headlamp headlamp; then
        available+=("dashboard")
        names+=("Dashboard (Headlamp) dashboard.localhost:8443  (via Ingress)")
    fi
    if release_exists vault vault; then
        available+=("vault")
        names+=("Vault        vault.localhost:8443  (via Ingress)")
    fi
    if release_exists grafana observability; then
        available+=("grafana")
        names+=("Grafana      grafana.localhost:8443  (via Ingress)")
    fi
    if release_exists jaeger observability; then
        available+=("jaeger")
        names+=("Jaeger       jaeger.localhost:8443  (via Ingress)")
    fi

    if [[ ${#available[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}No services deployed yet${NC}"
        echo -e "  Run: ${CYAN}./cde.sh deploy all${NC}"
        exit 0
    fi

    echo -e "  ${BLUE}Available services:${NC}\n"
    for i in "${!available[@]}"; do
        echo -e "    ${CYAN}$((i+1))${NC}) ${names[$i]}"
    done
    echo ""

    read -rp "  Select [1-${#available[@]}]: " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#available[@]} ]]; then
        err "Invalid selection"
        exit 1
    fi

    local svc="${available[$((choice-1))]}"
    log_file "INFO" "select_forward: user selected $svc"
    echo ""

    case "$svc" in
        dashboard) forward_dashboard ;;
        vault) forward_vault ;;
        grafana) forward_grafana ;;
        jaeger) forward_jaeger ;;
    esac
}

# Verify endpoint accessibility (Phase 6)
verify_endpoints() {
    log_file "INFO" "verify_endpoints: starting endpoint checks"
    local all_ok=true

    echo -e "\n  ${BLUE}Endpoint verification:${NC}"

    if release_exists headlamp headlamp; then
        if curl -sk --connect-timeout 2 --max-time 3 https://dashboard.localhost:8443 &>/dev/null; then
            ok "Dashboard  https://dashboard.localhost:8443"
        else
            warn "Dashboard  https://dashboard.localhost:8443 ${DIM}(not reachable)${NC}"
            all_ok=false
        fi
    fi

    if release_exists vault vault; then
        if curl -sk --connect-timeout 2 --max-time 3 https://vault.localhost:8443/v1/sys/health &>/dev/null; then
            ok "Vault      https://vault.localhost:8443"
        else
            warn "Vault      https://vault.localhost:8443 ${DIM}(not reachable)${NC}"
            all_ok=false
        fi
    fi

    if release_exists grafana observability; then
        if curl -sk --connect-timeout 2 --max-time 3 https://grafana.localhost:8443/api/health &>/dev/null; then
            ok "Grafana    https://grafana.localhost:8443"
        else
            warn "Grafana    https://grafana.localhost:8443 ${DIM}(not reachable)${NC}"
            all_ok=false
        fi
    fi

    if release_exists jaeger observability; then
        if curl -sk --connect-timeout 2 --max-time 3 https://jaeger.localhost:8443 &>/dev/null; then
            ok "Jaeger     https://jaeger.localhost:8443"
        else
            warn "Jaeger     https://jaeger.localhost:8443 ${DIM}(not reachable)${NC}"
            all_ok=false
        fi
    fi

    if release_exists postgresql data; then
        ok "PostgreSQL cluster:5432 ${DIM}(TLS, cluster-internal)${NC}"
    fi

    if release_exists redis data; then
        ok "Redis      cluster:6379 ${DIM}(TLS, cluster-internal)${NC}"
    fi

    if $all_ok; then
        log_file "INFO" "verify_endpoints: all endpoints reachable"
    else
        log_file "WARN" "verify_endpoints: some endpoints not reachable"
    fi
    $all_ok
}
