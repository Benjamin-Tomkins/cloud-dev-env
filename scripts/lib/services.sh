#!/usr/bin/env bash
# services.sh -- All deploy_* functions except vault, remove/teardown
#
# How It Works:
#   Each deploy_*() function follows the same pattern:
#   1. Skip if already healthy (svc_healthy check)
#   2. Start timer
#   3. Ensure TLS CA exists (setup_tls_ca)
#   4. helm upgrade --install with inline config
#   5. Create Ingress resource with cert-manager annotation for automatic TLS
#   6. Timer stop, spinner result
#
#   Standard Deploy Pattern:
#
#     svc_healthy? ──YES──► spinner_stop "skip" ──► return
#        │
#        NO
#        ▼
#     timer_start ──► setup_tls_ca ──► helm upgrade --install
#        │                                     │
#        │                              success?──NO──► spinner "error"
#        │                                     │
#        │                                    YES
#        │                                     ▼
#        │                              kubectl apply Ingress
#        │                                     │
#        └──────────────────────────────► timer_stop
#                                              ▼
#                                        spinner "success"
#
# cert-manager Webhook Readiness (Three-Phase):
#   After helm --wait returns, the webhook may still reject requests because
#   TLS cert propagation lags behind pod readiness.
#
#     Phase 1: Pod Ready         ──► k8s reports container running
#     Phase 2: EndpointSlice     ──► k8s networking has propagated addresses
#     Phase 3: Dry-run Issuer    ──► full API server → webhook TLS path works
#
# OTel Instrumentation:
#   The OTel Operator uses Instrumentation CRs (not code changes) to inject
#   auto-instrumentation into pods. The CR specifies which language agent to
#   inject and where to send traces (Jaeger's OTLP endpoint). Logs and metrics
#   exporters are set to "none" — we only collect traces for now.
#
# Dependencies: log.sh, ui.sh, timing.sh, k8s.sh, tls.sh, helm.sh, constants.sh,
#               portforward.sh (stop_port_forwards for teardown)

# =============================================================================
# 1. Deploy Infrastructure Services
# =============================================================================
# NGINX Ingress and cert-manager are required by all other services.
# They must be deployed first and are not optional.

deploy_ingress() {
    if svc_healthy ingress-nginx ingress-nginx; then
        log_file "INFO" "deploy_ingress: already healthy, skipping"
        spinner_stop "skip" "NGINX Ingress"
        return 0
    fi

    timer_start "NGINX Ingress"
    spinner_start "NGINX Ingress..."
    log_file "INFO" "Deploying NGINX Ingress..."

    if helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.watchIngressWithoutClass=true \
        --set controller.publishService.enabled=true \
        --set controller.service.type=NodePort \
        --set controller.hostPort.enabled=true \
        --set controller.resources.requests.cpu=50m \
        --set controller.resources.requests.memory=90Mi \
        --set controller.admissionWebhooks.enabled=false \
        --wait --timeout 3m 2>&1 | verbose_or_log; then
        timer_stop "NGINX Ingress"
        spinner_stop "success" "NGINX Ingress" "$(timer_show 'NGINX Ingress')"
    else
        timer_stop "NGINX Ingress"
        spinner_stop "error" "NGINX Ingress (failed)" "$(timer_show 'NGINX Ingress')"
        log_file "ERROR" "NGINX Ingress deployment failed"
        return 1
    fi
}

