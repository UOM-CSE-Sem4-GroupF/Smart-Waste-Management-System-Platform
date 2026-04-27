# F4 — Platform, Security & Integration
## Complete Task List
**Group F — Smart Waste Management System**

---

## Overview

F4 is the platform team. We own the infrastructure, security, CI/CD, observability, and deployment for the entire Group F system. Every other sub-group (F1, F2, F3) runs on top of what F4 builds.

**Our customers are F1, F2, and F3.** Their code runs in our cluster, deploys through our pipelines, authenticates through our Keycloak, and is secured by our Vault and Istio.

---

## Team Assignment

| Member | Primary Domain |
|--------|---------------|
| Lead (you) | Kong, Architecture, Hyperledger chaincode, Cross-team coordination |
| Member 2 | Kubernetes cluster, Helm charts, Terraform IaC, Argo CD |
| Member 3 | Keycloak, Vault, OPA, Istio |
| Member 4 | GitHub Actions CI/CD, Trivy, OWASP ZAP, Chaos Mesh, k6 |
| Member 5 | Prometheus, Grafana, ELK stack, Jaeger, PostgreSQL, InfluxDB |

---

## Week 1 Priorities — Unblocks Everyone

These must be done first. Nothing else in the project can start without them.

| Day | Task | Why it's urgent |
|-----|------|-----------------|
| Day 1 | Create GitHub org + repos + permissions | F1/F2/F3 cannot commit code |
| Day 1 | Write and share Platform Contract | Sets standards before bad habits form |
| Day 2–3 | `setup-local.sh` working on all laptops | Developers need an environment |
| Day 2–3 | Kafka topics created | F2 cannot write Flink consumers |
| Day 3–4 | Keycloak realm + test users + seed script | F3 cannot build login flows |
| Day 4 | GitHub Actions reusable workflow | F1/F2/F3 CI/CD from day one |
| Day 5 | End-to-end hello-world test | Proves the platform works before others stake their code on it |

---

## 1. Infrastructure & Kubernetes

### 1.1 Cluster setup
- [ ] Provision Kubernetes cluster (via Terraform)
- [ ] Create all 8 namespaces:
  - `gateway` — Kong, Istio ingress
  - `auth` — Keycloak, Vault, OPA
  - `messaging` — Kafka, Zookeeper, EMQX, Redis
  - `monitoring` — Prometheus, Grafana, ELK, Jaeger
  - `cicd` — Argo CD, Chaos Mesh, k6
  - `blockchain` — Hyperledger peer, orderer, CA
  - `waste-dev` — All F2 + F3 services (dev)
  - `waste-prod` — All F2 + F3 services (prod)
- [ ] Configure namespace resource quotas (prevent waste-dev starving waste-prod)
- [ ] Configure network policies:
  - `waste-prod` can reach `messaging` (Kafka, EMQX)
  - `waste-prod` can reach `auth` (Keycloak, Vault)
  - `waste-prod` cannot reach `cicd`
  - `monitoring` can scrape all namespaces
- [ ] Set up persistent volume claims for all stateful services

### 1.2 Node configuration
- [ ] Configure Kubernetes RBAC (team-level deploy permissions per namespace)
- [ ] Configure HPA (Horizontal Pod Autoscaler) for:
  - FastAPI ML service
  - Notification service
  - Bin status service
  - Flink task manager
- [ ] Configure liveness and readiness probes for all services
- [ ] Configure resource limits and requests for every pod
- [ ] Configure pod disruption budgets for critical services

---

## 2. Terraform (Infrastructure as Code)

- [ ] Write Terraform for Kubernetes cluster provisioning
- [ ] Write Terraform for networking (VPC, subnets, firewall rules)
- [ ] Write Terraform for storage (persistent volume configuration)
- [ ] Write Terraform for DNS configuration
- [ ] Create `environments/dev/` and `environments/prod/` tfvars
- [ ] Configure remote state backend (S3 or equivalent)
- [ ] Document how to run: `terraform init`, `plan`, `apply`

