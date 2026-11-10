// T17 (repl-1): AppRole logins at a low steady rate, as Consul's servers log
// in to Vault. Against the local cluster: on the PR secondary a login with an
// existing entity and an unlimited-use secret ID needs nothing from the
// primary, so it should keep working during a PR link cut (Table 6).
//   ROLE_ID, SECRET_ID   the consul-sim role's credentials (repl/setup.sh)
// Each login's token is revoked straight after, so tokens don't pile up.
import http from 'k6/http';
import { check } from 'k6';
import { arrivalScenarios, commonOptions, env, summary, targetThresholds } from './lib/common.js';

const VAULT_ADDR = env('VAULT_ADDR', 'https://primary.vault.repl.internal:8200');
const ROLE_ID = env('ROLE_ID', '');
const SECRET_ID = env('SECRET_ID', '');
const MOUNT = env('APPROLE_MOUNT', 'approle');

export const options = {
  ...commonOptions,
  scenarios: arrivalScenarios(),
  thresholds: targetThresholds('approle_login', 1000),
};

export default function () {
  const res = http.post(
    `${VAULT_ADDR}/v1/auth/${MOUNT}/login`,
    JSON.stringify({ role_id: ROLE_ID, secret_id: SECRET_ID }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'approle_login' }, timeout: env('REQ_TIMEOUT', '10s') },
  );
  const ok = check(res, { 'status 200': (r) => r.status === 200 });
  if (ok) {
    http.post(`${VAULT_ADDR}/v1/auth/token/revoke-self`, null, {
      headers: { 'X-Vault-Token': res.json('auth.client_token') },
      tags: { name: 'revoke_self' },
      timeout: env('REQ_TIMEOUT', '10s'),
    });
  }
}

export function handleSummary(data) {
  return summary(data);
}
