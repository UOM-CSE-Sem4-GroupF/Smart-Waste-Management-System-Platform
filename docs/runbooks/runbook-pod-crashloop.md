# Runbook: Pod CrashLoopBackOff

**Alert:** `PodCrashLoopBackOff`
**Condition:** A pod in `waste-dev`, `messaging`, `gateway`, or `auth` has restarted > 5 times in 10 minutes
**Severity:** High
**Team:** Platform

---

## Overview

`CrashLoopBackOff` means Kubernetes is restarting a container repeatedly because it exits with a non-zero code. In the SWMS platform the most common root causes are:

1. An `ExternalSecret` failed to sync from Vault, so the pod starts without required credentials and immediately panics.
2. A new image was pushed to GHCR with a bug (Argo CD Image Updater auto-updated the tag).
3. The image cannot be pulled (wrong tag, missing registry credentials, rate limit).
4. The pod exceeds its memory `limit` and is OOMKilled before it finishes starting.
5. A missing ConfigMap or misreferenced environment variable.

This runbook covers all namespaces managed by the platform repo: `waste-dev`, `waste-prod`, `messaging`, `gateway`, `auth`.

---

## Symptoms

- Prometheus / Alertmanager fires `PodCrashLoopBackOff`.
- `kubectl get pods -A` shows `CrashLoopBackOff` or high `RESTARTS` count.
- Affected service is returning errors or is completely down (check Grafana service health panels).
- Argo CD UI shows the application as `Degraded`.

---

## Diagnosis

### 1. Identify the crashing pod

```bash
# Scan all platform namespaces for unhealthy pods
kubectl get pods -n waste-dev
kubectl get pods -n waste-prod
kubectl get pods -n messaging
kubectl get pods -n gateway
kubectl get pods -n auth

# Or get a combined view sorted by restarts (requires kubectl 1.26+)
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -20
```

### 2. Read the pod events (often reveals the root cause immediately)

```bash
# Replace <pod-name> and <namespace> with actual values
kubectl describe pod <pod-name> -n <namespace>
```

Look at the `Events` section at the bottom. Key messages to look for:

| Event message | Likely cause |
|---|---|
| `Back-off pulling image` | Image tag does not exist or registry credentials missing |
| `ErrImagePull` / `ImagePullBackOff` | Same as above — image pull failure |
| `OOMKilled` | Container exceeded memory limit |
| `Error: secret ... not found` | ExternalSecret did not sync |
| `exec format error` | Wrong architecture image (e.g., ARM image on AMD64 node) |
| `Liveness probe failed` | App started but is unhealthy; check app logs |

### 3. Read the previous container logs

```bash
# Logs from the crashed container (most useful)
kubectl logs <pod-name> -n <namespace> --previous

# If the pod has multiple containers, specify the container
kubectl logs <pod-name> -n <namespace> -c <container-name> --previous

# Tail current logs if the pod keeps briefly starting
kubectl logs <pod-name> -n <namespace> --follow
```

### 4. Check ExternalSecret sync status

All service secrets come from Vault via ESO. If Vault was sealed or the secret path changed, ESO will fail to sync.

```bash
# Check all ExternalSecrets across namespaces
kubectl get externalsecret -A

# Describe the ExternalSecret for the affected namespace
kubectl describe externalsecret -n <namespace>
```

A healthy ESO object shows `READY: True` and `STATUS: SecretSynced`. Any other status means the K8s Secret the pod depends on is missing or stale.

### 5. Check image pull status

```bash
# See which image the pod is trying to pull
kubectl get pod <pod-name> -n <namespace> \
  -o jsonpath='{.spec.containers[*].image}'

# Check if imagePullSecrets are mounted
kubectl get pod <pod-name> -n <namespace> \
  -o jsonpath='{.spec.imagePullSecrets}'

# Check the GHCR pull secret exists
kubectl get secret ghcr-pull-secret -n <namespace>
```

---

## Fix Steps

### Fix A — ExternalSecret not synced (most common cause)

```bash
# Force ESO to re-sync immediately by annotating with a new timestamp
kubectl annotate externalsecret <externalsecret-name> -n <namespace> \
  force-sync=$(date +%s) --overwrite

# Watch the sync status
kubectl get externalsecret <externalsecret-name> -n <namespace> -w
```

Once the ExternalSecret shows `SecretSynced`, delete the crashing pod so Kubernetes recreates it with the now-present Secret:

```bash
kubectl delete pod <pod-name> -n <namespace>
```

If ESO cannot sync because Vault is sealed, follow the `runbook-vault-seal.md` first.

### Fix B — Bad image tag pushed by Argo CD Image Updater

```bash
# Check what image tag Argo CD deployed
kubectl get deployment <deployment-name> -n <namespace> \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Pin to the last known-good tag by editing the values file in the repo
# (then Argo CD will sync back automatically)
# OR, as an emergency override:
kubectl set image deployment/<deployment-name> \
  <container-name>=ghcr.io/uom-cse-sem4-groupf/<service>:<last-good-tag> \
  -n <namespace>

# Verify the rollout
kubectl rollout status deployment/<deployment-name> -n <namespace>
```

After stabilizing, revert the image tag in `apps/<service-name>/values-dev.yaml` and push to git so Argo CD tracks the correct state.

### Fix C — Image pull failure (missing registry credentials)

```bash
# Recreate the GHCR pull secret if missing
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat> \
  --docker-email=<email> \
  -n <namespace> \
  --dry-run=client -o yaml | kubectl apply -f -

# Delete the failing pod to trigger a fresh pull with the new secret
kubectl delete pod <pod-name> -n <namespace>
```

### Fix D — OOMKilled (container exceeds memory limit)

```bash
# Check the current limit
kubectl get pod <pod-name> -n <namespace> \
  -o jsonpath='{.spec.containers[0].resources}'

# Temporarily patch the deployment to raise the limit
kubectl patch deployment <deployment-name> -n <namespace> \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"512Mi"}]'

# Update the permanent value in apps/<service>/values-dev.yaml and commit
```

### Fix E — General restart after config change

```bash
# Rolling restart without changing anything (picks up updated ConfigMaps/Secrets)
kubectl rollout restart deployment/<deployment-name> -n <namespace>
kubectl rollout status deployment/<deployment-name> -n <namespace>
```

---

## Verification

```bash
# All pods in the affected namespace should be Running with 0 or stable RESTARTS
kubectl get pods -n <namespace>

# No events of type Warning for the pod
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# ExternalSecrets are all synced
kubectl get externalsecret -A

# Argo CD application is Healthy and Synced
# (check Argo CD UI or CLI)
# argocd app get <app-name>
```

Alert auto-resolves once the pod restart rate drops below the threshold for 10 minutes.

---

## Prevention

- Always set `resources.requests` and `resources.limits` in the base Helm chart (`helm/charts/base-service/values.yaml`) to prevent OOMKill at startup.
- Configure liveness and readiness probes with a generous `initialDelaySeconds` (30–60 s) so pods are not killed before Vault injection finishes.
- Use Argo CD Image Updater with a `semver` constraint (e.g., `~1.2`) rather than `latest` to prevent untested images from being auto-deployed.
- Add a pre-sync Argo CD hook that validates ExternalSecrets are `Ready` before rolling a new deployment.
- Store imagePullSecrets as part of the namespace bootstrap so they are never missing after a namespace recreation.
