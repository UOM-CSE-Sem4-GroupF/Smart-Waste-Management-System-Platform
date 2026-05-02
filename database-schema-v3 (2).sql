-- =============================================================
-- Group F — Smart Waste Management System
-- Database Schema v3.0
-- PostgreSQL 15+
-- =============================================================
-- Changes from v2.0:
--   + bin_clusters table (proper entity)
--   + devices table (ESP32 firmware config + status)
--   ~ bins: removed lat/lng (moved to cluster), added cluster_id FK
--   ~ collection_jobs: decomposed into 3NF
--     - core identity only
--     - emergency_job_details (1:1)
--     - routine_job_details (1:1)
--     - job_execution_metrics (1:1)
--     - timing fields removed (derived from job_state_transitions)
-- =============================================================


-- =============================================================
-- EXTENSIONS
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "cube";
CREATE EXTENSION IF NOT EXISTS "earthdistance";
-- earthdistance enables: earth_distance(ll_to_earth(lat,lng), ll_to_earth(lat,lng))
-- used for proximity queries in bin and cluster lookups


-- =============================================================
-- SCHEMAS AND ROLES
-- =============================================================

CREATE SCHEMA IF NOT EXISTS f2;
CREATE SCHEMA IF NOT EXISTS f3;

-- F2 application user — owns f2 schema
CREATE ROLE f2_app_user LOGIN;
GRANT ALL ON SCHEMA f2 TO f2_app_user;
GRANT ALL ON ALL TABLES IN SCHEMA f2 TO f2_app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA f2 GRANT ALL ON TABLES TO f2_app_user;

-- F3 application user — owns f3 schema, read-only on specific f2 tables
CREATE ROLE f3_app_user LOGIN;
GRANT ALL ON SCHEMA f3 TO f3_app_user;
GRANT ALL ON ALL TABLES IN SCHEMA f3 TO f3_app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA f3 GRANT ALL ON TABLES TO f3_app_user;




-- =============================================================
-- F2 SCHEMA
-- =============================================================


-- -------------------------------------------------------------
-- WASTE CATEGORIES
-- Reference table — static after initial seed
-- -------------------------------------------------------------

