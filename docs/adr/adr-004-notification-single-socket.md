# ADR-004: Single Notification Service for All Real-Time Events via Socket.IO
**Status:** Accepted
**Date:** 2026-05-08
**Deciders:** F4 Platform Team

## Context

Multiple F3 services generate events that the operator dashboard must display in real time: job status changes, bin fill alerts, driver location updates, and anomaly flags. If each service maintained its own WebSocket server, the frontend would need to open and manage multiple simultaneous connections, handle independent reconnection logic for each, and merge event streams client-side. This increases frontend complexity and makes event ordering guarantees harder to enforce.

## Decision

A single `notification-service` owns all WebSocket connections to dashboard clients using Socket.IO. F3 services publish events to dedicated Kafka topics (`waste.dashboard.*`). The notification service consumes all dashboard topics and fans events out to the appropriate Socket.IO rooms (e.g., per-zone, per-job, per-driver).

## Consequences

### Positive
- Frontend manages one connection; reconnection and authentication handled in one place.
- Event ordering within a room is consistent because a single consumer processes the stream.
- New event types added by publishing to a new Kafka topic; frontend subscribes to a new room.

### Negative
- Notification service is a single point of failure for all real-time dashboard data.
- Horizontal scaling requires sticky sessions or a Redis adapter for Socket.IO.

### Risks
- Kafka consumer lag in notification-service delays all dashboard event types simultaneously.