deploy_cert_manager() {
    if svc_healthy cert-manager cert-manager; then
        log_file "INFO" "deploy_cert_manager: already healthy, skipping"
        spinner_stop "skip" "cert-manager"
        return 0
    fi

    timer_start "cert-manager"
    spinner_start "cert-manager..."
    log_file "INFO" "Deploying cert-manager..."

    if helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true \
        --set resources.requests.cpu=10m \
        --set resources.requests.memory=32Mi \
        --set startupapicheck.enabled=false \
        --set webhook.resources.requests.cpu=10m \
        --set webhook.resources.requests.memory=32Mi \
        --set cainjector.resources.requests.cpu=10m \
        --set cainjector.resources.requests.memory=32Mi \
        --wait --timeout 3m 2>&1 | verbose_or_log; then

        # Three-phase cert-manager webhook readiness strategy.
        # The webhook must be fully operational before any Certificate/Issuer
        # resources can be created, but "pod Ready" alone isn't sufficient —
        # the API server → webhook TLS handshake can still fail.
        spinner_update "cert-manager: webhook readiness..."

        # Phase 1: Pod Ready (should be instant after --wait)
        wait_healthy cert-manager cert-manager 30

        # Phase 2: EndpointSlice has addresses (k8s networking is propagated)
        wait_for_endpoint_slice cert-manager cert-manager-webhook 15

        # Phase 3: Dry-run an Issuer apply to exercise the full API server →
        # webhook TLS path. Uses a self-signed Issuer (not Certificate) since
        # it doesn't reference other resources, so the webhook accepts it.
        local retries=60
        while [[ $retries -gt 0 ]]; do
            if kubectl apply --dry-run=server -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: webhook-readiness-test
  namespace: cert-manager
spec:
  selfSigned: {}
EOF
            then
                log_file "DEBUG" "cert-manager webhook dry-run succeeded"
                break
            fi
            sleep 1
            retries=$((retries - 1))
        done

        if [[ $retries -eq 0 ]]; then
            log_file "WARN" "cert-manager webhook dry-run never succeeded (proceeding anyway)"
        fi

        timer_stop "cert-manager"
        spinner_stop "success" "cert-manager" "$(timer_show cert-manager)"
        log_file "INFO" "cert-manager deployed and webhook ready"
    else
        timer_stop "cert-manager"
        spinner_stop "error" "cert-manager (failed)" "$(timer_show cert-manager)"
        log_file "ERROR" "cert-manager deployment failed"
        return 1
    fi
}

# =============================================================================
# 2. Deploy Observability Stack
# =============================================================================
# OTel operator, instrumentation CRs, Jaeger, and Grafana.

deploy_otel() {
    local target_ns="opentelemetry-operator-system"

    if svc_healthy opentelemetry-operator "$target_ns"; then
        log_file "INFO" "deploy_otel: already healthy, skipping"
        spinner_stop "skip" "OpenTelemetry Operator"
        return 0
    fi

    if ! kubectl get namespace cert-manager &>/dev/null; then
        deploy_cert_manager
    fi

    timer_start "OpenTelemetry"
    spinner_start "OpenTelemetry Operator..."
    log_file "INFO" "Deploying OpenTelemetry Operator..."

    # Auto-detect and clean up orphaned OTel resources if a previous install
    # landed in a different namespace (e.g., manual install vs chart default)
    local crd_ns
    crd_ns=$(kubectl get crd opampbridges.opentelemetry.io -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || echo "")

    if [[ -n "$crd_ns" && "$crd_ns" != "$target_ns" ]]; then
        log_file "INFO" "Cleaning up orphaned OTel resources from namespace: $crd_ns"
        [[ "$VERBOSE" == "true" ]] && echo -e "\n  ${DIM}Cleaning up orphaned OTel resources from namespace: $crd_ns${NC}"

        helm uninstall opentelemetry-operator -n "$crd_ns" 2>&1 | verbose_or_log || true
        kubectl delete deployment,service,serviceaccount,role,rolebinding,clusterrole,clusterrolebinding \
            -n "$crd_ns" -l app.kubernetes.io/name=opentelemetry-operator 2>&1 | verbose_or_log || true
        kubectl delete crd instrumentations.opentelemetry.io opampbridges.opentelemetry.io \
            opentelemetrycollectors.opentelemetry.io targetallocators.opentelemetry.io 2>&1 | verbose_or_log || true
        kubectl delete ns "$crd_ns" --ignore-not-found 2>&1 | verbose_or_log || true
    fi

    # Retry helm install — cert-manager webhook may still reject CRDs with x509
    # errors if its TLS cert hasn't fully propagated. Three attempts with 5s delay.
    local otel_ok=false
    local otel_attempts=3
    while [[ $otel_attempts -gt 0 ]]; do
        if helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
            --namespace "$target_ns" --create-namespace \
            --set admissionWebhooks.certManager.enabled=true \
            --set manager.resources.requests.cpu=10m \
            --set manager.resources.requests.memory=64Mi \
            --wait --timeout 3m 2>&1 | verbose_or_log; then
            otel_ok=true
            break
        fi
        otel_attempts=$((otel_attempts - 1))
        if [[ $otel_attempts -gt 0 ]]; then
            log_file "WARN" "OTel install failed (cert-manager webhook race?), retrying in 5s ($otel_attempts left)"
            sleep 5
        fi
    done

    if $otel_ok; then
        timer_stop "OpenTelemetry"
        spinner_stop "success" "OpenTelemetry Operator" "$(timer_show OpenTelemetry)"

        # Deploy Instrumentation CRs as a separate timed stage
        deploy_otel_instrumentation
    else
        timer_stop "OpenTelemetry"
        spinner_stop "error" "OpenTelemetry (failed)" "$(timer_show OpenTelemetry)"
        log_file "ERROR" "OpenTelemetry Operator deployment failed"
        return 1
    fi
}