**Repo location:** `group-f-platform/terraform/`

---

## 3. Helm Charts

F4 writes a Helm chart for every service in the system. F2/F3 own the code — F4 owns the deployment definition.

### 3.1 Platform services (F4 owns software + chart)

| Service | Namespace | Type |
|---------|-----------|------|
| Kong API gateway | gateway | Deployment |
| Keycloak | auth | Deployment (2 replicas) |
| HashiCorp Vault | auth | StatefulSet (3-node HA) |
| EMQX broker | messaging | StatefulSet |
| Kafka (3 brokers) | messaging | StatefulSet |
| Zookeeper (3 nodes) | messaging | StatefulSet |
| Redis | messaging | Deployment |
| Prometheus + AlertManager | monitoring | Deployment |
| Grafana | monitoring | Deployment |
| Elasticsearch | monitoring | StatefulSet |
| Logstash | monitoring | Deployment |
| Kibana | monitoring | Deployment |
| Jaeger | monitoring | Deployment |
| Istio control plane | istio-system | DaemonSet |
| Open Policy Agent | auth | Deployment |
| Argo CD | cicd | Deployment |
| Chaos Mesh | cicd | Deployment |
| Hyperledger peer | blockchain | StatefulSet |
| Hyperledger orderer | blockchain | StatefulSet |
| Hyperledger CA | blockchain | Deployment |

- [ ] Charts written for all platform services above

### 3.2 Application service charts (F2/F3 own code, F4 owns chart)

| Service | Owner | Namespace |
|---------|-------|-----------|
| Flink job manager | F2 | waste-prod |
| Flink task manager | F2 | waste-prod |
| FastAPI ML service | F2 | waste-prod |
| OR-Tools route optimizer | F2 | waste-prod |
| Airflow scheduler | F2 | waste-prod |
| Airflow worker | F2 | waste-prod |
| MLflow server | F2 | waste-prod |
| PostgreSQL | F2 | waste-prod |
| InfluxDB | F2 | waste-prod |
| Bin status service | F3 | waste-prod |
| Scheduler service | F3 | waste-prod |
| Notification service | F3 | waste-prod |
| Workflow orchestrator | F3 | waste-prod |
| Next.js dashboard | F3 | waste-prod |

- [ ] Charts written for all application services above

### 3.3 Each chart must include:
- [ ] `values.yaml` (defaults)
- [ ] `values-dev.yaml` (dev environment overrides — scaled down)
- [ ] `values-prod.yaml` (prod environment overrides — full scale)
- [ ] `templates/deployment.yaml`
- [ ] `templates/service.yaml`
- [ ] `templates/hpa.yaml` (for scalable services)
- [ ] `templates/configmap.yaml`
- [ ] Vault agent injection annotations on all application pods

**Repo location:** `group-f-platform/helm/`

---

## 4. Kong API Gateway

### 4.1 Route configuration

One YAML file per service route, stored in `group-f-platform/gateway/kong/routes/`

- [ ] `GET /api/v1/bins/*` → bin-status-service (any role)
- [ ] `GET /api/v1/bins/*/history` → bin-status-service (supervisor only)
- [ ] `GET /api/v1/zones/*` → bin-status-service (any role)
- [ ] `GET /api/v1/clusters/*` → bin-status-service (any role)
- [ ] `GET /api/v1/collection-jobs/*` → workflow-orchestrator (supervisor, fleet-operator)
- [ ] `POST /api/v1/collection-jobs/*/accept` → workflow-orchestrator (driver)
- [ ] `POST /api/v1/collection-jobs/*/cancel` → workflow-orchestrator (supervisor)
- [ ] `POST /api/v1/collections/*/bins/*/collected` → scheduler-service (driver)
- [ ] `POST /api/v1/collections/*/bins/*/skip` → scheduler-service (driver)
- [ ] `GET /api/v1/vehicles/*` → scheduler-service (supervisor, fleet-operator)
- [ ] `GET /api/v1/drivers/*` → scheduler-service (supervisor, fleet-operator)
- [ ] `GET /api/v1/ml/*` → fastapi-ml-service (supervisor)
- [ ] `WS /ws` → notification-service (WebSocket, all roles)
- [ ] Block all `/internal/*` routes (cluster-internal only, never external)
- [ ] `GET /health/*` → all services (no auth)
- [ ] `POST /api/v1/blockchain/collections` → Hyperledger SDK (orchestrator only)
- [ ] `GET /api/v1/blockchain/collections/:id` → Hyperledger SDK (supervisor)

