#!/usr/bin/env bash
# constants.sh -- Colors, icons, config vars, service lookups
#
# How It Works:
#   1. Define user-overridable config vars (cluster name, namespace, ports, flags)
#   2. Define ANSI color/icon constants used by all console output
#   3. Provide service lookup functions for port and namespace resolution
#
# Configuration:
#   CDE_CLUSTER        Cluster name                 (default: otel-dev)
#   CDE_APPS_NS        Application namespace        (default: otel-apps)
#   CDE_REGISTRY_PORT  Local registry port           (default: 5111)
#   CDE_VERBOSE        Show detailed output          (default: false)
#   CDE_NONINTERACTIVE Skip interactive prompts      (default: false)
#
# Dependencies: None (loaded first by all scripts)

# Configuration
CLUSTER_NAME="${CDE_CLUSTER:-otel-dev}"
APPS_NS="${CDE_APPS_NS:-otel-apps}"
REGISTRY_PORT="${CDE_REGISTRY_PORT:-5111}"
VERBOSE="${CDE_VERBOSE:-false}"
NONINTERACTIVE="${CDE_NONINTERACTIVE:-false}"
CDE_ACTIVE_FILE="/tmp/cde-${CLUSTER_NAME}.active"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Icons
CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
ARROW="${PURPLE}▸${NC}"
DOT="${YELLOW}○${NC}"

# Service configuration (bash 3.x compatible — case statements replace associative arrays)

# Map service name to its access port (Ingress HTTPS or cluster-internal)
get_svc_port() {
    case "$1" in
        vault) echo "8443" ;;
        grafana) echo "8443" ;;
        jaeger) echo "8443" ;;
        postgres|postgresql) echo "5432" ;;
        redis) echo "6379" ;;
        headlamp|dashboard) echo "8443" ;;
        *) echo "" ;;
    esac
}

# Map service name to its Kubernetes namespace
get_svc_ns() {
    case "$1" in
        ingress-nginx) echo "ingress-nginx" ;;
        cert-manager) echo "cert-manager" ;;
        vault) echo "vault" ;;
        opentelemetry-operator) echo "opentelemetry-operator-system" ;;
        jaeger|grafana) echo "observability" ;;
        redis|postgresql) echo "data" ;;
        headlamp) echo "headlamp" ;;
        *) echo "" ;;
    esac
}
