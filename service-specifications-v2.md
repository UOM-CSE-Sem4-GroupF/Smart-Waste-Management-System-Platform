# Group F — Smart Waste Management System
# Complete Service Specification Document
# Version 2.0 — Updated with architectural changes from design review

---

## Change Log (v1.0 → v2.0)

- **Database ownership**: F2 owns the entire PostgreSQL database (both f2 and f3 schemas). F3 services no longer hold direct DB credentials — all cross-service data access goes through F2's REST APIs via Kong. F3 services connect directly only to their own f3 schema tables.
- **Bin clusters**: Introduced `bin_clusters` table. OR-Tools routes to clusters (physical locations), not individual bins. Driver arrives at a cluster and collects all urgent bins there in one stop.
- **Devices table**: New `f2.devices` table stores ESP32 firmware configuration (bin depth, sleep intervals, urgency thresholds, MQTT topic, firmware version, config ACK tracking). Config pushed via Leshan/LwM2M.
- **Redis companion for bin_current_state**: Flink dual-writes to both PostgreSQL and Redis. Redis provides sub-millisecond single-bin lookups and TTL-based sensor offline detection (key expires after 30 min). PostgreSQL handles filtered queries and joins.
- **3NF decomposition of collection_jobs**: Split into `collection_jobs` (core identity only), `emergency_job_details` (1:1), `routine_job_details` (1:1), and `job_execution_metrics` (1:1). Timing fields removed from collection_jobs — derived from `job_state_transitions`.
- **OR-Tools as REST API**: OR-Tools is called synchronously by the scheduler service (`POST /internal/route-optimizer/solve`) with a 35-second timeout. It is no longer a Kafka consumer. Removed `waste.collection.jobs` and `waste.routes.optimized` topics.
- **Kafka topic revision**: Added `waste.bin.dashboard.updates`, `waste.vehicle.dashboard.updates`. Removed `waste.collection.jobs`, `waste.routes.optimized`, `waste.bin.status.changed`. Retained `waste.zone.statistics` (published by Flink, consumed by bin-status-service).
- **Wait window logic (Option C)**: On detecting a non-critical urgent bin (score 80–89), the orchestrator scans nearby clusters approaching urgency before dispatching. max_wait = min(predicted_full_at − 45 min, 30 min absolute). Critical bins (score ≥ 90 or e_waste) dispatch immediately.
- **Dashboard live update architecture**: bin-status-service enriches processed events and publishes to `waste.bin.dashboard.updates`. Scheduler-service enriches vehicle location events and publishes to `waste.vehicle.dashboard.updates`. Notification service is pure delivery — consumes both topics and streams via Socket.IO. No business logic in notification service.

---

## System Overview

The Smart Waste Management System serves a municipal council managing waste collection across multiple city zones. The system operates in two modes simultaneously:

**Routine mode** — pre-scheduled collection jobs per zone, optimised weekly as ML models retrain on newer data.

**Emergency mode** — automatic detection of urgent bin fill-ups triggering immediate job creation and driver dispatch with minimum supervisor intervention.

The system handles categorised waste (food, paper, glass, plastic, general, e_waste) with weight metadata per waste type, a heterogeneous lorry fleet with different cargo weight limits, and a full job lifecycle for both routine and emergency collections.

---

## Domain Model — Core Entities

### City & Zones
The city is divided into zones (Zone-1 through Zone-N). Each zone contains bin clusters. Routine collection schedules are defined per zone.

### Bin Clusters
A bin cluster is a physical location (e.g. "Central Market Complex", "Apartment Block 7B") containing one or more bins. OR-Tools routes to clusters — each cluster is one stop. The cluster holds the GPS coordinate used for routing. Individual bin GPS coordinates are optional and used only for precise identification, not routing.

### Waste Categories
```
food_waste    avg weight per litre: 0.9 kg/L   colour code: #8B4513
paper         avg weight per litre: 0.1 kg/L   colour code: #4169E1
glass         avg weight per litre: 2.5 kg/L   colour code: #228B22
plastic       avg weight per litre: 0.05 kg/L  colour code: #FF6347
general       avg weight per litre: 0.3 kg/L   colour code: #808080
e_waste       avg weight per litre: 3.2 kg/L   colour code: #FFD700 (special_handling = true)
```

### Bins
Each bin belongs to exactly one cluster. It has a fixed volume capacity, a waste category, and an optional individual GPS coordinate. Fill level sensor reads percentage full (0–100%).

Estimated weight = fill_level_pct/100 × volume_litres × avg_kg_per_litre

### Devices
Each bin has exactly one IoT device (ESP32). The device table stores firmware configuration that is pushed to the device via Leshan/LwM2M: bin depth, sleep intervals per fill tier, urgency thresholds, and the MQTT topic to publish on. Device status (last_seen_at, battery, signal, firmware version, config ACK) is also stored here.

### Lorries
Each lorry has a maximum cargo weight and a list of supported waste categories. A lorry can only be assigned to routes containing waste categories it supports. The system always selects the smallest sufficient vehicle.

Vehicle types:
```
small        ~2,000 kg   (~2 clusters)
medium       ~8,000 kg   (~quarter zone)
large        ~15,000 kg  (~half zone)
extra_large  ~25,000 kg  (~full zone)
```

### Jobs
Two types:
- **Routine job** — scheduled by zone, generated nightly by Airflow
- **Emergency job** — triggered when bin urgency score exceeds threshold

Both job types use the same state machine in the workflow orchestrator.

---

## Database Schema — Ground Truth

**Ownership rule**: F2 owns the entire PostgreSQL instance. F3 services write directly to f3 schema tables they own. F3 services access f2 schema data only through Kong APIs exposed by F2. There are no cross-schema grants to f3_app_user for f2 tables. This is documented in ADR-007.

### F2 owns — PostgreSQL (waste_db, f2 schema)

