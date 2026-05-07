# ADR-006: Collection Job State Machine Split Across Three Tables (3NF)
**Status:** Accepted
**Date:** 2026-05-08
**Deciders:** F4 Platform Team

## Context

A prototype used a single `collection_jobs` table with columns for each bin assignment and route waypoint stored as JSON blobs. Partial collections (driver collects 3 of 5 bins before vehicle breakdown) required updating the blob in-place, making it impossible to query which specific bins were completed without deserializing the entire record. Audit queries and partial-completion compensation logic were fragile and slow.

## Decision

Split the job persistence model into three normalized tables:

- `collection_jobs` — job lifecycle: status, assigned vehicle, scheduled time, cluster reference.
- `job_bin_assignments` — one row per bin per job: individual bin completion status, collected weight, timestamp.
- `job_routes` — one row per waypoint per job: GPS coordinates, planned vs. actual arrival time.

Each table is updated independently by the relevant service or driver event.

## Consequences

### Positive
- Partial completion tracked at row granularity in `job_bin_assignments`; no blob parsing.
- Route timing queries run against `job_routes` without touching job or assignment data.
- Standard SQL joins replace application-level deserialization.

### Negative
- Three-table writes require a transaction boundary; adds latency compared to a single-row update.
- Schema migrations affect three tables instead of one.

### Risks
- Transaction failures mid-write leave job state partially updated if retry logic is not idempotent.