### 4.2 Plugin configuration

- [ ] JWT authentication plugin (validates Keycloak RS256 tokens)
- [ ] Rate limiting plugin (100 req/min per consumer)
- [ ] Request logging plugin (ships to ELK via Logstash)
- [ ] CORS plugin (allow dashboard and mobile app origins)
- [ ] WebSocket proxy configuration (sticky sessions for Socket.IO)

**Repo location:** `group-f-platform/gateway/`

---

## 5. Keycloak Identity Server

### 5.1 Realm setup
- [ ] Create realm: `waste-management`
- [ ] Configure token lifespan: access token = 5 min, refresh = 30 min
- [ ] Configure password policy (min 8 chars, 1 uppercase, 1 number)
- [ ] Configure brute force detection (lock after 5 failed attempts)
- [ ] Enable SSL required (all requests must use HTTPS)

### 5.2 Roles
- [ ] `admin` — full system access, user management
- [ ] `supervisor` — view all bins/jobs/vehicles, cancel jobs, analytics
- [ ] `fleet-operator` — assign drivers, view vehicles, modify schedules
- [ ] `driver` — view own job, mark collections, accept/reject
- [ ] `viewer` — read-only dashboard access
- [ ] `sensor-device` — machine account, MQTT only, no API access

### 5.3 Clients
- [ ] `waste-web-app` — public client, Next.js dashboard
- [ ] `waste-mobile-app` — public client with PKCE, Flutter app
- [ ] `waste-api-internal` — confidential client, service-to-service auth
- [ ] `kong-gateway` — confidential client, token introspection permission

### 5.4 Custom driver user attributes
- [ ] `zone_id` — driver's primary zone
- [ ] `current_vehicle_id` — assigned vehicle
- [ ] `fcm_token` — Firebase push notification token
- [ ] `shift_start` / `shift_end` — working hours
- [ ] `employee_id` — HR reference

### 5.5 Seed test users (for development)
- [ ] `admin-user` / `Test1234!` — role: admin
- [ ] `supervisor-user` / `Test1234!` — role: supervisor, zone: zone-1
- [ ] `operator-user` / `Test1234!` — role: fleet-operator
- [ ] `driver-user` / `Test1234!` — role: driver, vehicle: LORRY-01

### 5.6 Export and automation
- [ ] Export realm as `realm-export.json`
- [ ] Commit to `group-f-platform/auth/keycloak/`
- [ ] Configure auto-import on Keycloak startup (via Helm values)
- [ ] Write `seed-keycloak.sh` to create test users programmatically

**Repo location:** `group-f-platform/auth/keycloak/`

---

## 6. HashiCorp Vault

### 6.1 Setup
- [ ] Deploy Vault in HA mode (3 nodes, StatefulSet)
- [ ] Initialise and unseal Vault
- [ ] Store unseal keys securely — **never in git**
- [ ] Enable Kubernetes auth method
- [ ] Configure Kubernetes auth with cluster API endpoint

### 6.2 Secret paths to provision

```
secret/waste-mgmt/
├── database/
│   ├── bin-status-service
│   ├── scheduler-service
│   ├── notification-service
│   ├── workflow-orchestrator
│   ├── fastapi-ml-service
│   └── flink-processor
├── kafka/
├── keycloak/
├── influxdb/
├── redis/
├── external/
│   ├── mapbox-api-key
│   └── fcm-server-key
├── hyperledger/
└── ci-cd/
```

