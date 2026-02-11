#!/usr/bin/env bash
# vault.sh -- Vault deploy/init/unseal lifecycle
#
# How It Works:
#   1. Helm install (standalone mode, in-memory storage, TLS via Ingress)
#   2. Wait for pod Running (smart poll, not fixed sleep)
#   3. Check vault status and branch:
#   4. Verify health endpoint returns 200
#
#   Init/Unseal State Machine:
#
#     helm install ──► wait pod Running ──► vault status?
#                                             │
#                    ┌───────────────────────┬┴──────────────────────┐
#                    ▼                       ▼                       ▼
#              not initialized          sealed + key            sealed, no key
#                    │                       │                       │
#                    ▼                       ▼                       ▼
#              operator init            unseal with             delete statefulset
#              (1 key, 1 thr)           stored key              + helm re-deploy
#                    │                       │                       │
#                    ▼                       │                       ▼
#              store creds in                │                  operator init
#              K8s Secret                    │                  (fresh start)
#                    │                       │                       │
#                    ▼                       │                       ▼
#                  unseal                    │                  store + unseal
#                    │                       │                       │
#                    └───────────┬───────────┘───────────────────────┘
#                                ▼
#                    vault_wait_ready (HTTP 200)
#
# Why This Exists:
#   Vault requires explicit initialization and unsealing after every pod restart
#   (we use in-memory storage for simplicity — no PVC to manage). This module
#   automates the full init/unseal lifecycle so `deploy all` is non-interactive.
#
# Security Notes:
#   - Root token and unseal key are stored in a K8s Secret for automatic unseal
#     on pod restart. This is for local development convenience only.
#   - The mkcert CA private key is loaded into the cluster (via tls.sh) so
#     cert-manager can sign browser-trusted certs. Never use this in production.
#   - vault_unseal() pipes the key via stdin to avoid exposing it in the host
#     process table (ps aux would show it if passed as a CLI argument).
#
# Dependencies: log.sh, ui.sh, timing.sh, k8s.sh, tls.sh, constants.sh

# =============================================================================
# 1. Query and Control Vault State
# =============================================================================

# Execute a command inside the vault pod
vault_exec() {
    kubectl exec -n vault vault-0 -- sh -c "export VAULT_ADDR=http://127.0.0.1:8200 && $1" 2>/dev/null
}

# Get vault status as JSON.
# vault status returns exit code 2 when sealed, so we suppress errors with
# `|| true` and validate the output by checking for the "initialized" key.
# Returns a fake default `{"initialized":false,"sealed":true}` when vault is
# unreachable, so callers can always parse the JSON without nil checks.
vault_status_json() {
    local output
    output=$(vault_exec 'vault status -format=json' 2>/dev/null) || true
    if [[ -n "$output" ]] && echo "$output" | grep -q '"initialized"'; then
        echo "$output"
    else
        log_file "DEBUG" "vault_status_json: could not reach vault, returning defaults"
        echo '{"initialized":false,"sealed":true}'
    fi
}

# Wait for vault to be unsealed (polls vault status)
vault_wait_unsealed() {
    local timeout="${1:-30}"
    local start=$SECONDS

    log_file "DEBUG" "vault_wait_unsealed: timeout=${timeout}s"
    while (( SECONDS - start < timeout )); do
        local status
        status=$(vault_status_json)
        if echo "$status" | grep -q '"sealed":[[:space:]]*false'; then
            log_file "INFO" "vault_wait_unsealed: unsealed after $((SECONDS - start))s"
            return 0
        fi
        sleep 0.5
    done
    log_file "WARN" "vault_wait_unsealed: timed out after ${timeout}s"
    return 1
}

