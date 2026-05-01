# cicd/ — Argo CD GitOps Configuration

This directory contains all Argo CD configuration for the Group F Smart Waste Management System platform. F4 owns this directory.

## Directory layout

```
cicd/
├── argocd/
│   ├── values-dev.yaml          Argo CD Helm chart values (local dev)
│   ├── image-updater-values.yaml  Image Updater Helm values
│   └── rbac-cm.yaml             RBAC documentation
├── projects/
│   ├── platform.yaml            AppProject for infrastructure namespaces
│   └── services.yaml            AppProject for waste-dev / waste-prod
├── bootstrap/
│   └── root-app.yaml            App-of-Apps root Application (applied once)
├── applications/
│   ├── kafka.yaml               Kafka (messaging namespace)
│   ├── emqx.yaml                EMQX MQTT broker (messaging namespace)
│   ├── keycloak.yaml            Keycloak (auth namespace)
│   ├── vault.yaml               HashiCorp Vault (auth namespace)
│   └── kong.yaml                Kong API Gateway (gateway namespace)
└── appsets/
    └── services-dev.yaml        ApplicationSet for F2/F3 services (phase 2)
```

## GitOps flow

```
Developer pushes code to a service repo (group-f-edge / group-f-data / group-f-application)
        │
        ▼
GitHub Actions triggers service-build.yml (from group-f-platform)
  1. Run tests (Node 20 or Python 3.11)
  2. Lint Dockerfile (hadolint)
  3. Build Docker image
  4. Scan with Trivy — fails on CRITICAL/HIGH CVEs
  5. Push to ghcr.io/uom-cse-sem4-groupf/<service-name>:<sha-tag>
        │
        ▼
Argo CD Image Updater polls GHCR every 2 minutes
  Detects new image tag
  Commits updated image.tag to this repo (group-f-platform)
        │
        ▼
Argo CD detects the commit (reconcile loop, 3-minute interval)
  Syncs the affected Application to K8s
  Rolling update — old pods terminate only after new pods pass liveness probe
  On failure: automatic rollback to previous Helm release
```

## Image Updater annotation contract

When a new F2/F3 service Application is onboarded, add these annotations to its `cicd/applications/<service>.yaml`:

```yaml
metadata:
  annotations:
    # Declare which images to track (one entry per container)
    argocd-image-updater.argoproj.io/image-list: >-
      app=ghcr.io/uom-cse-sem4-groupf/<service-name>

    # Strategy: 'digest' tracks latest on a branch; 'semver' tracks version tags
    argocd-image-updater.argoproj.io/app.update-strategy: digest
    argocd-image-updater.argoproj.io/app.allow-tags: regexp:^sha-

    # Write updated tag back to this repo via SSH deploy key
    argocd-image-updater.argoproj.io/write-back-method: >-
      git:secret:cicd/argocd-image-updater-ssh

    # Path to the Helm values file that contains image.tag
    argocd-image-updater.argoproj.io/write-back-target: >-
      helmvalues:apps/<service-name>/values-dev.yaml
```

## Onboarding a new F2/F3 service

1. F4 creates a Helm chart under `apps/<service-name>/` in this repo.
2. F4 creates `cicd/applications/<service-name>.yaml` using the pattern below.
3. Push to `main` → root Application auto-deploys the new Application.
4. Add Image Updater annotations (above) to the new Application manifest.
5. Service repo's CI (`service-build.yml`) starts pushing images → Image Updater picks them up.

### Minimal service Application template

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <service-name>
  namespace: cicd
  annotations:
    argocd-image-updater.argoproj.io/image-list: app=ghcr.io/uom-cse-sem4-groupf/<service-name>
    argocd-image-updater.argoproj.io/app.update-strategy: digest
    argocd-image-updater.argoproj.io/app.allow-tags: regexp:^sha-
    argocd-image-updater.argoproj.io/write-back-method: git:secret:cicd/argocd-image-updater-ssh
    argocd-image-updater.argoproj.io/write-back-target: helmvalues:apps/<service-name>/values-dev.yaml
spec:
  project: services
  source:
    repoURL: https://github.com/UOM-CSE-Sem4-GroupF/group-f-platform
    targetRevision: main
    path: apps/<service-name>
    helm:
      valueFiles:
        - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: waste-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
```

## Pinned chart versions

When upgrading a platform component, update the `targetRevision` in **both**:
- `cicd/applications/<component>.yaml`
- `scripts/setup-local.sh` (the `helm install`/`helm upgrade` command for that component)

| Component | Chart | Current targetRevision |
|-----------|-------|------------------------|
| Kafka     | `registry-1.docker.io/bitnamicharts/kafka` | `32.4.3` |
| EMQX      | `emqx/emqx` | `5.6.0` |
| Keycloak  | `registry-1.docker.io/bitnamicharts/keycloak` | `24.4.7` |
| Vault     | `hashicorp/vault` | `0.29.1` |
| Kong      | `kong/kong` | `2.48.0` |
| Argo CD   | `argo/argo-cd` | latest at install time |

## Prerequisites for Image Updater (run once per cluster)

```bash
# 1. Generate SSH deploy key
ssh-keygen -t ed25519 -C "image-updater@group-f.local" -f /tmp/image-updater-key

# 2. Add public key as Deploy Key WITH WRITE ACCESS to group-f-platform repo:
#    GitHub → group-f-platform → Settings → Deploy keys → Add deploy key

# 3. Create K8s secret
kubectl -n cicd create secret generic argocd-image-updater-ssh \
  --from-file=sshPrivateKey=/tmp/image-updater-key

# 4. Create GHCR pull secret (needs a PAT with read:packages scope)
kubectl -n cicd create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat>

# 5. Remove local key files
rm /tmp/image-updater-key /tmp/image-updater-key.pub
```
