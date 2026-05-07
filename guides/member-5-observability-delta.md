# Member 5: Observability Delta List
## Supplementary Tasks & Technical Specifications

This document lists the specific missing pieces that must be implemented to reach 100% compliance with Section 10 of the `f4-task-list.md`.

### 1. Missing Dashboard Details
While basic dashboards exist, the following specific visualizations are missing and must be added:
- **Performance Dashboard**:
  - CPU/Memory usage per pod/namespace.
  - Kafka Producers/Consumers throughput (messages/sec).
  - Network I/O for the Kong Gateway.
- **Waste Intelligence**:
  - Zone fill level heatmap.
  - Prediction accuracy: Predicted vs. Actual fill time chart.

### 2. Required Alert Rules (Prometheus)
Implement the following specific rules in `monitoring/prometheus/rules/custom_alerts.yaml`:

| Severity | Condition | Description |
|----------|-----------|-------------|
| CRITICAL | `bin_fill == 100` AND `active_job == 0` | Bin overflowing |
| CRITICAL | `kafka_consumer_lag > 10000` for 5m | F2 processing falling behind |
| CRITICAL | `pod_status == CrashLoopBackOff` | Service down |
| WARNING | No readings from zone for > 30m | Sensor outage |
| WARNING | `job_state == ESCALATED` | No vehicle found |
| WARNING | `vehicle_deviation > 500m` for 3m | Driver off route |
| WARNING | `vault_sealed == 1` | All secrets unavailable |
| INFO | `waste_model_retrained` event | ML model promoted |

### 3. Logstash Pipeline Hardening
Update `monitoring/elk/logstash/logstash.conf` to specifically parse these fields:
- `timestamp`
- `level`
- `service`
- `message`
- `traceId` (Crucial for Jaeger integration)
- **Retention**: Configure the Elasticsearch Index Lifecycle Management (ILM) for a **30-day retention**.

### 4. Jaeger Tracing Configuration
- **Sampling Rate**: Ensure the ConfigMap sets `sampling_rate: 1.0` (100%) for Dev and `0.1` (10%) for Prod.
- **Trace Propagation**: Verify that Node.js services are correctly forwarding the `X-B3-TraceId` headers to Kafka.

### 5. Shared Resources
- **Reference**: Review the `monitoring/README.md` for existing internal cluster URLs for Grafana and Kibana.
