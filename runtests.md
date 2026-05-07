# SWMS Platform — Test Suite Reference

Four testing layers: unit, component, integration, system. Unit and component run anywhere; integration and system require a live cluster.

---

## Prerequisites

```bash
# Python test deps
pip install -r requirements-test.txt

# Helm unittest plugin
helm plugin install https://github.com/helm-unittest/helm-unittest --version 0.6.3

# bats (shell tests)
npm install -g bats

# Helm dependency update — must run before app helm tests
make install-test-deps
```

---

## Quick Reference

| Command | What runs | Cluster needed |
|---|---|---|
| `make test-fast` | unit + component | No |
| `make test-unit` | helm + python + shell unit tests | No |
| `make test-component` | kong, kafka, manifest validation | No |
| `make test-integration` | cross-service config + cluster tests | Partially |
| `make test-system` | kind cluster deploy + namespace tests | kind only |
| `make test-all` | everything | Yes (kind + Minikube/DOKS) |

---

## 1. Unit Tests

Unit tests run with no cluster. They mock all external dependencies.

### 1a. Helm Chart Template Tests (`helm-unittest`)

Validates rendered Kubernetes manifests from `helm/charts/base-service/` and all 15 app charts.

**What each suite tests:**

| File | What it validates |
|---|---|
| `deployment_test.yaml` | Kind=Deployment, runAsNonRoot=true, runAsUser=1000, /health liveness probe, /ready readiness probe, resource requests+limits, allowPrivilegeEscalation=false, readOnlyRootFilesystem=true, ALL capabilities dropped |
| `service_test.yaml` | Kind=Service, ClusterIP type, correct port mapping |
| `hpa_test.yaml` | HPA does not render when disabled; renders with autoscaling/v2 API, correct min/max replicas and CPU target when enabled |
| `networkpolicy_test.yaml` | NetworkPolicy does not render when disabled; allows ingress from gateway and monitoring namespaces, includes both Ingress and Egress policy types |
| `externalsecret_test.yaml` | ExternalSecret does not render when disabled; uses external-secrets.io/v1, vault-backend ClusterSecretStore, Owner creation policy |
| `servicemonitor_test.yaml` | ServiceMonitor does not render when disabled; scrapes /metrics on http port, has release=monitoring label for Prometheus discovery |
| `pdb_test.yaml` | PDB does not render when disabled; uses policy/v1, correct minAvailable |

**Per-app chart tests** (in `tests/unit/helm/apps/`) verify that each app's `values-dev.yaml` overrides the correct image repository and service port, and that ExternalSecrets render for the right Vault paths.

```bash
# Base-service chart
helm unittest helm/charts/base-service/ --file 'tests/unit/helm/base-service/*_test.yaml'

# Single app
helm unittest apps/bin-status/ --file 'tests/unit/helm/apps/bin-status_test.yaml'

# All apps via make
make test-unit-helm
```

### 1b. Python Bridge Tests (`pytest`)

Tests for `messaging/emqx/bridge.py`. Kafka and MQTT are fully mocked — no broker needed.

| Test | What it validates |
|---|---|
| `test_on_message_maps_sensors_topic_to_kafka_bin_telemetry` | `sensors/*` MQTT → `waste.bin.telemetry` Kafka topic |
| `test_on_message_maps_vehicles_topic_to_kafka_vehicle_location` | `vehicles/*` MQTT → `waste.vehicle.location` Kafka topic |
| `test_on_message_unknown_prefix_routes_to_waste_general` | Unrecognised MQTT prefix falls back to `waste.general` |
| `test_on_message_wraps_payload_with_metadata` | Output message has `version`, `source_service`, `timestamp`, `payload` fields |
| `test_on_message_timestamp_is_milliseconds` | Timestamp is unix epoch in ms |
| `test_on_message_uses_device_id_as_kafka_key` | Last path segment of MQTT topic becomes Kafka message key |
| `test_on_message_handles_json_parse_error_gracefully` | Malformed JSON payload does not crash the bridge, producer.send not called |
| `test_environment_variable_defaults` | MQTT_BROKER, KAFKA_BROKER, MQTT_PORT match expected defaults |
| `test_topic_map_covers_sensors_and_vehicles` | TOPIC_MAP contains both prefix mappings |

```bash
pytest tests/unit/python/ -m unit -v
```

### 1c. Shell Script Tests (`bats`)

Tests for `scripts/setup-local.sh` and `scripts/setup-doks.sh` without executing any real cluster operations.

| File | What it validates |
|---|---|
| `test_setup_local.bats` | log helper functions output correct prefixes; log_error exits non-zero; WIN_PATHS loop skips nonexistent dirs; KAFKA_CHART_VERSION is set; namespaces applied before helm installs; idempotent `helm status` guards present |
| `test_setup_doks.bats` | DO_TOKEN check precedes terraform apply; `terraform apply -auto-approve` present; values-doks.yaml overlays used; `terraform destroy` documented; all required tools checked; log helpers defined |