CREATE TABLE f2.waste_categories (
    id                  SERIAL PRIMARY KEY,
    name                VARCHAR(50) UNIQUE NOT NULL,
    -- food_waste | paper | glass | plastic | general | e_waste
    avg_kg_per_litre    DECIMAL(5,3) NOT NULL,
    -- food_waste=0.900, paper=0.100, glass=2.500,
    -- plastic=0.050, general=0.300, e_waste=3.200
    colour_code         VARCHAR(7) NOT NULL,
    -- used by dashboard for bin marker and legend colours
    recyclable          BOOLEAN NOT NULL DEFAULT FALSE,
    special_handling    BOOLEAN NOT NULL DEFAULT FALSE,
    -- TRUE for e_waste — requires dedicated vehicle
    -- triggers immediate dispatch regardless of urgency score
    description         TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO f2.waste_categories
    (name, avg_kg_per_litre, colour_code, recyclable, special_handling)
VALUES
    ('food_waste', 0.900, '#8B4513', FALSE, FALSE),
    ('paper',      0.100, '#4169E1', TRUE,  FALSE),
    ('glass',      2.500, '#228B22', TRUE,  FALSE),
    ('plastic',    0.050, '#FF6347', TRUE,  FALSE),
    ('general',    0.300, '#808080', FALSE, FALSE),
    ('e_waste',    3.200, '#FFD700', FALSE, TRUE);


-- -------------------------------------------------------------
-- CITY ZONES
-- -------------------------------------------------------------

CREATE TABLE f2.city_zones (
    id                  SERIAL PRIMARY KEY,
    name                VARCHAR(100) NOT NULL,
    code                VARCHAR(20) UNIQUE NOT NULL,
    -- ZONE-01, ZONE-02 — used in Kafka messages and logs
    boundary_geojson    JSONB,
    -- GeoJSON Polygon: { "type": "Polygon", "coordinates": [[[lng,lat],...]] }
    collection_day      VARCHAR(10)
                        CHECK (collection_day IN (
                            'Monday','Tuesday','Wednesday',
                            'Thursday','Friday','Saturday','Sunday'
                        )),
    collection_time     TIME,
    supervisor_id       VARCHAR(100),
    -- Keycloak user_id of zone supervisor
    active              BOOLEAN NOT NULL DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_city_zones_active
    ON f2.city_zones(active)
    WHERE active = TRUE;


-- -------------------------------------------------------------
-- VEHICLE FLEET
-- Defined before clusters/bins so vehicle_waste_categories
-- can reference it
-- -------------------------------------------------------------

CREATE TABLE f2.vehicles (
    id                  VARCHAR(20) PRIMARY KEY,
    -- LORRY-01, LORRY-02, etc.
    registration        VARCHAR(20) UNIQUE NOT NULL,
    vehicle_type        VARCHAR(20) NOT NULL
                        CHECK (vehicle_type IN (
                            'small',        -- ~2,000 kg  ~2 clusters
                            'medium',       -- ~8,000 kg  ~quarter zone
                            'large',        -- ~15,000 kg ~half zone
                            'extra_large'   -- ~25,000 kg ~full zone
                        )),
    max_cargo_kg        DECIMAL(8,2) NOT NULL,
    -- CRITICAL: OR-Tools and scheduler use this as hard capacity constraint
    volume_m3           DECIMAL(6,2),
    driver_id           VARCHAR(20),
    -- FK to f3.drivers — nullable (vehicle without driver)
    -- one vehicle → one driver (always available assumption)
    status              VARCHAR(20) NOT NULL DEFAULT 'available'
                        CHECK (status IN ('available','dispatched','maintenance','decommissioned')),
    active              BOOLEAN NOT NULL DEFAULT TRUE,
    last_service_at     TIMESTAMPTZ,
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_vehicles_available
    ON f2.vehicles(status, active)
    WHERE status = 'available' AND active = TRUE;

CREATE INDEX idx_vehicles_type
    ON f2.vehicles(vehicle_type, status);


-- Junction table: which waste categories each vehicle accepts
-- Replaces VARCHAR[] waste_categories_supported from v2.0

CREATE TABLE f2.vehicle_waste_categories (
    vehicle_id          VARCHAR(20) NOT NULL REFERENCES f2.vehicles(id) ON DELETE CASCADE,
    category_id         INTEGER NOT NULL REFERENCES f2.waste_categories(id),
    PRIMARY KEY (vehicle_id, category_id)
);

CREATE INDEX idx_vehicle_waste_categories_cat
    ON f2.vehicle_waste_categories(category_id);


-- -------------------------------------------------------------
-- BIN CLUSTERS
-- NEW in v3.0
-- A cluster is a physical location that contains one or more bins
-- OR-Tools routes to clusters (not individual bins)
-- Drivers arrive at a cluster and collect all urgent bins there
-- -------------------------------------------------------------

CREATE TABLE f2.bin_clusters (
    id                  VARCHAR(20) PRIMARY KEY,
    -- CLUSTER-001, CLUSTER-002, etc.
    zone_id             INTEGER NOT NULL REFERENCES f2.city_zones(id),
    name                VARCHAR(100) NOT NULL,
    -- "Central Market Complex", "Apartment Block 7B", etc.
    lat                 DECIMAL(10,7) NOT NULL,
    lng                 DECIMAL(10,7) NOT NULL,
    -- Single GPS coordinate representing this cluster location
    -- This is what OR-Tools uses as the stop node in VRP
    address             TEXT,
    cluster_type        VARCHAR(30)
                        CHECK (cluster_type IN (
                            'residential',
                            'commercial',
                            'industrial',
                            'public_space',
                            'street_corner'
                        )),
    active              BOOLEAN NOT NULL DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_bin_clusters_zone
    ON f2.bin_clusters(zone_id, active)
    WHERE active = TRUE;

CREATE INDEX idx_bin_clusters_location
    ON f2.bin_clusters
    USING GIST (ll_to_earth(lat, lng));
-- Enables: earth_distance(ll_to_earth(?, ?), ll_to_earth(lat, lng)) < ?
-- Used by orchestrator scan-nearby query


-- -------------------------------------------------------------
-- BINS
-- Each bin belongs to exactly one cluster
-- v3.0: removed lat/lng (use cluster.lat/lng for routing)
--       added individual GPS only for precise sensor identification
--       if bins are co-located, cluster GPS is used for routing
-- -------------------------------------------------------------

CREATE TABLE f2.bins (
    id                  VARCHAR(20) PRIMARY KEY,
    -- BIN-001 through BIN-NNN
    cluster_id          VARCHAR(20) NOT NULL REFERENCES f2.bin_clusters(id),
    waste_category_id   INTEGER NOT NULL REFERENCES f2.waste_categories(id),
    volume_litres       DECIMAL(8,2) NOT NULL,
    -- physical container volume — used in weight calculation:
    -- weight_kg = (fill_pct / 100) × volume_litres × avg_kg_per_litre
    lat                 DECIMAL(10,7),
    lng                 DECIMAL(10,7),
    -- individual bin GPS (optional)
    -- used only for precise identification, NOT for routing
    -- routing always uses cluster.lat / cluster.lng
    address             TEXT,
    -- specific address if different from cluster address
    active              BOOLEAN NOT NULL DEFAULT TRUE,
    installed_at        TIMESTAMPTZ,
    last_maintained_at  TIMESTAMPTZ,
    notes               TEXT,
    depth_cm            INTEGER NOT NULL DEFAULT 120,
    -- Physical depth of the bin container
    -- Used by firmware: fill_pct = ((depth_cm - distance_cm) / depth_cm) × 100
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_bins_cluster
    ON f2.bins(cluster_id, active)
    WHERE active = TRUE;

CREATE INDEX idx_bins_category
    ON f2.bins(waste_category_id);

CREATE INDEX idx_bins_cluster_category
    ON f2.bins(cluster_id, waste_category_id);


-- -------------------------------------------------------------
-- DEVICES
-- NEW in v3.0
-- Represents the physical IoT sensor attached to each bin
-- Stores firmware configuration pushed to the device
-- Stores current device health reported by the device
-- -------------------------------------------------------------

CREATE TABLE f2.devices (
    id                  VARCHAR(50) PRIMARY KEY,
    -- Device identifier flashed at manufacture
    -- e.g. ESP32-MAC-AABB-CCDD-EEFF
    bin_id              VARCHAR(20) UNIQUE REFERENCES f2.bins(id),
    -- NULL if device is provisioned but not yet assigned to a bin
    -- UNIQUE: one device per bin
    device_type         VARCHAR(30) NOT NULL
                        CHECK (device_type IN (
                            'esp32_ultrasonic',   -- fill level via ultrasonic
                            'esp32_weight',       -- fill level via load cell
                            'rpi_gateway'         -- Raspberry Pi edge gateway
                        )),

    -- ── FIRMWARE CONFIGURATION ─────────────────────────────
    -- These values are pushed to the device via Leshan/LwM2M
    -- Device reads them on boot and after config update


    sleep_interval_normal_s   INTEGER NOT NULL DEFAULT 600,
    -- Sleep duration in seconds when fill < 50%   (default: 10 minutes)

    sleep_interval_monitor_s  INTEGER NOT NULL DEFAULT 300,
    -- Sleep duration when fill 50-75%              (default: 5 minutes)

    sleep_interval_urgent_s   INTEGER NOT NULL DEFAULT 120,
    -- Sleep duration when fill 75-90%              (default: 2 minutes)

    sleep_interval_critical_s INTEGER NOT NULL DEFAULT 30,
    -- Sleep duration when fill > 90%               (default: 30 seconds)

    urgency_threshold_monitor  INTEGER NOT NULL DEFAULT 50,
    -- fill_pct % at which device switches to monitor sleep cycle

    urgency_threshold_urgent   INTEGER NOT NULL DEFAULT 75,
    -- fill_pct % at which device switches to urgent sleep cycle

    urgency_threshold_critical INTEGER NOT NULL DEFAULT 90,
    -- fill_pct % at which device switches to critical sleep cycle

    mqtt_topic          VARCHAR(200),
    -- Topic device publishes to: sensors/bin/{bin_id}/telemetry
    -- Auto-populated on bin assignment

    firmware_target_version VARCHAR(20),
    -- Version the device should be running
    -- Leshan triggers OTA update if device reports different version

    -- ── DEVICE STATUS ───────────────────────────────────────
    -- These values are reported BY the device and written by F4/Leshan

    firmware_current_version VARCHAR(20),
    -- Currently running firmware version

    status              VARCHAR(20) NOT NULL DEFAULT 'provisioned'
                        CHECK (status IN (
                            'provisioned',    -- registered, awaiting bin assignment
                            'active',         -- assigned and reporting normally
                            'offline',        -- not seen for > 30 minutes
                            'maintenance',    -- taken offline for service
                            'decommissioned'  -- permanently retired
                        )),
    last_seen_at        TIMESTAMPTZ,
    -- Timestamp of most recent sensor reading received

    battery_level_pct   DECIMAL(5,2),
    -- Last reported battery level (NULL for mains-powered devices)

    signal_strength_dbm DECIMAL(6,2),
    -- Last reported MQTT signal strength

    -- ── PROVISIONING ────────────────────────────────────────

    provisioned_at      TIMESTAMPTZ DEFAULT NOW(),
    provisioned_by      VARCHAR(100),
    -- Keycloak user_id of admin who provisioned the device

    certificate_fingerprint VARCHAR(200),
    -- TLS certificate fingerprint for MQTT authentication
    -- Device uses this to authenticate to EMQX

    last_config_pushed_at  TIMESTAMPTZ,
    -- When F4 last pushed configuration to this device via Leshan

    last_config_ack_at     TIMESTAMPTZ,
    -- When device last acknowledged the configuration
    -- If last_config_pushed_at >> last_config_ack_at: device has not applied config

    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_devices_bin
    ON f2.devices(bin_id)
    WHERE bin_id IS NOT NULL;

CREATE INDEX idx_devices_status
    ON f2.devices(status);

CREATE INDEX idx_devices_last_seen
    ON f2.devices(last_seen_at)
    WHERE status = 'active';
-- Supports data quality check: "devices not seen for > 30 minutes"

CREATE INDEX idx_devices_config_pending
    ON f2.devices(last_config_pushed_at, last_config_ack_at)
    WHERE status = 'active';
-- Supports: "devices that have not acknowledged latest config"


-- -------------------------------------------------------------
-- BIN CURRENT STATE
-- Written by Flink on every sensor reading (UPSERT)
-- Single source of truth for current bin status
-- -------------------------------------------------------------

CREATE TABLE f2.bin_current_state (
    bin_id                  VARCHAR(20) PRIMARY KEY REFERENCES f2.bins(id),

    -- Sensor values at last reading
    fill_level_pct          DECIMAL(5,2) NOT NULL
                            CHECK (fill_level_pct BETWEEN 0 AND 100),
    battery_level_pct       DECIMAL(5,2)
                            CHECK (battery_level_pct BETWEEN 0 AND 100),
    signal_strength_dbm     DECIMAL(6,2),
    temperature_c           DECIMAL(5,2),

    -- Derived values — calculated by Flink at time of last reading
    -- All represent state AT last_reading_at, not necessarily current time
    estimated_weight_kg     DECIMAL(8,2),
    -- = (fill_level_pct / 100) × bins.volume_litres × waste_categories.avg_kg_per_litre
    fill_rate_pct_per_hour  DECIMAL(6,3),
    -- positive = filling, negative = emptying, NULL = insufficient history
    predicted_full_at       TIMESTAMPTZ,
    -- NULL if fill_rate <= 0 or insufficient history

    -- Flink urgency classification
    status                  VARCHAR(20) NOT NULL DEFAULT 'normal'
                            CHECK (status IN (
                                'normal', 'monitor', 'urgent', 'critical', 'offline'
                            )),
    urgency_score           INTEGER NOT NULL DEFAULT 0
                            CHECK (urgency_score BETWEEN 0 AND 100),

    -- Denormalized from bins/bin_clusters for query performance
    -- These never change after installation so denormalization is safe
    cluster_id              VARCHAR(20) NOT NULL,
    zone_id                 INTEGER NOT NULL,
    waste_category_id       INTEGER NOT NULL,
    volume_litres           DECIMAL(8,2) NOT NULL,

    -- Timestamps
    last_reading_at         TIMESTAMPTZ NOT NULL,
    last_collected_at       TIMESTAMPTZ,
    -- Set by bin-status-service when driver confirms collection
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Performance indexes for dashboard queries
CREATE INDEX idx_bin_state_zone_status
    ON f2.bin_current_state(zone_id, status, urgency_score DESC);
-- "Get all urgent bins in zone 3 ordered by urgency"

CREATE INDEX idx_bin_state_cluster
    ON f2.bin_current_state(cluster_id, status);
-- "Get all bin states for CLUSTER-012"

CREATE INDEX idx_bin_state_urgent
    ON f2.bin_current_state(urgency_score DESC)
    WHERE status IN ('urgent', 'critical');
-- "Get all urgent bins city-wide"

CREATE INDEX idx_bin_state_category
    ON f2.bin_current_state(zone_id, waste_category_id);
-- "Get all glass bins in zone 2"

CREATE INDEX idx_bin_state_stale
    ON f2.bin_current_state(last_reading_at)
    WHERE status != 'offline';
-- Data quality check: "bins not reporting for > 2 hours"


-- -------------------------------------------------------------
-- ROUTE PLANS
-- Written by OR-Tools route optimizer
-- Read by F3 workflow orchestrator
-- -------------------------------------------------------------

CREATE TABLE f2.route_plans (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id                  UUID,
    -- References f3.collection_jobs.id
    -- NULL for pre-computed routine routes before job is created
    vehicle_id              VARCHAR(20) NOT NULL REFERENCES f2.vehicles(id),
    route_type              VARCHAR(20) NOT NULL
                            CHECK (route_type IN ('routine', 'emergency')),
    zone_id                 INTEGER REFERENCES f2.city_zones(id),

    -- Waypoints — ordered array of cluster stops
    -- JSONB structure (documented):
    -- [
    --   {
    --     "sequence":               1,
    --     "cluster_id":             "CLUSTER-012",
    --     "cluster_name":           "Central Market",
    --     "lat":                    6.9271,
    --     "lng":                    79.8612,
    --     "bins":                   ["BIN-047", "BIN-049"],
    --     "waste_categories":       ["glass", "paper"],
    --     "fill_levels_at_planning": {"BIN-047": 85.3, "BIN-049": 78.1},
    --     "estimated_weight_kg":    556.0,
    --     "cumulative_weight_kg":   556.0,
    --     "estimated_arrival_iso":  "2026-04-15T09:18:00Z",
    --     "time_window_deadline_iso": "2026-04-15T10:18:00Z",
    --     "stop_duration_minutes":  10
    --   }
    -- ]
    waypoints               JSONB NOT NULL,

    -- Summary metrics
    total_clusters          INTEGER NOT NULL,
    total_bins              INTEGER NOT NULL,
    estimated_weight_kg     DECIMAL(8,2) NOT NULL,
    -- Must be <= vehicle.max_cargo_kg — enforced by OR-Tools
    estimated_distance_km   DECIMAL(8,2),
    estimated_minutes       INTEGER,
    or_tools_solver_time_ms INTEGER,
    solver_method           VARCHAR(30)
                            CHECK (solver_method IN ('or_tools', 'nearest_neighbour_fallback')),

    -- Validity
    valid_for_date          DATE,
    -- For pre-computed routine routes
    status                  VARCHAR(20) NOT NULL DEFAULT 'planned'
                            CHECK (status IN (
                                'planned', 'active', 'completed', 'superseded', 'cancelled'
                            )),
    superseded_by_id        UUID REFERENCES f2.route_plans(id),
    -- When a route is re-optimised, old plan points to replacement

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_route_plans_job
    ON f2.route_plans(job_id)
    WHERE job_id IS NOT NULL;

CREATE INDEX idx_route_plans_vehicle_date
    ON f2.route_plans(vehicle_id, valid_for_date);

CREATE INDEX idx_route_plans_active
    ON f2.route_plans(status)
    WHERE status IN ('planned', 'active');


-- -------------------------------------------------------------
-- ZONE SNAPSHOTS
-- Written by Flink sliding window every 2 minutes
-- -------------------------------------------------------------

CREATE TABLE f2.zone_snapshots (
    id                      BIGSERIAL PRIMARY KEY,
    zone_id                 INTEGER NOT NULL REFERENCES f2.city_zones(id),
    snapshot_at             TIMESTAMPTZ NOT NULL,
    window_minutes          INTEGER NOT NULL DEFAULT 10,

    avg_fill_level_pct      DECIMAL(5,2),
    urgent_bin_count        INTEGER NOT NULL DEFAULT 0,
    -- urgency_score > 60
    critical_bin_count      INTEGER NOT NULL DEFAULT 0,
    -- urgency_score > 85
    total_bins              INTEGER,
    total_clusters          INTEGER,
    total_estimated_kg      DECIMAL(10,2),
    dominant_waste_category VARCHAR(50),

    -- Per-category breakdown JSONB:
    -- {
    --   "glass":      {"count": 8,  "avg_fill": 71.3, "total_kg": 1440.0},
    --   "food_waste": {"count": 12, "avg_fill": 55.1, "total_kg": 1188.0}
    -- }
    category_breakdown      JSONB,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_zone_snapshots_zone_time
    ON f2.zone_snapshots(zone_id, snapshot_at DESC);

CREATE INDEX idx_zone_snapshots_recent
    ON f2.zone_snapshots(snapshot_at DESC);


-- -------------------------------------------------------------
-- ML MODEL PERFORMANCE
-- Written by Airflow after each training run
-- -------------------------------------------------------------

CREATE TABLE f2.model_performance (
    id                  BIGSERIAL PRIMARY KEY,
    model_name          VARCHAR(100) NOT NULL,
    -- fill_time_predictor | waste_generation_trend
    model_version       VARCHAR(50) NOT NULL,
    -- MLflow run ID
    mlflow_run_id       VARCHAR(200),

    trained_at          TIMESTAMPTZ NOT NULL,
    training_start_at   TIMESTAMPTZ,
    training_end_at     TIMESTAMPTZ,
    training_records    INTEGER,
    validation_records  INTEGER,

    -- Regression metrics for fill_time_predictor
    mae_hours           DECIMAL(6,3),
    rmse_hours          DECIMAL(6,3),
    r_squared           DECIMAL(5,4),

    promoted_to_prod    BOOLEAN NOT NULL DEFAULT FALSE,
    promoted_at         TIMESTAMPTZ,
    replaced_at         TIMESTAMPTZ,

    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (model_name, model_version)
);

CREATE INDEX idx_model_perf_prod
    ON f2.model_performance(model_name, promoted_to_prod)
    WHERE promoted_to_prod = TRUE;


-- =============================================================
-- F3 SCHEMA
-- =============================================================


-- -------------------------------------------------------------
-- DRIVERS
-- -------------------------------------------------------------

CREATE TABLE f3.drivers (
    id                  VARCHAR(20) PRIMARY KEY,
    -- DRV-001, DRV-002, etc.
    name                VARCHAR(100) NOT NULL,
    phone               VARCHAR(20),
    email               VARCHAR(200),
    keycloak_user_id    VARCHAR(100) UNIQUE NOT NULL,
    -- Links to Keycloak user — used to match JWT claims to driver record

    zone_id             INTEGER NOT NULL,
    -- No FK to f2.city_zones — cross-schema FK avoided
    -- Application enforces referential integrity

    current_vehicle_id  VARCHAR(20),
    -- No FK to f2.vehicles — cross-schema FK avoided

    status              VARCHAR(20) NOT NULL DEFAULT 'off_duty'
                        CHECK (status IN (
                            'available', 'on_job', 'off_duty', 'on_break'
                        )),
    shift_start         TIME,
    shift_end           TIME,

    -- Aggregate stats (updated on job completion for quick dashboard reads)
    total_jobs_completed    INTEGER NOT NULL DEFAULT 0,
    total_bins_collected    INTEGER NOT NULL DEFAULT 0,
    total_weight_kg         DECIMAL(10,2) NOT NULL DEFAULT 0,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_drivers_status
    ON f3.drivers(status);

CREATE INDEX idx_drivers_zone_status
    ON f3.drivers(zone_id, status);

CREATE INDEX idx_drivers_keycloak
    ON f3.drivers(keycloak_user_id);


-- -------------------------------------------------------------
-- ROUTINE SCHEDULES
-- Defines recurring collection schedule per zone
-- -------------------------------------------------------------

CREATE TABLE f3.routine_schedules (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    zone_id             INTEGER NOT NULL,
    -- No FK — cross-schema
    waste_category_id   INTEGER,
    -- NULL = collect all waste categories in this zone on this schedule
    -- NOT NULL = category-specific schedule (e.g. glass every Wednesday)
    frequency           VARCHAR(20) NOT NULL
                        CHECK (frequency IN ('daily','weekly','biweekly','monthly')),
    day_of_week         VARCHAR(10)
                        CHECK (day_of_week IN (
                            'Monday','Tuesday','Wednesday',
                            'Thursday','Friday','Saturday','Sunday'
                        )),
    -- NULL for daily frequency
    time_of_day         TIME NOT NULL,
    active              BOOLEAN NOT NULL DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_routine_schedules_zone
    ON f3.routine_schedules(zone_id, active)
    WHERE active = TRUE;

CREATE INDEX idx_routine_schedules_day
    ON f3.routine_schedules(day_of_week)
    WHERE active = TRUE;


-- =============================================================
-- SHARED UTILITY FUNCTION
-- Must be defined before any trigger that references it
-- =============================================================

CREATE OR REPLACE FUNCTION f3.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- -------------------------------------------------------------
-- COLLECTION JOBS — CORE
-- 3NF: contains only facts that depend directly on job identity
-- Type-specific data is in emergency_job_details / routine_job_details
-- Execution data is in job_execution_metrics
-- Timing is derived from job_state_transitions
-- -------------------------------------------------------------

CREATE TABLE f3.collection_jobs (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Core identity
    job_type            VARCHAR(20) NOT NULL
                        CHECK (job_type IN ('routine', 'emergency')),
    zone_id             INTEGER NOT NULL,
    state               VARCHAR(50) NOT NULL DEFAULT 'CREATED',
    -- Full state machine:
    -- CREATED → BIN_CONFIRMING → BIN_CONFIRMED
    -- → CLUSTER_ASSEMBLING → CLUSTER_ASSEMBLED
    -- → DISPATCHING → DISPATCHED → DRIVER_NOTIFIED
    -- → IN_PROGRESS → COMPLETING → COLLECTION_DONE
    -- → RECORDING_AUDIT → AUDIT_RECORDED → COMPLETED
    -- Failures: FAILED | ESCALATED | CANCELLED | DRIVER_REASSIGNMENT
    priority            INTEGER NOT NULL DEFAULT 5
                        CHECK (priority BETWEEN 1 AND 10),

    -- Assignment — populated during DISPATCHING state
    assigned_vehicle_id VARCHAR(20),
    -- No FK — cross-schema (references f2.vehicles)
    assigned_driver_id  VARCHAR(20) REFERENCES f3.drivers(id),
    route_plan_id       UUID,
    -- References f2.route_plans.id — no FK (cross-schema)

    -- Weight — the only numerical facts about the job itself
    planned_weight_kg   DECIMAL(8,2),
    -- From OR-Tools route plan at time of dispatch

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()

    -- Note: timing fields (assigned_at, accepted_at, started_at, etc.)
    -- are NOT stored here. Derive them from job_state_transitions:
    --   SELECT transitioned_at FROM job_state_transitions
    --   WHERE job_id = ? AND to_state = 'DRIVER_ACCEPTED'
    -- This eliminates update anomalies between the two tables.
);

CREATE INDEX idx_jobs_state
    ON f3.collection_jobs(state);

CREATE INDEX idx_jobs_zone_state
    ON f3.collection_jobs(zone_id, state);

CREATE INDEX idx_jobs_type_state
    ON f3.collection_jobs(job_type, state);

CREATE INDEX idx_jobs_driver_active
    ON f3.collection_jobs(assigned_driver_id)
    WHERE state IN (
        'DISPATCHED','DRIVER_NOTIFIED',
        'IN_PROGRESS','COMPLETING'
    );

CREATE INDEX idx_jobs_created
    ON f3.collection_jobs(created_at DESC);

CREATE INDEX idx_jobs_updated
    ON f3.collection_jobs(updated_at DESC);
-- Used for incremental dashboard sync

CREATE TRIGGER trg_jobs_updated_at
BEFORE UPDATE ON f3.collection_jobs
FOR EACH ROW EXECUTE FUNCTION f3.set_updated_at();


-- -------------------------------------------------------------
-- EMERGENCY JOB DETAILS
-- 1:1 with collection_jobs where job_type = 'emergency'
-- Contains all facts specific to emergency jobs
-- -------------------------------------------------------------

CREATE TABLE f3.emergency_job_details (
    job_id              UUID PRIMARY KEY REFERENCES f3.collection_jobs(id),

    -- The bin and cluster that triggered this job
    trigger_bin_id      VARCHAR(20) NOT NULL,
    trigger_cluster_id  VARCHAR(20) NOT NULL,
    trigger_urgency_score INTEGER NOT NULL,
    trigger_waste_category VARCHAR(50) NOT NULL,

    -- Clusters and bins assembled for this job
    -- Populated at end of wait window / cluster assembly phase
    cluster_ids         VARCHAR(20)[] NOT NULL DEFAULT '{}',
    -- Array of cluster_ids included in this job
    -- e.g. '{CLUSTER-012, CLUSTER-015}'
    bin_ids             VARCHAR(20)[] NOT NULL DEFAULT '{}',
    -- Array of bin_ids to be collected in this job

    -- Wait window tracking
    wait_window_applied BOOLEAN NOT NULL DEFAULT FALSE,
    -- TRUE if the system waited before dispatching
    wait_window_start_at TIMESTAMPTZ,
    wait_window_end_at  TIMESTAMPTZ,
    additional_clusters_found INTEGER NOT NULL DEFAULT 0,
    -- How many clusters were added during wait window scan

    -- Failure tracking
    failure_reason      TEXT,
    escalated_reason    TEXT,
    driver_rejection_count INTEGER NOT NULL DEFAULT 0,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_emergency_details_trigger_cluster
    ON f3.emergency_job_details(trigger_cluster_id);
-- Supports: "is there an active job for this cluster?"

CREATE INDEX idx_emergency_details_trigger_bin
    ON f3.emergency_job_details(trigger_bin_id);


-- -------------------------------------------------------------
-- ROUTINE JOB DETAILS
-- 1:1 with collection_jobs where job_type = 'routine'
-- Contains all facts specific to routine jobs
-- -------------------------------------------------------------

CREATE TABLE f3.routine_job_details (
    job_id              UUID PRIMARY KEY REFERENCES f3.collection_jobs(id),

    -- Schedule that generated this job
    schedule_id         UUID REFERENCES f3.routine_schedules(id),
    scheduled_date      DATE NOT NULL,
    scheduled_time      TIME NOT NULL,

    -- Scope of this routine job
    zone_coverage       VARCHAR(20) NOT NULL DEFAULT 'full_zone'
                        CHECK (zone_coverage IN ('full_zone', 'category_specific')),
    waste_category_id   INTEGER,
    -- NULL if zone_coverage = 'full_zone'
    -- NOT NULL if zone_coverage = 'category_specific'

    -- All bins in scope for this routine collection
    bin_ids             VARCHAR(20)[] NOT NULL DEFAULT '{}',
    cluster_ids         VARCHAR(20)[] NOT NULL DEFAULT '{}',

    -- Failure tracking
    failure_reason      TEXT,
    escalated_reason    TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_routine_details_schedule
    ON f3.routine_job_details(schedule_id);

CREATE INDEX idx_routine_details_date
    ON f3.routine_job_details(scheduled_date);


-- -------------------------------------------------------------
-- JOB EXECUTION METRICS
-- 1:1 with collection_jobs
-- Populated only when job reaches COMPLETED or COLLECTION_DONE
-- Contains all facts about how the job was executed
-- -------------------------------------------------------------

CREATE TABLE f3.job_execution_metrics (
    job_id              UUID PRIMARY KEY REFERENCES f3.collection_jobs(id),

    -- Weight actuals
    actual_weight_kg    DECIMAL(8,2),
    -- Actual waste collected (from vehicle_weight_logs or sum of bins)

    -- Distance actuals
    planned_distance_km DECIMAL(8,2),
    actual_distance_km  DECIMAL(8,2),

    -- Duration actuals (in minutes)
    planned_duration_min INTEGER,
    actual_duration_min  INTEGER,

    -- Collection summary
    bins_collected_count INTEGER NOT NULL DEFAULT 0,
    bins_skipped_count   INTEGER NOT NULL DEFAULT 0,
    bins_total_count     INTEGER NOT NULL DEFAULT 0,

    -- Vehicle utilisation at completion
    vehicle_utilisation_pct DECIMAL(5,2),
    -- (actual_weight_kg / vehicle.max_cargo_kg) × 100

    -- Efficiency ratios
    distance_efficiency_pct DECIMAL(5,2),
    -- (planned_distance_km / actual_distance_km) × 100
    duration_efficiency_pct DECIMAL(5,2),
    -- (planned_duration_min / actual_duration_min) × 100

    -- Audit linkage
    hyperledger_tx_id   VARCHAR(200),
    kafka_offset        BIGINT,
    -- Kafka offset of waste.bin.processed that triggered this job (emergency only)

    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_execution_metrics_date
    ON f3.job_execution_metrics(recorded_at DESC);


-- -------------------------------------------------------------
-- BIN COLLECTION RECORDS
-- One row per bin per job
-- Records each individual bin pickup
-- -------------------------------------------------------------

CREATE TABLE f3.bin_collection_records (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id              UUID NOT NULL REFERENCES f3.collection_jobs(id),
    bin_id              VARCHAR(20) NOT NULL,
    cluster_id          VARCHAR(20) NOT NULL,
    -- Denormalized for query performance
    sequence_number     INTEGER NOT NULL,
    -- Planned order in route (1 = first stop at its cluster)

    -- Timing
    planned_arrival_at  TIMESTAMPTZ,
    -- Estimated arrival from OR-Tools route plan
    arrived_at          TIMESTAMPTZ,
    -- When vehicle GPS showed < 50m from cluster
    collected_at        TIMESTAMPTZ,
    -- When driver tapped "Collected" in Flutter app
    skipped_at          TIMESTAMPTZ,
    -- When driver tapped "Skip"
    skip_reason         VARCHAR(30)
                        CHECK (skip_reason IN (
                            'locked', 'inaccessible', 'already_empty',
                            'hazardous', 'bin_missing', 'other'
                        )),
    skip_notes          TEXT,

    -- Weight
    fill_level_at_collection    DECIMAL(5,2),
    -- Sensor reading at time of collection
    estimated_weight_kg         DECIMAL(8,2),
    -- Calculated at time of route planning
    actual_weight_kg            DECIMAL(8,2),
    -- Entered by driver if vehicle has scale (optional)

    -- Evidence
    driver_notes        TEXT,
    photo_url           TEXT,
    gps_lat             DECIMAL(10,7),
    gps_lng             DECIMAL(10,7),
    gps_accuracy_m      DECIMAL(6,2),

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    UNIQUE (job_id, bin_id),
    -- A bin can only appear once per job

    CONSTRAINT chk_collected_xor_skipped CHECK (
        NOT (collected_at IS NOT NULL AND skipped_at IS NOT NULL)
        -- Cannot be both collected AND skipped
    )
);

CREATE INDEX idx_bin_collection_job
    ON f3.bin_collection_records(job_id, sequence_number ASC);

CREATE INDEX idx_bin_collection_bin
    ON f3.bin_collection_records(bin_id);

CREATE INDEX idx_bin_collection_bin_time
    ON f3.bin_collection_records(bin_id, collected_at DESC);
-- "Show last 5 collections for BIN-047"

CREATE INDEX idx_bin_collection_cluster
    ON f3.bin_collection_records(cluster_id, job_id);
-- "Show all bins collected at CLUSTER-012 on this job"


-- -------------------------------------------------------------
-- JOB STATE TRANSITIONS
-- Immutable audit log — every state change recorded
-- Also used to derive timing fields (replaces 9 timestamp columns)
-- -------------------------------------------------------------

CREATE TABLE f3.job_state_transitions (
    id                  BIGSERIAL PRIMARY KEY,
    job_id              UUID NOT NULL REFERENCES f3.collection_jobs(id),
    from_state          VARCHAR(50),
    -- NULL for initial CREATED transition
    to_state            VARCHAR(50) NOT NULL,
    reason              TEXT,
    actor               VARCHAR(100),
    -- 'system' | 'driver:DRV-001' | 'supervisor:SUP-001'
    metadata            JSONB,
    -- Additional context:
    -- { "retry_attempt": 2, "excluded_drivers": ["DRV-003"] }
    -- { "wait_window_ms": 900000 }
    -- { "or_tools_solver_ms": 4200 }
    transitioned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
    -- This IS the timing record for this state
    -- To get assigned_at: WHERE to_state = 'DISPATCHED'
    -- To get accepted_at: WHERE to_state = 'DRIVER_ACCEPTED' (via IN_PROGRESS)
);

-- Append-only table — no UPDATE or DELETE
CREATE INDEX idx_transitions_job
    ON f3.job_state_transitions(job_id, transitioned_at ASC);

CREATE INDEX idx_transitions_state
    ON f3.job_state_transitions(to_state, transitioned_at DESC);
-- "Find all ESCALATED transitions in last 24 hours"


-- -------------------------------------------------------------
-- JOB STEP RESULTS
-- Log of every external service call made by the orchestrator
-- -------------------------------------------------------------

CREATE TABLE f3.job_step_results (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id              UUID NOT NULL REFERENCES f3.collection_jobs(id),
    step_name           VARCHAR(100) NOT NULL,
    -- bin_confirmation | driver_dispatch | driver_notification |
    -- blockchain_audit | cluster_scan | etc.
    attempt_number      INTEGER NOT NULL DEFAULT 1,
    success             BOOLEAN NOT NULL,
    service_called      VARCHAR(100),
    -- bin-status-service | scheduler-service | hyperledger | etc.
    request_payload     JSONB,
    response_payload    JSONB,
    error_message       TEXT,
    duration_ms         INTEGER,
    executed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_step_results_job
    ON f3.job_step_results(job_id, executed_at ASC);


-- -------------------------------------------------------------
-- DRIVER ASSIGNMENT HISTORY
-- Tracks every assignment attempt per job
-- Used by orchestrator to build exclude_driver_ids on retry
-- -------------------------------------------------------------

CREATE TABLE f3.driver_assignment_history (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id              UUID NOT NULL REFERENCES f3.collection_jobs(id),
    driver_id           VARCHAR(20) REFERENCES f3.drivers(id),
    vehicle_id          VARCHAR(20),
    assignment_type     VARCHAR(20) NOT NULL
                        CHECK (assignment_type IN (
                            'offered', 'accepted', 'rejected', 'timeout', 'released'
                        )),
    rejection_reason    VARCHAR(100),
    -- 'too_heavy' | 'out_of_zone' | 'personal' | 'timeout'
    offered_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at        TIMESTAMPTZ
);

CREATE INDEX idx_assignment_history_job
    ON f3.driver_assignment_history(job_id, offered_at ASC);


-- -------------------------------------------------------------
-- VEHICLE WEIGHT LOGS
-- Actual cargo weight per job (one record per job)
-- -------------------------------------------------------------

CREATE TABLE f3.vehicle_weight_logs (
    id                  BIGSERIAL PRIMARY KEY,
    job_id              UUID NOT NULL REFERENCES f3.collection_jobs(id),
    vehicle_id          VARCHAR(20) NOT NULL,
    max_cargo_kg        DECIMAL(8,2) NOT NULL,
    -- Snapshot of vehicle limit at time of job (fleet may change)
    weight_before_kg    DECIMAL(8,2),
    -- Tare weight at start of job
    weight_after_kg     DECIMAL(8,2),
    -- Gross weight at end of job
    net_cargo_kg        DECIMAL(8,2) GENERATED ALWAYS AS
                        (weight_after_kg - weight_before_kg) STORED,
    -- Auto-computed: actual waste collected
    utilisation_pct     DECIMAL(5,2) GENERATED ALWAYS AS
                        (((weight_after_kg - weight_before_kg) / max_cargo_kg) * 100) STORED,
    -- Auto-computed: how full was the lorry at completion
    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (job_id, vehicle_id)
    -- One weight record per vehicle per job
);

CREATE INDEX idx_weight_logs_vehicle
    ON f3.vehicle_weight_logs(vehicle_id, recorded_at DESC);


-- Apply remaining updated_at triggers
CREATE TRIGGER trg_drivers_updated_at
    BEFORE UPDATE ON f3.drivers
    FOR EACH ROW EXECUTE FUNCTION f3.set_updated_at();

CREATE TRIGGER trg_schedules_updated_at
    BEFORE UPDATE ON f3.routine_schedules
    FOR EACH ROW EXECUTE FUNCTION f3.set_updated_at();


-- =============================================================
-- VIEWS
-- =============================================================

-- Active jobs with live progress (used by dashboard)
CREATE VIEW f3.v_active_jobs AS
SELECT
    j.id,
    j.job_type,
    j.zone_id,
    j.state,
    j.priority,
    j.assigned_vehicle_id,
    j.assigned_driver_id,
    d.name                          AS driver_name,
    j.route_plan_id,
    j.planned_weight_kg,
    j.created_at,
    j.updated_at,
    -- Timing derived from transitions
    (SELECT transitioned_at FROM f3.job_state_transitions t
     WHERE t.job_id = j.id AND t.to_state = 'DISPATCHED'
     LIMIT 1)                       AS dispatched_at,
    (SELECT transitioned_at FROM f3.job_state_transitions t
     WHERE t.job_id = j.id AND t.to_state = 'IN_PROGRESS'
     LIMIT 1)                       AS started_at,
    -- Progress from bin_collection_records
    COUNT(r.id)                     AS total_bins,
    COUNT(r.collected_at)           AS bins_collected,
    COUNT(r.skipped_at)             AS bins_skipped,
    SUM(CASE WHEN r.collected_at IS NULL
              AND r.skipped_at IS NULL THEN 1 ELSE 0 END) AS bins_pending,
    COALESCE(SUM(r.actual_weight_kg), 0) AS actual_weight_so_far_kg
FROM f3.collection_jobs j
LEFT JOIN f3.drivers d
    ON d.id = j.assigned_driver_id
LEFT JOIN f3.bin_collection_records r
    ON r.job_id = j.id
WHERE j.state NOT IN ('COMPLETED', 'CANCELLED', 'FAILED')
GROUP BY j.id, d.name;


-- Completed job efficiency metrics (used by analytics dashboard)
CREATE VIEW f3.v_job_efficiency AS
SELECT
    j.id,
    j.job_type,
    j.zone_id,
    j.created_at::DATE              AS job_date,
    m.actual_weight_kg,
    j.planned_weight_kg,
    m.actual_distance_km,
    m.planned_distance_km,
    m.actual_duration_min,
    m.planned_duration_min,
    m.bins_collected_count,
    m.bins_skipped_count,
    m.bins_total_count,
    m.vehicle_utilisation_pct,
    m.distance_efficiency_pct,
    m.duration_efficiency_pct,
    m.hyperledger_tx_id,
    -- Timing from transitions
    (SELECT transitioned_at FROM f3.job_state_transitions t
     WHERE t.job_id = j.id AND t.to_state = 'COMPLETED'
     LIMIT 1)                       AS completed_at
FROM f3.collection_jobs j
JOIN f3.job_execution_metrics m
    ON m.job_id = j.id
WHERE j.state = 'COMPLETED';


-- Cluster current urgency summary (used by dashboard map)
CREATE VIEW f2.v_cluster_urgency AS
SELECT
    c.id                            AS cluster_id,
    c.name                          AS cluster_name,
    c.zone_id,
    c.lat,
    c.lng,
    c.address,
    COUNT(s.bin_id)                 AS total_bins,
    MAX(s.urgency_score)            AS max_urgency_score,
    CASE
        WHEN MAX(s.urgency_score) >= 85 THEN 'critical'
        WHEN MAX(s.urgency_score) >= 60 THEN 'urgent'
        WHEN MAX(s.urgency_score) >= 30 THEN 'monitor'
        ELSE 'normal'
    END                             AS cluster_status,
    -- Cluster colour = worst bin status colour
    SUM(s.estimated_weight_kg)      AS total_weight_kg,
    COUNT(CASE WHEN s.status IN ('urgent','critical') THEN 1 END) AS urgent_bins,
    MIN(s.predicted_full_at)        AS earliest_predicted_full
FROM f2.bin_clusters c
LEFT JOIN f2.bin_current_state s
    ON s.cluster_id = c.id
WHERE c.active = TRUE
GROUP BY c.id, c.name, c.zone_id, c.lat, c.lng, c.address;


-- Device health summary (used by F4 monitoring)
CREATE VIEW f2.v_device_health AS
SELECT
    d.id                            AS device_id,
    d.bin_id,
    b.cluster_id,
    d.device_type,
    d.status,
    d.firmware_current_version,
    d.firmware_target_version,
    d.firmware_current_version != d.firmware_target_version
                                    AS firmware_update_pending,
    d.last_seen_at,
    EXTRACT(EPOCH FROM (NOW() - d.last_seen_at)) / 60
                                    AS minutes_since_last_seen,
    d.battery_level_pct,
    d.battery_level_pct < 10        AS low_battery,
    d.last_config_pushed_at,
    d.last_config_ack_at,
    d.last_config_pushed_at > d.last_config_ack_at
                                    AS config_update_pending
FROM f2.devices d
LEFT JOIN f2.bins b ON b.id = d.bin_id
WHERE d.status != 'decommissioned';


-- =============================================================
-- INDEX STRATEGY SUMMARY
-- =============================================================
--
-- Dashboard "live map" query (most frequent):
--   idx_bin_state_zone_status   → urgent bins in zone ordered by urgency
--   idx_bin_state_cluster       → all bins at a cluster
--   v_cluster_urgency           → pre-aggregated cluster status
--
-- Orchestrator "is there an active job for this cluster?":
--   idx_emergency_details_trigger_cluster
--   idx_jobs_zone_state
--
-- Scheduler "find available vehicle":
--   idx_vehicles_available
--   vehicle_waste_categories join
--
-- Driver app "what is my active job?":
--   idx_jobs_driver_active
--
-- Analytics queries:
--   idx_bin_collection_bin_time → bin collection history
--   idx_weight_logs_vehicle     → vehicle utilisation
--   idx_zone_snapshots_zone_time → zone statistics over time
--   v_job_efficiency            → pre-joined metrics
--
-- Data quality checks:
--   idx_bin_state_stale         → sensors not reporting
--   idx_devices_last_seen       → offline devices
--   idx_devices_config_pending  → devices with pending config
--
-- =============================================================


-- =============================================================
-- CROSS-SCHEMA GRANTS
-- =============================================================
-- Approved cross-schema reads: F3 may read these F2 tables
GRANT USAGE ON SCHEMA f2 TO f3_app_user;
GRANT SELECT ON f2.bin_current_state   TO f3_app_user;
GRANT SELECT ON f2.bins                TO f3_app_user;
GRANT SELECT ON f2.bin_clusters        TO f3_app_user;
GRANT SELECT ON f2.waste_categories    TO f3_app_user;
GRANT SELECT ON f2.city_zones          TO f3_app_user;
GRANT SELECT ON f2.vehicles            TO f3_app_user;
GRANT SELECT ON f2.vehicle_waste_categories TO f3_app_user;
GRANT SELECT ON f2.route_plans         TO f3_app_user;
-- F3 also needs to write vehicle status on dispatch
GRANT UPDATE (status, updated_at) ON f2.vehicles TO f3_app_user;

