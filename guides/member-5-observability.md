# Member 5: Observability Guru
## Domain: Monitoring, Logging, and Jaeger Tracing (Section 10)

### 📋 Overview
You provide the visibility required to manage a complex microservice ecosystem. If a request fails, you should be able to tell exactly where and why.

### 🛠️ Key Tasks
1. **Metrics & Dashboards (Prometheus/Grafana)**
   - Build the 4 critical dashboards (Operations, Performance, Health, Intelligence).
   - Set up AlertManager for Slack/Discord notifications on system failures.
2. **Distributed Tracing (Jaeger)**
   - Configure Istio to export trace spans to Jaeger.
   - Verify trace propagation: Kong -> Orchestrator -> Kafka -> Bin Status.
3. **Log Management (ELK)**
   - Deploy Elasticsearch, Logstash, and Kibana.
   - Configure Logstash to parse structured JSON logs for easy filtering by `trace_id`.

### 📖 Reference Paths
- **Dashboards/Alerts:** `monitoring/grafana/` & `monitoring/prometheus/`
- **ELK Config:** `monitoring/elk/`
- **Tracing:** `monitoring/jaeger/`

### 💡 Pro-Tips
- Use **Grafana Tempo** if you want to integrate traces directly into your Grafana dashboards.
- Ensure all microservices are using the `X-B3-TraceId` headers for consistent tracing.
