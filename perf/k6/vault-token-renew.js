// T17 (repl-1): token renewals at a low steady rate. setup() logs in POOL
// times with the consul-sim AppRole role (renewable tokens, 1 h TTL), then
// each iteration renews one of them in turn. Tokens and leases are local to
// each PR cluster, so on the PR secondary this should keep working during a
// PR link cut (Table 6).
import http from 'k6/http';
import { check, fail } from 'k6';
import exec from 'k6/execution';
import { arrivalScenarios, commonOptions, env, summary, targetThresholds } from './lib/common.js';

const VAULT_ADDR = env('VAULT_ADDR', 'https://primary.vault.repl.internal:8200');
const POOL = Number(env('POOL', 50));

export const options = {
  ...commonOptions,
  scenarios: arrivalScenarios(),
  thresholds: targetThresholds('token_renew', 1000),
  setupTimeout: '5m',
};

export function setup() {
  const tokens = [];
  for (let i = 0; i < POOL; i++) {
    const res = http.post(
      `${VAULT_ADDR}/v1/auth/${env('APPROLE_MOUNT', 'approle')}/login`,
      JSON.stringify({ role_id: env('ROLE_ID', ''), secret_id: env('SECRET_ID', '') }),
      { headers: { 'Content-Type': 'application/json' }, tags: { name: 'setup_login' } },
    );
    if (res.status !== 200) fail(`setup login failed: ${res.status} ${res.body}`);
    tokens.push(res.json('auth.client_token'));
  }
  return { tokens };
}

export default function (data) {
  const token = data.tokens[exec.scenario.iterationInTest % data.tokens.length];
  const res = http.post(`${VAULT_ADDR}/v1/auth/token/renew-self`, JSON.stringify({ increment: '1h' }), {
    headers: { 'X-Vault-Token': token, 'Content-Type': 'application/json' },
    tags: { name: 'token_renew' },
    timeout: env('REQ_TIMEOUT', '10s'),
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  return summary(data);
}
