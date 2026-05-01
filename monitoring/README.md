# Monitoring Setup — Prometheus + Grafana

**Owner:** F4 Platform Team  
**Namespace:** `monitoring`

---

## What This Sets Up

- **Prometheus** — collects metrics from all services in the cluster
- **Grafana** — displays dashboards and alerts
- **Alertmanager** — sends alerts when something goes wrong

---

## How to Deploy

### Prerequisites
- Minikube running
- Helm installed

### Install

```bash
# Add the Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install Prometheus + Grafana
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values values.yaml
```

### Check it's running

```bash
kubectl --namespace monitoring get pods
```

All pods should show `Running`.

---

## Accessing Grafana

```bash
# Get password
kubectl --namespace monitoring get secrets monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo

# Port forward
export POD_NAME=$(kubectl --namespace monitoring get pod \
  -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=monitoring" -oname)
kubectl --namespace monitoring port-forward $POD_NAME 3000
```

Open: http://localhost:3000  
Username: `admin`  
Password: *(from command above)*

---

## Accessing Prometheus

```bash
kubectl --namespace monitoring port-forward \
  svc/monitoring-kube-prometheus-prometheus 9090
```

Open: http://localhost:9090

---

## Key Metrics Tracked

| Metric | Description |
|--------|-------------|
| `waste_bins_urgent_total` | Number of urgent bins needing collection |
| `waste_collection_jobs_active` | Active lorry collection jobs |
| `waste_lorry_cargo_utilisation` | How full each lorry is |
| `kafka_consumer_lag` | Whether F2 is keeping up with sensor data |

---

## Alerts Configured

| Alert | Severity | Condition |
|-------|----------|-----------|
| BinOverflow | CRITICAL | Bin 100% full with no active job |
| KafkaConsumerLag | CRITICAL | Consumer lag > 10,000 messages |
| ZoneSensorOutage | WARNING | No sensor reading from zone for 30+ min |
| JobEscalated | WARNING | No driver found after retries |
| VehicleDeviation | WARNING | Lorry > 500m off planned route |
| PodCrashLoop | CRITICAL | Any service pod crash looping |
