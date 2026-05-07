# Runbook: Database Connection Pool Exhaustion

**Alert:** High DB connection count or `connection refused` / `too many connections` errors in service logs
**Condition:** Active connections approaching `max_connections` on the PostgreSQL instance, or services failing to acquire a connection
**Severity:** High
**Team:** Platform / Backend

---

## Overview

The SWMS platform uses a PostgreSQL StatefulSet (`postgres-waste`) in the `waste-dev` (or `waste-prod`) namespace. All F2/F3 application services connect to this single instance. Each service maintains a connection pool (typically via HikariCP or SQLAlchemy). If a service leaks connections, if too many replicas are running without a connection pooler, or if the StatefulSet is unhealthy, all services can be denied new connections simultaneously. PgBouncer (if deployed) acts as a multiplexing proxy to reduce raw connections to PostgreSQL.

PostgreSQL default `max_connections` in the Helm chart is 100. With multiple services each holding 10-connection pools, this limit is easily reached.

---

## Symptoms

- Service logs contain `FATAL: remaining connection slots are reserved`, `too many connections`, or `connection refused` to port 5432.
- Grafana "PostgreSQL Connections" panel shows active connections at or near `max_connections`.
- API requests return 500 errors or time out during DB-heavy operations.
- New service pods fail their readiness probes (they cannot reach the DB on startup).
- PgBouncer (if deployed) logs `no more connections allowed` or `pool_size exhausted`.

---

## Diagnosis

### 1. Check PostgreSQL StatefulSet health

```bash
kubectl get statefulset postgres-waste -n waste-dev
kubectl get pods -n waste-dev -l app=postgres-waste

# Check recent pod events
kubectl describe pod postgres-waste-0 -n waste-dev | tail -40
```

If the pod is not `Running`, fix the StatefulSet first — connection issues are secondary.

### 2. Check total and per-service active connections

```bash
# Open a psql session inside the postgres pod
kubectl exec -it postgres-waste-0 -n waste-dev -- \
  psql -U waste_admin -d waste_management
```

Once inside `psql`, run the following queries:

```sql
-- Total active connections vs. max
SELECT count(*) AS active, (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections
FROM pg_stat_activity
WHERE state = 'active';

-- Connections grouped by application / service
SELECT application_name, state, count(*)
FROM pg_stat_activity
GROUP BY application_name, state
ORDER BY count(*) DESC;

-- Long-running queries that may be holding connections
SELECT pid, now() - query_start AS duration, query, state
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start < now() - interval '5 minutes'
ORDER BY duration DESC;

-- Idle connections consuming slots
SELECT count(*), state
FROM pg_stat_activity
GROUP BY state;

-- Terminate a long-running query by PID (replace 12345 with actual PID)
-- SELECT pg_terminate_backend(12345);
```

Exit `psql` with `\q`.

### 3. Check PgBouncer status (if deployed)

```bash
kubectl get pods -n waste-dev -l app=pgbouncer

# PgBouncer admin console (if running)
kubectl exec -it <pgbouncer-pod> -n waste-dev -- \
  psql -U pgbouncer -p 6432 pgbouncer

# Inside PgBouncer admin console:
# SHOW POOLS;
# SHOW CLIENTS;
# SHOW SERVERS;
# \q
```

If PgBouncer is not deployed but services are hitting connection limits, adding PgBouncer is the long-term fix (see Prevention).

### 4. Check which service pods are running and how many replicas

```bash
kubectl get deployments -n waste-dev
kubectl get pods -n waste-dev
```

Count the replicas per service. If a service was recently scaled up without adjusting pool size, the total connections can spike.

---

## Fix Steps

### Fix A — Restart affected service pods (they will reconnect cleanly)

When a service has leaked connections or has idle connections piling up, a rolling restart is the fastest safe fix. Restarting closes all sockets held by the pod.

```bash
# Rolling restart for a specific service
kubectl rollout restart deployment/<service-name> -n waste-dev

# Watch the rollout
kubectl rollout status deployment/<service-name> -n waste-dev
```

