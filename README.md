# CDE - Cloud Developer Environment

Local Kubernetes environment for experimenting with OpenTelemetry auto-instrumentation, HashiCorp Vault secrets management, and cloud-native observability patterns (on MacOS).

**Goal:** Fast local iteration on K8s configurations with zero observability code in applications.

<img width="546" height="542" alt="image" src="https://github.com/user-attachments/assets/25f3e463-315d-4aa2-b555-ea235f00cc24" />

## Quick Start

```bash
# Full setup in one command (creates cluster + deploys everything)
./cde deploy all

# Check what's running
./cde status

# Open a dashboard in your browser
./cde open vault
./cde open grafana
```

## Prerequisites

- Docker Desktop (running)
- kubectl
- Helm 3.x
- k3d

Install on macOS:
```bash
brew install kubectl helm k3d
```

Optional (recommended):
```bash
brew install mkcert && mkcert -install   # Browser-trusted TLS certificates
```

## Services

All dashboards are served over HTTPS via NGINX Ingress at `*.localhost:8443`.

| Service | URL | Namespace |
|---------|-----|-----------|
| Dashboard (Headlamp) | https://dashboard.localhost:8443 | headlamp |
| Vault | https://vault.localhost:8443 | vault |
| Grafana | https://grafana.localhost:8443 | observability |
| Jaeger | https://jaeger.localhost:8443 | observability |
| OTel Operator | (cluster-internal) | opentelemetry-operator-system |
| PostgreSQL | cluster:5432 (TLS) | data |
| Redis | cluster:6379 (TLS) | data |

Infrastructure services (deployed automatically):

| Service | Purpose | Namespace |
|---------|---------|-----------|
| NGINX Ingress | TLS termination + routing | ingress-nginx |
| cert-manager | Automatic TLS certificates | cert-manager |

## Commands

```
Usage: cde.sh [options] <command> [args]

Options:
  -v, --verbose     Show detailed output
  -h, --help        Show this help

Cluster:
  up                Create/start cluster with core services
  down              Stop cluster (preserves data)
  destroy           Delete cluster entirely
  status            Show cluster and services status

Services:
  deploy <svc>      Deploy: dashboard, vault, otel, jaeger, grafana, redis, postgres
  deploy all        Deploy everything (creates cluster if needed)
  remove <svc>      Remove a service
  teardown          Remove all services

Access:
  open <svc>        Open in browser: dashboard, vault, grafana, jaeger
  forward <svc>     Show service access info
  serve             Show all service URLs

Other:
  prereqs           Check prerequisites
  token             Generate and copy dashboard token to clipboard
  trust-ca          Export and trust the CDE CA certificate (macOS)
```

### Examples

```bash
./cde deploy all             # Full setup in one command
./cde status                 # See what's running
./cde open vault             # Open Vault in browser
./cde -v deploy postgres     # Deploy with verbose output
./cde teardown               # Remove all services
./cde destroy                # Delete the cluster entirely
```

## Project Structure

```
otel-experiments/
├── cde                       # Entry point (runs scripts/cde.sh)
├── scripts/
│   ├── cde.sh                # Main CLI orchestrator
│   ├── test-cde.sh           # Test suite (14 tests)
│   └── lib/                  # Library modules
│       ├── constants.sh      # Colors, icons, service config
│       ├── log.sh            # Debug logging
│       ├── timing.sh         # Deploy timer system
│       ├── ui.sh             # Spinner, output helpers
│       ├── k8s.sh            # Health checks, smart waits
│       ├── helm.sh           # Helm repo management
│       ├── cluster.sh        # k3d cluster lifecycle
│       ├── tls.sh            # TLS CA setup, cert helpers
│       ├── vault.sh          # Vault deploy/init/unseal
│       ├── services.sh       # All other deploy functions
│       └── portforward.sh    # Service access, endpoint verification
├── infra/
│   └── k3d-config.yaml       # k3d cluster configuration
├── apps/                     # Application layer
│   ├── deploy.sh             # Build, deploy, and test apps
│   ├── teardown.sh           # Remove all app resources
│   ├── vault-setup.sh        # Configure Vault secrets & auth for apps
│   ├── namespace.yaml        # App namespace definition
│   ├── service-account.yaml  # App service account
│   ├── ingress.yaml          # App ingress routes
│   ├── java-api/             # Spring Boot API (Java 25, OTel auto-instrumented)
│   └── python-api/           # FastAPI (Python, OTel auto-instrumented)
├── log/                      # Debug logs (gitignored)
└── README.md
```