```sql
-- Waste category metadata (reference data — seeded at install)
CREATE TABLE f2.waste_categories (
    id                  SERIAL PRIMARY KEY,
    name                VARCHAR(50) UNIQUE NOT NULL,
    avg_kg_per_litre    DECIMAL(5,3) NOT NULL,
    colour_code         VARCHAR(7),
    recyclable          BOOLEAN NOT NULL DEFAULT FALSE,
    special_handling    BOOLEAN NOT NULL DEFAULT FALSE, -- TRUE for e_waste
    description         TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- City zones
CREATE TABLE f2.city_zones (
    id                  SERIAL PRIMARY KEY,
    name                VARCHAR(100) NOT NULL,
    code                VARCHAR(20) UNIQUE NOT NULL,   -- ZONE-01, ZONE-02
    boundary_geojson    JSONB,
    collection_day      VARCHAR(10),
    collection_time     TIME,
    supervisor_id       VARCHAR(100),                  -- Keycloak user_id
    active              BOOLEAN DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Vehicle fleet
CREATE TABLE f2.vehicles (
    id                  VARCHAR(20) PRIMARY KEY,       -- LORRY-01
    registration        VARCHAR(20) UNIQUE NOT NULL,
    vehicle_type        VARCHAR(20) NOT NULL,          -- small/medium/large/extra_large
    max_cargo_kg        DECIMAL(8,2) NOT NULL,
    volume_m3           DECIMAL(6,2),
    driver_id           VARCHAR(20),                   -- references f3.drivers (no FK)
    status              VARCHAR(20) DEFAULT 'available',
    active              BOOLEAN DEFAULT TRUE,
    last_service_at     TIMESTAMPTZ,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Junction: which waste categories each vehicle accepts
CREATE TABLE f2.vehicle_waste_categories (
    vehicle_id          VARCHAR(20) REFERENCES f2.vehicles(id) ON DELETE CASCADE,
    category_id         INTEGER REFERENCES f2.waste_categories(id),
    PRIMARY KEY (vehicle_id, category_id)
);

-- Bin clusters (physical collection locations — OR-Tools routes to these)
CREATE TABLE f2.bin_clusters (
    id                  VARCHAR(20) PRIMARY KEY,       -- CLUSTER-001
    zone_id             INTEGER NOT NULL REFERENCES f2.city_zones(id),
    name                VARCHAR(100) NOT NULL,         -- "Central Market Complex"
    lat                 DECIMAL(10,7) NOT NULL,        -- GPS used by OR-Tools
    lng                 DECIMAL(10,7) NOT NULL,
    address             TEXT,
    cluster_type        VARCHAR(30),                   -- residential/commercial/industrial/etc
    active              BOOLEAN DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Bin registry (each bin belongs to exactly one cluster)
CREATE TABLE f2.bins (
    id                  VARCHAR(20) PRIMARY KEY,       -- BIN-001
    cluster_id          VARCHAR(20) NOT NULL REFERENCES f2.bin_clusters(id),
    waste_category_id   INTEGER NOT NULL REFERENCES f2.waste_categories(id),
    volume_litres       DECIMAL(8,2) NOT NULL,
    lat                 DECIMAL(10,7),                 -- individual bin GPS (optional)
    lng                 DECIMAL(10,7),                 -- routing always uses cluster GPS
    address             TEXT,
    active              BOOLEAN DEFAULT TRUE,
    installed_at        TIMESTAMPTZ,
    last_maintained_at  TIMESTAMPTZ,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Devices (IoT sensors — one per bin)
-- Stores both firmware configuration (pushed via Leshan) and device health
CREATE TABLE f2.devices (
    id                          VARCHAR(50) PRIMARY KEY,   -- ESP32-MAC-AABB-CCDD-EEFF
    bin_id                      VARCHAR(20) UNIQUE REFERENCES f2.bins(id),
    device_type                 VARCHAR(30) NOT NULL,      -- esp32_ultrasonic / esp32_weight / rpi_gateway

    -- Firmware configuration (pushed via Leshan/LwM2M)
    bin_depth_cm                INTEGER NOT NULL DEFAULT 120,
    sleep_interval_normal_s     INTEGER NOT NULL DEFAULT 600,
    sleep_interval_monitor_s    INTEGER NOT NULL DEFAULT 300,
    sleep_interval_urgent_s     INTEGER NOT NULL DEFAULT 120,
    sleep_interval_critical_s   INTEGER NOT NULL DEFAULT 30,
    urgency_threshold_monitor   INTEGER NOT NULL DEFAULT 50,
    urgency_threshold_urgent    INTEGER NOT NULL DEFAULT 75,
    urgency_threshold_critical  INTEGER NOT NULL DEFAULT 90,
    mqtt_topic                  VARCHAR(200),              -- sensors/bin/{bin_id}/telemetry
    firmware_target_version     VARCHAR(20),

    -- Device health (reported by device)
    firmware_current_version    VARCHAR(20),
    status                      VARCHAR(20) DEFAULT 'provisioned',
    last_seen_at                TIMESTAMPTZ,
    battery_level_pct           DECIMAL(5,2),
    signal_strength_dbm         DECIMAL(6,2),

    -- Provisioning
    provisioned_at              TIMESTAMPTZ DEFAULT NOW(),
    provisioned_by              VARCHAR(100),
    certificate_fingerprint     VARCHAR(200),
    last_config_pushed_at       TIMESTAMPTZ,
    last_config_ack_at          TIMESTAMPTZ,
    notes                       TEXT,
    created_at                  TIMESTAMPTZ DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ DEFAULT NOW()
);

-- Current bin state (upserted by Flink on every reading)
-- Denormalized fields (cluster_id, zone_id, waste_category_id, volume_litres)
-- are safe to denormalize — they never change after installation
CREATE TABLE f2.bin_current_state (
    bin_id                  VARCHAR(20) PRIMARY KEY REFERENCES f2.bins(id),
    fill_level_pct          DECIMAL(5,2) NOT NULL,
    battery_level_pct       DECIMAL(5,2),
    signal_strength_dbm     DECIMAL(6,2),
    temperature_c           DECIMAL(5,2),
    estimated_weight_kg     DECIMAL(8,2),
    fill_rate_pct_per_hour  DECIMAL(6,3),
    predicted_full_at       TIMESTAMPTZ,
    status                  VARCHAR(20) NOT NULL DEFAULT 'normal',
    urgency_score           INTEGER NOT NULL DEFAULT 0,

    -- Denormalized for query performance (dashboard map loads)
    cluster_id              VARCHAR(20) NOT NULL,
    zone_id                 INTEGER NOT NULL,
    waste_category_id       INTEGER NOT NULL,
    volume_litres           DECIMAL(8,2) NOT NULL,

    last_reading_at         TIMESTAMPTZ NOT NULL,
    last_collected_at       TIMESTAMPTZ,
    updated_at              TIMESTAMPTZ DEFAULT NOW()
);

-- Redis companion for bin_current_state:
-- Flink also writes HSET bin:{bin_id} {...} EX 1800 on every reading.
-- Key TTL = 30 minutes → key expiry = sensor offline detection.
-- Redis serves single-bin fast lookups and the offline check.
-- PostgreSQL serves filtered queries, joins, and aggregations.

-- Route plans (written by OR-Tools route optimizer service)
CREATE TABLE f2.route_plans (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id                  UUID,                        -- references f3.collection_jobs
    vehicle_id              VARCHAR(20) NOT NULL REFERENCES f2.vehicles(id),
    route_type              VARCHAR(20) NOT NULL,        -- routine / emergency
    zone_id                 INTEGER REFERENCES f2.city_zones(id),
    -- Waypoints: ordered array of cluster stops
    -- Each stop: { sequence, cluster_id, cluster_name, lat, lng,
    --              bins, waste_categories, fill_levels_at_planning,
    --              estimated_weight_kg, cumulative_weight_kg,
    --              estimated_arrival_iso, time_window_deadline_iso,
    --              stop_duration_minutes }
    waypoints               JSONB NOT NULL,
    total_clusters          INTEGER NOT NULL,
    total_bins              INTEGER NOT NULL,
    estimated_weight_kg     DECIMAL(8,2) NOT NULL,
    estimated_distance_km   DECIMAL(8,2),
    estimated_minutes       INTEGER,
    or_tools_solver_time_ms INTEGER,
    solver_method           VARCHAR(30),                 -- or_tools / nearest_neighbour_fallback
    valid_for_date          DATE,
    status                  VARCHAR(20) DEFAULT 'planned',
    superseded_by_id        UUID REFERENCES f2.route_plans(id),
    created_at              TIMESTAMPTZ DEFAULT NOW()
);

-- Zone analytics snapshots (written by Flink sliding window every 2 minutes)
CREATE TABLE f2.zone_snapshots (
    id                      BIGSERIAL PRIMARY KEY,
    zone_id                 INTEGER NOT NULL REFERENCES f2.city_zones(id),
    snapshot_at             TIMESTAMPTZ NOT NULL,
    window_minutes          INTEGER DEFAULT 10,
    avg_fill_level_pct      DECIMAL(5,2),
    urgent_bin_count        INTEGER DEFAULT 0,
    critical_bin_count      INTEGER DEFAULT 0,
    total_bins              INTEGER,
    total_clusters          INTEGER,
    total_estimated_kg      DECIMAL(10,2),
    dominant_waste_category VARCHAR(50),
    category_breakdown      JSONB,                      -- per-category fill/weight stats
    created_at              TIMESTAMPTZ DEFAULT NOW()
);

-- ML model performance tracking
CREATE TABLE f2.model_performance (
    id                  BIGSERIAL PRIMARY KEY,
    model_name          VARCHAR(100) NOT NULL,
    model_version       VARCHAR(50) NOT NULL,
    mlflow_run_id       VARCHAR(200),
    trained_at          TIMESTAMPTZ NOT NULL,
    training_records    INTEGER,
    validation_records  INTEGER,
    mae_hours           DECIMAL(6,3),
    rmse_hours          DECIMAL(6,3),
    r_squared           DECIMAL(5,4),
    promoted_to_prod    BOOLEAN DEFAULT FALSE,
    promoted_at         TIMESTAMPTZ,
    replaced_at         TIMESTAMPTZ,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (model_name, model_version)
);
```

### F2 owns — InfluxDB measurements

```
bin_readings_raw
  tags:    bin_id, zone_id, waste_category, cluster_id
  fields:  fill_level_pct, battery_level_pct, signal_strength, temperature_c
  retention: 1 year

bin_readings_processed
  tags:    bin_id, zone_id, waste_category, cluster_id, status
  fields:  fill_level_pct, urgency_score, estimated_weight_kg,
           fill_rate_pct_per_hour, predicted_full_hours
  retention: 90 days

vehicle_positions
  tags:    vehicle_id, driver_id, job_id, zone_id
  fields:  lat, lng, speed_kmh, heading_degrees, cargo_weight_kg
  retention: 1 year

zone_statistics
  tags:    zone_id, waste_category
  fields:  avg_fill_level, urgent_count, critical_count,
           total_bins, total_weight_kg
  retention: 2 years

waste_generation_trends
  tags:    zone_id, waste_category, day_of_week
  fields:  avg_daily_kg, avg_fill_rate, peak_hour
  retention: forever
```

### F3 owns — PostgreSQL (waste_db, f3 schema)

