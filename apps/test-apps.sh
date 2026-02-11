#!/usr/bin/env bash
# test-apps.sh -- Integration smoke tests for deployed apps
# Verifies: pods running, OTel init-containers injected, Vault secrets present,
#           endpoints responding, traces reaching Jaeger
set -euo pipefail

NAMESPACE="otel-apps"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Pod Status ==="
# ─────────────────────────────────────────────────────────────────────────────

for app in java-api python-api; do
    pod=$(kubectl get pod -n "$NAMESPACE" -l app="$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod" ]]; then
        fail "$app pod exists"
        continue
    fi
    pass "$app pod exists ($pod)"

    phase=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}')
    if [[ "$phase" == "Running" ]]; then pass "$app pod phase=Running"; else fail "$app pod phase=Running (got $phase)"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== OTel Init-Container Injection ==="
# ─────────────────────────────────────────────────────────────────────────────

for app in java-api python-api; do
    pod=$(kubectl get pod -n "$NAMESPACE" -l app="$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [[ -z "$pod" ]] && { fail "$app OTel init-container (no pod)"; continue; }

    init_containers=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.initContainers[*].name}')
    if echo "$init_containers" | grep -q "opentelemetry-auto-instrumentation"; then
        pass "$app has OTel init-container"
    else
        fail "$app has OTel init-container (found: $init_containers)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Vault Agent Injection ==="
# ─────────────────────────────────────────────────────────────────────────────

for app in java-api python-api; do
    pod=$(kubectl get pod -n "$NAMESPACE" -l app="$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [[ -z "$pod" ]] && { fail "$app Vault injection (no pod)"; continue; }

    # Check for vault-agent init-container
    init_containers=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.initContainers[*].name}')
    if echo "$init_containers" | grep -q "vault-agent-init"; then
        pass "$app has vault-agent-init container"
    else
        fail "$app has vault-agent-init container (found: $init_containers)"
    fi

    # Check that the secrets file was actually written
    secret_content=$(kubectl exec -n "$NAMESPACE" "$pod" -c "$app" -- cat /vault/secrets/config 2>/dev/null || echo "")
    if [[ -n "$secret_content" ]]; then
        pass "$app has /vault/secrets/config"
    else
        fail "$app has /vault/secrets/config (empty or missing)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== OTel Environment Variables ==="
# ─────────────────────────────────────────────────────────────────────────────

for app in java-api python-api; do
    pod=$(kubectl get pod -n "$NAMESPACE" -l app="$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [[ -z "$pod" ]] && { fail "$app OTel env vars (no pod)"; continue; }

    # The OTel operator injects OTEL_EXPORTER_OTLP_ENDPOINT into the container env
    env_val=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath="{.spec.containers[?(@.name=='$app')].env[?(@.name=='OTEL_EXPORTER_OTLP_ENDPOINT')].value}" 2>/dev/null || echo "")
    if [[ -n "$env_val" ]]; then
        pass "$app has OTEL_EXPORTER_OTLP_ENDPOINT=$env_val"
    else
        fail "$app has OTEL_EXPORTER_OTLP_ENDPOINT (not set by operator)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Endpoint Responses ==="
# ─────────────────────────────────────────────────────────────────────────────

for app in java python; do
    resp=$(curl -sk "https://api.localhost:8443/$app/" 2>/dev/null || echo "")
    if [[ -z "$resp" ]]; then
        fail "$app-api endpoint responds"
        continue
    fi
    pass "$app-api endpoint responds"

    # Check vault_injected field
    if echo "$resp" | grep -q '"vault_injected":[[:space:]]*true'; then
        pass "$app-api reports vault_injected=true"
    else
        fail "$app-api reports vault_injected=true (response: $resp)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Jaeger Traces ==="
# ─────────────────────────────────────────────────────────────────────────────

# Query Jaeger API for services that have reported traces
jaeger_services=$(curl -sk "https://jaeger.localhost:8443/api/services" 2>/dev/null || echo "")
if [[ -z "$jaeger_services" ]]; then
    fail "Jaeger API reachable"
else
    pass "Jaeger API reachable"
    for svc in java-api python-api; do
        if echo "$jaeger_services" | grep -q "$svc"; then
            pass "$svc traces visible in Jaeger"
        else
            fail "$svc traces visible in Jaeger (not yet reported)"
        fi
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "  All tests passed." || exit 1