## Apps

The `apps/` directory contains sample workloads that demonstrate OTel auto-instrumentation and Vault secret injection with zero application code changes.

```bash
# Deploy apps (build, push to k3d, configure vault, deploy, test)
cd apps && ./deploy.sh

# Clean up apps for a fresh redeploy
cd apps && ./teardown.sh

# Full cycle
cd apps && ./teardown.sh && ./deploy.sh
```

Each app pod gets automatic sidecar injection:
- **OTel auto-instrumentation**: Traces exported to Jaeger (via OTLP/HTTP on port 4318)
- **Vault agent**: Secrets injected to `/vault/secrets/config` via Kubernetes auth

App endpoints (via Ingress):
- Java API: `https://api.localhost:8443/java/`
- Python API: `https://api.localhost:8443/python/`

## Architecture

### TLS Everywhere

All services use HTTPS via cert-manager with automatic certificate management:

- **Dashboards** (Headlamp, Vault, Grafana, Jaeger): TLS terminated at NGINX Ingress, served at `*.localhost:8443`
- **Data stores** (PostgreSQL, Redis): Native TLS with cert-manager certificates, cluster-internal only
- **CA**: Uses mkcert CA if available (browser-trusted), falls back to self-signed CA

### How It Works

```
Browser ──HTTPS──▶ NGINX Ingress ──HTTP──▶ Service Pod
                   (TLS termination)       (internal)
                   *.localhost:8443
```

The k3d cluster maps port 443 on the node to 8443 on localhost. NGINX Ingress handles TLS termination using certificates issued by cert-manager. Services run plain HTTP internally.

### Auto-Instrumentation

The OTel Operator watches for annotated pods and injects init containers that attach the instrumentation agent at startup. No code changes required in the applications.

```
Pod Creation ──▶ OTel Operator webhook ──▶ Inject init container + env vars
                 Vault Injector webhook ──▶ Inject vault-agent sidecar
```

Traces flow from the app pods to Jaeger via OTLP/HTTP. Logs and metrics export are disabled (no backend configured for them yet).

### Design Principles

- Single CLI (`./cde`) manages the entire lifecycle
- All services accessible over HTTPS with valid certificates
- Smart waits replace fixed sleeps (polls pod/endpoint state)
- Unique credentials generated per deployment (Grafana, Vault)
- Bash 3.x compatible (runs on stock macOS)

## TLS in Browsers

If you have `mkcert` installed and ran `mkcert -install`, all certificates are automatically trusted by your browser.

Without mkcert, the CDE uses a self-signed CA. To trust it:

```bash
./cde trust-ca       # Adds the CA to macOS system keychain (requires sudo)
```

## Troubleshooting

### Cluster won't start
```bash
docker info                    # Verify Docker is running
k3d cluster list               # Check existing clusters
./cde destroy                  # Clean up
./cde deploy all               # Retry
```

### Service shows as failed
```bash
./cde.sh -v deploy <service>   # Redeploy with verbose output
```

### Check debug logs
```bash
ls log/                        # List log files
cat log/cde-*.log | tail -50   # Recent log entries
```

### Reset everything
```bash
./cde teardown                 # Remove all services
./cde deploy all               # Fresh deploy
```