```sql
-- Drivers
CREATE TABLE f3.drivers (
    id                  VARCHAR(20) PRIMARY KEY,        -- DRV-001
    name                VARCHAR(100) NOT NULL,
    phone               VARCHAR(20),
    email               VARCHAR(200),
    keycloak_user_id    VARCHAR(100) UNIQUE NOT NULL,
    zone_id             INTEGER NOT NULL,               -- no FK (cross-schema avoided)
    current_vehicle_id  VARCHAR(20),                   -- no FK (cross-schema avoided)
    status              VARCHAR(20) DEFAULT 'off_duty',
    shift_start         TIME,
    shift_end           TIME,
    total_jobs_completed    INTEGER DEFAULT 0,
    total_bins_collected    INTEGER DEFAULT 0,
    total_weight_kg         DECIMAL(10,2) DEFAULT 0,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Routine collection schedules
CREATE TABLE f3.routine_schedules (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    zone_id             INTEGER NOT NULL,
    waste_category_id   INTEGER,                       -- NULL = all categories
    frequency           VARCHAR(20) NOT NULL,
    day_of_week         VARCHAR(10),
    time_of_day         TIME NOT NULL,
    active              BOOLEAN DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Collection jobs — CORE (3NF)
-- Contains only facts that depend directly on job identity.
-- Type-specific data → emergency_job_details / routine_job_details
-- Execution metrics → job_execution_metrics
-- Timing → derived from job_state_transitions (no timestamp columns here)
CREATE TABLE f3.collection_jobs (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type            VARCHAR(20) NOT NULL,           -- routine / emergency
    zone_id             INTEGER NOT NULL,
    state               VARCHAR(50) NOT NULL DEFAULT 'CREATED',
    -- State machine:
    -- CREATED → BIN_CONFIRMING → BIN_CONFIRMED
    -- → CLUSTER_ASSEMBLING → CLUSTER_ASSEMBLED
    -- → DISPATCHING → DISPATCHED → DRIVER_NOTIFIED
    -- → IN_PROGRESS → COMPLETING → COLLECTION_DONE
    -- → RECORDING_AUDIT → AUDIT_RECORDED → COMPLETED
    -- Failures: FAILED | ESCALATED | CANCELLED | DRIVER_REASSIGNMENT
    priority            INTEGER DEFAULT 5,
    assigned_vehicle_id VARCHAR(20),                   -- no FK (cross-schema)
    assigned_driver_id  VARCHAR(20) REFERENCES f3.drivers(id),
    route_plan_id       UUID,                          -- references f2.route_plans (no FK)
    planned_weight_kg   DECIMAL(8,2),
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
    -- NOTE: assigned_at, accepted_at, started_at, completed_at etc. are NOT stored here.
    -- Derive them from job_state_transitions:
    --   SELECT transitioned_at FROM f3.job_state_transitions
    --   WHERE job_id = ? AND to_state = 'DISPATCHED'
);

-- Emergency job details (1:1 with collection_jobs where job_type = 'emergency')
CREATE TABLE f3.emergency_job_details (
    job_id                      UUID PRIMARY KEY REFERENCES f3.collection_jobs(id),
    trigger_bin_id              VARCHAR(20) NOT NULL,
    trigger_cluster_id          VARCHAR(20) NOT NULL,
    trigger_urgency_score       INTEGER NOT NULL,
    trigger_waste_category      VARCHAR(50) NOT NULL,
    cluster_ids                 VARCHAR(20)[] DEFAULT '{}', -- all clusters in job
    bin_ids                     VARCHAR(20)[] DEFAULT '{}', -- all bins in job
    wait_window_applied         BOOLEAN DEFAULT FALSE,
    wait_window_start_at        TIMESTAMPTZ,
    wait_window_end_at          TIMESTAMPTZ,
    additional_clusters_found   INTEGER DEFAULT 0,
    failure_reason              TEXT,
    escalated_reason            TEXT,
    driver_rejection_count      INTEGER DEFAULT 0,
    created_at                  TIMESTAMPTZ DEFAULT NOW()
);

-- Routine job details (1:1 with collection_jobs where job_type = 'routine')
CREATE TABLE f3.routine_job_details (
    job_id              UUID PRIMARY KEY REFERENCES f3.collection_jobs(id),
    schedule_id         UUID REFERENCES f3.routine_schedules(id),
    scheduled_date      DATE NOT NULL,
    scheduled_time      TIME NOT NULL,
    zone_coverage       VARCHAR(20) DEFAULT 'full_zone',
    waste_category_id   INTEGER,
    bin_ids             VARCHAR(20)[] DEFAULT '{}',
    cluster_ids         VARCHAR(20)[] DEFAULT '{}',
    failure_reason      TEXT,
    escalated_reason    TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Job execution metrics (1:1 with collection_jobs — populated at completion)
CREATE TABLE f3.job_execution_metrics (
    job_id                  UUID PRIMARY KEY REFERENCES f3.collection_jobs(id),
    actual_weight_kg        DECIMAL(8,2),
    planned_distance_km     DECIMAL(8,2),
    actual_distance_km      DECIMAL(8,2),
    planned_duration_min    INTEGER,
    actual_duration_min     INTEGER,
    bins_collected_count    INTEGER DEFAULT 0,
    bins_skipped_count      INTEGER DEFAULT 0,
    bins_total_count        INTEGER DEFAULT 0,
    vehicle_utilisation_pct DECIMAL(5,2),
    distance_efficiency_pct DECIMAL(5,2),
    duration_efficiency_pct DECIMAL(5,2),
    hyperledger_tx_id       VARCHAR(200),
    kafka_offset            BIGINT,
    recorded_at             TIMESTAMPTZ DEFAULT NOW()
);

-- Individual bin collections within a job
CREATE TABLE f3.bin_collection_records (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id                      UUID NOT NULL REFERENCES f3.collection_jobs(id),
    bin_id                      VARCHAR(20) NOT NULL,
    cluster_id                  VARCHAR(20) NOT NULL,   -- denormalized
    sequence_number             INTEGER NOT NULL,
    planned_arrival_at          TIMESTAMPTZ,
    arrived_at                  TIMESTAMPTZ,
    collected_at                TIMESTAMPTZ,
    skipped_at                  TIMESTAMPTZ,
    skip_reason                 VARCHAR(30),
    skip_notes                  TEXT,
    fill_level_at_collection    DECIMAL(5,2),
    estimated_weight_kg         DECIMAL(8,2),
    actual_weight_kg            DECIMAL(8,2),
    driver_notes                TEXT,
    photo_url                   TEXT,
    gps_lat                     DECIMAL(10,7),
    gps_lng                     DECIMAL(10,7),
    gps_accuracy_m              DECIMAL(6,2),
    created_at                  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (job_id, bin_id),
    CONSTRAINT chk_collected_xor_skipped CHECK (
        NOT (collected_at IS NOT NULL AND skipped_at IS NOT NULL)
    )
);

-- State transition audit log (immutable — append only)
-- Also used to derive timing: WHERE job_id = ? AND to_state = 'DISPATCHED'
CREATE TABLE f3.job_state_transitions (
    id              BIGSERIAL PRIMARY KEY,
    job_id          UUID NOT NULL REFERENCES f3.collection_jobs(id),
    from_state      VARCHAR(50),
    to_state        VARCHAR(50) NOT NULL,
    reason          TEXT,
    actor           VARCHAR(100),
    metadata        JSONB,
    transitioned_at TIMESTAMPTZ DEFAULT NOW()
);

-- Step execution log (orchestrator records each external call)
CREATE TABLE f3.job_step_results (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id          UUID NOT NULL REFERENCES f3.collection_jobs(id),
    step_name       VARCHAR(100) NOT NULL,
    attempt_number  INTEGER DEFAULT 1,
    success         BOOLEAN NOT NULL,
    service_called  VARCHAR(100),
    request_payload JSONB,
    response_payload JSONB,
    error_message   TEXT,
    duration_ms     INTEGER,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Driver assignment history per job
CREATE TABLE f3.driver_assignment_history (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id          UUID NOT NULL REFERENCES f3.collection_jobs(id),
    driver_id       VARCHAR(20) REFERENCES f3.drivers(id),
    vehicle_id      VARCHAR(20),
    assignment_type VARCHAR(20) NOT NULL,  -- offered/accepted/rejected/timeout/released
    rejection_reason VARCHAR(100),
    offered_at      TIMESTAMPTZ DEFAULT NOW(),
    responded_at    TIMESTAMPTZ
);

-- Vehicle weight log per job
CREATE TABLE f3.vehicle_weight_logs (
    id              BIGSERIAL PRIMARY KEY,
    job_id          UUID NOT NULL REFERENCES f3.collection_jobs(id),
    vehicle_id      VARCHAR(20) NOT NULL,
    max_cargo_kg    DECIMAL(8,2) NOT NULL,
    weight_before_kg DECIMAL(8,2),
    weight_after_kg  DECIMAL(8,2),
    net_cargo_kg     DECIMAL(8,2) GENERATED ALWAYS AS (weight_after_kg - weight_before_kg) STORED,
    utilisation_pct  DECIMAL(5,2) GENERATED ALWAYS AS (((weight_after_kg - weight_before_kg) / max_cargo_kg) * 100) STORED,
    recorded_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (job_id, vehicle_id)
);
```

---

## Kafka Topics — Complete Registry

F4 owns all topics. F4 creates them before any service runs.

