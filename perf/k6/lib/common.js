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

// Pass criteria from the test targets (README "Targets"), overridable per run,
// judged on the steady scenario only (the warm-up runs at a lower rate and
// would dilute p99):
//   P99_MS    end-to-end p99 limit in ms (script-specific default)
//   MAX_ERROR_RATE  failed-request rate limit (default 0.001 = 0.1%)
//   MIN_ACHIEVED    abort once more than 1 - MIN_ACHIEVED (default 5%) of the
//                   steady iterations were dropped: every VU busy, so the rest
//                   of the step would only measure a starved load generator.
export function targetThresholds(metricTag, defaultP99Ms) {
  const p99 = Number(env('P99_MS', defaultP99Ms));
  const errors = Number(env('MAX_ERROR_RATE', 0.001));
  const planned = Number(env('RATE', 50)) * durationSeconds(env('HOLD', '10m'));
  const maxDropped = Math.max(1, Math.floor(planned * (1 - Number(env('MIN_ACHIEVED', 0.95)))));
  return {
    [`http_req_failed{name:${metricTag},scenario:steady}`]: [`rate<${errors}`],
    [`http_req_duration{name:${metricTag},scenario:steady}`]: [`p(99)<${p99}`],
    'dropped_iterations{scenario:steady}': [{ threshold: `count<${maxDropped}`, abortOnFail: true, delayAbortEval: '30s' }],
  };
}

// durationSeconds('2m') -> 120 (k6 duration strings: h, m, s, ms; combined like 1m30s).
export function durationSeconds(d) {
  let total = 0;
  const re = /(\d+(?:\.\d+)?)(ms|h|m|s)/g;
  let m;
  while ((m = re.exec(String(d))) !== null) {
    total += Number(m[1]) * { h: 3600, m: 60, s: 1, ms: 0.001 }[m[2]];
  }
  return total;
}

export function env(name, fallback) {
  const v = __ENV[name];
  return v === undefined || v === '' ? fallback : v;
}

// RATE  = target iterations/s per load generator
// RAMP  = ramp-up duration, HOLD = steady-state duration
// START_RATE = where the ramp starts (default RATE/10; a chained stress step
//              passes the previous step's rate, so load doesn't dip between steps)
// Two scenarios, so results can be judged on the steady state alone:
//   warmup  ramping-arrival-rate, START_RATE -> RATE over RAMP (omitted if RAMP is 0)
//   steady  constant-arrival-rate at RATE for HOLD, starting after RAMP
// Requests carry the scenario tag (warmup|steady); scripts that need unique
// names per iteration must include exec.scenario.name.
export function arrivalScenarios() {
  const rate = Number(env('RATE', 50));
  const ramp = env('RAMP', '2m');
  const vus = Number(env('VUS', 100));
  const maxVUs = Number(env('MAX_VUS', 2000));
  const scenarios = {
    steady: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: env('HOLD', '10m'),
      preAllocatedVUs: vus,
      maxVUs,
      startTime: durationSeconds(ramp) > 0 ? ramp : '0s',
    },
  };
  if (durationSeconds(ramp) > 0) {
    scenarios.warmup = {
      executor: 'ramping-arrival-rate',
      startRate: Number(env('START_RATE', Math.max(1, Math.floor(rate / 10)))),
      timeUnit: '1s',
      preAllocatedVUs: vus,
      maxVUs,
      stages: [{ target: rate, duration: ramp }],
    };
  }
  return scenarios;
}

export function summary(data) {
  const out = { stdout: textSummary(data, { indent: ' ', enableColors: false }) };
  if (__ENV.SUMMARY_FILE) {
    out[__ENV.SUMMARY_FILE] = JSON.stringify(data, null, 2);
  }
  return out;
}
