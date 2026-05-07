# ADR-002: Weight-Aware Bin Collection Priority Scoring
**Status:** Accepted
**Date:** 2026-05-08
**Deciders:** F4 Platform Team

## Context

Early routing prototypes sorted bins by fill level percentage alone. Field analysis revealed two failure modes: (1) compacted waste produces bins that are heavy but report low fill levels, causing them to be skipped; (2) organic waste bins left uncollected overflow faster and create health hazards regardless of fill percentage. Fill level as the sole signal produces suboptimal and sometimes unsafe collection schedules.

## Decision

The route optimizer scores each bin using a composite formula:

```
score = fill% × weight_factor × category_urgency
```

Bins are sorted descending by score. `weight_factor` is derived from the bin's reported weight relative to its rated capacity. `category_urgency` is a static multiplier (organic > hazardous > general > recyclable).

## Consequences

### Positive
- Heavy compacted bins surface in schedules even at moderate fill levels.
- Organic waste bins receive higher priority, reducing overflow incidents.
- Scoring is deterministic and auditable; operators can inspect any bin's score.

### Negative
- Requires bins to report weight data; bins without weight sensors fall back to fill-level-only scoring.
- Category urgency multipliers need periodic tuning as operational data accumulates.

### Risks
- Miscalibrated weight sensors could inflate scores for specific bins, creating routing bias.