```
Topic                           Publisher            Consumers                        Retention
──────────────────────────────────────────────────────────────────────────────────────────────────────
waste.bin.telemetry             F1 EMQX              F2 Flink                         7 days
waste.bin.processed             F2 Flink             F3 orchestrator, F3 bin-status   3 days
waste.bin.dashboard.updates     F3 bin-status-svc    F3 notification-service          5 min
waste.vehicle.location          F1/Flutter           F3 scheduler-service, F2 Flink   7 days
waste.vehicle.dashboard.updates F3 scheduler-svc     F3 notification-service          5 min
waste.vehicle.deviation         F2 Flink             F3 scheduler-service             1 day
waste.routine.schedule.trigger  F4 Airflow           F3 orchestrator                  1 day
waste.job.completed             F3 orchestrator      F2 Spark, F4 Hyperledger         30 days
waste.driver.responses          F3 Flutter→Kong      F3 orchestrator                  1 day
waste.zone.statistics           F2 Flink             F3 bin-status-service            7 days
waste.audit.events              F3 orchestrator      F4 Hyperledger                   365 days
waste.model.retrained           F2 Spark             F3 orchestrator                  1 day
```

**Removed from v1.0**: `waste.collection.jobs`, `waste.routes.optimized`, `waste.bin.status.changed`

**Key note on OR-Tools**: OR-Tools is no longer a Kafka consumer. It is a synchronous REST service called by the scheduler: `POST /internal/route-optimizer/solve`. The scheduler calls it during the DISPATCHING step with a 35-second timeout. On timeout, the scheduler falls back to nearest-neighbour routing.

---

## Service Specifications

---

### SERVICE 1 — Bin Sensor Firmware
**Owner:** F1 | **Language:** C++ (ESP32) | **Repo:** group-f-edge/firmware

#### Responsibility
Read bin fill level using an ultrasonic sensor. Manage power efficiently using deep sleep cycles. Publish readings via MQTT. Handle network failures with local buffering.

#### How it works

The ESP32 wakes from deep sleep based on fill tier. It fires the ultrasonic sensor, calculates fill percentage using bin_depth_cm from the device configuration (pushed via Leshan), and publishes to EMQX.

```
Measurement logic:
  distance_cm = ultrasonic.measure()
  bin_depth_cm = from device config (default 120 cm)
  fill_pct = ((bin_depth_cm - distance_cm) / bin_depth_cm) × 100
  fill_pct = clamp(fill_pct, 0, 100)

Sleep cycle (thresholds from device config — defaults shown):
  fill < 50%:   sleep 10 minutes  (normal)
  fill 50-75%:  sleep 5 minutes   (monitor)
  fill 75-90%:  sleep 2 minutes   (urgent)
  fill > 90%:   sleep 30 seconds  (critical — frequent updates)
```

#### MQTT Message Published

```json
Topic: sensors/bin/BIN-047/telemetry

{
  "bin_id": "BIN-047",
  "fill_level_pct": 85.3,
  "battery_level_pct": 72.1,
  "signal_strength_dbm": -67,
  "temperature_c": 28.4,
  "timestamp": "2026-04-15T09:14:22Z",
  "firmware_version": "2.1.4",
  "error_flags": 0
}
```

#### Integration
- Publishes to EMQX (F1 internal)
- EMQX bridges to Kafka `waste.bin.telemetry`
- Eclipse Leshan (F1) manages device registration; device config (bin_depth_cm, sleep intervals, thresholds) pushed via LwM2M and stored in `f2.devices`

---

### SERVICE 2 — Edge Gateway
**Owner:** F1 | **Platform:** Raspberry Pi | **Runtime:** Node-RED | **Repo:** group-f-edge/gateway

#### Responsibility
Aggregate sensor data from multiple ESP32 devices in a zone. Apply edge filtering. Buffer data during network outages. Forward valid readings to cloud EMQX.

#### Processing
1. **Deduplication** — reject if same bin_id sent identical value within 60 seconds
2. **Sanity check** — reject if fill_level outside 0-100 or timestamp > 5 minutes old
3. **Buffering** — if cloud EMQX unavailable, store in local queue (max 1000 messages)
4. **Forward** — publish to cloud EMQX on `sensors/bin/{bin_id}/telemetry`

---

### SERVICE 3 — EMQX MQTT Broker
**Owner:** F4 (deployed) / F1 (configured) | **Repo:** group-f-platform/messaging

#### Bridge configuration

```yaml
bridges:
  - name: kafka_bridge
    type: kafka
    bootstrap_servers: kafka.messaging.svc.cluster.local:9092
    topic_mapping:
      - mqtt_topic: "sensors/bin/+/telemetry"
        kafka_topic: "waste.bin.telemetry"
        qos: 1
      - mqtt_topic: "vehicle/+/location"
        kafka_topic: "waste.vehicle.location"
        qos: 1
```

---

### SERVICE 4 — Flink Stream Processor
**Owner:** F2 | **Language:** Python (PyFlink) | **Repo:** group-f-data/flink-processor

#### Responsibility
Real-time stream processing of all sensor and vehicle data. Classifies bin urgency. Calculates fill rates and predicted full times. Detects anomalies. Computes zone-level aggregations. Detects vehicle route deviations. Writes all results to InfluxDB, PostgreSQL (bin_current_state upsert), and Redis.

#### Processing pipelines

**Pipeline 1 — Bin telemetry processor**

```
Source: Kafka waste.bin.telemetry
        │
        ├── Raw writer → InfluxDB bin_readings_raw
        │
        ├── Load bin metadata from PostgreSQL (bins + bin_clusters + waste_categories)
        │     (loaded via F2 internal DB connection)
        │
        ├── Calculate estimated_weight_kg:
        │     fill_pct × volume_litres × avg_kg_per_litre
        │
        ├── Urgency classification:
        │     fill < 50%:    status=normal,   urgency_score=0-30
        │     fill 50-75%:   status=monitor,  urgency_score=30-60
        │     fill 75-90%:   status=urgent,   urgency_score=60-85
        │     fill > 90%:    status=critical, urgency_score=85-100
        │     e_waste bins get urgency_score bumped +10 (special_handling)
        │
        ├── Fill rate calculation (keyed state per bin):
        │     fill_rate = (current_fill - previous_fill) / time_diff_hours
        │     predicted_full_at = NOW() + (100 - fill_pct) / fill_rate
        │
        ├── Anomaly detection:
        │     fill rate > 15%/hour → RAPID_FILLING alert
        │     fill rate < -5%/hour → POSSIBLE_TAMPERING alert
        │     no reading for 30 min → SENSOR_OFFLINE alert
        │     battery < 10% → LOW_BATTERY alert
        │
        ├── Write to InfluxDB bin_readings_processed
        │
        ├── DUAL WRITE — both of these happen on every reading:
        │     1. UPSERT → PostgreSQL f2.bin_current_state
        │           (includes denormalized: cluster_id, zone_id,
        │            waste_category_id, volume_litres)
        │     2. HSET → Redis bin:{bin_id} {...} EX 1800
        │           (TTL = 30 min → key expiry = sensor offline detection)
        │
        └── Publish to Kafka waste.bin.processed
```

**Pipeline 2 — Zone aggregation (sliding 10-min window, every 2 min)**

```
Source: Kafka waste.bin.processed
  Key by zone_id
  Sliding window: 10 min, slide 2 min
  Aggregate per zone:
    avg_fill_level_pct
    urgent_bin_count (urgency_score > 60)
    critical_bin_count (urgency_score > 85)
    total_estimated_weight_kg
    category_breakdown (per waste_category)
  Write to PostgreSQL f2.zone_snapshots
  Publish to Kafka waste.zone.statistics
  Write to InfluxDB zone_statistics
```

**Pipeline 3 — Vehicle deviation detector**

```
Source: Kafka waste.vehicle.location
  Key by vehicle_id
  Load planned route from PostgreSQL f2.route_plans
  Compare GPS to planned waypoints (Haversine)
  Maintain 5-min deviation history in keyed state
  If deviation > 500m for > 2 minutes:
    Publish to Kafka waste.vehicle.deviation
```

**Pipeline 4 — Vehicle position historian**

```
Source: Kafka waste.vehicle.location
  Write directly to InfluxDB vehicle_positions (no processing)
```

---

### SERVICE 5 — FastAPI ML Service
**Owner:** F2 | **Language:** Python | **Repo:** group-f-data/ml-service

#### Responsibility
Expose trained ML models as REST APIs. Serve fill time predictions, waste generation forecasts, route quality scoring. Load current production model from MLflow at startup.

#### Endpoints

```
GET  /api/v1/ml/predict/fill-time
     Query: bin_id, current_fill_level
     Returns: predicted_full_at, confidence_interval

GET  /api/v1/ml/predict/zone-generation
     Query: zone_id, date_range
     Returns: predicted_kg_per_day, by_waste_category

POST /api/v1/ml/score/route
     Body: route_plan with stops and weights
     Returns: efficiency_score, suggestions

GET  /api/v1/ml/trends/waste-generation
     Query: zone_id, period (week/month/quarter)
     Returns: time-series of waste generated by category

GET  /health
     Returns: {status, model_version, loaded_at}
```

