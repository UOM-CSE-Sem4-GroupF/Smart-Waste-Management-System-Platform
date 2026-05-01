Helm charts for SWMS
=====================

This folder contains Helm chart scaffolds for F2/F3 services. Start by copying
`helm/charts/base-service` to create a service-specific chart (e.g.
`bin-status-service`). The `values.yaml` defaults the storage class to
`do-block-storage` for DigitalOcean Kubernetes (DOKS).

Quick start (dev):

```bash
# from repo root
helm upgrade --install bin-status helm/charts/bin-status-service -n waste-dev --create-namespace -f helm/charts/bin-status-service/values-dev.yaml
```
