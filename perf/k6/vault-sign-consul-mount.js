// Vault-only load against the *real* Consul-managed intermediate:
//   k6 -> Vault NLB -> <connect_<dc>_inter>/sign/leaf-cert (role created by
//   Consul with no_store=true)
//
// Isolates Vault PKI signing throughput from Consul's CSR rate limiter and
// agent overhead. Uses one pre-generated Consul-shaped CSR (EC P-256 +
// SPIFFE URI SAN) created by run-k6.sh.
//
// T11 reuses it on the synthetic mount with stored certificates (one Raft write
// per sign): PKI_PATH=pki_perf ROLE=leaf-store PKI_TOKEN=$VAULT_TOKEN.
import http from 'k6/http';
import { check } from 'k6';
import { arrivalScenarios, commonOptions, env, summary, targetThresholds } from './lib/common.js';

const csr = open(env('CSR_FILE', '/opt/perf/results/leaf.csr'));
const VAULT_ADDR = env('VAULT_ADDR', 'https://vault.perf.internal:8200');
// Consul's own policy (consul-connect-ca) via env.sh; falls back to VAULT_TOKEN.
// PKI_TOKEN overrides both (env.sh always sets SIGN_VAULT_TOKEN).
const TOKEN = env('PKI_TOKEN', env('SIGN_VAULT_TOKEN', env('VAULT_TOKEN', '')));
const PKI_PATH = env('PKI_PATH', `connect_${env('CONSUL_DATACENTER', 'dc1')}_inter`);
const ROLE = env('ROLE', 'leaf-cert');
const TTL = env('LEAF_TTL', '168h');

export const options = {
  ...commonOptions,
  scenarios: arrivalScenarios(),
  // Target: Vault sign p99 <= 100 ms, < 0.1% errors (README "Targets").
  thresholds: targetThresholds('sign', 100),
};

export default function () {
  const res = http.post(
    `${VAULT_ADDR}/v1/${PKI_PATH}/sign/${ROLE}`,
    JSON.stringify({ csr: csr, ttl: TTL }),
    {
      headers: { 'X-Vault-Token': TOKEN, 'Content-Type': 'application/json' },
      tags: { name: 'sign' },
      timeout: '30s',
    },
  );

  check(res, {
    'status 200': (r) => r.status === 200,
    'has certificate': (r) => r.status === 200 && String(r.json('data.certificate')).startsWith('-----BEGIN CERTIFICATE'),
  });
}

export function handleSummary(data) {
  return summary(data);
}
