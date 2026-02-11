#!/usr/bin/env bash
# vault.sh -- Vault deploy/init/unseal (full rewrite with smart waits)

# ─────────────────────────────────────────────────────────────────────────────
# Vault helpers
# ─────────────────────────────────────────────────────────────────────────────

# Execute a command inside the vault pod
vault_exec() {
    kubectl exec -n vault vault-0 -- sh -c "export VAULT_ADDR=http://127.0.0.1:8200 && $1" 2>/dev/null
}

# Get vault status as JSON
# Note: vault status returns exit code 2 when sealed, so we can't use || fallback
# directly -- it would append the fallback to the real output
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

# Unseal vault by piping key via stdin (avoids exposing key in host process table)
# Note: vault doesn't support reading unseal keys from stdin directly, so we
# pipe to `read` in the pod's shell, then pass as an argument within the pod.
vault_unseal() {
    local key="$1"
    printf '%s\n' "$key" | kubectl exec -i -n vault vault-0 -- \
        sh -c 'export VAULT_ADDR=http://127.0.0.1:8200 && read KEY && vault operator unseal "$KEY"' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Main deploy function
# ─────────────────────────────────────────────────────────────────────────────

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

        # Clean up any old TLS cert with wrong SANs (from pre-Ingress deploys)
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

                # Delete the statefulset to clear ephemeral data, then let helm recreate
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