- [ ] All secret paths provisioned with correct values

### 6.3 Vault policies (one per service)

- [ ] `bin-status-service-policy.hcl`
- [ ] `scheduler-service-policy.hcl`
- [ ] `notification-service-policy.hcl`
- [ ] `workflow-orchestrator-policy.hcl`
- [ ] `fastapi-ml-service-policy.hcl`
- [ ] `flink-processor-policy.hcl`
- [ ] `ci-pipeline-policy.hcl`

Each policy: read only what that service needs. Nothing more.

### 6.4 Kubernetes auth roles
- [ ] One Kubernetes auth role per service account (maps service → policy)

### 6.5 Dynamic database credentials
- [ ] Configure Vault database engine for PostgreSQL
- [ ] Create dynamic role per service (TTL: 1 hour)
- [ ] Verify: each pod gets unique DB username on startup

**Repo location:** `group-f-platform/auth/vault/`

---

## 7. Istio Service Mesh

- [ ] Install Istio control plane in `istio-system` namespace
- [ ] Enable sidecar injection on all application namespaces:
  - Label namespace: `istio-injection=enabled`
  - Namespaces: `waste-dev`, `waste-prod`, `messaging`, `auth`, `gateway`
- [ ] Write `PeerAuthentication` — enforce mTLS STRICT per namespace
- [ ] Write `AuthorizationPolicy` per service:
  - Only workflow-orchestrator can call `/internal/*` of scheduler-service
  - Only workflow-orchestrator can call `/internal/*` of bin-status-service
  - Only workflow-orchestrator can call `/internal/*` of notification-service
  - Only scheduler-service can call `/internal/route-optimizer/*`
  - Only scheduler-service can call `/internal/notify/vehicle-*`
  - Only bin-status-service can call `/internal/notify/bin-*`
- [ ] Write `VirtualService` for canary deployment support (90/10 traffic split)
- [ ] Write `DestinationRule` for load balancing policy per service
- [ ] Verify: Prometheus receiving Istio metrics (traces, latency, error rates)

**Repo location:** `group-f-platform/istio/`

---

## 8. Kafka

### 8.1 Cluster
- [ ] Deploy Kafka (3 brokers) as StatefulSet in `messaging` namespace
- [ ] Deploy Zookeeper (3 nodes) as StatefulSet
- [ ] Configure persistent volumes per broker (min 20GB each)
- [ ] Configure replication factor = 3 for all topics

### 8.2 Create all topics

| Topic | Partitions | Retention | Notes |
|-------|-----------|-----------|-------|
| `waste.bin.telemetry` | 3 | 7 days | Raw sensor readings |
| `waste.bin.processed` | 3 | 3 days | Flink enriched |
| `waste.bin.dashboard.updates` | 3 | 5 minutes | Live dashboard |
| `waste.vehicle.location` | 3 | 7 days | GPS pings |
| `waste.vehicle.dashboard.updates` | 3 | 5 minutes | Live dashboard |
| `waste.vehicle.deviation` | 3 | 1 day | Flink alerts |
| `waste.routine.schedule.trigger` | 1 | 1 day | Airflow → orchestrator |
| `waste.job.completed` | 3 | 30 days | Job completion events |
| `waste.driver.responses` | 3 | 1 day | Accept/reject |
| `waste.zone.statistics` | 3 | 7 days | Flink zone aggregations |
| `waste.audit.events` | 3 | 365 days | Blockchain feed |
| `waste.model.retrained` | 1 | 1 day | ML model promotion |

- [ ] All 12 topics created with correct settings
- [ ] Write `create-kafka-topics.sh` script

