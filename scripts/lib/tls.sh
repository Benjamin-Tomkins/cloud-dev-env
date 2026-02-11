#!/usr/bin/env bash
# tls.sh -- TLS CA setup + trust

setup_tls_ca() {
    # Create CDE CA infrastructure for local TLS if not exists
    if kubectl get clusterissuer cde-ca-issuer &>/dev/null; then
        log_file "DEBUG" "setup_tls_ca: cde-ca-issuer already exists, skipping"
        return 0
    fi

    log_file "INFO" "Setting up TLS CA..."
    [[ "$VERBOSE" == "true" ]] && echo -e "\n  ${DIM}Setting up TLS CA...${NC}"

    # Use mkcert CA if available (trusted by browsers automatically)
    if command -v mkcert &>/dev/null && [[ -f "$(mkcert -CAROOT)/rootCA.pem" ]]; then
        log_file "INFO" "Using mkcert CA (browser-trusted)"
        [[ "$VERBOSE" == "true" ]] && echo -e "  ${DIM}Using mkcert CA (browser-trusted)${NC}"

        # WARNING: mkcert root CA private key is loaded into the cluster so cert-manager
        # can sign browser-trusted certificates. This means anyone with access to the
        # cluster can mint certificates your browser will trust for ANY domain.
        # This is acceptable for local development only. Never use this pattern in
        # shared or production environments.
        kubectl create secret tls mkcert-ca \
            --cert="$(mkcert -CAROOT)/rootCA.pem" \
            --key="$(mkcert -CAROOT)/rootCA-key.pem" \
            -n cert-manager --dry-run=client -o yaml | kubectl apply -f - 2>&1 | verbose_or_log

        kubectl apply -f - <<EOF 2>&1 | verbose_or_log
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cde-ca-issuer
spec:
  ca:
    secretName: mkcert-ca
EOF
    else
        # Fall back to self-signed CA
        [[ "$VERBOSE" != "true" ]] && echo -e "\n  ${YELLOW}!${NC} ${DIM}mkcert not found - using self-signed CA (browsers will show warnings)${NC}"
        [[ "$VERBOSE" != "true" ]] && echo -e "  ${DIM}Install mkcert for trusted certs: brew install mkcert && mkcert -install${NC}\n"

        kubectl apply -f - <<EOF 2>&1 | verbose_or_log
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cde-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: CDE Local CA
  secretName: cde-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cde-ca-issuer
spec:
  ca:
    secretName: cde-ca-secret
EOF

        kubectl wait --for=condition=Ready certificate/cde-ca -n cert-manager --timeout=60s 2>&1 | verbose_or_log || true
        log_file "INFO" "setup_tls_ca: self-signed CA created"
    fi
}

# Apply a cert-manager Certificate with retries (handles webhook race)
# Usage: apply_certificate <<EOF ... EOF
apply_certificate() {
    local yaml
    yaml=$(cat)
    local retries=10
    while [[ $retries -gt 0 ]]; do
        local output
        if output=$(echo "$yaml" | kubectl apply -f - 2>&1); then
            echo "$output" | verbose_or_log
            return 0
        fi
        log_file "DEBUG" "apply_certificate: webhook not ready, retrying ($retries left)"
        [[ "$VERBOSE" == "true" ]] && echo "$output" | verbose_or_log
        sleep 2
        retries=$((retries - 1))
    done
    log_file "ERROR" "apply_certificate: failed after retries"
    return 1
}

remove_trusted_ca() {
    local script_dir ca_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ca_file="${script_dir}/../../cde-ca.crt"

    local need_keychain=false
    if [[ "$(uname)" == "Darwin" ]] && security find-certificate -c "CDE Local CA" /Library/Keychains/System.keychain &>/dev/null; then
        need_keychain=true
    fi

    # Nothing to do
    if [[ "$need_keychain" != "true" ]] && [[ ! -f "$ca_file" ]]; then
        return 0
    fi

    # Remove from macOS keychain
    if [[ "$need_keychain" == "true" ]]; then
        echo -e "\n  ${DIM}sudo required to remove CDE CA certificate from the system keychain${NC}"
        if sudo security delete-certificate -c "CDE Local CA" /Library/Keychains/System.keychain 2>/dev/null; then
            ok "CA removed from keychain"
        else
            warn "CA removal from keychain failed"
        fi
    fi

    # Remove cert file
    if [[ -f "$ca_file" ]]; then
        rm -f "$ca_file"
        log_file "INFO" "remove_trusted_ca: removed $ca_file"
    fi
}

auto_trust_ca() {
    # Only run on macOS
    [[ "$(uname)" != "Darwin" ]] && return 0

    # Check if CA secret exists
    if ! kubectl get secret cde-ca-secret -n cert-manager &>/dev/null; then
        log_file "DEBUG" "auto_trust_ca: no CA secret found, skipping"
        return 0
    fi

    local script_dir ca_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ca_file="${script_dir}/../../cde-ca.crt"

    # Export the CA certificate
    kubectl get secret cde-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca_file" 2>/dev/null

    # Check if already trusted
    if security find-certificate -c "CDE Local CA" /Library/Keychains/System.keychain &>/dev/null; then
        return 0
    fi

    echo ""
    echo -e "  ${DIM}sudo required to trust CDE CA certificate in the system keychain${NC}"
    if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca_file" 2>/dev/null; then
        ok "CA trusted - restart browser to apply"
    else
        echo -e "  ${DIM}Run './cde.sh trust-ca' manually if needed${NC}"
    fi
}
