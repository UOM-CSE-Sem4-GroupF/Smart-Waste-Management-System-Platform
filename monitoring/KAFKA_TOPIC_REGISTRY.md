# Group F — Smart Waste Management System
# Technical Artifact: Kafka Topic Registry (v2.0)

This registry documents the event-driven communication backbone of the Smart Waste Management System. All topics are initialized via the `kafka-topic-init` K8s job.

## 1. Ingestion Layer
These topics handle raw telemetry from edge devices and GPS trackers.

| Topic Name | Partitions | Retention | Description |
| :--- | :---: | :--- | :--- |
| `waste.bin.telemetry` | 6 | 7 Days | Raw fill-level and status data from bins. |
| `waste.vehicle.location` | 6 | 7 Days | Real-time GPS coordinates from collection vehicles. |

## 2. Processing & Action Layer
Intermediate topics used by Flink and Spark for data enrichment and state management.

| Topic Name | Partitions | Retention | Description |
| :--- | :---: | :--- | :--- |
| `waste.bin.processed` | 6 | 3 Days | Enriched bin data (fill-time prediction + anomalies). |
| `waste.routine.schedule.trigger` | 3 | 1 Day | Signal to generate collection routes for the day. |
| `waste.zone.statistics` | 3 | 7 Days | Aggregated zone metrics for regional optimization. |

## 3. Dashboard Streaming Layer
Low-retention topics optimized for high-throughput real-time UI updates.

| Topic Name | Partitions | Retention | Description |
| :--- | :---: | :--- | :--- |
| `waste.bin.dashboard.updates` | 6 | 5 Mins | Compressed bin updates for the Next.js dashboard. |
| `waste.vehicle.dashboard.updates` | 6 | 5 Mins | Live vehicle positioning for the dashboard map. |

## 4. Operational Layer
Topics driving the daily workflow between dispatchers and drivers.

| Topic Name | Partitions | Retention | Description |
| :--- | :---: | :--- | :--- |
| `waste.driver.responses` | 3 | 1 Day | Job accept/reject signals from driver handhelds. |
| `waste.vehicle.deviation` | 3 | 1 Day | Alerts when vehicles leave assigned geofence areas. |

## 5. Analytics & Governance (Audit Trail)
Long-term storage for reporting, compliance, and ML model training.

| Topic Name | Partitions | Retention | Description |
| :--- | :---: | :--- | :--- |
| `waste.job.completed` | 3 | 30 Days | Summary records of every finished collection job. |
| `waste.audit.events` | 3 | 365 Days | Immutable system-wide audit trail (Security/Compliance). |
| `waste.model.retrained` | 3 | 1 Day | Metadata for updated fill-time prediction models. |

---
**Owner:** F4 Platform Team  
**Last Updated:** 2026-05-08  
**Standard:** Platform Contract v1.4
