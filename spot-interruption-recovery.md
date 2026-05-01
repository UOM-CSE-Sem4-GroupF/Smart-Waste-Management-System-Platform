# Spot Instance Interruption Recovery

## What Happened

The cluster uses AWS Spot instances to cut node costs by ~70%. AWS can reclaim Spot nodes at any time and replace them in a different Availability Zone. When this happens, EBS volumes (used by Kafka and EMQX) are stranded — they are AZ-locked and cannot follow the pod to a new AZ.

**Symptoms:**
- `docker compose up` on the Edge simulator times out connecting to EMQX
- `kubectl get pods -n messaging` shows `emqx-0` and/or `kafka-broker-0` as `Pending`
- `kubectl describe pod emqx-0 -n messaging` shows `volume node affinity conflict`

---

## Recovery Commands

Run these from the platform repo root with kubectl context set to the EKS cluster.

### Step 1 — Update kubeconfig (if not already done)

```bash
aws eks update-kubeconfig --region eu-north-1 --name swms-eks-dev
```

### Step 2 — Delete the AZ-locked PVCs

This deletes the stranded EBS volumes. Kafka topic data and EMQX user config are lost but will be restored by the bootstrap jobs in Step 4. This is acceptable for the dev cluster.

```bash
kubectl delete pvc data-kafka-broker-0 emqx-data-emqx-0 -n messaging
```

### Step 3 — Delete the stuck pods

The StatefulSets will immediately recreate the pods. With the PVCs gone, new EBS volumes are provisioned in whichever AZ the scheduler picks (gp3 uses `WaitForFirstConsumer` so the volume follows the pod).

```bash
kubectl delete pod kafka-broker-0 emqx-0 -n messaging
```

### Step 4 — Wait for pods to be Running

```bash
kubectl get pods -n messaging -w
```

Wait until both `emqx-0` and `kafka-broker-0` show `1/1 Running`.

### Step 5 — Re-run bootstrap jobs

The fresh Kafka broker has no topics and EMQX has no MQTT users or bridge rules. These jobs restore them.

```bash
# Delete old completed jobs first (kubectl will reject duplicates otherwise)
kubectl delete job kafka-topic-init emqx-bootstrap -n messaging --ignore-not-found

# Re-apply
kubectl apply -f ./messaging/kafka/topics.yaml -n messaging
kubectl apply -f ./messaging/emqx/emqx-bootstrap.yaml -n messaging
```

### Step 6 — Confirm everything is healthy

```bash
# All pods should be Running or Completed
kubectl get pods -n messaging

# Kafka broker should advertise the correct NLB hostname
kubectl exec -n messaging kafka-broker-0 -- bash -c \
  'grep advertised /opt/bitnami/kafka/config/server.properties'

# External Kafka connectivity test
python verify_external_kafka.py
```

---

## Why This Keeps Happening

The node group uses Spot instances across 3 AZs (eu-north-1a, eu-north-1b, eu-north-1c). When a Spot node in one AZ is reclaimed, the ASG replaces it — but not necessarily in the same AZ. Stateful workloads with EBS volumes are AZ-bound, so they get stuck.

**Longer-term mitigations (not yet implemented):**

| Option | Trade-off |
|---|---|
| Add On-Demand node(s) for stateful pods | Eliminates interruption risk, adds ~$30–50/mo |
| Use `topologySpreadConstraints` to pin stateful pods to a fixed AZ | Reduces recurrence, but that AZ could still be interrupted |
| Switch Kafka/EMQX persistence to EFS (multi-AZ) | Eliminates the AZ binding issue, adds latency and cost |
| Use `volumeClaimTemplates` with a topology key annotation | Forces PVC creation in the same AZ as a pinned node |

For now, the recovery above takes about 5 minutes and is the accepted runbook for the dev cluster.