# Deploy Instrumentation CRs that tell the OTel Operator which language agents
# to inject and where to send traces. Pods in the otel-apps namespace that have
# the annotation `instrumentation.opentelemetry.io/inject-java: "true"` (or
# python) will automatically get an init container with the agent.
deploy_otel_instrumentation() {
    # Skip if already exists
    if kubectl get instrumentation java-instrumentation -n otel-apps &>/dev/null && \
       kubectl get instrumentation python-instrumentation -n otel-apps &>/dev/null; then
        log_file "INFO" "deploy_otel_instrumentation: already exists, skipping"
        spinner_stop "skip" "OpenTelemetry Instrumentation"
        return 0
    fi

    timer_start "OTel Instrumentation"
    spinner_start "OpenTelemetry Instrumentation..."
    log_file "INFO" "Creating OTel Instrumentation CRs in otel-apps namespace"

    # Wait for operator webhook to be ready before applying CRs
    kubectl rollout status deployment/opentelemetry-operator -n opentelemetry-operator-system --timeout=60s 2>&1 | verbose_or_log || true

    kubectl create namespace otel-apps 2>/dev/null || true

    if kubectl apply -f - <<'INSTR_EOF' 2>&1 | verbose_or_log
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: java-instrumentation
  namespace: otel-apps
spec:
  exporter:
    endpoint: http://jaeger.observability.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
    - b3
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.24.0
    env:
      - name: OTEL_JAVAAGENT_DEBUG
        value: "false"
      - name: OTEL_INSTRUMENTATION_MICROMETER_ENABLED
        value: "true"
      - name: OTEL_LOGS_EXPORTER
        value: "none"
      - name: OTEL_METRICS_EXPORTER
        value: "none"
---
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: python-instrumentation
  namespace: otel-apps
spec:
  exporter:
    endpoint: http://jaeger.observability.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
    - b3
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  python:
    env:
      - name: OTEL_PYTHON_LOG_CORRELATION
        value: "true"
      - name: OTEL_LOGS_EXPORTER
        value: "none"
      - name: OTEL_METRICS_EXPORTER
        value: "none"
INSTR_EOF
    then
        log_file "INFO" "OTel Instrumentation CRs created (java, python)"
        timer_stop "OTel Instrumentation"
        spinner_stop "success" "OpenTelemetry Instrumentation" "$(timer_show 'OTel Instrumentation')"
    else
        log_file "ERROR" "OTel Instrumentation CR creation failed"
        timer_stop "OTel Instrumentation"
        spinner_stop "error" "OpenTelemetry Instrumentation" "$(timer_show 'OTel Instrumentation')"
    fi
}

