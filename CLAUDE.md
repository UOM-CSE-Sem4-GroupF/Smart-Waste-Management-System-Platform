# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> For full system context (domain model, Kafka topics, service inventory, architecture decisions), see `CLAUDE_guide.md` in this repo.

---

## What This Repo Is

This is the **F4 platform repo** — pure infrastructure configuration. There is no application code. Everything here produces Kubernetes manifests and Helm value overrides that Argo CD deploys to the cluster.

GitHub org: `UOM-CSE-Sem4-GroupF` — platform repo is `group-f-platform`.

---

## Development Commands

### Local cluster lifecycle (Minikube)
```bash
# Full local setup (idempotent — safe to re-run)
bash ./scripts/setup-local.sh

# Clean slate
minikube delete && minikube start && bash ./scripts/setup-local.sh

# Verify everything is up
kubectl get pods -A
```

Minikube requires 4 CPUs / 6 GB RAM / 20 GB disk. On Windows, Docker Desktop must be running first.

### DigitalOcean cloud deployment (DOKS)
```bash
export DO_TOKEN="dop_v1_..."          # from DigitalOcean dashboard
bash ./scripts/setup-doks.sh
```

This provisions the DOKS cluster via Terraform (`terraform/do/`), configures kubectl, then installs all platform services. Each service gets both a `values-dev.yaml` and a `values-doks.yaml` overlay (LoadBalancer IPs, storage class `do-block-storage`).

Destroy when not in use:
```bash
cd terraform/do && terraform destroy -var="do_token=$DO_TOKEN"
```

### Access services after local setup
```bash
# Kong proxy (API gateway)
minikube service kong-kong-proxy -n gateway

# Keycloak admin UI  →  admin / swms-admin-dev-2026
minikube service keycloak -n auth

# Vault UI  →  token: swms-vault-dev-root-token
kubectl port-forward -n auth svc/vault 30820:8200

# EMQX dashboard  →  admin / swms-emqx-dev-2026  (NodePort 31083)
```

On DOKS, use `kubectl port-forward` for Keycloak, Vault, and EMQX dashboard — only Kong and EMQX MQTT are exposed via LoadBalancer.

### Kafka debugging
```bash
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-topics.sh --list --bootstrap-server localhost:9092

kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-console-consumer.sh --topic <topic> --from-beginning \
  --bootstrap-server localhost:9092
```

### Apply individual config changes without re-running full setup
```bash
# Kong declarative config
kubectl apply -f ./gateway/kong/kong-config.yaml -n gateway

# Kafka topics (re-runs topic-init Job)
kubectl apply -f ./messaging/kafka/topics.yaml -n messaging

# Keycloak realm
kubectl create configmap keycloak-realm-config \
  --from-file=waste-management-realm.json=./auth/keycloak/realm-export.json \
  -n auth --dry-run=client -o yaml | kubectl apply -f -

# Vault policies / bootstrap
kubectl apply -f ./auth/vault/vault-policies.yaml -n auth

# Namespaces
kubectl apply -f ./namespaces/namespaces-dev.yaml
```

### Helm upgrades (after editing values files)
```bash
helm upgrade kafka oci://registry-1.docker.io/bitnamicharts/kafka \
  -n messaging -f ./messaging/kafka/values-dev.yaml

helm upgrade kong kong/kong \
  -n gateway -f ./gateway/kong/values-dev.yaml

helm upgrade keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
  -n auth -f ./auth/keycloak/values-dev.yaml

helm upgrade vault hashicorp/vault \
  -n auth -f ./auth/vault/values-dev.yaml

helm upgrade emqx emqx/emqx \
  -n messaging -f ./messaging/emqx/values-dev.yaml
```

On DOKS, append `-f ./messaging/kafka/values-doks.yaml` (etc.) to layer the cloud overrides.

### Cleanup
```bash
helm uninstall kong -n gateway
helm uninstall keycloak -n auth
helm uninstall kafka -n messaging
helm uninstall emqx -n messaging
helm uninstall vault -n auth

kubectl delete namespaces gateway auth messaging monitoring cicd blockchain waste-dev waste-prod
```

---

## Repository Structure

