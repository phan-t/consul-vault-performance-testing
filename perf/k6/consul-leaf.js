// End-to-end service mesh leaf certificate issuance:
//   k6 -> local Consul client agent (/v1/agent/connect/ca/leaf/<svc>)
//      -> agent generates key + CSR -> ConnectCA.Sign RPC, forwarded to the
//         Consul *leader* (a write RPC; followers/read replicas don't sign)
//      -> leader's Vault CA provider -> Vault <intermediate>/sign/leaf-cert (no_store)
//
// Every iteration uses a never-seen service name so the agent's leaf cache
// misses and a real signing request is made. Note the agent keeps each issued
// leaf in its cache (and renews it near expiry), so very long runs grow agent
// memory - restart the agent between large runs.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { arrivalScenarios, commonOptions, env, summary, targetThresholds } from './lib/common.js';

const ADDR = env('CONSUL_HTTP_ADDR', 'http://127.0.0.1:8500');
const TOKEN = env('CONSUL_HTTP_TOKEN', '');
const RUN_ID = env('RUN_ID', `${Date.now()}`);
const NODE = env('PERF_NODE', 'lg');

const rateLimited = new Counter('consul_csr_rate_limited');

export const options = {
  ...commonOptions,
  scenarios: arrivalScenarios(),
  discardResponseBodies: false,
  // Target: end-to-end leaf p99 <= 1 s, < 0.1% errors (README "Targets").
  thresholds: targetThresholds('leaf', 1000),
};

export default function () {
  // Service names must start with "perf-" (perf ACL policy) and be DNS-safe.
  const svc = `perf-${RUN_ID}-${NODE}-${exec.scenario.name}-${exec.vu.idInTest}-${exec.vu.iterationInScenario}`.toLowerCase();
  const res = http.get(`${ADDR}/v1/agent/connect/ca/leaf/${svc}`, {
    headers: { 'X-Consul-Token': TOKEN },
    tags: { name: 'leaf' },
    timeout: '60s',
  });

  if (res.status !== 200 && String(res.body).includes('rate limit')) {
    rateLimited.add(1);
  }

  check(res, {
    'status 200': (r) => r.status === 200,
    'has CertPEM': (r) => r.status === 200 && String(r.json('CertPEM')).startsWith('-----BEGIN CERTIFICATE'),
  });
}

export function handleSummary(data) {
  return summary(data);
}
