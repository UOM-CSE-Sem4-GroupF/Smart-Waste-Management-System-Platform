# Runbook: Kafka Consumer Lag Critical

**Alert:** `KafkaConsumerLagCritical`
**Condition:** Consumer group lag > 10,000 messages on any topic
**Severity:** Critical
**Team:** Platform / Data Engineering

---

## Overview

The Flink telemetry processor consumes from Kafka topics (primarily `waste.bin.telemetry` and `waste.vehicle.location`). When the lag grows beyond 10,000 the system is falling behind real-time sensor data, which delays route optimization and bin-full alerts. Common causes are: a stalled Flink job, a schema mismatch in incoming messages, or an under-resourced Flink pod that cannot keep up with EMQX burst traffic.

---

## Symptoms

- Prometheus/Alertmanager fires `KafkaConsumerLagCritical`.
- Grafana "Kafka Consumer Lag" panel shows one or more consumer groups with a rising offset delta.
- Bin-full or vehicle-location events are delayed or missing from dashboards.
- `flink-telemetry` pod may be in `CrashLoopBackOff` or showing high CPU / OOMKilled.

---

## Diagnosis

### 1. Check Flink pod status and logs

```bash
# Overall pod health in the messaging namespace
kubectl get pods -n messaging -l app=flink-telemetry

# Tail logs for the active pod
kubectl logs -n messaging -l app=flink-telemetry --tail=200

# If the pod is crash-looping, read the previous container's logs
kubectl logs -n messaging -l app=flink-telemetry --previous --tail=200
```

Look for:
- `SchemaRegistryException` or `DeserializationException` — schema mismatch.
- `OutOfMemoryError` — under-resourced, needs scaling.
- `KafkaException: Not leader for partition` — broker-side issue.

### 2. Check consumer group offsets

```bash
# Exec into the Kafka broker pod
kubectl exec -it kafka-broker-0 -n messaging -- bash

# List all consumer groups
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list

# Inspect lag for the Flink consumer group (adjust group name as needed)
kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group flink-telemetry-consumer-group
```

The output shows `CURRENT-OFFSET`, `LOG-END-OFFSET`, and `LAG` per partition. A lag of > 10,000 on any partition confirms the alert. Note which topics/partitions are affected.

### 3. Check Kafka broker health

```bash
# Broker pod status
kubectl get pods -n messaging -l app.kubernetes.io/name=kafka

# Broker logs — look for leader election or ISR shrinkage
kubectl logs -n messaging kafka-broker-0 --tail=100

# List topics and verify partition counts
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-topics.sh --list --bootstrap-server localhost:9092

# Describe a specific topic
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-topics.sh --describe \
  --topic waste.bin.telemetry \
  --bootstrap-server localhost:9092
```

---

## Fix Steps

### Fix A — Restart the Flink telemetry pod (first action, low risk)

```bash
kubectl rollout restart deployment/flink-telemetry -n messaging

# Watch rollout progress
kubectl rollout status deployment/flink-telemetry -n messaging
```

Wait 2–3 minutes and re-check consumer lag.

### Fix B — Scale up if lag continues to grow

```bash
# Increase replica count (ensure partition count >= replica count)
kubectl scale deployment/flink-telemetry -n messaging --replicas=3

# Verify new pods are Running
kubectl get pods -n messaging -l app=flink-telemetry
```

If the topic has fewer partitions than desired replicas, add partitions first:

```bash
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-topics.sh \
  --alter \
  --topic waste.bin.telemetry \
  --partitions 6 \
  --bootstrap-server localhost:9092
```

### Fix C — Investigate and fix schema errors

If logs show deserialization errors:

1. Identify the malformed messages:

```bash
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-console-consumer.sh \
  --topic waste.bin.telemetry \
  --from-beginning \
  --max-messages 20 \
  --bootstrap-server localhost:9092
```

2. If messages are malformed (sent by a buggy device firmware), reset the consumer group offset past the bad range:

```bash
# CAUTION: this skips messages. Only do this after confirming the range is garbage.
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group flink-telemetry-consumer-group \
  --topic waste.bin.telemetry \
  --reset-offsets \
  --to-latest \
  --execute
```

3. Restart the Flink pod after the offset reset.

### Fix D — Kafka broker is unhealthy

If broker pods are not all `Running`:

```bash
# Check StatefulSet status
kubectl get statefulset -n messaging

# Restart a specific broker pod (safe for KRaft single-broker dev setup)
kubectl delete pod kafka-broker-0 -n messaging

# On DOKS (3-broker setup), do a rolling restart
kubectl rollout restart statefulset/kafka -n messaging
```

---

## Verification

```bash
# Re-check lag — should trend toward 0
kubectl exec -it kafka-broker-0 -n messaging -- \
  kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group flink-telemetry-consumer-group

# Confirm Flink pods are stable
kubectl get pods -n messaging -l app=flink-telemetry

# Confirm no restart count is climbing
kubectl get pods -n messaging -l app=flink-telemetry \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STATUS:.status.phase'
```

Alert should auto-resolve in Alertmanager once lag drops below 10,000 for 5 consecutive minutes.

---

## Prevention

- Set resource `requests` and `limits` on the Flink deployment to avoid OOMKill during bursts (minimum: 1 CPU / 2 Gi RAM per replica).
- Use at least 3 partitions per topic so multiple Flink replicas can process in parallel from day one.
- Configure a dead-letter topic (`waste.bin.telemetry.dlq`) in the Flink job so malformed messages are parked rather than causing the consumer to stall.
- Add a Grafana alert on `kafka_consumer_lag > 1000` as an early warning (before the critical threshold).
- Test schema changes in a dev Kafka instance before rolling to production EMQX bridges.
