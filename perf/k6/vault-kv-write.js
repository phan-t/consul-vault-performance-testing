// T11 - Vault Raft write load: KV v2 writes at a fixed arrival rate.
//   k6 -> Vault NLB -> kv_perf/data/<key> (kv-perf-mount.sh, max_versions=1)
//
// Every write is one Raft commit on the active node (standbys forward it), so
// at the same offered rate the latency difference between 3, 5 and 7 voters is
// the cost of reaching quorum. Keys cycle over KEYS so the data set stays the
// same size (overwrites, one version kept) whatever the rate or duration.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { arrivalScenarios, commonOptions, env, summary, targetThresholds } from './lib/common.js';

const VAULT_ADDR = env('VAULT_ADDR', 'https://vault.perf.internal:8200');
const TOKEN = env('VAULT_TOKEN', '');
const MOUNT = env('KV_MOUNT', 'kv_perf');
const KEYS = Number(env('KEYS', 10000));
// Payload size in bytes (a typical small secret).
const VALUE = 'x'.repeat(Number(env('VALUE_BYTES', 1024)));
const PREFIX = `${env('PERF_NODE', 'lg')}`;
// Log the first few failures (status and body) from a handful of VUs, so a
// failing run says why. raft-1's 64 KiB runs failed 84% of writes, fast
// (p50 56 ms), and left no trace of the cause.
let logged = 0;

export const options = {
  ...commonOptions,
  scenarios: arrivalScenarios(),
  thresholds: targetThresholds('kv_write', 100),
};

export default function () {
  const key = `${PREFIX}-${exec.scenario.iterationInTest % KEYS}`;
  const res = http.post(
    `${VAULT_ADDR}/v1/${MOUNT}/data/${key}`,
    JSON.stringify({ data: { value: VALUE } }),
    {
      headers: { 'X-Vault-Token': TOKEN, 'Content-Type': 'application/json' },
      tags: { name: 'kv_write' },
      timeout: env('REQ_TIMEOUT', '30s'),
    },
  );
  const ok = check(res, { 'status 200': (r) => r.status === 200 });
  if (!ok && exec.vu.idInTest <= 5 && logged < 3) {
    logged += 1;
    console.warn(`kv_write failed: status ${res.status} ${res.error || ''} ${String(res.body || '').slice(0, 300)}`);
  }
}

export function handleSummary(data) {
  return summary(data);
}