### 8.3 Kafka ACLs (access control per service)
- [ ] EMQX: produce to `waste.bin.telemetry`, `waste.vehicle.location`
- [ ] F2 Flink: consume `waste.bin.telemetry`, produce `waste.bin.processed`, `waste.zone.statistics`, `waste.vehicle.deviation`
- [ ] F3 orchestrator: consume `waste.bin.processed`, `waste.routine.schedule.trigger`, `waste.model.retrained` — produce `waste.job.completed`, `waste.audit.events`
- [ ] F3 bin-status-service: consume `waste.bin.processed`, `waste.zone.statistics` — produce `waste.bin.dashboard.updates`
- [ ] F3 scheduler-service: consume `waste.vehicle.location`, `waste.vehicle.deviation` — produce `waste.vehicle.dashboard.updates`
- [ ] F3 notification-service: consume `waste.bin.dashboard.updates`, `waste.vehicle.dashboard.updates`
- [ ] F4 Hyperledger: consume `waste.audit.events`

### 8.4 EMQX bridge
- [ ] Configure EMQX → Kafka bridge for bin telemetry:
  - MQTT topic: `sensors/bin/+/telemetry` → Kafka: `waste.bin.telemetry`
- [ ] Configure EMQX → Kafka bridge for vehicle GPS:
  - MQTT topic: `vehicle/+/location` → Kafka: `waste.vehicle.location`

**Repo location:** `group-f-platform/messaging/`

---

## 9. EMQX MQTT Broker

- [ ] Deploy EMQX in `messaging` namespace
- [ ] Expose LoadBalancer service for F1 edge devices to connect
- [ ] Configure device certificate authentication (certs provisioned via Vault)
- [ ] Configure Kafka bridge rules (see Section 8.4)
- [ ] Configure topic ACLs:
  - `sensor-device` role can only publish to `sensors/bin/+/telemetry`
  - `sensor-device` role can only publish to `vehicle/+/location`
  - Subscriptions to `config/device/+` (to receive config updates)
- [ ] Test end-to-end: ESP32 connects → publishes → message appears in Kafka

**Repo location:** `group-f-platform/messaging/emqx/`

---

## 10. Observability Stack

### 10.1 Prometheus + Grafana

**Alert rules:**

| Severity | Condition | Description |
|----------|-----------|-------------|
| CRITICAL | bin fill = 100% AND no active job | Bin overflowing |
| CRITICAL | Kafka consumer lag > 10,000 for > 5 min | F2 processing falling behind |
| CRITICAL | Service pod in CrashLoopBackOff | Service down |
| WARNING | No bin readings from zone for > 30 min | Sensor outage |
| WARNING | Collection job state = ESCALATED | No vehicle found |
| WARNING | Vehicle deviation > 500m for > 3 min | Driver off route |
| WARNING | Vault seal detected | All secrets unavailable |
| INFO | `waste.model.retrained` event received | ML model promoted |

- [ ] Write all alert rules above

**Grafana dashboards to build:**

- [ ] **Dashboard 1 — Operations Overview**
  - Live bin status counts by zone (normal/monitor/urgent/critical)
  - Active jobs by type and state
  - Vehicle fleet utilisation gauges
  - Kafka consumer lag per topic

- [ ] **Dashboard 2 — Collection Performance**
  - Jobs completed per hour (today vs 7-day average)
  - Emergency vs routine ratio
  - Average job duration trend
  - Driver performance heatmap

- [ ] **Dashboard 3 — Platform Health**
  - Service uptime per pod
  - API response times by endpoint (p50, p95, p99)
  - Error rates per service
  - Flink checkpoint duration
  - Vault secret rotation status

- [ ] **Dashboard 4 — Waste Intelligence**
  - Bin fill rate distribution by waste category
  - Zone fill level heatmap
  - ML model MAE over time
  - Prediction accuracy: predicted vs actual fill time

### 10.2 ELK Stack

- [ ] Deploy Elasticsearch (StatefulSet, persistent volumes, min 50GB)
- [ ] Deploy Logstash
- [ ] Deploy Kibana
- [ ] Write Logstash pipeline to parse structured JSON logs from all pods
  - Parse fields: `timestamp`, `level`, `service`, `message`, `traceId`
  - Index pattern: `waste-logs-YYYY.MM.DD`
