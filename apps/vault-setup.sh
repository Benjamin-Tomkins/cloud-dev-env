#!/usr/bin/env bash
# vault-setup.sh -- Configure Vault with secrets, auth, and policies for app pods
#
# How It Works:
#   1. Wait for Vault to be unsealed
#   2. Enable KV v2 secrets engine at secret/
#   3. Write test secrets (db_host, db_password, redis_host, api_key)
#   4. Enable Kubernetes auth method
#   5. Configure Kubernetes auth with in-cluster API server
#   6. Create read-only policy for secret/data/apps/config
#   7. Bind service account (app-sa in otel-apps) to policy via role
#
# Kubernetes Auth Flow:
#
#   ┌─────────────┐    SA token    ┌──────────────┐   validate   ┌──────────┐
#   │ Pod (app-sa) │──────────────►│ Vault K8s    │─────────────►│ K8s API  │
#   │ in otel-apps │               │ Auth Method  │◄─────────────│ Server   │
#   └─────────────┘               └──────┬───────┘   confirmed  └──────────┘
#                                        │
#                                  maps SA to "app" role
#                                        │
#                                        ▼
#                                 ┌──────────────┐    grants    ┌────────────────────┐
#                                 │ "app-policy"  │────────────►│ read access to     │
#                                 │ (read-only)   │             │ secret/data/apps/* │
#                                 └──────────────┘             └────────────────────┘
#
# Configuration:
#   CDE_APPS_NS  Application namespace  (used indirectly via NAMESPACE)
#
# Security:
#   vault_exec_token() pipes the root token via stdin to avoid exposing it
#   in the host process table. The token is read with `read -r` inside the
#   pod's shell and exported as VAULT_TOKEN within the container only.
set -euo pipefail

VAULT_NS="vault"
APP_NS="otel-apps"

vault_exec() {
    kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "export VAULT_ADDR=http://127.0.0.1:8200 && $1"
}

# Run a vault command with token passed via stdin (avoids exposing token in process table)
vault_exec_token() {
    local token="$1"
    local cmd="$2"
    printf '%s\n' "$token" | kubectl exec -i -n "$VAULT_NS" vault-0 -- \
        sh -c 'export VAULT_ADDR=http://127.0.0.1:8200 && IFS= read -r VAULT_TOKEN && export VAULT_TOKEN && '"$cmd"
}

# Wait for Vault to be ready and unsealed
echo "  Waiting for Vault to be ready..."
attempts=30
while [[ $attempts -gt 0 ]]; do
    if vault_exec 'vault status -format=json' 2>/dev/null | grep -q '"sealed".*false'; then
        break
    fi
    sleep 2
    attempts=$((attempts - 1))
done
if [[ $attempts -eq 0 ]]; then
    echo "ERROR: Vault not ready after 60s"
    exit 1
fi

# Get root token from stored credentials
ROOT_TOKEN=$(kubectl get secret vault-init-creds -n "$VAULT_NS" -o jsonpath='{.data.root_token}' | base64 -d)
if [[ -z "$ROOT_TOKEN" ]]; then
    echo "ERROR: Could not retrieve Vault root token"
    exit 1
fi

echo "Configuring Vault..."

# Enable KV v2 secrets engine (idempotent - ignore if already enabled)
vault_exec_token "$ROOT_TOKEN" "vault secrets enable -path=secret kv-v2" 2>/dev/null || true

# Create test secrets
echo "  Writing test secrets..."
vault_exec_token "$ROOT_TOKEN" "vault kv put secret/apps/config \
    db_host=postgres.database.svc.cluster.local \
    db_password=supersecret123 \
    redis_host=redis.cache.svc.cluster.local \
    api_key=test-api-key-12345"

# Enable Kubernetes auth method (idempotent)
vault_exec_token "$ROOT_TOKEN" "vault auth enable kubernetes" 2>/dev/null || true

# Configure Kubernetes auth with in-cluster API server
echo "  Configuring Kubernetes auth..."
vault_exec_token "$ROOT_TOKEN" "vault write auth/kubernetes/config \
    kubernetes_host=https://kubernetes.default.svc.cluster.local:443"

# Create policy granting read on app secrets
echo "  Creating app policy..."
vault_exec_token "$ROOT_TOKEN" "vault policy write app-policy - <<'POLICY'
path \"secret/data/apps/config\" {
  capabilities = [\"read\"]
}
POLICY"

# Create role binding service account to policy
echo "  Creating app role..."
vault_exec_token "$ROOT_TOKEN" "vault write auth/kubernetes/role/app \
    bound_service_account_names=app-sa \
    bound_service_account_namespaces=$APP_NS \
    policies=app-policy \
    ttl=1h"

echo "Vault setup complete."
