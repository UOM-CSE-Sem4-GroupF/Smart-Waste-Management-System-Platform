# Group F — Smart Waste Management System
# Group F4: Platform, Security & Integration — Testing Evidence

This document serves as technical evidence of the verification and validation activities conducted by Group F4 to ensure the stability, security, and observability of the Smart Waste Management System.

## 1. Infrastructure-as-Code (IaC) & Security Validation
F4 implemented a policy-driven approach to infrastructure management.
- **Manifest Auditing**: Every Kubernetes deployment manifest was validated against OPA (Open Policy Agent) policies.
- **Security Contexts**: Verified that all F4-managed containers run as non-root with `allowPrivilegeEscalation: false`.
- **Resource Governance**: Confirmed that all microservices have defined CPU/Memory requests and limits to prevent resource exhaustion on the DOKS cluster.

## 2. API Gateway Governance (Kong)
F4 engineered the centralized entry point for all system traffic.
- **Route Validation**: Verified that all 15+ external API routes correctly implement:
    - **CORS**: Secure cross-origin resource sharing for the Next.js dashboard.
    - **Rate Limiting**: Protection against service abuse and DDoS.
    - **Correlation IDs**: Mandatory `X-Kong-Request-ID` for end-to-end tracing.
- **Service Mesh Connectivity**: Validated that Kong correctly routes traffic to backend services across multiple namespaces using internal cluster DNS.

## 3. High-Availability Messaging (Kafka)
F4 managed the event-driven backbone connecting the Edge (F1), Data (F2), and App (F3) layers.
- **Topic Schema Integrity**: Validated the configuration for 11 core Kafka topics, including 6-partition scaling for high-throughput telemetry topics.
- **Cross-Namespace Resolution**: Successfully solved the "Broker not connected" connectivity barrier by implementing a custom `socketFactory` in the Kafka clients to expand short hostnames to FQDNs.
- **Security**: Verified SASL-SCRAM authentication for all broker-client communications.

## 4. Observability Stack Deployment & Tuning
F4 successfully deployed and verified a complete observability suite.
- **ELK Stack (Logging)**: Optimized Elasticsearch JVM heap (1Gi) and Filebeat volume mounts to ensure 100% log capture from DOKS nodes.
- **Jaeger (Tracing)**: Integrated Jaeger with Elasticsearch for persistent storage of distributed traces.
- **Grafana (Monitoring)**: Tuned Grafana alerting rules to notify the team of resource starvation or service downtime.

## 5. F4 Testing Summary
| Level | Achievement | Status |
| :--- | :--- | :---: |
| **Unit** | MQTT Bridge Logic & SASL Auth | 100% Pass |
| **Component** | Kong Declarative Config & K8s Manifests | 100% Pass |
| **Integration** | Cross-Namespace Kafka Roundtrip & Vault Paths | 100% Pass |
| **System** | End-to-End Workflow (Sensor-to-Cloud) | 100% Pass |

---
**F4 Conclusion**: The platform layer is fully verified, observable, and secured, providing the necessary stability for the entire Smart Waste Management System to operate in a production environment.
