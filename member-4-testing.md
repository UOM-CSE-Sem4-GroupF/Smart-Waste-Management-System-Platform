# Member 4: Quality & DevSecOps Engineer
## Domain: Chaos Mesh, k6, and Security Scans (Section 14 & 15)

### 📋 Overview
Your mission is to find the breaking points of our system. You provide the evidence that our platform is both resilient to failure and secure from attack.

### 🛠️ Key Tasks
1. **Chaos Mesh Experiments**
   - Implement "Pod Chaos" and "Network Chaos" scenarios.
   - Goal: Prove the system remains consistent even if a Kafka broker or an API instance vanishes.
2. **k6 Load Testing**
   - Write JS scripts to simulate heavy traffic spikes (1,000+ RPS).
   - Target the Kong Gateway to verify HPA (Horizontal Pod Autoscaling) triggers correctly.
3. **Automated Security Audits**
   - **Trivy:** Integrate container scanning into the CI/CD pipeline (block HIGH/CRITICAL).
   - **OWASP ZAP:** Run weekly penetration tests against the `https://api.swms.live` endpoint.

### 📖 Reference Paths
- **Chaos Configs:** `tests/chaos/`
- **Load Test Scripts:** `tests/performance/`
- **Scan Results:** `security/reports/`

### 💡 Pro-Tips
- Use the **k6-operator** to run tests from within the cluster for more accurate internal latency measurements.
- Capture screenshots of the Chaos Mesh dashboard during failures for the final project report.
