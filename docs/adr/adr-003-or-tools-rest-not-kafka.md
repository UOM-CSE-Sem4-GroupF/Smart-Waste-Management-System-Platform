# ADR-003: Route Optimizer Exposed as REST API, Not Kafka Consumer
**Status:** Accepted
**Date:** 2026-05-08
**Deciders:** F4 Platform Team

## Context

The route optimizer runs Google OR-Tools to solve a vehicle routing problem (VRP) for each collection job. The scheduler service needs the optimized route before it can create and dispatch a job. This is an inherently synchronous, request-response interaction: the caller blocks until the solution is returned. An event-driven design would require publishing an optimization request to Kafka, consuming a result event, and correlating the two — adding significant complexity with no throughput or decoupling benefit, since optimization runs are low-frequency (tens per day, not thousands per second).

## Decision

The route optimizer is deployed as a REST microservice. The scheduler calls it via `HTTP POST /optimize` with a payload of candidate bins and vehicle constraints, and receives the ordered route in the response body.

## Consequences

### Positive
- No correlation ID management or result-queue plumbing required.
- Latency is direct; no queuing delay between request and route creation.
- Simple to test in isolation with HTTP clients.

### Negative
- Synchronous call creates a runtime dependency; optimizer downtime blocks job creation.
- Does not benefit from Kafka's replay capability for optimization requests.

### Risks
- Long-running VRP solves (large clusters, tight constraints) may breach HTTP timeout thresholds; a configurable deadline must be enforced.
