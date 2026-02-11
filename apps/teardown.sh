#!/usr/bin/env bash
#
# teardown.sh -- Remove all app resources for a clean redeploy
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source shared CDE libraries (colors, icons)
source "$SCRIPT_DIR/../scripts/lib/constants.sh"

NAMESPACE="${CDE_APPS_NS:-otel-apps}"

echo -e "\n${PURPLE}${BOLD}◆ Apps${NC} Teardown\n"

# Delete app deployments and services
for app in java-api python-api; do
    if kubectl get deployment "$app" -n "$NAMESPACE" &>/dev/null; then
        kubectl delete -f "${app}/" -n "$NAMESPACE" --ignore-not-found 2>&1
        echo -e "  ${CHECK} ${app} removed"
    fi
done

# Delete ingress
if kubectl get ingress apps-ingress -n "$NAMESPACE" &>/dev/null; then
    kubectl delete -f ingress.yaml --ignore-not-found 2>&1
    echo -e "  ${CHECK} Ingress removed"
fi

# Delete service account
kubectl delete -f service-account.yaml --ignore-not-found 2>&1
echo -e "  ${CHECK} Service account removed"

# Clean up vault app config (policy, role, secrets) — ignore errors if vault is gone
VAULT_NS="vault"
if kubectl get pod vault-0 -n "$VAULT_NS" &>/dev/null; then
    echo -e "\n  ${DIM}Cleaning vault app config...${NC}"
    kubectl exec -n "$VAULT_NS" vault-0 -- sh -c \
        'export VAULT_ADDR=http://127.0.0.1:8200 && \
         vault delete auth/kubernetes/role/app 2>/dev/null; \
         vault policy delete app-policy 2>/dev/null; \
         vault kv metadata delete secret/apps/config 2>/dev/null; \
         true' 2>/dev/null || true
    echo -e "  ${CHECK} Vault app config cleaned"
fi

echo -e "\n${GREEN}Done!${NC} Namespace ${DIM}${NAMESPACE}${NC} kept (run ${CYAN}kubectl delete ns ${NAMESPACE}${NC} to remove entirely)\n"