- [ ] Create Kibana index patterns
- [ ] Configure log retention policy (30 days)
- [ ] Create Kibana saved searches for common queries:
  - All ERROR logs in last 1 hour
  - Logs by service
  - Logs by traceId (follow a request across services)

### 10.3 Jaeger Distributed Tracing

- [ ] Deploy Jaeger
- [ ] Configure Istio to export trace spans to Jaeger
- [ ] Set sampling rate: 100% in dev, 10% in prod
- [ ] Verify: a request from Kong → bin-status-service → Kafka produces a full trace

**Repo location:** `group-f-platform/observability/`

---

## 11. CI/CD Pipelines

### 11.1 GitHub Actions reusable workflow

Write in `group-f-platform/.github/workflows/service-build.yml`:

```
Steps:
  1. checkout code
  2. run tests (pytest / jest depending on language)
  3. build Docker image
  4. run Trivy scan — CRITICAL/HIGH CVEs fail the build
  5. push image to GHCR with commit SHA tag
  6. update image.tag in Helm values file in group-f-platform
  7. commit and push values change (triggers Argo CD)
```

- [ ] Write `service-build.yml` reusable workflow
- [ ] Write `security-scan.yml` (OWASP ZAP against staging URL)
- [ ] Write `schema-migration.yml` (runs Prisma migrations on merge to main)
- [ ] Document how F1/F2/F3 teams call the reusable workflow (3-line usage example)
- [ ] Test end-to-end with a hello-world service

### 11.2 Argo CD GitOps

- [ ] Deploy Argo CD in `cicd` namespace
- [ ] Connect to `group-f-platform` GitHub repo
- [ ] Create Argo CD Application resource per service
- [ ] Configure auto-sync on merge to `main` branch
- [ ] Configure health checks per service type (Deployment, StatefulSet)
- [ ] Test rollback: deploy a service with a bad image → verify auto-rollback

**Repo location:** `group-f-platform/.github/` and `group-f-platform/cicd/`

---

## 12. Databases

### 12.1 PostgreSQL

- [ ] Deploy PostgreSQL as StatefulSet in `waste-prod` namespace
- [ ] Configure persistent volume (min 50GB)
- [ ] Run database schema migration v3.0 (`database-schema-v3.sql`)
- [ ] Create `f2` and `f3` schemas
- [ ] Create roles: `f2_app_user`, `f3_app_user`, `f3_readonly_role`
- [ ] Grant cross-schema permissions as defined in schema
- [ ] Deploy PgBouncer connection pooler
- [ ] Configure automated daily backups
- [ ] Write seed data SQL:
  - waste_categories (6 rows — already in schema)
  - city_zones (example zones)
  - bin_clusters (example clusters)
  - bins (example bins per cluster)
  - vehicles (4 example vehicles — one per type)
  - devices (one device per bin)

### 12.2 InfluxDB

- [ ] Deploy InfluxDB as StatefulSet
- [ ] Create organisation: `waste-mgmt`
- [ ] Create buckets:

| Bucket | Retention |
|--------|-----------|
| `bin-telemetry` (raw) | 1 year |
| `bin-processed` | 90 days |
| `vehicle-positions` | 1 year |
| `zone-statistics` | 2 years |
| `waste-generation-trends` | Forever |

- [ ] Create API tokens per service (stored in Vault)

**Repo location:** `group-f-platform/databases/`

---

## 13. Hyperledger Fabric Blockchain

### 13.1 Network setup
- [ ] Deploy peer node (StatefulSet in `blockchain` namespace)
- [ ] Deploy orderer node (StatefulSet)
- [ ] Deploy Certificate Authority
- [ ] Create channel: `waste-collection-channel`
- [ ] Configure MSP (Membership Service Provider)
- [ ] Configure TLS for all peer communication