This service is also responsible for serving bin metadata queries from F3. Because F3 cannot read f2 schema directly, F2 exposes read-only REST endpoints for bin, cluster, zone, vehicle, and waste category data via Kong.

**Additional F2 data access endpoints (for F3 consumption):**

```
GET  /api/v1/bins
     Query: zone_id, cluster_id, status, waste_category, page, limit
     Returns: bins with current state (joins bin_current_state + bins + clusters)

GET  /api/v1/bins/:bin_id
     Returns: bin detail with current state, cluster, zone, waste category

GET  /api/v1/bins/:bin_id/history
     Query: from, to, interval
     Returns: fill level time-series from InfluxDB

GET  /api/v1/clusters/:cluster_id
     Returns: cluster with all its bins and their current states

GET  /api/v1/clusters/:cluster_id/snapshot
     Returns: urgency summary for cluster (max urgency, total weight, bin list)
     Called by: F3 workflow orchestrator to get cluster state before dispatch

POST /api/v1/clusters/scan-nearby
     Body: { lat, lng, radius_km, min_urgency_score }
     Returns: clusters within radius meeting urgency threshold
     Called by: F3 orchestrator during wait window scan (Option C)

GET  /api/v1/zones
GET  /api/v1/zones/:zone_id/summary
GET  /api/v1/waste-categories

GET  /api/v1/vehicles/available
     Query: waste_category, min_cargo_kg
     Returns: available vehicles matching criteria
     Called by: F3 scheduler during dispatch

GET  /api/v1/vehicles/:vehicle_id

PATCH /api/v1/vehicles/:vehicle_id/status
     Body: { status: 'dispatched' | 'available' | 'maintenance' }
     Called by: F3 scheduler on dispatch and job completion

POST /api/v1/bins/:bin_id/mark-collected
     Body: { job_id, driver_id, collected_at, fill_level_at_time }
     Called by: F3 orchestrator on job completion
     Resets bin_current_state fill level and sets last_collected_at
```

---

### SERVICE 6 — OR-Tools Route Optimizer
**Owner:** F2 | **Language:** Python + FastAPI | **Repo:** group-f-data/route-optimizer

#### Responsibility
Synchronous REST service. Solve the Capacitated VRP with Time Windows. Called by the scheduler service during job dispatch. Returns an optimised route or a fallback nearest-neighbour route on timeout.

#### How it is called

OR-Tools is no longer a Kafka consumer. It is called synchronously:

```
POST /internal/route-optimizer/solve
Body: {
  zone_id: int,
  bins_to_collect: [{ bin_id, cluster_id, lat, lng,
                      estimated_weight_kg, urgency_score,
                      deadline_iso, waste_category }],
  available_vehicles: [{ vehicle_id, max_cargo_kg,
                          waste_categories_supported }],
  depot: { lat, lng }
}
Response: {
  vehicle_id: string,
  waypoints: [...],               // ordered cluster stops
  total_clusters: int,
  total_bins: int,
  estimated_weight_kg: float,
  estimated_distance_km: float,
  estimated_minutes: int,
  solver_time_ms: int,
  solver_method: "or_tools" | "nearest_neighbour_fallback"
}
```

**Timeout behaviour**: 30-second internal time limit for OR-Tools solver. If solver exceeds 30 seconds, falls back to nearest-neighbour heuristic and returns that result. The scheduler has an outer 35-second HTTP timeout for the entire call.

#### VRP constraints

```
1. Capacity:
   sum(estimated_weight_kg for bins at all stops) <= vehicle.max_cargo_kg

2. Time windows:
   urgency_score >= 90 OR e_waste → deadline 60 min from now
   urgency_score >= 80            → deadline 120 min from now
   urgency_score >= 70            → deadline 240 min from now
   routine bins                   → end of scheduled collection window

3. Waste category:
   vehicle must support waste category of every bin in route

4. Weight estimation:
   Uses estimated_weight_kg already computed by Flink
   (fill_pct × volume_litres × avg_kg_per_litre from waste_categories)

Objective: minimise total distance, heavy penalty for missing deadlines
```

---

### SERVICE 7 — Airflow Batch Orchestrator
**Owner:** F2 | **Platform:** Apache Airflow | **Repo:** group-f-data/airflow-dags

#### DAG 1 — nightly_ml_retraining (Sunday 00:00)

```
Task 1: validate_training_data (Great Expectations)
Task 2: extract_training_dataset (joins readings + completions)
Task 3: train_fill_prediction_model (LightGBM → MLflow)
Task 4: train_generation_trend_model (LSTM → MLflow)
Task 5: promote_models_if_better (compare MAE — promote if > 5% improvement)
         → publishes waste.model.retrained to Kafka if promoted
Task 6: update_zone_analytics (Spark → InfluxDB waste_generation_trends)
Task 7: generate_weekly_route_schedule (OR-Tools for next week's routines)
```

#### DAG 2 — routine_job_generator (daily 23:00)

```
Task 1: check_tomorrows_schedules (query f3.routine_schedules)
Task 2: generate_routine_jobs
        For each scheduled zone:
          Query all active bins and clusters
          Create f3.collection_jobs records (job_type = routine)
          Publish waste.routine.schedule.trigger to Kafka
Task 3: notify_operations_team (dashboard summary notification)
```

#### DAG 3 — data_quality_checks (every 6 hours)

```
Great Expectations suite:
  Check bin_current_state freshness (all active bins < 2 hours old)
  Check for stuck fill levels (same exact value > 4 hours)
  Check vehicle_positions continuity (active jobs < 10 min GPS gap)
  Check Redis TTL health (compare expired keys vs device last_seen_at)
  Alert F4 monitoring on any failure
```

---

### SERVICE 8 — Bin Status Service
**Owner:** F3 | **Language:** Node.js + TypeScript + Fastify + Prisma | **Repo:** group-f-application/bin-status-service

#### Responsibility
Consume `waste.bin.processed` and `waste.zone.statistics` from Kafka. Apply business rules to determine if collection should be requested. Enrich processed events and publish to `waste.bin.dashboard.updates` for the notification service to stream. Respond to orchestrator internal calls for cluster snapshots and nearby-cluster scans.

**Note**: This service does not directly query f2 PostgreSQL. It calls F2's REST APIs via Kong for any f2 data it needs.

#### Kafka consumption and publishing

```
Consumes: waste.bin.processed
  Enriches each event with cluster metadata (via F2 API call, cached)
  Checks urgency business rules
  Publishes to waste.bin.dashboard.updates:
  {
    event_type: "bin:update",
    bin_id, cluster_id, cluster_name, zone_id,
    fill_level_pct, status, urgency_score,
    estimated_weight_kg, waste_category, waste_category_colour,
    fill_rate_pct_per_hour, predicted_full_at,
    battery_level_pct, has_active_job, last_collected_at,
    collection_triggered: boolean
  }
  Throttle: always publish if status changed or urgency_score >= 80;
            otherwise max once per minute for unchanged normal bins

Consumes: waste.zone.statistics (from Flink)
  Enriches with zone metadata (zone name, active job count)
  Updates zone summary cache
  Publishes to waste.bin.dashboard.updates with event_type: "zone:stats"
```

#### Internal API (for orchestrator)

```
POST /internal/clusters/:cluster_id/snapshot
     Returns: {
       cluster_id, cluster_name, zone_id,
       bins: [{ bin_id, waste_category, fill_level_pct,
                urgency_score, estimated_weight_kg,
                predicted_full_at, status }],
       max_urgency_score, total_weight_kg
     }
     Data source: calls F2 GET /api/v1/clusters/:cluster_id/snapshot

POST /internal/clusters/scan-nearby
     Body: { lat, lng, radius_km, min_urgency_score }
     Returns: nearby clusters approaching urgency threshold
     Data source: calls F2 POST /api/v1/clusters/scan-nearby
     Used by: orchestrator during wait window scan (Option C)
```

#### Public API (via Kong)

```
GET  /api/v1/bins             → proxies to F2 /api/v1/bins
GET  /api/v1/bins/:bin_id     → proxies to F2 /api/v1/bins/:bin_id
GET  /api/v1/bins/:bin_id/history  → calls F2 ML service history endpoint
GET  /api/v1/zones/:zone_id/summary → returns zone summary with business context
GET  /health
```

---

### SERVICE 9 — Scheduler Service
**Owner:** F3 | **Language:** Node.js + TypeScript + Fastify + Prisma | **Repo:** group-f-application/scheduler-service

#### Responsibility
Called by the orchestrator to dispatch a driver and vehicle to a job. Internally calls OR-Tools REST to get the optimised route. Tracks vehicle cargo weight and GPS progress. Handles driver collection API calls. Publishes enriched vehicle position events.

