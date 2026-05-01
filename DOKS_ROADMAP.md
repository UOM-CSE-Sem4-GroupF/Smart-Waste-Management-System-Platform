# SWMS Platform: DOKS Migration Roadmap & Team Allocation

Based on the [f4-task-list.md](file:///e:/Porjects/sem%204/Software-Engineering/Smart-Wast-Management-System/Smart-Waste-Management-System-Platform/f4-task-list.md) and the current state of the DigitalOcean migration, here is the breakdown of remaining work, divided into phases and allocated to **4 team members**.

## 👥 Team Allocation (4 Members)

| Member | Primary Responsibilities |
| :--- | :--- |
| **Lead (Hiruna)** | Architecture, Cross-team Integration, Kong Gateway, Hyperledger Blockchain. |
| **Member 2** | DOKS Infrastructure (Terraform), Helm Charts (Services), Argo CD (GitOps). |
| **Member 3** | Security Hardening (Vault HA, Istio mTLS, OPA), Identity (Keycloak). |
| **Member 4** | Observability (Monitoring/Logging), CI/CD Pipelines, Databases (Postgres/Influx), Testing (Chaos/Load). |

---

## 🛠️ Phase 1: Foundation & Data (Weeks 1-2)
*Focus: Stabilizing the DOKS cluster and ensuring data persistence for F2/F3 teams.*

### [Member 2] Core Infrastructure
- [ ] Finalize `terraform/do` for full cluster provisioning with LoadBalancers.
- [ ] Migrate `helm/` charts to use DigitalOcean `do-block-storage` as default.
- [ ] Deploy Argo CD into `cicd` namespace for GitOps sync.

### [Member 4] Databases & Messaging
- [ ] Deploy **PostgreSQL** & **InfluxDB** with proper PVC storage.
- [ ] Deploy **Kafka** (3 brokers) and create all 12 core topics.
- [ ] Configure **EMQX** with the Kafka bridge for live telemetry.

### [Member 3] Identity Migration
- [ ] Deploy **Keycloak** and import `realm-export.json`.
- [ ] Configure **Vault** (Dev Mode initially) for secret injection.

### [Lead] Gateway & Integration
- [ ] Configure **Kong Gateway** with public LB IP for external access.
- [ ] Verify E2E flow: Edge Simulator -> EMQX -> Kafka -> Consumer.

---

## 🛡️ Phase 2: Security & Visibility (Weeks 3-4)
*Focus: Hardening the platform and enabling full observability.*

### [Member 3] Security Hardening
- [ ] Move **Vault** to 3-node HA mode with Kubernetes Auth.
- [ ] Install **Istio** and enable mTLS STRICT across all namespaces.
- [ ] Implement **OPA** policies for service-level authorization.

### [Member 4] Observability Stack
- [ ] Deploy **Prometheus & Grafana** with the standard SWMS dashboards.
- [ ] Set up **ELK Stack** (Elasticsearch, Logstash, Kibana) for log aggregation.
- [ ] Configure **Jaeger** for distributed tracing across Istio.

### [Member 2 & Lead] App Onboarding
- [ ] Work with F2/F3 to deploy their service charts via Argo CD.
- [ ] Set up Kong routes and rate-limiting for all F3 API endpoints.

---

## 🚀 Phase 3: Validation & Handoff (Weeks 5-8)
*Focus: Proof-of-recovery, performance validation, and final reports.*

### [Member 4] Testing & CI/CD
- [ ] Implement and run **Chaos Mesh** experiments (Pod kills, network delays).
- [ ] Execute **k6 load tests** to verify p99 latency targets.
- [ ] Finalize GitHub Actions reusable workflows for F1/F2/F3 groups.

### [Lead] Blockchain & Report
- [ ] Deploy **Hyperledger Fabric** network and `collection-record` chaincode.
- [ ] Draft **Section 5 (Security & Deployment)** of the final project report.
- [ ] Consolidate all team member individual contribution reports.

### [Member 2 & 3] Final Hardening
- [ ] Run **Trivy** scans and **OWASP ZAP** pentests.
- [ ] Configure Automated Daily Backups for PostgreSQL.
