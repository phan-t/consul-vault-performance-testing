// Shared k6 helpers: an open-model (arrival-rate) scenario driven by env vars,
// plus a JSON + text summary written to $SUMMARY_FILE.
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

// Options shared by every script:
//  * summaryTrendStats adds p(99) to summary.json (k6 omits it by default).
//  * systemTags drops "url" (unique per request in consul-leaf.js) and other
//    high-cardinality tags so Prometheus remote write doesn't explode series.
export const commonOptions = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  systemTags: ['status', 'method', 'name', 'scenario', 'expected_response', 'check'],
};

// Pass criteria from the test targets (README "Targets"), overridable per run:
//   P99_MS    end-to-end p99 limit in ms (script-specific default)
//   MAX_ERROR_RATE  failed-request rate limit (default 0.001 = 0.1%)
export function targetThresholds(metricTag, defaultP99Ms) {
  const p99 = Number(env('P99_MS', defaultP99Ms));
  const errors = Number(env('MAX_ERROR_RATE', 0.001));
  return {
    [`http_req_failed{name:${metricTag}}`]: [`rate<${errors}`],
    [`http_req_duration{name:${metricTag}}`]: [`p(99)<${p99}`],
  };
}

export function env(name, fallback) {
  const v = __ENV[name];
  return v === undefined || v === '' ? fallback : v;
}

// RATE  = target iterations/s per load generator
// RAMP  = ramp-up duration, HOLD = steady-state duration
export function arrivalScenario() {
  const rate = Number(env('RATE', 50));
  return {
    executor: 'ramping-arrival-rate',
    startRate: Number(env('START_RATE', Math.max(1, Math.floor(rate / 10)))),
    timeUnit: '1s',
    preAllocatedVUs: Number(env('VUS', 100)),
    maxVUs: Number(env('MAX_VUS', 2000)),
    stages: [
      { target: rate, duration: env('RAMP', '2m') },
      { target: rate, duration: env('HOLD', '10m') },
    ],
  };
}

export function summary(data) {
  const out = { stdout: textSummary(data, { indent: ' ', enableColors: false }) };
  if (__ENV.SUMMARY_FILE) {
    out[__ENV.SUMMARY_FILE] = JSON.stringify(data, null, 2);
  }
  return out;
}