**Note**: Vehicle and bin data is obtained from F2 REST APIs via Kong. Only f3 schema tables are written directly.

#### Kafka consumption and publishing

```
Consumes: waste.vehicle.location
  For each vehicle GPS ping:
    Looks up active job assignment for that vehicle
    Enriches event with job context (job_id, driver_id, bins_collected, cargo_weight_kg)
    Publishes to waste.vehicle.dashboard.updates:
    {
      vehicle_id, driver_id, job_id, zone_id,
      lat, lng, speed_kmh,
      cargo_weight_kg, cargo_limit_kg, cargo_utilisation_pct,
      bins_collected, bins_total,
      current_cluster, next_cluster
    }
    Updates bin_collection_records.arrived_at when vehicle is within 50m of next stop

Consumes: waste.vehicle.deviation
  Forwards to notification service for supervisor alert
```

#### Internal API (for orchestrator)

```
POST /internal/scheduler/dispatch
     Called by: orchestrator during DISPATCHING step
     Body: {
       job_id, zone_id, waste_category, planned_weight_kg,
       cluster_ids, bin_ids, exclude_driver_ids
     }
     Process:
       1. Call F2 GET /api/v1/vehicles/available
            (filtered by waste_category, min_cargo_kg)
       2. Find available driver with matching vehicle and zone
       3. Call OR-Tools POST /internal/route-optimizer/solve
            (35-second HTTP timeout)
       4. If OR-Tools timeout: fall back to nearest-neighbour route
       5. Write route_plan_id to f3.collection_jobs
       6. PATCH F2 /api/v1/vehicles/:id/status → 'dispatched'
       7. UPDATE f3.drivers SET status = 'on_job'
       8. Call F3 notification-service to send driver push
       9. Write f3.driver_assignment_history record
     Returns: { success, driver_id, vehicle_id, route_plan_id,
                estimated_start, waypoints_summary }

POST /internal/scheduler/release
     Called by: orchestrator on job cancellation
     Body: { job_id, driver_id, vehicle_id }
     PATCH F2 /api/v1/vehicles/:id/status → 'available'
     UPDATE f3.drivers SET status = 'available'
```

#### Driver API (via Kong)

```
POST /api/v1/collections/:job_id/bins/:bin_id/collected
     Body: { fill_level_at_collection, gps_lat, gps_lng,
             actual_weight_kg, notes, photo_url }
     Updates: f3.bin_collection_records.collected_at
     Calculates cumulative cargo weight
     If cargo > 90% vehicle capacity:
       Notifies orchestrator via internal call

POST /api/v1/collections/:job_id/bins/:bin_id/skip
     Body: { reason: 'locked' | 'inaccessible' | 'already_empty' |
                      'hazardous' | 'bin_missing' | 'other', notes }
     Updates: f3.bin_collection_records.skipped_at

GET  /api/v1/vehicles/active       (supervisor/fleet-operator)
GET  /api/v1/drivers/available     (supervisor/fleet-operator)
GET  /api/v1/jobs/:job_id/progress (supervisor/fleet-operator/driver own job)
GET  /health
```

---

### SERVICE 10 — Collection Workflow Orchestrator
**Owner:** F3 | **Language:** Node.js + TypeScript + Fastify + Prisma | **Repo:** group-f-application/workflow-orchestrator

#### Responsibility
Manage the complete lifecycle of both routine and emergency collection jobs. Maintain explicit state machine. Implement wait window logic (Option C) for non-critical urgent bins. Handle driver rejection with retry. Escalate to supervisor when automation cannot resolve. Record completions on blockchain.

#### State machine

```
CREATED → BIN_CONFIRMING → BIN_CONFIRMED
        → CLUSTER_ASSEMBLING → CLUSTER_ASSEMBLED
        → DISPATCHING → DISPATCHED → DRIVER_NOTIFIED
        → IN_PROGRESS (driver collecting)
        → COMPLETING → COLLECTION_DONE
        → RECORDING_AUDIT → AUDIT_RECORDED
        → COMPLETED

Failure paths:
        → FAILED
        → ESCALATED
        → CANCELLED
        → DRIVER_REASSIGNMENT
```

#### Two entry points

**Emergency entry (Kafka waste.bin.processed):**
```
Condition: urgency_score >= 80 AND no active job for this bin's cluster
Creates: f3.collection_jobs (job_type = 'emergency')
Runs full workflow from CREATED
```

**Routine entry (Kafka waste.routine.schedule.trigger):**
```
Creates: f3.collection_jobs (job_type = 'routine')
Skips BIN_CONFIRMING step
Runs from CLUSTER_ASSEMBLING state
Cluster list = all clusters in zone with scheduled collection
```

#### Emergency workflow execution

**Step 1 — Confirm bin urgency (BIN_CONFIRMING)**
```
Calls: F3 bin-status-service POST /internal/clusters/:cluster_id/snapshot
Timeout: 5 seconds
If cluster no longer has urgent bins → CANCELLED
If still urgent → BIN_CONFIRMED
Records trigger in f3.emergency_job_details
```

**Step 2 — Wait window and cluster assembly (CLUSTER_ASSEMBLING)**

This implements Option C — before dispatching, scan for nearby clusters approaching urgency to batch them into the same job.

```
Critical dispatch (skip wait):
  if urgency_score >= 90 OR waste_category = 'e_waste':
    → immediately proceed to CLUSTER_ASSEMBLED with trigger cluster only

Non-critical urgent dispatch (wait window):
  max_wait = min(predicted_full_at - 45 minutes, 30 minutes)
  During wait window, call F3 bin-status-service
    POST /internal/clusters/scan-nearby
    { lat: trigger_cluster.lat, lng: trigger_cluster.lng,
      radius_km: 2.0, min_urgency_score: 65 }
  Collect nearby clusters approaching urgency
  After max_wait elapses:
    Build final bin_ids and cluster_ids list
    Calculate total_weight_kg for all selected bins
    → CLUSTER_ASSEMBLED

Records in f3.emergency_job_details:
  wait_window_applied, wait_window_start_at/end_at, additional_clusters_found
```

**Step 3 — Dispatch (DISPATCHING)**
```
Calls: F3 scheduler-service POST /internal/scheduler/dispatch
  Body: { job_id, zone_id, waste_category,
          planned_weight_kg (total of all selected bins),
          cluster_ids, bin_ids, exclude_driver_ids }
The scheduler internally calls OR-Tools to compute the route.
Retry: 3 attempts, 2-minute wait between attempts
If all fail → ESCALATED, notify supervisor
→ DISPATCHED
```

**Step 4 — Notify driver (DRIVER_NOTIFIED)**
```
Scheduler service handles push notification during dispatch.
Orchestrator records transition to DRIVER_NOTIFIED.
```

**Step 5 — Wait for driver acceptance**
```
Driver taps Accept in Flutter app
→ POST /api/v1/collection-jobs/:job_id/accept
→ DRIVER_ACCEPTED → IN_PROGRESS

If driver rejects:
  Records rejection in f3.driver_assignment_history
  Returns to step 3 with exclude_driver_ids += rejected driver
  Max 3 rejections before ESCALATED

If timeout (10 minutes):
  Releases driver, returns to step 3
  Second timeout → ESCALATED
```

**Step 6 — Monitor in progress**
```
Job stays IN_PROGRESS while driver collects
Scheduler tracks bin-by-bin progress and vehicle weight
If vehicle > 90% capacity mid-route:
  Orchestrator is notified by scheduler
  Remaining bins split into new job automatically
```

**Step 7 — Complete**
```
Scheduler reports all bins actioned (collected or skipped)
Orchestrator calls F2 POST /api/v1/bins/:bin_id/mark-collected
  for each collected bin
Calculates actual vs planned metrics
→ COLLECTION_DONE
```

**Step 8 — Record audit**
```
Calls Hyperledger service via Kong
Records: job_id, all bin_ids, driver_id, vehicle_id,
         timestamps (from job_state_transitions), actual weights, GPS trail hash
Returns: transaction_id → stored in f3.job_execution_metrics.hyperledger_tx_id
→ AUDIT_RECORDED → COMPLETED
```

**Step 9 — Publish completion**
```
Publishes waste.job.completed to Kafka
F2 Spark uses this for model retraining labels
F4 Hyperledger has secondary consumer for archival
```

#### Job Status API

```
GET  /api/v1/collection-jobs          (supervisor, fleet-operator)
GET  /api/v1/collection-jobs/:job_id  (supervisor, fleet-operator, driver own jobs)
GET  /api/v1/collection-jobs/stats    (supervisor)
POST /api/v1/collection-jobs/:job_id/cancel   (supervisor only)
POST /api/v1/collection-jobs/:job_id/accept   (driver — own job only)
GET  /health
```

---

### SERVICE 11 — Notification Service
**Owner:** F3 | **Language:** Node.js + TypeScript + Fastify + Socket.IO + Redis adapter | **Repo:** group-f-application/notification-service

