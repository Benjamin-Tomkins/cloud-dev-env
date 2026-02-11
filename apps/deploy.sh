#!/usr/bin/env bash
#
# deploy.sh -- Build, deploy, and test applications
#
# How It Works:
#   1. Build Docker images (java-api, python-api)
#   2. Import images into k3d cluster registry
#   3. Create namespace + service account
#   4. Configure Vault secrets & Kubernetes auth (via vault-setup.sh)
#   5. Apply K8s manifests + rollout restart (picks up OTel/Vault injection)
#   6. Wait for pods ready
#   7. Run smoke tests (verify end-to-end integration)
#
#   Build → Deploy → Test Pipeline:
#
#     Build                    Deploy                           Test
#     ─────                    ──────                           ────
#     docker build java  ─┐    namespace + SA ──► vault-setup   pod running?
#     docker build python ─┼─► k3d image import   │             OTel injected?
#                          │                       ▼             Vault injected?
#                          │    kubectl apply manifests          secrets present?
#                          │    rollout restart ──────────────►  endpoint responds?
#                          │    wait pods ready                  vault_injected=true?
#                          └──────────────────────────────────►  traces in Jaeger?
#
# The stage() function wraps each step with timing + spinner, so the output
# matches the CDE infrastructure scripts' visual style.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source shared CDE libraries (colors, icons, spinner)
source "$SCRIPT_DIR/../scripts/lib/constants.sh"
source "$SCRIPT_DIR/../scripts/lib/ui.sh"

cleanup() {
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
    fi
    [[ -n "${_SPINNER_LABEL_FILE:-}" ]] && rm -f "$_SPINNER_LABEL_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# 1. Track Stage Timing and Results
# =============================================================================
_STAGE_TIMES=()

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 60 ]]; then
        local mins=$(( secs / 60 )) rem=$(( secs % 60 ))
        [[ "$rem" -gt 0 ]] && echo "${mins}m ${rem}s" || echo "${mins}m"
    else
        echo "${secs}s"
    fi
}

# Run a stage with timing + spinner. Captures stdout/stderr, shows pass/fail.
#
# Usage: stage "Label" command args...
# Returns: 0 on success, 1 on failure (prints last 20 lines of output)
stage() {
    local label="$1"; shift
    local start=$SECONDS
    spinner_start "$label..."

    local output
    if output=$("$@" 2>&1); then
        local elapsed=$(( SECONDS - start ))
        _STAGE_TIMES+=("${label}:${elapsed}")
        spinner_stop "success" "$label" "$(format_duration $elapsed)"
        return 0
    else
        local elapsed=$(( SECONDS - start ))
        _STAGE_TIMES+=("${label}:${elapsed}")
        spinner_stop "error" "$label" "$(format_duration $elapsed)"
        echo -e "\n${DIM}${output}${NC}" | tail -20
        return 1
    fi
}

# =============================================================================
# 2. Set Up Environment Config
# =============================================================================
NAMESPACE="${CDE_APPS_NS:-otel-apps}"
CLUSTER="${CDE_CLUSTER:-otel-dev}"

# =============================================================================
# 3. Build and Deploy Application Images
# =============================================================================

do_build_java() {
    docker build -t java-api:latest java-api/
}

do_build_python() {
    docker build -t python-api:latest python-api/
}

do_import() {
    k3d image import java-api:latest python-api:latest -c "$CLUSTER"
}

do_namespace() {
    kubectl apply -f namespace.yaml
    kubectl apply -f service-account.yaml
}

do_vault_setup() {
    bash vault-setup.sh
}

do_deploy_java() {
    kubectl apply -f java-api/
    # Restart to force pod recreation — OTel and Vault inject via mutating webhooks
    # at pod creation time, so existing pods won't pick up CR changes
    kubectl rollout restart deployment/java-api -n "$NAMESPACE" 2>/dev/null || true
}

do_deploy_python() {
    kubectl apply -f python-api/
    kubectl rollout restart deployment/python-api -n "$NAMESPACE" 2>/dev/null || true
}

do_ingress() {
    kubectl apply -f ingress.yaml
}

do_wait_pods() {
    # Wait for rollouts first — old pods get terminated during restart, so
    # waiting on "all pods Ready" too early would see the dying pods
    kubectl rollout status deployment/java-api -n "$NAMESPACE" --timeout=120s
    kubectl rollout status deployment/python-api -n "$NAMESPACE" --timeout=120s
    kubectl wait --for=condition=Ready pods --all -n "$NAMESPACE" --timeout=300s
}

# =============================================================================
# 4. Verify Integration with Smoke Tests
# =============================================================================
# Each test verifies a specific integration point to catch misconfigurations
# early. Tests run in-order: pod state → injection → secrets → endpoints → traces.
PASS=0
FAIL=0

test_pass() { echo -e "  ${CHECK} $1"; PASS=$((PASS + 1)); }
test_fail() { echo -e "  ${CROSS} $1"; FAIL=$((FAIL + 1)); }

test_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then test_pass "$desc"; else test_fail "$desc"; fi
}