# Wait for vault to be ready via health endpoint
vault_wait_ready() {
    local timeout="${1:-30}"
    local start=$SECONDS

    log_file "DEBUG" "vault_wait_ready: timeout=${timeout}s"
    while (( SECONDS - start < timeout )); do
        # Vault returns 200 when initialized, unsealed, and active
        local http_code
        http_code=$(kubectl exec -n vault vault-0 -- sh -c \
            'wget -q -O /dev/null -S http://127.0.0.1:8200/v1/sys/health 2>&1 | head -1 | grep -o "[0-9][0-9][0-9]"' \
            2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            log_file "INFO" "vault_wait_ready: health endpoint returned 200 after $((SECONDS - start))s"
            return 0
        fi
        sleep 0.5
    done
    log_file "WARN" "vault_wait_ready: health endpoint timed out after ${timeout}s (last http=$http_code)"
    return 1
}

# Unseal vault by piping key via stdin.
# vault CLI doesn't support reading unseal keys from stdin directly, so we pipe
# to `read` inside the pod's shell and pass as an argument there. The key only
# appears in the pod's process table (internal to the container), never on the host.
#
# Usage: vault_unseal <unseal_key>
vault_unseal() {
    local key="$1"
    printf '%s\n' "$key" | kubectl exec -i -n vault vault-0 -- \
        sh -c 'export VAULT_ADDR=http://127.0.0.1:8200 && read KEY && vault operator unseal "$KEY"' 2>/dev/null
}

# =============================================================================
# 2. Deploy and Initialize Vault
# =============================================================================

# Deploy Vault: helm install → wait for pod → init/unseal → health check.
# Handles three states: fresh install, sealed (stored key available), and
# sealed with lost key (full reset via statefulset delete + re-init).
deploy_vault() {
    # Skip if already healthy
    if svc_healthy vault vault; then
        log_file "INFO" "deploy_vault: already healthy, skipping"
        spinner_stop "skip" "Vault"
        return 0
    fi

    timer_start "Vault"

    # Ensure TLS CA exists for Ingress certificate
    setup_tls_ca

    spinner_start "Vault..."
    log_file "INFO" "Deploying Vault..."

    # Vault serves HTTP internally; TLS termination at Ingress
    if helm upgrade --install vault hashicorp/vault \
        --namespace vault --create-namespace \
        --set 'server.dev.enabled=false' \
        --set 'server.standalone.enabled=true' \
        --set 'server.dataStorage.enabled=false' \
        --set 'server.resources.requests.cpu=50m' \
        --set 'server.resources.requests.memory=64Mi' \
        --set 'ui.enabled=true' \
        --set 'injector.enabled=true' \
        --set 'server.extraEnvironmentVars.VAULT_ADDR=http://127.0.0.1:8200' \
        --set 'server.standalone.config=ui = true
listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_disable = true
}
storage "inmem" {}
disable_mlock = true' \
        --timeout 3m 2>&1 | verbose_or_log; then

        # Clean up stale TLS cert/secret that may have wrong SANs from a
        # previous deploy. cert-manager will recreate from the Ingress annotation.
        kubectl delete certificate vault-tls -n vault &>/dev/null || true
        kubectl delete secret vault-tls -n vault &>/dev/null || true

        # Create Ingress with cert-manager TLS termination
        kubectl apply -f - <<EOF 2>&1 | verbose_or_log
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault
  namespace: vault
  annotations:
    cert-manager.io/cluster-issuer: cde-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - vault.localhost
      secretName: vault-tls
  rules:
    - host: vault.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault
                port:
                  number: 8200
EOF

        # Wait for pod to be running (not ready - needs init/unseal first)
        spinner_update "Vault: waiting for pod..."
        kubectl wait --for=condition=PodScheduled pod/vault-0 -n vault --timeout=60s 2>&1 | verbose_or_log || true

        # Smart wait: poll for Running phase instead of fixed sleep
        wait_for_pod_phase vault "app.kubernetes.io/instance=vault" "Running" 60

        # Initialize Vault if needed
        spinner_update "Vault: checking status..."
        local vault_status
        vault_status=$(vault_status_json)
        log_file "INFO" "Vault status: $vault_status"

        if echo "$vault_status" | grep -q '"initialized":[[:space:]]*false'; then
            spinner_update "Vault: initializing..."
            log_file "INFO" "Initializing Vault..."
            local init_output
            init_output=$(vault_exec 'vault operator init -key-shares=1 -key-threshold=1 -format=json')
            log_file "DEBUG" "vault init output length: ${#init_output}"

            # Store credentials
            VAULT_UNSEAL_KEY=$(echo "$init_output" | tr -d ' \n' | grep -o '"unseal_keys_b64":\["[^"]*"' | cut -d'"' -f4)
            VAULT_ROOT_TOKEN=$(echo "$init_output" | tr -d ' \n' | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)
            log_file "DEBUG" "vault unseal key length: ${#VAULT_UNSEAL_KEY}, token length: ${#VAULT_ROOT_TOKEN}"

            if [[ -z "$VAULT_UNSEAL_KEY" || -z "$VAULT_ROOT_TOKEN" ]]; then
                log_file "ERROR" "Failed to parse vault init output"
            else
                # NOTE: Root token stored in K8s Secret for local development convenience.
                # This enables automatic unseal on cluster restart without user interaction.
                # Do not use this pattern in shared or production environments.
                kubectl apply -f - <<CREDEOF 2>&1 | verbose_or_log
apiVersion: v1
kind: Secret
metadata:
  name: vault-init-creds
  namespace: vault
type: Opaque
stringData:
  root_token: "${VAULT_ROOT_TOKEN}"
  unseal_key: "${VAULT_UNSEAL_KEY}"
CREDEOF

                # Unseal and wait for unsealed state (replaces sleep 3)
                spinner_update "Vault: unsealing..."
                vault_unseal "$VAULT_UNSEAL_KEY" 2>&1 | verbose_or_log
                vault_wait_unsealed 30
                log_file "INFO" "Vault unsealed after init"
            fi

        # Check if sealed and unseal if needed (e.g., pod restarted)
        elif echo "$vault_status" | grep -q '"sealed":[[:space:]]*true'; then
            spinner_update "Vault: unsealing..."
            log_file "INFO" "Vault is sealed, attempting unseal with stored key"
            local stored_key
            stored_key=$(kubectl get secret vault-init-creds -n vault -o jsonpath='{.data.unseal_key}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
            log_file "DEBUG" "stored unseal key length: ${#stored_key}"
            if [[ -n "$stored_key" ]]; then
                vault_unseal "$stored_key" 2>&1 | verbose_or_log
                vault_wait_unsealed 30  # replaces sleep 3
                log_file "INFO" "Vault unsealed with stored key"
            elif echo "$vault_status" | grep -q '"initialized":[[:space:]]*true'; then
                # Vault initialized but unseal key lost - full reset for dev environment
                spinner_update "Vault: resetting..."
                log_file "WARN" "Vault initialized but unseal key lost - full reset"
                [[ "$VERBOSE" == "true" ]] && echo -e "\n  ${DIM}Vault initialized but unseal key lost - resetting...${NC}"

                # Delete statefulset to clear ephemeral inmem storage — helm upgrade
                # alone won't reset vault state because the pod keeps running
                kubectl delete statefulset vault -n vault --cascade=foreground --grace-period=5 2>&1 | verbose_or_log || true
                kubectl delete pvc -n vault -l app.kubernetes.io/instance=vault 2>&1 | verbose_or_log || true

                # Re-deploy via helm to recreate clean statefulset
                spinner_update "Vault: re-deploying..."
                helm upgrade --install vault hashicorp/vault \
                    --namespace vault --create-namespace \
                    --set 'server.dev.enabled=false' \
                    --set 'server.standalone.enabled=true' \
                    --set 'server.dataStorage.enabled=false' \
                    --set 'server.resources.requests.cpu=50m' \
                    --set 'server.resources.requests.memory=64Mi' \
                    --set 'ui.enabled=true' \
                    --set 'injector.enabled=true' \
                    --set 'server.extraEnvironmentVars.VAULT_ADDR=http://127.0.0.1:8200' \
                    --set 'server.standalone.config=ui = true
listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_disable = true
}
storage "inmem" {}
disable_mlock = true' \
                    --timeout 3m 2>&1 | verbose_or_log

                # Wait for fresh pod
                spinner_update "Vault: waiting for pod..."
                wait_for_pod_phase vault "app.kubernetes.io/instance=vault" "Running" 60

                # Re-initialize fresh vault
                spinner_update "Vault: initializing..."
                local init_output
                init_output=$(vault_exec 'vault operator init -key-shares=1 -key-threshold=1 -format=json')
                log_file "DEBUG" "vault re-init output length: ${#init_output}"
                VAULT_UNSEAL_KEY=$(echo "$init_output" | grep -o '"unseal_keys_b64":\["[^"]*"' | cut -d'"' -f4)
                VAULT_ROOT_TOKEN=$(echo "$init_output" | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)

                if [[ -n "$VAULT_UNSEAL_KEY" && -n "$VAULT_ROOT_TOKEN" ]]; then
                    kubectl apply -f - <<CREDEOF 2>&1 | verbose_or_log
apiVersion: v1
kind: Secret
metadata:
  name: vault-init-creds
  namespace: vault
type: Opaque
stringData:
  root_token: "${VAULT_ROOT_TOKEN}"
  unseal_key: "${VAULT_UNSEAL_KEY}"
CREDEOF
                    vault_unseal "$VAULT_UNSEAL_KEY" 2>&1 | verbose_or_log
                    vault_wait_unsealed 30
                    log_file "INFO" "Vault re-initialized and unsealed"
                else
                    log_file "ERROR" "Vault re-initialization failed - could not parse credentials"
                fi
            fi
        fi

        # Final health verification via vault health endpoint
        spinner_update "Vault: verifying health..."
        if vault_wait_ready 30; then
            timer_stop "Vault"
            spinner_stop "success" "Vault" "$(timer_show Vault)"
            log_file "INFO" "Vault healthy"
        elif wait_healthy vault vault 60; then
            timer_stop "Vault"
            spinner_stop "success" "Vault" "$(timer_show Vault)"
            log_file "INFO" "Vault healthy (k8s ready)"
        else
            timer_stop "Vault"
            spinner_stop "warn" "Vault (starting...)" "$(timer_show Vault)"
            log_file "WARN" "Vault deployed but not yet fully ready"
        fi
    else
        timer_stop "Vault"
        spinner_stop "error" "Vault (failed)" "$(timer_show Vault)"
        log_file "ERROR" "Vault helm install failed"
        return 1
    fi
}