#### Responsibility
Pure delivery service. Consume `waste.bin.dashboard.updates` and `waste.vehicle.dashboard.updates` from Kafka and stream them to connected clients via Socket.IO. Accept direct HTTP calls from the orchestrator and scheduler for discrete alert notifications. No business logic. No database queries. No enrichment.

#### Kafka consumption (pure streaming)

```
Consumes: waste.bin.dashboard.updates (published by bin-status-service)
  Already enriched — just stream to correct Socket.IO room
  socket.to(`dashboard-zone-${event.zone_id}`).emit('bin:update', event)
  socket.to('dashboard-all').emit('bin:update', event)

Consumes: waste.vehicle.dashboard.updates (published by scheduler-service)
  Already enriched — just stream
  socket.to('fleet-ops').emit('vehicle:position', event)
  socket.to(`dashboard-all`).emit('vehicle:position', event)
```

#### Direct HTTP calls (from orchestrator/scheduler)

```
POST /internal/notify/driver-assigned
  { driver_id, job_id, route_summary }
  Pushes to Socket.IO room driver-{driver_id}
  Sends FCM push if driver not connected

POST /internal/notify/job-cancelled
  { driver_id, job_id, reason }

POST /internal/notify/job-escalated
  { supervisor_id, job_id, reason, urgent_bins }

POST /internal/notify/route-updated
  { driver_id, job_id, message }

POST /internal/notify/vehicle-deviation
  { fleet_operator_room, vehicle_id, deviation_m, message }
```

#### Socket.IO rooms

```
dashboard-zone-{zone_id}  → supervisors watching a specific zone
dashboard-all             → supervisors watching full city
driver-{driver_id}        → individual driver
fleet-ops                 → fleet operators

Events emitted:
  bin:update        → { bin_id, fill_level, status, urgency_score,
                        estimated_weight_kg, waste_category,
                        waste_category_colour, predicted_full_at,
                        cluster_id, zone_id, has_active_job }
  vehicle:position  → { vehicle_id, driver_id, job_id, lat, lng,
                        speed_kmh, cargo_weight_kg, cargo_limit_kg,
                        cargo_utilisation_pct, bins_collected, bins_total }
  job:status        → { job_id, state, zone_id }
  alert:urgent      → { bin_id, urgency_score, zone_id, message }
  alert:deviation   → { vehicle_id, deviation_m, message }
  zone:stats        → { zone_id, avg_fill, urgent_count, weight_kg }
```

#### Redis adapter
Multi-pod Socket.IO synchronisation uses Redis adapter (same Redis instance used by bin_current_state). This ensures a dashboard client connected to pod A receives events published by pod B.

---

### SERVICE 12 — Next.js Dashboard
**Owner:** F3 | **Language:** TypeScript + React | **Repo:** group-f-application/web-dashboard

#### Responsibility
Provide municipality supervisors and fleet operators with real-time operational visibility. Display live bin fill levels and vehicle positions on a Mapbox map using the REST + Socket.IO pattern. Show analytics and historical data.

#### Data loading pattern

```
Initial load (REST via Kong):
  GET /api/v1/bins?zone_id=&limit=1000 → seed all bin states
  GET /api/v1/vehicles/active           → seed all active vehicles
  GET /api/v1/collection-jobs?state=active → seed active jobs

Live delta (Socket.IO from notification service):
  bin:update events → update bin marker colour and state
  vehicle:position events → move vehicle marker
  job:status events → update job panel
  alert:* events → alert banner

Note: bin:update and vehicle:position events arrive already enriched
from bin-status-service and scheduler-service respectively.
The dashboard renders directly without any additional API calls.
```

#### Views

**View 1 — Live operations map**
```
Mapbox map:
  Cluster markers (one per cluster, not per bin) at zoom < 13
    Colour = worst bin status in cluster
    Size proportional to total_weight_kg
  Individual bin markers at zoom >= 13
  Vehicle markers with heading arrow
  Route polylines per active job
  Zone boundary overlays (toggleable)
  Filter panel: zone, waste category, status

Data: REST initial load + Socket.IO bin:update + vehicle:position
```

**View 2 — Job management**
```
Active jobs (live — Socket.IO job:status events)
  Job card: type, zone, driver, vehicle,
            progress (X/N bins), cargo weight bar,
            current state with colour, est. completion
  Click → detail drawer with full state timeline

Completed jobs (REST):
  Filterable table, export CSV
  Each row includes Hyperledger TX ID for audit
```

**View 3 — Bin detail panel**
```
Opens when supervisor clicks bin or cluster on map:
  Fill level gauge, waste category badge, estimated weight
  Predicted full time, battery level
  7-day fill chart (F2 FastAPI history endpoint)
  Collection history (last 5 jobs)
```

**View 4 — Analytics**
```
Zone + time period selector
  Chart 1: Waste generation by category (stacked bar, daily)
  Chart 2: Fill rate heatmap (zones × hours)
  Chart 3: Collection efficiency (planned vs actual)
  Chart 4: Vehicle utilisation
  Chart 5: 7-day predictive forecast
  All sourced from F2 FastAPI ML endpoints via Kong
```

**View 5 — Historical retrieval**
```
Search by bin_id, job_id, driver, vehicle, date range, zone
Bin history: fill time-series + every collection event
Job history: full state timeline + step log + audit TX ID
Export to CSV/PDF
```

---

### SERVICE 13 — Flutter Mobile App (Driver)
**Owner:** F3 | **Language:** Dart | **Repo:** group-f-application/mobile-app

#### Responsibility
Driver-facing app. Shows assigned collection route with cluster stops on a map. Allows driver to mark bins collected or skipped at each cluster stop. Accepts or rejects job assignments. Publishes GPS while on an active job. Shows job history.

#### Core flows

**Job acceptance:**
```
FCM push notification → driver opens app → job detail screen
  Map with cluster stops (not individual bin markers)
  Total bins, estimated weight, duration, weight vs capacity
  [ACCEPT] → POST /api/v1/collection-jobs/:id/accept
           → GPS publishing starts via MQTT
  [REJECT] → POST /api/v1/collection-jobs/:id/reject
           → { reason: 'too_heavy' | 'out_of_zone' | 'personal' }
```

**Collection at a cluster stop:**
```
Driver arrives at cluster (proximity < 50m detected):
  App shows all bins at this cluster stop
  For each bin: fill level, waste category, estimated weight

  For each bin:
    [COLLECTED] → confirmation sheet
                   optional: actual weight, notes, photo
                   POST /api/v1/collections/:job_id/bins/:bin_id/collected

    [SKIP]      → reason picker
                   POST /api/v1/collections/:job_id/bins/:bin_id/skip

  When all bins at cluster actioned:
    [Done with this stop] → navigate to next cluster on map
```

**GPS publishing (MQTT, every 5 seconds on active job):**
```json
Topic: vehicle/{vehicle_id}/location
{
  "vehicle_id": "LORRY-03",
  "driver_id": "DRV-007",
  "job_id": "...",
  "lat": 6.9271,
  "lng": 79.8612,
  "speed_kmh": 34,
  "heading_degrees": 182,
  "timestamp": "2026-04-15T09:18:05Z"
}
```
Stop publishing when job completes or app goes to background (battery conservation).

---

### SERVICE 14 — Kong API Gateway
**Owner:** F4 | **Repo:** group-f-platform/gateway

#### Route registry

```
Route                                         Backend                    Auth
──────────────────────────────────────────────────────────────────────────────────────
GET  /api/v1/bins*                            F2 FastAPI (data service)  JWT any role
GET  /api/v1/bins/*/history                   F2 FastAPI                 JWT supervisor
GET  /api/v1/clusters*                        F2 FastAPI                 JWT any role
GET  /api/v1/zones*                           F2 FastAPI                 JWT any role
GET  /api/v1/vehicles*                        F3 scheduler               JWT sup/operator
GET  /api/v1/drivers*                         F3 scheduler               JWT sup/operator
GET  /api/v1/collection-jobs*                 F3 orchestrator            JWT sup/operator
POST /api/v1/collection-jobs/*/accept         F3 orchestrator            JWT driver
POST /api/v1/collection-jobs/*/cancel         F3 orchestrator            JWT supervisor
POST /api/v1/collections/*/bins/*/collected   F3 scheduler               JWT driver
POST /api/v1/collections/*/bins/*/skip        F3 scheduler               JWT driver
GET  /api/v1/ml/*                             F2 FastAPI                 JWT supervisor
WS   /ws                                      F3 notification            JWT all roles
GET  /health/*                                all services               none
```

All `/internal/*` routes are blocked at Kong — internal service calls only within the Kubernetes cluster.

---

### SERVICE 15 — Keycloak Identity Server
**Owner:** F4 | **Repo:** group-f-platform/auth/keycloak

#### Realm: waste-management — Roles

