# Runbook: Vault Sealed

**Alert:** `VaultSealed`
**Condition:** `vault_core_unsealed == 0` (Vault is in sealed state)
**Severity:** Critical
**Team:** Platform / Security

---

## Overview

HashiCorp Vault is the secrets backend for the entire SWMS platform. When Vault is sealed, all pods relying on Vault injection (via the sidecar agent) cannot start, External Secrets Operator (ESO) cannot sync, and new pods that need secrets will fail their `init` containers. Vault seals on pod restart if the `postStart` unseal hook did not run or if the unseal keys are missing. In dev mode (`dev: true` in `auth/vault/values-dev.yaml`), Vault should auto-unseal; a sealed state in dev mode means the pod restarted and the hook failed.

All Vault resources live in the `auth` namespace.

---

## Symptoms

- Prometheus fires `VaultSealed`.
- `vault_core_unsealed` metric is `0` in Grafana.
- New pods that use Vault agent injection are stuck in `Init:0/1` or `Init:Error`.
- ESO `ExternalSecret` objects report `SecretSyncedError` or `ProviderError`.
- Keycloak, Kafka, or EMQX pods fail to start (they depend on Vault-injected secrets).
- `kubectl exec` into Vault returns `Error initializing: Vault is sealed`.

---

## Diagnosis

### 1. Confirm Vault pod is Running and check its status

```bash
# Pod health
kubectl get pods -n auth -l app.kubernetes.io/name=vault

# Vault status (sealed/unsealed, HA mode, etc.)
kubectl exec -it vault-0 -n auth -- vault status
```

If `Sealed: true` is in the output, proceed below.

### 2. Check Vault pod logs for the unseal hook

```bash
# Current logs
kubectl logs -n auth vault-0 --tail=200

# Previous container logs (if the pod has restarted)
kubectl logs -n auth vault-0 --previous --tail=200
```

Look for:
- `postStart hook failed` — the lifecycle hook that unseals on startup did not execute.
- `connection refused` or `dial tcp` errors before the hook ran — Vault was not ready when the hook fired.
- `permission denied` — the hook script could not read the unseal key.

### 3. Verify the vault-init-keys Secret exists

```bash
kubectl get secret vault-init-keys -n auth

# Decode the unseal key (base64)
kubectl get secret vault-init-keys -n auth \
  -o jsonpath='{.data.unseal-key}' | base64 -d
```

If the Secret is missing, the bootstrap Job has not run or the Secret was deleted. Jump to Fix B.

### 4. Check ExternalSecret sync errors (downstream impact)

```bash
kubectl get externalsecret -A
kubectl describe externalsecret keycloak-secrets -n auth
kubectl describe externalsecret kafka-credentials -n messaging
```

---

## Fix Steps

### Fix A — Re-run the Vault bootstrap Job (primary fix)

The bootstrap Job in `auth/vault/vault-policies.yaml` seeds secrets, creates policies, and configures Kubernetes auth. Re-applying it is idempotent.

```bash
# From the repo root
kubectl apply -f auth/vault/vault-policies.yaml -n auth

# Watch the Job
kubectl get job -n auth
kubectl logs -n auth -l job-name=vault-bootstrap --follow
```

If the Job completes successfully, Vault should be unsealed and secrets seeded. Continue to Verification.

### Fix B — Manual unseal using the unseal key

Use this when the bootstrap Job cannot run or when Vault needs an immediate unseal.

```bash
# Step 1: Retrieve the unseal key
UNSEAL_KEY=$(kubectl get secret vault-init-keys -n auth \
  -o jsonpath='{.data.unseal-key}' | base64 -d)

# Step 2: Unseal Vault
kubectl exec -it vault-0 -n auth -- vault operator unseal "$UNSEAL_KEY"
```

Vault requires only 1 unseal key in dev/single-share mode (threshold = 1). On a production setup with Shamir secret sharing (threshold = 3 of 5), you need to run `vault operator unseal` three times with three different keys.

After unsealing, verify:

```bash
kubectl exec -it vault-0 -n auth -- vault status
# Sealed: false
```

### Fix C — Vault pod is not Running at all

```bash
# Check pod events
kubectl describe pod vault-0 -n auth

# Restart the StatefulSet pod
kubectl delete pod vault-0 -n auth
# Kubernetes will reschedule it; then repeat Fix A or Fix B
```

### Fix D — Force ESO to re-sync after Vault is unsealed

```bash
# Annotate each ExternalSecret to trigger immediate re-sync
kubectl annotate externalsecret keycloak-secrets -n auth \
  force-sync=$(date +%s) --overwrite

kubectl annotate externalsecret kafka-credentials -n messaging \
  force-sync=$(date +%s) --overwrite

kubectl annotate externalsecret emqx-credentials -n messaging \
  force-sync=$(date +%s) --overwrite
```

---

## Verification

```bash
# Vault should report Sealed: false
kubectl exec -it vault-0 -n auth -- vault status

# ESO secrets should be Ready
kubectl get externalsecret -A

# Downstream pods that were stuck should now start
kubectl get pods -n auth
kubectl get pods -n messaging
kubectl get pods -n gateway

# Quick smoke-test: list Vault secret engines (requires a valid token)
ROOT_TOKEN="swms-vault-dev-root-token"
kubectl exec -it vault-0 -n auth -- \
  vault login "$ROOT_TOKEN"
kubectl exec -it vault-0 -n auth -- \
  vault secrets list
```

Alert auto-resolves once `vault_core_unsealed == 1` is scraped by Prometheus (up to 1 scrape interval, typically 30 s).

---

## Prevention

- In non-dev clusters, use Vault Auto Unseal with a cloud KMS provider (AWS KMS, GCP CKMS, or DigitalOcean's equivalent) so Vault unseals automatically after a pod restart without human intervention.
- Store the `vault-init-keys` Secret in a location outside the cluster (e.g., a DigitalOcean managed secret or a separate Vault instance) so it survives cluster rebuilds.
- Alert on `vault_core_unsealed == 0` with a 2-minute pending window to catch transient restarts before ESO or services notice.
- Configure a Vault `readinessProbe` (already in the Helm chart default) and a `startupProbe` so that the unseal `postStart` hook has adequate time to fire before the pod is marked ready.
- Periodically test the manual unseal procedure in staging so the team is practiced before a production incident.