get_pod() {
    kubectl get pod -n "$NAMESPACE" -l "app=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

run_tests() {
    for app in java-api python-api; do
        local pod
        pod=$(get_pod "$app") || true
        if [[ -z "$pod" ]]; then
            test_fail "$app pod exists"
            continue
        fi

        # Pod running
        local phase
        phase=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}')
        if [[ "$phase" == "Running" ]]; then
            test_pass "$app pod running"
        else
            test_fail "$app pod running ${DIM}(phase=$phase)${NC}"
        fi

        # OTel init-container injected by operator
        local inits
        inits=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.initContainers[*].name}')
        if echo "$inits" | grep -q "opentelemetry-auto-instrumentation"; then
            test_pass "$app OTel auto-instrumentation injected"
        else
            test_fail "$app OTel auto-instrumentation injected ${DIM}(containers: $inits)${NC}"
        fi

        # Vault agent init-container
        if echo "$inits" | grep -q "vault-agent-init"; then
            test_pass "$app Vault agent injected"
        else
            test_fail "$app Vault agent injected ${DIM}(containers: $inits)${NC}"
        fi

        # Vault secrets file present
        local secret_content
        secret_content=$(kubectl exec -n "$NAMESPACE" "$pod" -c "$app" -- cat /vault/secrets/config 2>/dev/null || echo "")
        if [[ -n "$secret_content" ]]; then
            test_pass "$app /vault/secrets/config present"
        else
            test_fail "$app /vault/secrets/config present"
        fi

        # OTEL_EXPORTER_OTLP_ENDPOINT set by operator
        local otel_ep
        otel_ep=$(kubectl get pod -n "$NAMESPACE" "$pod" \
            -o jsonpath="{.spec.containers[?(@.name=='$app')].env[?(@.name=='OTEL_EXPORTER_OTLP_ENDPOINT')].value}" 2>/dev/null || echo "")
        if [[ -n "$otel_ep" ]]; then
            test_pass "$app OTEL_EXPORTER_OTLP_ENDPOINT set"
        else
            test_fail "$app OTEL_EXPORTER_OTLP_ENDPOINT set"
        fi
    done

    echo ""

    # Endpoint responses via Ingress
    for app in java python; do
        local resp
        resp=$(curl -sk "https://api.localhost:8443/$app/" 2>/dev/null || echo "")
        if [[ -z "$resp" ]]; then
            test_fail "$app-api endpoint responds via ingress"
            continue
        fi
        test_pass "$app-api endpoint responds via ingress"

        if echo "$resp" | grep -q '"vault_injected":[[:space:]]*true'; then
            test_pass "$app-api vault_injected=true"
        else
            test_fail "$app-api vault_injected=true ${DIM}($resp)${NC}"
        fi
    done

    echo ""

    # Jaeger traces
    local jaeger_services
    jaeger_services=$(curl -sk "https://jaeger.localhost:8443/api/services" 2>/dev/null || echo "")
    if [[ -z "$jaeger_services" ]]; then
        test_fail "Jaeger API reachable"
    else
        test_pass "Jaeger API reachable"
        for svc in java-api python-api; do
            if echo "$jaeger_services" | grep -q "$svc"; then
                test_pass "$svc traces in Jaeger"
            else
                test_fail "$svc traces in Jaeger ${DIM}(not yet reported)${NC}"
            fi
        done
    fi
}

# =============================================================================
# 5. Execute Build-Deploy-Test Pipeline
# =============================================================================

echo -e "\n${PURPLE}${BOLD}◆ Apps${NC} Deploy & Test\n"

# Build
echo -e "${BLUE}Build${NC}"
stage "Docker build java-api"    do_build_java
stage "Docker build python-api"  do_build_python
stage "Import images to k3d"     do_import

# Deploy
echo -e "\n${BLUE}Deploy${NC}"
stage "Namespace & service account" do_namespace
stage "Vault secrets & auth"        do_vault_setup
stage "Java API manifests"          do_deploy_java
stage "Python API manifests"        do_deploy_python
stage "Ingress (TLS)"               do_ingress
stage "Wait for pods ready"         do_wait_pods

# Test
echo -e "\n${BLUE}Test${NC}"
echo -e "  ${DIM}Verifying OTel instrumentation, Vault injection, and endpoints${NC}"
echo ""
run_tests

# Summary
echo -e "  ${DIM}─────────────────────────────────${NC}"

local_total=0
for entry in "${_STAGE_TIMES[@]}"; do
    local_total=$(( local_total + ${entry#*:} ))
done

if [[ $FAIL -eq 0 ]]; then
    echo -e "\n${GREEN}${BOLD}◆ Apps Ready!${NC}  ${DIM}${PASS} tests passed in $(format_duration $local_total)${NC}\n"
else
    echo -e "\n${YELLOW}${BOLD}◆ Apps Deployed${NC}  ${DIM}${PASS} passed, ${FAIL} failed in $(format_duration $local_total)${NC}\n"
fi

echo -e "  ${BLUE}Endpoints:${NC}"
echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
echo -e "  Java API    ${CYAN}https://api.localhost:8443/java/${NC}"
echo -e "  Python API  ${CYAN}https://api.localhost:8443/python/${NC}"
echo -e "  Jaeger      ${CYAN}https://jaeger.localhost:8443${NC}"
echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"

echo -e "\n  ${BLUE}Timing:${NC}"
echo -e "  ${DIM}─────────────────────────────────${NC}"
for entry in "${_STAGE_TIMES[@]}"; do
    printf "  %-30s %s\n" "${entry%%:*}" "$(format_duration ${entry#*:})"
done
echo -e "  ${DIM}─────────────────────────────────${NC}"
printf "  ${BOLD}%-30s %s${NC}\n" "Total" "$(format_duration $local_total)"
echo ""

[[ $FAIL -gt 0 ]] && exit 1 || exit 0
