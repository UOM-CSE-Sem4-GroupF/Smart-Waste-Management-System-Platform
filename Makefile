SHELL := /bin/bash

HELM_UNITTEST_VERSION ?= 0.6.3

# Install test dependencies
.PHONY: install-test-deps
install-test-deps:
	pip install -r requirements-test.txt
	helm plugin install https://github.com/helm-unittest/helm-unittest --version $(HELM_UNITTEST_VERSION) 2>/dev/null || true
	helm dependency update apps/bin-status/
	helm dependency update apps/core-api/
	helm dependency update apps/frontend/
	helm dependency update apps/orchestrator/
	helm dependency update apps/scheduler/
	helm dependency update apps/notification/
	helm dependency update apps/ml-service/
	helm dependency update apps/route-optimizer/
	helm dependency update apps/airflow/
	helm dependency update apps/flink-deviation/
	helm dependency update apps/flink-sensor/
	helm dependency update apps/flink-telemetry/
	helm dependency update apps/flink-vehicle/
	helm dependency update apps/flink-zone/
	helm dependency update apps/spark/

# Unit tests — no cluster required
.PHONY: test-unit
test-unit: test-unit-helm test-unit-python test-unit-shell

.PHONY: test-unit-helm
test-unit-helm:
	@echo "=== Helm unit tests: base-service ==="
	helm unittest helm/charts/base-service/ \
	  --file 'tests/unit/helm/base-service/*_test.yaml'
	@echo "=== Helm unit tests: apps ==="
	@for app in bin-status core-api frontend orchestrator scheduler notification ml-service route-optimizer airflow flink-deviation flink-sensor flink-telemetry flink-vehicle flink-zone spark; do \
	  echo "  Testing $$app ..."; \
	  helm unittest apps/$$app/ --file "tests/unit/helm/apps/$${app}_test.yaml" || exit 1; \
	done

.PHONY: test-unit-python
test-unit-python:
	pytest tests/unit/python/ -m unit -v

.PHONY: test-unit-shell
test-unit-shell:
	@command -v bats >/dev/null 2>&1 || { echo "bats not installed. Install: npm install -g bats"; exit 1; }
	bats tests/unit/shell/test_setup_local.bats
	bats tests/unit/shell/test_setup_doks.bats

# Component tests — validates config files statically, no cluster required
.PHONY: test-component
test-component:
	pytest tests/component/ -m component -v

# Integration tests — requires running cluster
.PHONY: test-integration
test-integration:
	pytest tests/integration/ -m integration -v

# System tests — requires full cluster with all services
.PHONY: test-system
test-system:
	bash tests/system/test_namespace_creation.sh
	bash tests/system/test_cluster_deploy.sh

# Run all test layers
.PHONY: test-all
test-all: test-unit test-component test-integration test-system

# Run fast tests only (unit + component — CI on every PR)
.PHONY: test-fast
test-fast: test-unit test-component
