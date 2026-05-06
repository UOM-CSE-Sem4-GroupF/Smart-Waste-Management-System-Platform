# 🚀 Flink Processor: Deployment Readiness Guide

This guide outlines the steps required to prepare the `Smart-Waste-Management-System-DataAnalysis` repository for production deployment on the DOKS cluster via Argo CD.

---

## 1. Automated CI/CD (GitHub Actions)
To enable GitOps, we must automate the creation of Docker images. Create the following file in your repository:

**Path**: `.github/workflows/deploy-flink.yaml`

```yaml
name: Build and Push Flink Processor

on:
  push:
    branches: [ main ]
    paths:
      - 'flink-processor/**'

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/flink-processor

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Log in to the Container registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata (tags, labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=latest
            type=sha,format=short

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: ./flink-processor
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

---

## 2. Flexible Dockerfile
We need to allow the same Docker image to run any of the 5 different Flink jobs (`job.py`, `job_vehicle.py`, etc.). Update the end of your `Dockerfile`:

**Modify `flink-processor/Dockerfile`**:
```dockerfile
# ... existing build steps ...

# Change CMD to allow overrides via Helm
ENTRYPOINT ["python"]
CMD ["job.py", "--mode", "pyflink-kafka"]
```

> [!TIP]
> This allows the Platform repo to override the command for different pipelines (e.g., `command: ["python", "job_vehicle.py", "--mode", "pyflink-kafka"]`).

---

## 3. Environment & Secret Readiness
Ensure `config.py` is robust for a production environment.

1.  **Check `load_dotenv()`**: It should remain at the top of `config.py`. In production, there will be no `.env` file; the code will fall back to system environment variables injected by Kubernetes.
2.  **Verify Variable Names**: Ensure these variables match exactly what Argo CD provides:
    *   `KAFKA_PASSWORD` (Injected via Vault)
    *   `POSTGRES_PASSWORD` (Injected via Vault)
    *   `INFLUX_TOKEN` (Injected via Vault)

---

## 4. Handover Checklist for Platform Team
Once the image is pushed to GHCR, provide the following information to the Platform Team (F4):

1.  **Image URL**: `ghcr.io/uom-cse-sem4-groupf/flink-processor:latest` (or specific SHA).
2.  **Job Command**: Specify which script should be run for which deployment.
3.  **Missing Topics**: List any new Kafka topics or InfluxDB buckets that need to be created in the cluster.

---
**Status**: Ready for Implementation.