```
admin           — full system access, user management
supervisor      — view all, cancel jobs, analytics, export
fleet-operator  — assign drivers, view vehicles, modify schedules
driver          — own job only, collect/skip, accept/reject
viewer          — read-only dashboard
sensor-device   — machine account for ESP32, MQTT publish only
```

#### Custom driver JWT attributes
`zone_id`, `vehicle_id`, `employee_id`, `fcm_token`, `shift_start`, `shift_end` — embedded in JWT so services need no database lookup for basic driver context.

---

### SERVICE 16 — HashiCorp Vault
**Owner:** F4 | **Repo:** group-f-platform/auth/vault

#### Secret paths

```
secret/waste-mgmt/
├── database/
│   ├── bin-status-service        (f3 schema credentials)
│   ├── scheduler-service         (f3 schema credentials)
│   ├── notification-service      (no DB — still needs Kafka creds)
│   ├── workflow-orchestrator     (f3 schema credentials)
│   ├── fastapi-ml-service        (f2 schema read + write credentials)
│   ├── flink-processor           (f2 schema write credentials)
│   └── route-optimizer           (f2 schema read credentials)
├── redis/
│   host, port, password          (shared Redis instance)
├── kafka/
│   bootstrap-servers, username, password, ssl-cert
├── keycloak/
│   admin-password, client-secrets
├── influxdb/
│   token, org, bucket names
├── external/
│   mapbox-api-key, fcm-server-key, smtp-credentials
├── hyperledger/
│   admin-cert, admin-key, peer-tlscert
└── ci-cd/
    github-token, registry-password
```

All pods receive secrets via Vault agent sidecar injection. No secrets in code or Kubernetes manifests. F3 services receive f3-schema-only database credentials — not f2 schema credentials.

---

### SERVICE 17 — Prometheus + Grafana
**Owner:** F4 | **Repo:** group-f-platform/observability

#### Key metrics

```
Business:
  waste_bins_urgent_total              gauge, by zone/category
  waste_collection_jobs_active         gauge, by job_type
  waste_collection_jobs_completed      counter
  waste_collection_duration_hours      histogram
  waste_lorry_cargo_utilisation        gauge, by vehicle_id
  waste_bins_overflowed_total          counter, by zone
  waste_wait_window_duration_seconds   histogram (Option C wait time)
  waste_clusters_added_during_wait     histogram (additional clusters found)

Platform:
  kafka_consumer_lag                   by topic/group_id
  flink_checkpoint_duration_ms
  redis_key_ttl_expiries_total        (sensor offline events per hour)
  http_request_duration_seconds

Alerts:
  CRITICAL: bin overflow (fill = 100 AND no active job)
  CRITICAL: kafka consumer lag > 10000 for > 5 minutes
  WARNING:  no bin readings from zone > 30 minutes
  WARNING:  collection job ESCALATED
  WARNING:  vehicle deviation > 500m > 3 minutes
  WARNING:  Redis key not refreshed (device offline) for > 30 min
  INFO:     model retrained and promoted
```

---

### SERVICE 18 — Hyperledger Fabric Blockchain
**Owner:** F4 | **Repo:** group-f-platform/blockchain

#### Smart contract — CollectionRecord

```go
type CollectionRecord struct {
    JobID            string      `json:"job_id"`
    JobType          string      `json:"job_type"`
    ZoneID           int         `json:"zone_id"`
    DriverID         string      `json:"driver_id"`
    VehicleID        string      `json:"vehicle_id"`
    ClustersVisited  []string    `json:"clusters_visited"`
    BinsCollected    []BinRecord `json:"bins_collected"`
    TotalWeightKg    float64     `json:"total_weight_kg"`
    RouteDistanceKm  float64     `json:"route_distance_km"`
    StartedAt        string      `json:"started_at"`
    CompletedAt      string      `json:"completed_at"`
    WaitWindowUsed   bool        `json:"wait_window_used"`
    GPSTrailHash     string      `json:"gps_trail_hash"`
    TxID             string      `json:"tx_id"`
    CreatedAt        string      `json:"created_at"`
}

type BinRecord struct {
    BinID           string  `json:"bin_id"`
    ClusterID       string  `json:"cluster_id"`
    WasteCategory   string  `json:"waste_category"`
    FillLevelAtTime float64 `json:"fill_level_at_time"`
    CollectedAt     string  `json:"collected_at"`
    WeightKg        float64 `json:"weight_kg"`
    GPSLat          float64 `json:"gps_lat"`
    GPSLng          float64 `json:"gps_lng"`
}
```

---

## Integration Points Summary

```
F1 → F4    ESP32 → MQTT → EMQX (F4 deployed)
F1 → F2    EMQX bridges → Kafka waste.bin.telemetry
F1/F3 → F2 Flutter GPS → EMQX → Kafka waste.vehicle.location

F2 → F2    Flink upserts bin_current_state (PostgreSQL + Redis dual write)
F2 → F2    Flink publishes waste.bin.processed → F2 internal
F2 → F3    Kafka waste.bin.processed → F3 bin-status-service, F3 orchestrator
F2 → F3    Kafka waste.zone.statistics → F3 bin-status-service
F2 → F3    REST /api/v1/* (bins, clusters, zones, vehicles) called by F3 via Kong

F3 → F2    Kafka waste.job.completed → F2 Spark retraining labels
F3 → F2    REST PATCH /api/v1/vehicles/:id/status (scheduler on dispatch)
F3 → F2    REST POST /api/v1/bins/:id/mark-collected (orchestrator on completion)
F3 → F2    REST POST /internal/route-optimizer/solve (scheduler → OR-Tools, sync)
F3 → F3    bin-status-service → Kafka waste.bin.dashboard.updates → notification-service
F3 → F3    scheduler-service  → Kafka waste.vehicle.dashboard.updates → notification-service
F3 → F3    orchestrator → bin-status-service (cluster snapshot, nearby scan)
F3 → F3    orchestrator → scheduler-service (dispatch, release)
F3 → F3    notification-service → Socket.IO → Next.js / Flutter

F3 → F4    Kafka waste.audit.events → Hyperledger
F3 → F4    REST calls via Kong for all external-facing APIs

F4 → all   Vault injects secrets at pod startup
F4 → all   Keycloak validates JWT on every Kong request
F4 → all   Prometheus scrapes /metrics from every service
F4 → all   Istio injects sidecar for mTLS
F4 → all   Argo CD deploys all services from Helm charts
```

---

## Platform Contract — Rules All Sub-Groups Must Follow

```
1. DOCKERFILE
   Every service must have a Dockerfile at repo root
   Base image: node:20-alpine or python:3.11-slim
   Non-root user, expose /health endpoint

2. HEALTH ENDPOINT
   GET /health → { status: "ok", service: "name", version: "1.0.0" }
   HTTP 200 healthy, HTTP 503 not

3. LOGGING
   Structured JSON to stdout only
   Required fields: timestamp, level, service, message, traceId
   No secrets in logs

4. SECRETS
   Never hardcode. Never in environment variables committed to git.
   Read from /vault/secrets/ files (injected by F4 Vault agent)

5. KAFKA SCHEMAS
   All Kafka messages must include: timestamp, version, source_service
   Schema registry: /group-f-docs/kafka-schemas.json (F4 maintains)

6. DATABASE ACCESS — CRITICAL
   F3 services write only to f3 schema tables they own.
   F3 services NEVER read f2 schema tables directly.
   F3 must call F2 REST APIs via Kong to access f2 data.
   F2 services have full access to both schemas.
   Documented in ADR-007.

7. KONG ROUTES
   Request new routes via PR to group-f-platform/gateway/kong/routes/
   Internal service calls use /internal/* prefix (blocked externally)

8. NEW KEYCLOAK ROLES
   Raise issue in group-f-platform labelled 'role-request'
   F4 provisions within 24 hours

9. CI/CD
   Use reusable workflow from group-f-platform/.github/workflows/
   Do not write your own pipeline from scratch

10. WEIGHT CALCULATIONS
    Always use f2.waste_categories.avg_kg_per_litre from PostgreSQL
    Never hardcode weight estimates
    Estimated weight = fill_pct/100 × volume_litres × avg_kg_per_litre

11. REDIS KEY CONVENTION
    bin:{bin_id}       → current bin state hash (TTL 1800s)
    Managed exclusively by Flink. Other services read-only via GET/HGETALL.
    Redis password from Vault: secret/waste-mgmt/redis

12. OR-TOOLS INTEGRATION
    Scheduler calls OR-Tools synchronously during DISPATCHING step.
    HTTP timeout: 35 seconds.
    On timeout, scheduler falls back to nearest-neighbour route.
    Do NOT publish to Kafka to trigger OR-Tools — call REST directly.
```

---

*Document version 2.0 — Group F Smart Waste Management System*
*Updated by F4 Platform Team*
*Changes from v1.0 documented in Change Log at top of this document*