deploy_jaeger() {
    if svc_healthy jaeger observability; then
        log_file "INFO" "deploy_jaeger: already healthy, skipping"
        spinner_stop "skip" "Jaeger"
        return 0
    fi

    timer_start "Jaeger"
    spinner_start "Jaeger..."
    log_file "INFO" "Deploying Jaeger..."

    # Ensure TLS CA exists for Ingress certificate
    setup_tls_ca

    if helm upgrade --install jaeger jaegertracing/jaeger \
        --namespace observability --create-namespace \
        --set provisionDataStore.cassandra=false \
        --set allInOne.enabled=true \
        --set allInOne.resources.requests.cpu=50m \
        --set allInOne.resources.requests.memory=64Mi \
        --set storage.type=memory \
        --set agent.enabled=false \
        --set collector.enabled=false \
        --set query.enabled=false \
        --wait --timeout 3m 2>&1 | verbose_or_log; then

        # Create Ingress with cert-manager TLS termination
        kubectl apply -f - <<EOF 2>&1 | verbose_or_log
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jaeger
  namespace: observability
  annotations:
    cert-manager.io/cluster-issuer: cde-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - jaeger.localhost
      secretName: jaeger-tls
  rules:
    - host: jaeger.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jaeger
                port:
                  number: 16686
EOF

        timer_stop "Jaeger"
        spinner_stop "success" "Jaeger" "$(timer_show Jaeger)"
    else
        timer_stop "Jaeger"
        spinner_stop "error" "Jaeger (failed)" "$(timer_show Jaeger)"
        log_file "ERROR" "Jaeger deployment failed"
        return 1
    fi
}

deploy_grafana() {
    if svc_healthy grafana observability; then
        log_file "INFO" "deploy_grafana: already healthy, skipping"
        spinner_stop "skip" "Grafana"
        return 0
    fi

    timer_start "Grafana"

    # Generate unique admin password
    local grafana_pw
    grafana_pw=$(openssl rand -base64 12)

    # Ensure TLS CA exists for Ingress certificate
    setup_tls_ca

    spinner_start "Grafana..."
    log_file "INFO" "Deploying Grafana..."

    # Grafana serves HTTP internally; TLS termination at Ingress
    if helm upgrade --install grafana grafana/grafana \
        --namespace observability --create-namespace \
        --set adminPassword="$grafana_pw" \
        --set persistence.enabled=false \
        --set resources.requests.cpu=50m \
        --set resources.requests.memory=64Mi \
        --wait --timeout 3m 2>&1 | verbose_or_log; then

        # Clean up any old TLS cert with wrong SANs (from pre-Ingress deploys)
        kubectl delete certificate grafana-tls -n observability &>/dev/null || true
        kubectl delete secret grafana-tls -n observability &>/dev/null || true

        # Create Ingress with cert-manager TLS termination
        kubectl apply -f - <<EOF 2>&1 | verbose_or_log
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: observability
  annotations:
    cert-manager.io/cluster-issuer: cde-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - grafana.localhost
      secretName: grafana-tls
  rules:
    - host: grafana.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 80
EOF

        timer_stop "Grafana"
        spinner_stop "success" "Grafana" "$(timer_show Grafana)"
    else
        timer_stop "Grafana"
        spinner_stop "error" "Grafana (failed)" "$(timer_show Grafana)"
        log_file "ERROR" "Grafana deployment failed"
        return 1
    fi
}

# =============================================================================
# 3. Deploy Data Services
# =============================================================================
# Redis and PostgreSQL with TLS certificates.