```bash
bats tests/unit/shell/test_setup_local.bats
bats tests/unit/shell/test_setup_doks.bats
```

---

## 2. Component Tests

Static analysis of config files. No cluster needed.

### 2a. Kong Config (`tests/component/kong/test_kong_config.py`)

Parses `gateway/kong/kong-config.yaml` and validates the declarative Kong config.

| Test | What it validates |
|---|---|
| `test_config_uses_format_version_3` | `_format_version: "3.0"` |
| `test_all_services_have_url` | Every service has an `http://` cluster-internal URL |
| `test_all_routes_have_at_least_one_path` | No empty-path routes |
| `test_cors_plugin_on_all_api_routes` | CORS plugin present on every route |
| `test_rate_limiting_on_all_routes` | Rate-limiting plugin on every route |
| `test_expected_services_present` | bin-status, orchestrator, scheduler, core-api, ml-service, route-optimizer, notification all defined |
| `test_bin_status_exposes_bins_and_zones_routes` | `/api/v1/bins` and `/api/v1/zones` paths present |
| `test_no_internal_paths_exposed` | No route path starts with `/internal` |
| `test_notification_service_has_socket_io_route` | `/socket.io` route present |
| `test_global_plugins_include_correlation_id` | `correlation-id` global plugin configured |
| `test_global_plugins_include_file_log` | `file-log` global plugin configured |
| `test_all_services_use_cluster_internal_dns` | All service URLs contain `svc.cluster.local` |

```bash
pytest tests/component/kong/ -m component -v
```

### 2b. Kafka Topics Schema (`tests/component/kafka/test_topics_schema.py`)

Parses the shell script embedded in `messaging/kafka/topics.yaml` and validates topic definitions.

| Test | What it validates |
|---|---|
| `test_manifest_is_a_job` | Document kind is `Job` |
| `test_job_in_messaging_namespace` | Namespace is `messaging` |
| `test_all_expected_topics_defined` | All 12 platform topics are defined (waste.bin.telemetry, waste.vehicle.location, waste.bin.processed, waste.routine.schedule.trigger, waste.zone.statistics, waste.bin.dashboard.updates, waste.vehicle.dashboard.updates, waste.driver.responses, waste.vehicle.deviation, waste.job.completed, waste.audit.events, waste.model.retrained) |
| `test_no_duplicate_topic_names` | No topic name appears twice |
| `test_topic_naming_convention` | Every topic follows `waste.<entity>.<event>` with lowercase alphanumeric/underscore segments |
| `test_partition_count_at_least_one` | All topics have ≥1 partition |
| `test_retention_values_are_positive_integers` | All retention_ms values are positive |
| `test_high_throughput_topics_have_6_partitions` | Ingestion and dashboard topics have 6 partitions |
| `test_audit_topic_has_long_retention` | `waste.audit.events` retains ≥30 days |

```bash
pytest tests/component/kafka/ -m component -v
```

### 2c. Manifest Security Checks (`tests/component/manifests/`)

Renders each service chart with `helm template` and checks security invariants using Python assertions. OPA policy files (`.rego`) are also provided for use with the `conftest` CLI tool.

**Python assertions** (inline, always run if `helm` is available):
- Every non-Flink container has resource requests and limits
- Non-Flink services run as non-root (`runAsNonRoot: true`)
- All containers have `allowPrivilegeEscalation: false`

**OPA policies** (require `conftest` CLI — skipped if not installed):
- `security.rego` — deny containers running as root or allowing privilege escalation
- `labels.rego` — deny Deployments/Services missing required labels
- `resources.rego` — deny containers without cpu/memory requests and limits

Note: Flink services (`flink-deviation`, `flink-sensor`, `flink-telemetry`, `flink-vehicle`, `flink-zone`) intentionally run as root (PyFlink requirement) and are excluded from non-root assertions.

```bash
# Python assertions only
pytest tests/component/manifests/test_manifests.py -m component -v

# With OPA (requires conftest CLI: https://www.conftest.dev/)
# conftest test <manifest.yaml> --policy tests/component/manifests/policies/
```

---

## 3. Integration Tests

Some tests are static (no cluster); others need a running cluster.

### 3a. Cross-Service Config Consistency (`test_cross_service_config.py`) — Static

No cluster needed. Reads all `apps/*/values-dev.yaml` files.

