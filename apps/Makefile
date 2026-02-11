# otel-experiments Applications Makefile
# Manages application builds and deployments in the otel-apps namespace

NAMESPACE := otel-apps
CLUSTER := $(or $(CDE_CLUSTER),otel-dev)

.PHONY: help deploy teardown status logs restart test unit-test smoke-test

help: ## Show this help
	@echo "otel-experiments Applications"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

deploy: ## Build, deploy, and test all applications
	@bash deploy.sh

teardown: ## Remove all applications from the cluster
	@echo "Removing applications from namespace $(NAMESPACE)..."
	@kubectl delete -f ingress.yaml --ignore-not-found=true
	@kubectl delete -f python-api/ --ignore-not-found=true
	@kubectl delete -f java-api/ --ignore-not-found=true
	@kubectl delete -f service-account.yaml --ignore-not-found=true
	@echo ""
	@echo "Deleting namespace $(NAMESPACE)..."
	@kubectl delete -f namespace.yaml --ignore-not-found=true
	@echo ""
	@echo "All applications removed"

status: ## Show application status
	@echo "=== Pods ==="
	@kubectl get pods -n $(NAMESPACE) -o wide 2>/dev/null || echo "No pods found"
	@echo ""
	@echo "=== Services ==="
	@kubectl get svc -n $(NAMESPACE) 2>/dev/null || echo "No services found"
	@echo ""
	@echo "=== Ingress ==="
	@kubectl get ingress -n $(NAMESPACE) 2>/dev/null || echo "No ingress found"
	@echo ""
	@echo "=== OTel Instrumentation ==="
	@kubectl get instrumentation -n $(NAMESPACE) 2>/dev/null || echo "No OTel resources found"
	@echo ""
	@echo "=== Endpoints ==="
	@echo "Java API:   https://api.localhost:8443/java/"
	@echo "Python API: https://api.localhost:8443/python/"
	@echo "Jaeger:     https://jaeger.localhost:8443"

logs: ## Show logs from application pods
	@echo "=== Java API Logs ==="
	@kubectl logs -n $(NAMESPACE) -l app=java-api --tail=20 2>/dev/null || echo "No logs available"
	@echo ""
	@echo "=== Python API Logs ==="
	@kubectl logs -n $(NAMESPACE) -l app=python-api --tail=20 2>/dev/null || echo "No logs available"

restart: ## Restart all application deployments
	@echo "Restarting deployments..."
	@kubectl rollout restart deployment/java-api -n $(NAMESPACE) 2>/dev/null || true
	@kubectl rollout restart deployment/python-api -n $(NAMESPACE) 2>/dev/null || true
	@echo "Restart triggered"

java-logs: ## Show Java API logs only
	@kubectl logs -n $(NAMESPACE) -l app=java-api -f

python-logs: ## Show Python API logs only
	@kubectl logs -n $(NAMESPACE) -l app=python-api -f

test: unit-test smoke-test ## Run all tests (unit + smoke)

unit-test: ## Run unit tests (Python pytest, Java Maven)
	@echo "=== Python Unit Tests ==="
	@cd python-api && python -m pytest test_main.py -v
	@echo ""
	@echo "=== Java Unit Tests ==="
	@cd java-api && mvn test -q

smoke-test: ## Run integration smoke tests against live cluster
	@bash test-apps.sh
