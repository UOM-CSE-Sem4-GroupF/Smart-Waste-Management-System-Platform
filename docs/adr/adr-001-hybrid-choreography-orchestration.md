# ADR-001: Hybrid Choreography-Orchestration Pattern
**Status:** Accepted
**Date:** 2026-05-08
**Deciders:** F4 Platform Team

## Context

The system has two fundamentally different data flows. IoT telemetry arrives continuously from hundreds of bins at high frequency; this suits event-driven choreography. Collection job management is a multi-step workflow (schedule → dispatch → in-progress → completed) that requires visibility into current state and controlled transitions. Pure choreography for job workflows makes debugging and compensation logic impractical. Pure orchestration for IoT data introduces a bottleneck and doesn't scale.

## Decision

Use choreography (Kafka events) for the IoT data pipeline and orchestration (REST state machine) for collection job workflows. These two patterns operate in separate bounded contexts and do not conflict.

## Consequences

### Positive
- F2 Flink jobs process telemetry autonomously at throughput Kafka supports.
- F3 job state transitions are explicit, auditable, and easy to compensate on failure.
- Each domain uses the most appropriate integration style.

### Negative
- Engineers must understand both patterns; context-switching increases onboarding time.
- Two different debugging approaches required (consumer lag vs. REST trace logs).

### Risks
- Boundary between choreography and orchestration contexts must be clearly documented; ambiguity leads to misrouted logic.