deploy_redis() {
    if svc_healthy redis data; then
        log_file "INFO" "deploy_redis: already healthy, skipping"
        spinner_stop "skip" "Redis"
        return 0
    fi

    timer_start "Redis"
    spinner_start "Redis..."
    log_file "INFO" "Deploying Redis..."

    # Ensure TLS certificate exists
    setup_tls_ca
    if ! kubectl get secret redis-tls -n data &>/dev/null; then
        kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f - 2>&1 | verbose_or_log
        apply_certificate <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: redis-tls
  namespace: data
spec:
  secretName: redis-tls
  duration: 8760h
  renewBefore: 720h
  commonName: redis
  dnsNames:
    - localhost
    - redis-master
    - redis-master.data.svc
  ipAddresses:
    - 127.0.0.1
  issuerRef:
    name: cde-ca-issuer
    kind: ClusterIssuer
EOF
        kubectl wait --for=condition=Ready certificate/redis-tls -n data --timeout=60s 2>&1 | verbose_or_log || true
    fi

    if helm upgrade --install redis bitnami/redis \
        --namespace data --create-namespace \
        --set architecture=standalone \
        --set auth.enabled=false \
        --set master.persistence.enabled=false \
        --set master.resources.requests.cpu=50m \
        --set master.resources.requests.memory=64Mi \
        --set replica.persistence.enabled=false \
        --set pdb.create=false \
        --set tls.enabled=true \
        --set tls.certificatesSecret=redis-tls \
        --set tls.certFilename=tls.crt \
        --set tls.certKeyFilename=tls.key \
        --set tls.certCAFilename=ca.crt \
        --wait --timeout 5m 2>&1 | verbose_or_log; then
        timer_stop "Redis"
        spinner_stop "success" "Redis" "$(timer_show Redis)"
    else
        timer_stop "Redis"
        spinner_stop "error" "Redis (failed)" "$(timer_show Redis)"
        log_file "ERROR" "Redis deployment failed"
        return 1
    fi
}

deploy_postgres() {
    if svc_healthy postgresql data; then
        log_file "INFO" "deploy_postgres: already healthy, skipping"
        spinner_stop "skip" "PostgreSQL"
        return 0
    fi

    timer_start "PostgreSQL"
    spinner_start "PostgreSQL..."
    log_file "INFO" "Deploying PostgreSQL..."

    # Ensure TLS certificate exists
    setup_tls_ca
    if ! kubectl get secret postgresql-tls -n data &>/dev/null; then
        kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f - 2>&1 | verbose_or_log
        apply_certificate <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: postgresql-tls
  namespace: data
spec:
  secretName: postgresql-tls
  duration: 8760h
  renewBefore: 720h
  commonName: postgresql
  dnsNames:
    - localhost
    - postgresql
    - postgresql.data.svc
  ipAddresses:
    - 127.0.0.1
  issuerRef:
    name: cde-ca-issuer
    kind: ClusterIssuer
EOF
        kubectl wait --for=condition=Ready certificate/postgresql-tls -n data --timeout=60s 2>&1 | verbose_or_log || true
    fi

    if helm upgrade --install postgresql bitnami/postgresql \
        --namespace data --create-namespace \
        --set auth.postgresPassword=postgres \
        --set auth.database=app \
        --set primary.persistence.enabled=false \
        --set primary.resources.requests.cpu=50m \
        --set primary.resources.requests.memory=64Mi \
        --set readReplicas.persistence.enabled=false \
        --set volumePermissions.enabled=true \
        --set primary.pdb.create=false \
        --set readReplicas.pdb.create=false \
        --set tls.enabled=true \
        --set tls.certificatesSecret=postgresql-tls \
        --set tls.certFilename=tls.crt \
        --set tls.certKeyFilename=tls.key \
        --set tls.certCAFilename=ca.crt \
        --wait --timeout 5m 2>&1 | verbose_or_log; then
        timer_stop "PostgreSQL"
        spinner_stop "success" "PostgreSQL" "$(timer_show PostgreSQL)"
    else
        timer_stop "PostgreSQL"
        spinner_stop "error" "PostgreSQL (failed)" "$(timer_show PostgreSQL)"
        log_file "ERROR" "PostgreSQL deployment failed"
        return 1
    fi
}

