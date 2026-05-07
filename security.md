# Member 3: Security & Mesh Architect
## Domain: Istio Security, OPA, and mTLS (Section 7 & 14.1)

### 📋 Overview
You are responsible for the cluster's internal "Shield." You must ensure that only authorized services can talk to each other and that no insecure configurations are deployed.

### 🛠️ Key Tasks
1. **Istio AuthorizationPolicies**
   - Implement the 6+ specific access rules.
   - Example: Only `orchestrator` should have permission to call `scheduler/internal/*`.
2. **OPA Admission Control**
   - Write Rego policies for the Kubernetes Admission Controller.
   - Rule 1: Block any pod that tries to run with `allowPrivilegeEscalation: true`.
   - Rule 2: Enforce mandatory labels (`app`, `version`) on all deployments.
3. **mTLS Enforcement**
   - Apply `PeerAuthentication` with `mode: STRICT` to the `waste-dev` and `messaging` namespaces.

### 📖 Reference Paths
- **Istio Config:** `infrastructure/istio/`
- **Security Policies:** `security/opa/`

### 💡 Pro-Tips
- Use `istioctl proxy-config` to verify if your AuthPolicies are actually being pushed to the sidecars.
- Test your OPA policies using the `opa test` command before deploying the ConfigMap.
