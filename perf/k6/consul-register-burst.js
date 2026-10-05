// Scenario 2 - sidecar registration burst (and renewal fleet):
//   k6 registers COUNT services, each WITH a Connect sidecar definition, on the
//   local Consul client agent at RATE registrations/s. No Envoy or app runs:
//   the agent's proxy-config manager fetches each sidecar's leaf immediately
//   (agent -> ConnectCA.Sign on the Consul leader -> Vault sign/leaf-cert).
//
//   leaf_ready_ms = time from registration start until the leaf is available
//   (the GET is de-duplicated with the agent's own in-flight fetch, so it does
//   not cause a second signing).
//
//   CLEANUP=true (default) deregisters everything in teardown. CLEANUP=false
//   keeps the fleet registered: the agent then renews every leaf at ~60-90% of
//   leaf_cert_ttl, which is a realistic steady renewal load (set a short TTL
//   first: consul-ca-limits.sh --leaf-ttl 1h). Remove later with perf-cleanup.sh.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { commonOptions, env, summary } from './lib/common.js';

const ADDR = env('CONSUL_HTTP_ADDR', 'http://127.0.0.1:8500');
const TOKEN = env('CONSUL_HTTP_TOKEN', '');
const RUN_ID = env('RUN_ID', `${Date.now()}`);
const NODE = env('PERF_NODE', 'lg');
const COUNT = Number(env('COUNT', 1000));
const RATE = Number(env('RATE', 50));
const CLEANUP = env('CLEANUP', 'true') === 'true';

// Must start with "perf-" (perf ACL policy covers perf-* incl. *-sidecar-proxy).
const PREFIX = `perf-burst-${RUN_ID}-${NODE}`.toLowerCase();
const HEADERS = { 'X-Consul-Token': TOKEN, 'Content-Type': 'application/json' };

const registerMs = new Trend('register_ms', true);
const leafReadyMs = new Trend('leaf_ready_ms', true);
const registered = new Counter('sidecars_registered');

export const options = {
  ...commonOptions,
  scenarios: {
    burst: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: `${Math.ceil(COUNT / RATE)}s`,
      preAllocatedVUs: Number(env('VUS', 200)),
      maxVUs: Number(env('MAX_VUS', 2000)),
    },
  },
  setupTimeout: '1m',
  teardownTimeout: '30m',
  thresholds: {
    checks: ['rate>0.99'],
    leaf_ready_ms: [`p(99)<${Number(env('P99_MS', 1000))}`],
  },
};

export default function () {
  const n = exec.scenario.iterationInTest;
  if (n >= COUNT) {
    return;
  }
  const name = `${PREFIX}-${n}`;
  const body = {
    ID: name,
    Name: name,
    Port: 10000 + (n % 50000),
    Connect: {
      SidecarService: {
        // Explicit port: the auto-assign range (21000-21255) only fits 256 sidecars.
        Port: 20000 + (n % 40000),
        // Replace the default TCP/alias checks (no Envoy is listening, so they
        // would flap to critical and add catalog writes) with a passing TTL check.
        Checks: [{ Name: 'perf-noop', TTL: '8760h', Status: 'passing' }],
      },
    },
  };

  const t0 = Date.now();
  const reg = http.put(`${ADDR}/v1/agent/service/register`, JSON.stringify(body), {
    headers: HEADERS,
    tags: { name: 'register' },
  });
  registerMs.add(Date.now() - t0);
  if (!check(reg, { registered: (r) => r.status === 200 })) {
    return;
  }
  registered.add(1);

  const leaf = http.get(`${ADDR}/v1/agent/connect/ca/leaf/${name}`, {
    headers: HEADERS,
    tags: { name: 'leaf_wait' },
    timeout: '120s',
  });
  const ok = check(leaf, {
    'leaf ready': (r) => r.status === 200 && String(r.json('CertPEM')).startsWith('-----BEGIN CERTIFICATE'),
  });
  if (ok) {
    leafReadyMs.add(Date.now() - t0);
  }
}

export function teardown() {
  if (!CLEANUP) {
    console.log(`CLEANUP=false: leaving services with prefix ${PREFIX} registered`);
    return;
  }
  const res = http.get(`${ADDR}/v1/agent/services`, { headers: HEADERS, tags: { name: 'cleanup' } });
  const ids = Object.keys(res.json() || {}).filter((id) => id.startsWith(PREFIX));
  // Sidecars first, then parents.
  ids.sort((a, b) => Number(b.endsWith('-sidecar-proxy')) - Number(a.endsWith('-sidecar-proxy')));
  for (const id of ids) {
    http.put(`${ADDR}/v1/agent/service/deregister/${id}`, null, { headers: HEADERS, tags: { name: 'cleanup' } });
  }
  console.log(`deregistered ${ids.length} services with prefix ${PREFIX}`);
}

export function handleSummary(data) {
  return summary(data);
}