### 13.2 Chaincode (smart contracts)
- [ ] Write `collection-record.go` chaincode:
  - `RecordCollection(ctx, recordJSON)` — write collection to ledger
  - `QueryRecord(ctx, jobId)` — read by job ID
  - `QueryByJobId(ctx, jobId)` — same as above
  - `QueryByZoneAndDate(ctx, zoneId, date)` — audit query
- [ ] Write tests for chaincode
- [ ] Deploy chaincode to `waste-collection-channel`

### 13.3 REST API wrapper
- [ ] Write REST API using Hyperledger Fabric Go SDK:
  - `POST /api/v1/blockchain/collections` — called by orchestrator
  - `GET /api/v1/blockchain/collections/:job_id` — called by dashboard
- [ ] Expose via Kong (with JWT auth)

### 13.4 Monitoring
- [ ] Add Prometheus metrics: transaction throughput, block time
- [ ] Add Grafana panel for blockchain health in Dashboard 3

**Repo location:** `group-f-platform/blockchain/`

---

## 14. Security

### 14.1 Open Policy Agent
- [ ] Deploy OPA as Kubernetes admission controller
- [ ] Write policy: only orchestrator can call `/internal/*` routes
- [ ] Write policy: driver can only access their own assigned job
- [ ] Write policy: supervisor role required for job cancellation
- [ ] Write policy: sensor-device role restricted to MQTT topics only
- [ ] Write policy: no pod can run as root user (admission control)

### 14.2 Trivy container scanning
- [ ] Integrated in GitHub Actions (blocks CRITICAL/HIGH CVEs on build)
- [ ] Configure scheduled weekly scan of all running images in cluster
- [ ] Alert via Prometheus when new CVEs found in production images

### 14.3 OWASP ZAP API penetration testing
- [ ] Configure ZAP scan against Kong gateway staging URL
- [ ] Run scan after every significant deployment
- [ ] Document findings and remediations (required for project report Section 5)
- [ ] Generate ZAP HTML report — include in project report

**Repo location:** `group-f-platform/security/`

---

## 15. Testing

### 15.1 Chaos testing (Chaos Mesh)

Write one experiment YAML per scenario:

- [ ] Kill Flink task manager pod → verify recovery from checkpoint, no events lost
- [ ] Kill notification service pod → verify Kafka events queue, resume on restart
- [ ] Network partition between orchestrator and scheduler → verify retry logic
- [ ] Kill one Kafka broker → verify 2 remaining brokers handle load
- [ ] Kill PostgreSQL pod → verify StatefulSet recovers with data intact
- [ ] CPU stress on bin-status-service → verify HPA scales up
- [ ] Document all experiment results for project report Section 4

### 15.2 Load testing (k6)

Write k6 scripts for:

- [ ] 1,000 concurrent bin events through Kong (`POST` to internal endpoint simulated)
- [ ] 100 concurrent WebSocket connections from dashboard clients
- [ ] 500 API requests/sec against `GET /api/v1/bins` (most frequent query)
- [ ] Sustained load: 10 min at 200 req/sec across all endpoints

**Targets:**
- p99 latency < 500ms
- 500 req/s sustained without error rate > 0.1%
- 100 WebSocket connections stable for 10 min

- [ ] Run load tests before each sprint demo
- [ ] Document results for project report Section 5

**Repo location:** `group-f-platform/tests/`

---

## 16. Local Development Setup