After restarting the worst offenders (identified in step 2 above), re-check the connection count in `pg_stat_activity`.

### Fix B — Terminate idle connections in PostgreSQL directly

If idle connections are using up all slots and pods cannot be restarted immediately:

```bash
kubectl exec -it postgres-waste-0 -n waste-dev -- \
  psql -U waste_admin -d waste_management -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE state = 'idle'
      AND query_start < now() - interval '10 minutes'
      AND pid <> pg_backend_pid();
  "
```

This frees slots for active services without downtime.

### Fix C — Increase max_connections temporarily

Only do this if you cannot reduce connections fast enough and service degradation is ongoing. Increasing `max_connections` requires a PostgreSQL restart.

```bash
# Edit the Helm values file and increase max_connections
# In auth/vault/values-dev.yaml or the postgres helm values, update:
# postgresql.conf: max_connections = 200

# Then apply the change
helm upgrade postgres-waste <chart> \
  -n waste-dev \
  -f <values-file-with-increased-max-connections>

# OR, apply a direct config patch (requires pod restart)
kubectl exec -it postgres-waste-0 -n waste-dev -- \
  psql -U waste_admin -c "ALTER SYSTEM SET max_connections = 200;"

# Restart the PostgreSQL pod to apply (brief downtime)
kubectl delete pod postgres-waste-0 -n waste-dev
```

Note: `max_connections` also increases shared memory usage. On a 2 Gi pod, 200 connections is the practical ceiling.

### Fix D — postgres-waste StatefulSet is unhealthy

```bash
# Check PVC status (data may still be safe)
kubectl get pvc -n waste-dev

# Force a pod replacement (StatefulSet will recreate it with the same PVC)
kubectl delete pod postgres-waste-0 -n waste-dev

# Watch recovery
kubectl get pods -n waste-dev -l app=postgres-waste -w
```

Once the pod is `Running`, services will reconnect automatically via their pool retry logic. If all services are in `CrashLoopBackOff` waiting for the DB, restart them after the DB is up:

```bash
kubectl rollout restart deployment -n waste-dev
```

### Fix E — Deploy PgBouncer if not present (connection multiplexing)

This is a structural fix for environments running many service replicas. PgBouncer sits between services and PostgreSQL, multiplexing many client connections into a small pool of server connections.

Add a PgBouncer deployment to `waste-dev` and update all service `DATABASE_URL` environment variables to point to PgBouncer's port (6432) instead of PostgreSQL's port (5432). Consult the base-service Helm chart values for the env var key name.

---

## Verification

```bash
# Re-check connection count — should be well below max_connections
kubectl exec -it postgres-waste-0 -n waste-dev -- \
  psql -U waste_admin -d waste_management -c \
  "SELECT count(*) FROM pg_stat_activity;"

# All service pods Running with 0 errors in logs
kubectl get pods -n waste-dev
kubectl logs deployment/<service-name> -n waste-dev --tail=50 | grep -i "error\|exception\|refused"

# Service health endpoints responding
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://<service-name>.<namespace>.svc.cluster.local:<port>/health
```

Alert should auto-resolve once connection count drops and service error rates return to baseline.

---

## Prevention

- Deploy PgBouncer in `transaction` pooling mode in front of PostgreSQL. This alone typically reduces raw connections by 5-10x for stateless HTTP services.
- Set a conservative `pool_size` in each service's application config (e.g., 5 connections per replica) and document this in the service's `values-dev.yaml`.
- Add a Grafana alert at 70% of `max_connections` (i.e., alert at 70 connections if max is 100) for an early warning before saturation.
- Set PostgreSQL `idle_in_transaction_session_timeout = 30s` and `statement_timeout = 60s` to auto-close runaway connections.
- Use the `pg_stat_activity` dashboard in Grafana to trend connection usage over time. Sudden spikes after a deployment indicate a connection leak in that service version.
- Ensure the `postgres-waste` StatefulSet PVC uses the `do-block-storage` storage class on DOKS (not `hostPath`) so data survives node replacement.