# =============================================================================
# 4. Deploy Dashboard UI
# =============================================================================

deploy_dashboard() {
    if svc_healthy headlamp headlamp; then
        log_file "INFO" "deploy_dashboard: already healthy, skipping"
        spinner_stop "skip" "Dashboard (Headlamp)"
        return 0
    fi

    timer_start "Dashboard"
    spinner_start "Dashboard (Headlamp)..."
    log_file "INFO" "Deploying Dashboard (Headlamp)..."

    # Ensure TLS CA exists for Ingress certificate
    setup_tls_ca

    if helm upgrade --install headlamp headlamp/headlamp \
        --namespace headlamp --create-namespace \
        --set resources.requests.cpu=50m \
        --set resources.requests.memory=64Mi \
        --wait --timeout 3m 2>&1 | verbose_or_log; then

        # Create Ingress with cert-manager TLS termination
        kubectl apply -f - <<EOF 2>&1 | verbose_or_log
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp
  namespace: headlamp
  annotations:
    cert-manager.io/cluster-issuer: cde-ca-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - dashboard.localhost
      secretName: headlamp-tls
  rules:
    - host: dashboard.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: headlamp
                port:
                  number: 80
EOF

        # Create admin service account for easy access
        kubectl apply -f - <<EOF 2>&1 | verbose_or_log
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: headlamp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: headlamp
EOF

        timer_stop "Dashboard"
        spinner_stop "success" "Dashboard (Headlamp)" "$(timer_show Dashboard)"
    else
        timer_stop "Dashboard"
        spinner_stop "error" "Dashboard (Headlamp) (failed)" "$(timer_show Dashboard)"
        log_file "ERROR" "Dashboard (Headlamp) deployment failed"
        return 1
    fi
}

# =============================================================================
# 5. Remove Deployed Services
# =============================================================================

# Remove a single helm release by name and namespace.
# No-op if the release isn't installed.
remove_service() {
    local name=$1
    local ns=$2
    if helm status "$name" -n "$ns" &>/dev/null; then
        log_file "INFO" "remove_service: removing $name from $ns"
        spinner_start "Removing $name..."
        if helm uninstall "$name" -n "$ns" 2>&1 | verbose_or_log; then
            log_file "INFO" "remove_service: $name removed successfully"
            spinner_stop "success" "$name removed"
        else
            log_file "ERROR" "remove_service: $name removal failed"
            spinner_stop "error" "$name (failed)"
        fi
    else
        log_file "DEBUG" "remove_service: $name not installed in $ns, skipping"
    fi
}

# Remove all services in reverse dependency order.
# Services are removed in reverse install order so dependents go first.
teardown_services() {
    log_file "INFO" "teardown_services: starting"
    echo -e "\n${PURPLE}◆ CDE${NC} Teardown\n"
    show_context
    stop_port_forwards
    remove_service headlamp headlamp
    remove_service postgresql data
    remove_service redis data
    remove_service grafana observability
    remove_service jaeger observability
    if kubectl get instrumentation -n otel-apps &>/dev/null 2>&1 && \
       kubectl get instrumentation -n otel-apps -o name 2>/dev/null | grep -q .; then
        if kubectl delete instrumentation --all -n otel-apps 2>&1 | verbose_or_log; then
            ok "otel instrumentation removed"
        else
            err "otel instrumentation removal failed"
        fi
    fi
    remove_service opentelemetry-operator opentelemetry-operator-system
    remove_service vault vault
    remove_service cert-manager cert-manager
    remove_service ingress-nginx ingress-nginx
    remove_trusted_ca
    log_file "INFO" "teardown_services: completed"
    echo -e "\n${GREEN}Done!${NC}\n"
}
