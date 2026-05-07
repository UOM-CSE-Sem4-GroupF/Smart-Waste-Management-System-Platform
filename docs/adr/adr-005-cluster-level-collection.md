# ADR-005: Collection Jobs Operate at Bin-Cluster Level
**Status:** Accepted
**Date:** 2026-05-08
**Deciders:** F4 Platform Team

## Context

An initial design dispatched a separate collection job for each individual bin that crossed the fill threshold. Field simulation showed this produced an impractical number of small, geographically overlapping truck dispatches. Trucks would visit the same street multiple times in a shift to collect adjacent bins whose alerts triggered minutes apart. Vehicle utilization was below 40% in simulations, and route complexity made scheduling intractable.

## Decision

Bins are grouped into geographic clusters (3-8 bins each) during system configuration. A collection job is created at the cluster level. When any bin in a cluster crosses the dispatch threshold, the job covers the entire cluster. The driver collects all bins in the cluster in a single stop.

## Consequences

### Positive
- Reduces vehicle trips by approximately 60% compared to per-bin dispatch in simulation.
- Simplifies routing: optimizer works over clusters, not individual bins.
- Drivers have predictable, coherent routes rather than fragmented individual stops.

### Negative
- Low-fill bins in a triggered cluster are collected earlier than strictly necessary, increasing collection frequency for those bins.
- Cluster boundaries must be reconfigured if bin locations change significantly.

### Risks
- Poorly defined clusters (too large, geographically dispersed) negate the trip-reduction benefit.