```
scripts/
  setup-local.sh          Idempotent Minikube full-stack setup
  setup-doks.sh           DigitalOcean DOKS cloud deployment (Terraform + Helm)

namespaces/
  namespaces-dev.yaml     All 8 K8s namespaces defined here

gateway/kong/
  kong-config.yaml        Kong DB-less declarative config (ConfigMap)
  values-dev.yaml         Kong Helm values (DB-less mode, NodePort 30080)
  values-doks.yaml        DOKS overrides (LoadBalancer, DO annotations)

auth/keycloak/
  realm-export.json       Full realm definition: roles, clients, test users
  realm-configmap.yaml    ConfigMap wrapper for realm-export.json
  external-secret.yaml    ExternalSecret (ESO) pulling Keycloak creds from Vault
  values-dev.yaml         Keycloak Helm values (NodePort 30180)
  values-doks.yaml        DOKS overrides

auth/vault/
  vault-policies.yaml     Vault bootstrap Job: seeds secrets + configures K8s auth
  values-dev.yaml         Vault Helm values (dev mode, NodePort 30820)

messaging/kafka/
  topics.yaml             K8s Job that creates all 13 Kafka topics
  external-secret.yaml    ExternalSecret pulling Kafka creds from Vault
  values-dev.yaml         Kafka Helm values (single KRaft broker, no Zookeeper)
  values-doks.yaml        DOKS overrides (3 brokers, persistent storage)

messaging/emqx/
  emqx-bootstrap.yaml     K8s Job: creates MQTT users + Kafka bridge rules
  bridge-deployment.yaml  Standalone EMQX–Kafka bridge deployment manifest
  external-secret.yaml    ExternalSecret pulling EMQX creds from Vault
  values-dev.yaml         EMQX Helm values (NodePort 31883/31083)
  values-doks.yaml        DOKS overrides

monitoring/
  values.yaml             kube-prometheus-stack Helm values

helm/charts/base-service/ Reusable Helm chart template for all F2/F3 services
  Chart.yaml
  values.yaml             Default values: image, service, resources, probes, HPA
  values-dev.yaml         Dev overrides
  values-prod.yaml        Prod overrides
  templates/              deployment, service, configmap, hpa, pvc

cicd/
  bootstrap/root-app.yaml App-of-Apps bootstrap — apply once after Argo CD install
  applications/           Per-platform-service Argo CD Applications (Kafka, Kong, etc.)
  appsets/services-dev.yaml ApplicationSet for F2/F3 services (Phase 2 — currently commented out)
  argocd/                 Argo CD Helm values, RBAC, Image Updater config
  projects/               Argo CD project definitions (platform, services)

infrastructure/
  eso/cluster-secret-store.yaml  ESO ClusterSecretStore pointing at Vault backend
```

---

## Key Patterns

### Adding a new Kong route
Edit `gateway/kong/kong-config.yaml` — add a new entry under `services:`. Kong runs in DB-less mode; the entire config is the single source of truth. Re-apply the ConfigMap and restart the Kong pod.

Kong blocks all `/internal/*` paths — services call each other via K8s DNS directly.

### Adding a Kafka topic
Add a `create_topic` call in `messaging/kafka/topics.yaml`. The Job uses `--if-not-exists` so it is safe to re-run. Topic naming convention: `waste.<entity>.<event>`.

### Adding a Keycloak role or client
Edit `auth/keycloak/realm-export.json`. For new service clients, add to the `clients` array. Roles are embedded in JWTs so downstream services never need a DB lookup.

### Seeding a new Vault secret
Edit `auth/vault/vault-policies.yaml` (the bootstrap Job). All secrets live under `secret/waste-mgmt/`. Vault injects them into pods as files at `/vault/secrets/` via the sidecar agent — never via environment variables.

### External Secrets Operator (ESO)
Vault → K8s Secret bridge: `infrastructure/eso/cluster-secret-store.yaml` defines a `ClusterSecretStore` using Vault's Kubernetes auth. Each service that needs a K8s Secret has a corresponding `external-secret.yaml` referencing paths under `secret/waste-mgmt/`. ESO syncs these automatically; Helm charts reference the resulting K8s Secrets.

### Onboarding a new F2/F3 service (Phase 2)
1. Create `apps/<service-name>/Chart.yaml` using `helm/charts/base-service/` as the parent chart.
2. Add `apps/<service-name>/values-dev.yaml` with the service image and env vars.
3. Uncomment `cicd/appsets/services-dev.yaml` (once first service is ready) — the ApplicationSet auto-generates an Argo CD Application per directory under `apps/`.
4. Argo CD Image Updater then watches GHCR and writes back `image.tag` to `values-dev.yaml` on each push.

### Argo CD App-of-Apps bootstrap
The `cicd/bootstrap/root-app.yaml` application watches `cicd/applications/` and manages all platform Applications. Bootstrap it once:
```bash
kubectl apply -n cicd -f cicd/bootstrap/root-app.yaml
```
After that, all changes to `cicd/applications/*.yaml` are auto-deployed.

### EMQX MQTT ↔ Kafka bridge rules
Configured in `messaging/emqx/emqx-bootstrap.yaml`. Current bridge:
- MQTT topic `sensors/#` → Kafka `waste.bin.telemetry`
- MQTT topic `vehicles/#` → Kafka `waste.vehicle.location`

---

## Dev Credentials (local only)

| Service | Credential |
|---|---|
| Keycloak admin | `admin` / `swms-admin-dev-2026` |
| Vault root token | `swms-vault-dev-root-token` |
| EMQX dashboard | `admin` / `swms-emqx-dev-2026` |
| MQTT sensor device | `sensor-device` / `swms-sensor-dev-2026` |
| MQTT edge gateway | `edge-gateway` / `swms-edge-dev-2026` |
| Keycloak test supervisor | `supervisor@swms-dev.local` / `swms-supervisor-dev` |
| Keycloak test driver | `driver@swms-dev.local` / `swms-driver-dev` |
