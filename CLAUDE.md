# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> For full system context (domain model, Kafka topics, service inventory, architecture decisions), see `CLAUDE_guide.md` in this repo.

---

## What This Repo Is

This is the **F4 platform repo** — pure infrastructure configuration. There is no application code. Everything here produces Kubernetes manifests and Helm value overrides that Argo CD deploys to the cluster.

---

## Development Commands

### Cluster lifecycle
```bash
# Full local setup (idempotent — safe to re-run)
bash ./scripts/setup-local.sh

# Clean slate
minikube delete && minikube start && bash ./scripts/setup-local.sh

# Verify everything is up
kubectl get pods -A
```

### Access services after setup
```bash
# Kong proxy (API gateway)
minikube service kong-kong-proxy -n gateway

# Keycloak admin UI  →  admin / swms-admin-dev-2026
minikube service keycloak -n auth

# Vault UI  →  token: swms-vault-dev-root-token
# (NodePort 30820 — use minikube tunnel or port-forward)
kubectl port-forward -n auth svc/vault 30820:8200

# EMQX dashboard  →  admin / swms-emqx-dev-2026
# (NodePort 31083)
```

### Kafka debugging
```bash
# List topics
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-topics.sh --list --bootstrap-server localhost:9092

# Tail a topic (replace <topic>)
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
```

### Cleanup
```bash
helm uninstall kong -n gateway
helm uninstall keycloak -n auth
helm uninstall kafka -n messaging
helm uninstall emqx -n messaging
helm uninstall vault -n auth

# Nuke all namespaces
kubectl delete namespaces gateway auth messaging monitoring cicd blockchain waste-dev waste-prod
```

---

## Repository Structure

```
scripts/
  setup-local.sh          Idempotent full-stack setup (run this first)

namespaces/
  namespaces-dev.yaml     All 8 K8s namespaces defined here

gateway/kong/
  kong-config.yaml        Kong DB-less declarative config (ConfigMap)
                          Add new service routes here — applied as a K8s ConfigMap
  values-dev.yaml         Kong Helm values (DB-less mode, NodePort 30080)

auth/keycloak/
  realm-export.json       Full realm definition: roles, clients, test users
                          Mounted as a ConfigMap; Keycloak imports on first start
  values-dev.yaml         Keycloak Helm values (NodePort 30180)

auth/vault/
  vault-policies.yaml     Vault bootstrap Job: seeds secrets + configures K8s auth
  values-dev.yaml         Vault Helm values (dev mode, NodePort 30820)

messaging/kafka/
  topics.yaml             K8s Job that creates all 13 Kafka topics with retention config
  values-dev.yaml         Kafka Helm values (single KRaft broker, no Zookeeper)

messaging/emqx/
  emqx-bootstrap.yaml     K8s Job: creates MQTT users + Kafka bridge rules
  values-dev.yaml         EMQX Helm values (NodePort 31883 for MQTT, 31083 for dashboard)
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

---

## Minikube Resource Requirements

`setup-local.sh` starts Minikube with 4 CPUs / 6 GB RAM / 20 GB disk. This is the minimum to run Kafka + Keycloak + Kong + Vault + EMQX simultaneously. On Windows, Docker Desktop must be running before the script is invoked.