| Test | What it validates |
|---|---|
| `test_kafka_topics_referenced_in_env_exist_in_topics_yaml` | Any env var value matching `waste.*` pattern must be defined in topics.yaml |
| `test_external_secret_vault_paths_use_swms_prefix` | All ExternalSecret `vaultPath` values start with `swms/` |
| `test_vault_policies_cover_kafka_secrets` | `vault-policies.yaml` contains `swms/kafka` path |
| `test_vault_policies_cover_postgres_secrets` | `vault-policies.yaml` contains postgres secret path |
| `test_no_app_references_undefined_kafka_topic` | Kafka-specific env var names (matching KAFKA_*TOPIC pattern) point to defined topics |

```bash
pytest tests/integration/test_cross_service_config.py -v
```

### 3b. Kafka Round-Trip (`test_kafka_roundtrip.py`) — Cluster required

```bash
export KAFKA_BROKER=<host>:9092
export KAFKA_USER=user1
export KAFKA_PASS=<password>
pytest tests/integration/test_kafka_roundtrip.py -m integration -v
```

| Test | What it validates |
|---|---|
| `test_produce_to_bin_telemetry` | Producer can send to `waste.bin.telemetry`; returns valid partition+offset |
| `test_roundtrip_message_intact` | Message produced and consumed at exact offset has correct payload |
| `test_message_schema_has_required_fields` | Consumed message contains version, source_service, timestamp, payload |
| `test_sasl_scram_authentication_required` | PLAINTEXT connection without credentials fails |

### 3c. Service Health Checks (`test_service_health.py`) — Cluster required

Port-forwards each service and calls `GET /health`. Requires `kubectl` in PATH.

```bash
pytest tests/integration/test_service_health.py -m integration -v
```

Tests 7 services: bin-status (3002), orchestrator (3001), scheduler (3003), notification (3004), core-api (8001), ml-service (8000), route-optimizer (8083).

### 3d. Kong Gateway Routes (`test_gateway_routes.py`) — Cluster required

```bash
export KONG_PROXY_URL=http://localhost:30080   # Minikube
# or
export KONG_PROXY_URL=http://<kong-lb-ip>      # DOKS

pytest tests/integration/test_gateway_routes.py -m integration -v
```

| Test | What it validates |
|---|---|
| `test_public_route_does_not_return_404_or_502` | All 10 public routes are reachable via Kong (not 404/502) |
| `test_internal_path_returns_404_from_gateway` | `/internal/anything` returns 404 |
| `test_bins_route_has_cors_header` | CORS plugin adds `Access-Control-Allow-Origin` header |
| `test_request_id_header_present` | `X-Request-ID` header present on every response |

---

## 4. System Tests

Spin up real clusters. Run nightly in CI or manually.

### 4a. Namespace Creation (`test_namespace_creation.sh`)

Creates a temporary kind cluster, applies `namespaces/namespaces-dev.yaml`, verifies all 8 namespaces exist with correct `managed-by=f4-platform` label, then destroys the cluster.

```bash
bash tests/system/test_namespace_creation.sh
```

Expected output: `=== System test PASSED: all 8 namespaces created with correct labels ===`

### 4b. Cluster Deploy (`test_cluster_deploy.sh`)

Creates a kind cluster, installs the bin-status chart (with nginx:alpine as a stand-in image), waits for pod to reach Running state, verifies phase == Running, then destroys the cluster.

```bash
bash tests/system/test_cluster_deploy.sh
```

Expected output: `=== System test PASSED: cluster deploy + pod running ===`

### 4c. E2E Workflow (`test_e2e_workflow.py`)

Full MQTT → bridge → Kafka → Kong end-to-end test against a fully deployed Minikube or DOKS stack.

```bash
export EMQX_HOST=localhost
export EMQX_PORT=31883
export KONG_URL=http://localhost:30080
export KAFKA_BROKER=kafka.messaging.svc.cluster.local:9092
export KAFKA_USER=user1
export KAFKA_PASS=<password>

pytest tests/system/test_e2e_workflow.py -m system -v
```

| Test | What it validates |
|---|---|
| `test_mqtt_publish_reaches_kafka` | MQTT message published to `sensors/e2e/<bin_id>` appears on `waste.bin.telemetry` topic within 15s |
| `test_bins_api_reachable_via_kong` | `GET /api/v1/bins` via Kong does not return 502/503/404 |
| `test_vehicles_api_reachable_via_kong` | `GET /api/v1/vehicles` via Kong does not return 502/503/404 |

---

## CI Workflow

`.github/workflows/tests.yml` runs:

| Trigger | Jobs |
|---|---|
| Every PR + push to main | `helm-unit`, `python-unit`, `shell-unit`, `component`, `integration-static` |
| Nightly (02:00 UTC) + manual | + `system-namespaces` |

Fast path for PRs: `make test-fast` (unit + component, ~2-5 min, no cluster).
