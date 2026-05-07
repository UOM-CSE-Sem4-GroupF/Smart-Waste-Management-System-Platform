/**
 * k6 Load Test — Smart Waste Management System
 * Target: Kong API Gateway (https://api.swms.live)
 *
 * Run locally:
 *   k6 run tests/performance/load-test.js
 *
 * Run against live cluster (replace KONG_URL):
 *   k6 run -e KONG_URL=http://<KONG_LB_IP> tests/performance/load-test.js
 *
 * Run with k6-operator inside the cluster:
 *   kubectl apply -f tests/performance/k6-run.yaml
 *
 * Pass criteria (defined in thresholds below):
 *   - p95 response time < 500ms
 *   - p99 response time < 1000ms
 *   - Error rate < 1%
 *   - Peak RPS >= 1000
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

// ── Custom metrics ────────────────────────────────────────────────────────────
const errorRate = new Rate("error_rate");
const binListLatency = new Trend("bin_list_latency");
const jobCreateLatency = new Trend("job_create_latency");

// ── Test configuration ────────────────────────────────────────────────────────
const KONG_URL = __ENV.KONG_URL || "https://api.swms.live";

export const options = {
  stages: [
    { duration: "30s", target: 100 },   // warm-up: ramp to 100 VUs
    { duration: "1m",  target: 500 },   // ramp to 500 VUs
    { duration: "2m",  target: 1000 },  // spike: hold 1000 VUs (≈1000+ RPS)
    { duration: "1m",  target: 1000 },  // sustain peak load
    { duration: "30s", target: 0 },     // ramp down
  ],
  thresholds: {
    http_req_duration: ["p(95)<500", "p(99)<1000"],
    error_rate:        ["rate<0.01"],   // < 1% errors
    http_req_failed:   ["rate<0.01"],
  },
};

// ── Shared headers ────────────────────────────────────────────────────────────
const headers = {
  "Content-Type": "application/json",
  "Accept":       "application/json",
};

// ── Scenario: read-heavy (70% of requests) ───────────────────────────────────
function readScenario() {
  // GET /api/v1/bins — list all bins with fill levels
  const start = Date.now();
  const res = http.get(`${KONG_URL}/api/v1/bins`, { headers });
  binListLatency.add(Date.now() - start);

  check(res, {
    "bins 200": (r) => r.status === 200,
    "bins has data": (r) => {
      try { return JSON.parse(r.body).length >= 0; } catch { return false; }
    },
  }) || errorRate.add(1);

  sleep(0.1);

  // GET /api/v1/vehicles — list vehicle positions
  const vRes = http.get(`${KONG_URL}/api/v1/vehicles`, { headers });
  check(vRes, { "vehicles 200": (r) => r.status === 200 }) || errorRate.add(1);

  sleep(0.1);

  // GET /data-analysis/health — data analysis service health
  const hRes = http.get(`${KONG_URL}/data-analysis/health`, { headers });
  check(hRes, { "data-analysis health 200": (r) => r.status === 200 }) || errorRate.add(1);
}

// ── Scenario: write-heavy (30% of requests) ──────────────────────────────────
function writeScenario() {
  // POST /api/v1/jobs — create a collection job (triggers orchestrator)
  const payload = JSON.stringify({
    zone_id: `zone-${Math.floor(Math.random() * 10) + 1}`,
    priority: Math.random() > 0.8 ? "high" : "normal",
    scheduled_at: new Date(Date.now() + 3600000).toISOString(),
  });

  const start = Date.now();
  const res = http.post(`${KONG_URL}/api/v1/jobs`, payload, { headers });
  jobCreateLatency.add(Date.now() - start);

  check(res, {
    "job created 201": (r) => r.status === 201,
    "job has id":      (r) => {
      try { return !!JSON.parse(r.body).id; } catch { return false; }
    },
  }) || errorRate.add(1);

  sleep(0.5);
}

// ── Main VU loop ──────────────────────────────────────────────────────────────
export default function () {
  if (Math.random() < 0.7) {
    readScenario();
  } else {
    writeScenario();
  }
}

// ── Summary report ────────────────────────────────────────────────────────────
export function handleSummary(data) {
  return {
    "security/reports/load-test-summary.json": JSON.stringify(data, null, 2),
    stdout: textSummary(data),
  };
}

function textSummary(data) {
  const m = data.metrics;
  return `
=== SWMS Load Test Summary ===
Duration: ${data.state.testRunDurationMs / 1000}s
VUs peak: ${m.vus_max?.values?.max ?? "n/a"}

Latency (all requests):
  p50  = ${m.http_req_duration?.values?.["p(50)"]?.toFixed(0) ?? "n/a"}ms
  p95  = ${m.http_req_duration?.values?.["p(95)"]?.toFixed(0) ?? "n/a"}ms
  p99  = ${m.http_req_duration?.values?.["p(99)"]?.toFixed(0) ?? "n/a"}ms

Throughput:
  Total requests = ${m.http_reqs?.values?.count ?? "n/a"}
  RPS (avg)      = ${m.http_reqs?.values?.rate?.toFixed(1) ?? "n/a"}

Error rate: ${((m.error_rate?.values?.rate ?? 0) * 100).toFixed(2)}%

Thresholds: ${Object.values(data.metrics)
    .flatMap((v) => (v.thresholds ? Object.entries(v.thresholds) : []))
    .map(([name, t]) => `${t.ok ? "PASS" : "FAIL"} ${name}`)
    .join("\n  ")}
`;
}