- [ ] Write `setup-local.sh` — one command, full local cluster in < 10 minutes
- [ ] Write `teardown.sh` — clean reset
- [ ] Write `seed-keycloak.sh` — creates all test users and roles
- [ ] Write `create-kafka-topics.sh` — creates all 12 topics
- [ ] Write `seed-database.sql` — initial reference data (zones, clusters, bins, vehicles)
- [ ] Test `setup-local.sh` on a clean machine (not just the developer's own)
- [ ] Document minimum hardware requirements:
  - RAM: 16GB minimum, 32GB recommended
  - CPU: 4 cores minimum
  - Disk: 30GB free
- [ ] Write `group-f-docs/platform-onboarding.md`

**Repo location:** `group-f-platform/scripts/`

---

## 17. Documentation

- [ ] `platform-contract.md` — rules all sub-groups must follow (share Week 1)
- [ ] `kafka-schemas.json` — all 12 topic message schemas
- [ ] `onboarding.md` — how F1/F2/F3 use the platform
- [ ] `runbooks/` — how to handle common incidents:
  - `runbook-kafka-consumer-lag.md`
  - `runbook-vault-seal.md`
  - `runbook-pod-crashloop.md`
  - `runbook-database-connection-pool.md`
- [ ] `CLAUDE.md` in all 5 repos (already written — keep updated)
- [ ] Architecture Decision Records (ADRs):
  - `adr-001-hybrid-choreography-orchestration.md`
  - `adr-002-weight-aware-routing.md`
  - `adr-003-or-tools-rest-not-kafka.md`
  - `adr-004-notification-single-socket.md`
  - `adr-005-cluster-level-collection.md`
  - `adr-006-3nf-job-decomposition.md`

**Repo location:** `group-f-docs/`

---

## 18. Project Report Contributions (F4 sections)

These are the report sections F4 leads or co-authors:

| Section | F4 Contribution |
|---------|-----------------|
| Section 2 — Architecture | C4 diagrams, hybrid pattern justification, ADRs |
| Section 5 — Deployment plan | Kubernetes namespace design, Helm chart structure, Terraform plan |
| Section 5 — Security | Keycloak RBAC design, Vault secret management, Istio mTLS, OWASP ZAP results |
| Section 5 — Performance | k6 load test results, HPA configuration, scalability analysis |
| Section 4 — Testing | Chaos Mesh experiment results, platform-level test coverage |
| Section 6 — Agile Scrum | Sprint board screenshots, burndown charts, velocity data from Linear |

---

## Checklist Summary — By Sprint

### Sprint 1 (Week 1–2) — Platform Foundation
```
[ ] GitHub org + repos + permissions
[ ] Platform contract document
[ ] setup-local.sh working
[ ] Kafka cluster + all 12 topics
[ ] Keycloak realm + clients + roles + test users
[ ] Kong basic routing
[ ] GitHub Actions reusable workflow
[ ] Argo CD connected to repo
[ ] Vault deployed (dev mode for now)
[ ] E2E hello-world test passing
[ ] PostgreSQL deployed + schema v3.0 migrated
[ ] InfluxDB deployed + buckets created
```

### Sprint 2 (Week 3–4) — Security + Observability
```
[ ] Vault HA mode + all secrets provisioned
[ ] Vault policies per service
[ ] Istio mTLS enforcement
[ ] AuthorizationPolicy per service
[ ] Prometheus + all alert rules
[ ] Grafana dashboards 1–4
[ ] ELK stack + Logstash pipeline
[ ] Jaeger tracing
[ ] EMQX bridge to Kafka
[ ] OPA policies
```

### Sprint 3 (Week 5–6) — Blockchain + Testing + Hardening
```
[ ] Hyperledger Fabric network
[ ] CollectionRecord chaincode deployed
[ ] Hyperledger REST API via Kong
[ ] Chaos Mesh experiments (all 6 scenarios)
[ ] k6 load tests (all 4 scripts)
[ ] OWASP ZAP penetration test
[ ] Trivy scheduled scans
[ ] All Helm charts complete and tested
[ ] Terraform IaC complete
[ ] PgBouncer + database backups
```

### Sprint 4 (Week 7–8) — Polish + Report + Demo
```
[ ] Runbooks written
[ ] ADRs written
[ ] All documentation complete
[ ] Demo environment stable
[ ] Load test results documented
[ ] Chaos test results documented
[ ] ZAP report included in report
[ ] Individual contribution reports (2 pages per member)
```

---

*F4 Platform Team — Group F Smart Waste Management System*
*Lead: Hiruna | Repo: group-f-platform*
