# 📁 SWMS Kafka Topic Registry — v2.0

**Project**: Smart Waste Management System (SWMS)
**Registry Owner**: F4 Platform Group

This document lists all **11 active Kafka topics** provisioned in the EKS cluster. These topics are created automatically via the `kafka-topic-init` job.

> **v2.0 Changes**: Removed `waste.bin.status.changed`, `waste.collection.jobs`, and `waste.routes.optimized` — OR-Tools is now a synchronous REST service called directly by the scheduler. Added `waste.bin.dashboard.updates` and `waste.vehicle.dashboard.updates` for the pre-enriched dashboard streaming pipeline.

---

## 🏗️ 1. Ingestion Layer (Edge ➡️ F2 Flink)

| Topic Name | Partitions | Retention | Purpose |
| :--- | :--- | :--- | :--- |
| `waste.bin.telemetry` | 6 | 7 Days | Raw JSON sensor readings from ESP32 bins. |
| `waste.vehicle.location` | 6 | 7 Days | Real-time GPS coordinates from garbage trucks. |

---

## ⚡ 2. Processing & Action Layer (F2 ➡️ F3 Orchestration)

| Topic Name | Partitions | Retention | Purpose |
| :--- | :--- | :--- | :--- |
| `waste.bin.processed` | 6 | 3 Days | Flink-enriched telemetry with urgency scores. |
| ~~`waste.bin.status.changed`~~ | ~~3~~ | ~~3 Days~~ | ~~**REMOVED v2.0** — High-level status transitions. Replaced by `waste.bin.dashboard.updates`.~~ |
| ~~`waste.collection.jobs`~~ | ~~3~~ | ~~7 Days~~ | ~~**REMOVED v2.0** — OR-Tools is now a synchronous REST call from the scheduler, not a Kafka consumer.~~ |
| ~~`waste.routes.optimized`~~ | ~~3~~ | ~~1 Day~~ | ~~**REMOVED v2.0** — OR-Tools returns its result directly in the HTTP response to the scheduler.~~ |
| `waste.routine.schedule.trigger` | 3 | 1 Day | Automated triggers from Airflow DAGs. |
| `waste.zone.statistics` | 3 | 7 Days | Zone aggregation output from Flink sliding window (every 2 min). Consumed by F3 bin-status-service. |

---

## 📊 3. Dashboard Streaming Layer (F3 Services ➡️ Notification Service)

| Topic Name | Partitions | Retention | Purpose |
| :--- | :--- | :--- | :--- |
| `waste.bin.dashboard.updates` | 6 | 5 Min | **NEW v2.0** — Pre-enriched bin state events published by bin-status-service. Notification service streams directly to dashboard via Socket.IO without further processing. |
| `waste.vehicle.dashboard.updates` | 6 | 5 Min | **NEW v2.0** — Pre-enriched vehicle position events published by scheduler-service. Notification service streams directly to dashboard via Socket.IO without further processing. |

---

## 🚚 4. Operational Layer (Drivers ➡️ F3)

| Topic Name | Partitions | Retention | Purpose |
| :--- | :--- | :--- | :--- |
| `waste.driver.responses` | 3 | 1 Day | Driver interaction (Accept/Reject/Complete job). |
| `waste.vehicle.deviation` | 3 | 1 Day | Alerts when a truck leaves its optimised path. |

---

## 📜 5. Analytics & Governance (F2/F3 ➡️ F4)

| Topic Name | Partitions | Retention | Purpose |
| :--- | :--- | :--- | :--- |
| `waste.job.completed` | 3 | 30 Days | Finalised job records for billing and analytics. |
| `waste.audit.events` | 3 | 365 Days | **Long-term logs** for Hyperledger blockchain sync. |
| `waste.model.retrained` | 3 | 1 Day | ML model promotion notifications from Spark/Airflow. |

---

## 🛠️ Management Configuration

- **Automatic Topic Creation**: `DISABLED`
- **Default Replication Factor**: 1 (Developer Mode)
- **Minimum In-Sync Replicas**: 1

### Active topic count: 11
### Removed topics (do not recreate): `waste.bin.status.changed`, `waste.collection.jobs`, `waste.routes.optimized`
