#!/bin/bash
# Stage 0 for the replication build: activate PR and DR in order, then set up
# the mounts, roles, and tokens T17 uses. Idempotent: each step checks the
# replication status first, so a rerun continues where it stopped.
#
#   1. Every cluster initialised (its first node flips the bootstrap flag),
#      then the delay between the sites (latency.sh, SITE_RTT_MS, 12 ms).
#   2. primary: enable as PR primary and DR primary.
#   3. pr-sec: activate as PR secondary, then an admin token on it through a
#      replicated AppRole role (activation replaces its data and tokens).
#   4. primary-dr: activate as the primary's DR secondary.
#   5. pr-sec: enable as DR primary; pr-sec-dr: activate as its DR secondary.
#   6. Wait for every secondary to stream WALs.
#   7. Mounts and auth on the primary (they replicate): kv_perf, pki_perf,
#      AppRole roles for the load and OPS-B; DR operation token roles.
. /opt/perf/scripts/repl/lib.sh

CA_FILE=/opt/vault/tls/ca.crt # on the Vault nodes: every cluster's certificate has the same CA

step() { log "setup: $*"; event setup step "$*"; }

wait_bootstrap() {
  local c s
  s=$(now_s)
  for c in $CLUSTERS; do
    until [ "$(aws ssm get-parameter --region "$(cl "$c" region)" --name "$(cl "$c" bootstrap_param)" \
      --query Parameter.Value --output text 2>/dev/null)" = "complete" ]; do
      [ $(($(now_s) - s)) -gt 1800 ] && die "$c not initialised after 30 min"
      sleep 10
    done
    wait_healthy "$c" 600 || die "$c not healthy"
  done
}

mode() { repl_status "$1" | jq -r --arg t "$2" '.[$t].mode // "disabled"'; } # mode <cluster> <dr|performance>

enable_primary() { # enable_primary <cluster> <dr|performance>
  local c=$1 t=$2
  if [ "$(mode "$c" "$t")" = "primary" ]; then return 0; fi
  step "enable $t primary on $c"
  wait_unsealed "$c" 600 || die "$c has sealed nodes"
  # Retry a 503: a node the NLB still sends requests to may be sealed.
  local i
  for i in $(seq 1 10); do
    v "$c" write -f "sys/replication/$t/primary/enable" primary_cluster_addr="$(cl "$c" cluster_addr)" >/dev/null && break
    [ "$i" -eq 10 ] && die "enable $t primary on $c failed"
    sleep 10
  done
  sleep 10
  wait_healthy "$c" 300 || die "$c not healthy after enabling $t primary"
}

activate_secondary() { # activate_secondary <primary> <secondary> <dr|performance>
  local p=$1 s=$2 t=$3 wrap
  if [ "$(mode "$s" "$t")" = "secondary" ]; then return 0; fi
  step "activate $s as $t secondary of $p"
  # Revoke a stale ID first (a rerun after a failed activation).
  v "$p" write "sys/replication/$t/primary/revoke-secondary" id="$s" >/dev/null 2>&1 || true
  wrap=$(v "$p" write -format=json "sys/replication/$t/primary/secondary-token" id="$s" ttl=30m | jq -er .wrap_info.token)
  # primary_api_addr: the token names the primary's node IP, which the TLS
  # certificate doesn't cover, so pass the NLB name.
  v "$s" write "sys/replication/$t/secondary/enable" token="$wrap" \
    primary_api_addr="$(cl "$p" addr)" ca_file="$CA_FILE" >/dev/null
  forget_token "$s"
}

# An admin token on the PR secondary. Activation wipes its token store, and
# 2.1.1+ent refuses sys/generate-root on a performance secondary (403 even for
# the status read, seen in the repl-dry run). So the primary gets a repl-admin
# policy and AppRole role, which replicate, and setup logs in to the PR
# secondary with it: a local token with a 24-hour period. Cached as that
# cluster's token (lib.sh token), which every later step uses.
admin_token() { # admin_token <cluster>
  local c=$1 f="$STATE_DIR/token-$1" creds res tok
  if [ -s "$f" ] && TOKEN_OVERRIDE=$(cat "$f") v "$c" token lookup >/dev/null 2>&1; then return 0; fi
  step "admin token on $c through the replicated repl-admin AppRole role"
  jq -e 'has("approle/")' <<<"$(v primary auth list -format=json)" >/dev/null || v primary auth enable approle >/dev/null
  v primary policy write repl-admin - >/dev/null <<'POL'
path "*" { capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"] }
POL
  v primary write auth/approle/role/repl-admin token_policies=repl-admin token_period=24h \
    secret_id_num_uses=0 secret_id_ttl=0 >/dev/null
  creds=$(jq -n --arg r "$(v primary read -field=role_id auth/approle/role/repl-admin/role-id)" \
    --arg s "$(v primary write -f -field=secret_id auth/approle/role/repl-admin/secret-id)" '{role_id: $r, secret_id: $s}')
  # The role reaches the secondary through replication: retry for a minute.
  for _ in $(seq 1 12); do
    res=$(TOKEN_OVERRIDE=none api "$c" POST auth/approle/login "$creds")
    tok=$(jq -r '.auth.client_token // empty' <<<"${res#* }" 2>/dev/null || true)
    [ -n "$tok" ] && break
    sleep 5
  done
  [ -n "$tok" ] || die "admin login on $c failed: $res"
  (umask 077 && echo "$tok" > "$f")
}

wait_streaming() { # wait_streaming <cluster> <dr|performance>
  local secs
  secs=$(wait_state "$1" "$2" stream-wals 1800) || die "$1 ($2) not streaming WALs after 30 min: $(repl_status "$1")"
  # Activation leaves the standbys sealed until they're restarted.
  unseal_standbys "$1"
  event setup step "$1 $2 stream-wals" secs "$secs"
}

mounts() {
  step "mounts, auth and policies on the primary"
  local m
  m=$(v primary secrets list -format=json)
  jq -e 'has("kv_perf/")' <<<"$m" >/dev/null || v primary secrets enable -path=kv_perf -version=2 kv >/dev/null
  sleep 5
  v primary write kv_perf/config max_versions=1 >/dev/null
  v primary kv put -mount=kv_perf probe value=setup >/dev/null

  # pki_perf: EC P-256 root and intermediate, roles like Consul's leaf-cert.
  if ! jq -e 'has("pki_perf_root/")' <<<"$m" >/dev/null; then
    v primary secrets enable -path=pki_perf_root -max-lease-ttl=87600h pki >/dev/null
    v primary write -format=json pki_perf_root/root/generate/internal common_name="perf root" key_type=ec key_bits=256 ttl=87600h >/dev/null
  fi
  if ! jq -e 'has("pki_perf/")' <<<"$m" >/dev/null; then
    v primary secrets enable -path=pki_perf -max-lease-ttl=8760h pki >/dev/null
    csr=$(v primary write -format=json pki_perf/intermediate/generate/internal common_name="perf intermediate" key_type=ec key_bits=256 | jq -r .data.csr)
    cert=$(v primary write -format=json pki_perf_root/root/sign-intermediate csr="$csr" format=pem_bundle ttl=8760h | jq -r .data.certificate)
    v primary write pki_perf/intermediate/set-signed certificate="$cert" >/dev/null
  fi
  # leaf-nostore signs Consul-shaped CSRs (key_type=any). leaf-store also
  # issues the stored leafs for the revocation test, and issue needs a fixed
  # key type.
  v primary write pki_perf/roles/leaf-nostore allow_any_name=true enforce_hostnames=false \
    allowed_uri_sans="spiffe://*" require_cn=false key_type=any ttl=168h max_ttl=168h no_store=true >/dev/null
  v primary write pki_perf/roles/leaf-store allow_any_name=true enforce_hostnames=false \
    allowed_uri_sans="spiffe://*" require_cn=false key_type=ec key_bits=256 ttl=168h max_ttl=168h no_store=false >/dev/null
  # Cross-cluster revocation (Table 6): a PR secondary can revoke a
  # certificate the primary issued, through the primary.
  v primary write pki_perf/config/crl cross_cluster_revocation=true auto_rebuild=true >/dev/null

  # The load's policy: Consul-like signing, KV, its own token.
  v primary policy write consul-sim - >/dev/null <<'POL'
path "pki_perf/sign/leaf-nostore" { capabilities = ["update"] }
path "pki_perf/issue/leaf-store"  { capabilities = ["update"] }
path "kv_perf/data/*"             { capabilities = ["create", "update", "read"] }
path "kv_perf/metadata/*"         { capabilities = ["read", "list"] }
path "auth/token/renew-self"      { capabilities = ["update"] }
path "auth/token/lookup-self"     { capabilities = ["read"] }
POL

  # AppRole: consul-sim (unlimited-use secret IDs, as Consul's), first-login
  # (never used before the PR cut: needs a new entity), limited-use (each login
  # decrements its secret ID, a write on the primary).
  jq -e 'has("approle/")' <<<"$(v primary auth list -format=json)" >/dev/null || v primary auth enable approle >/dev/null
  for r in consul-sim:0 first-login:0 limited-use:5; do
    v primary write "auth/approle/role/${r%%:*}" token_policies=consul-sim token_ttl=1h token_max_ttl=24h \
      secret_id_num_uses="${r#*:}" secret_id_ttl=0 >/dev/null
    if [ ! -s "$STATE_DIR/approle-${r%%:*}.json" ]; then
      (umask 077 && jq -n --arg r "$(v primary read -field=role_id "auth/approle/role/${r%%:*}/role-id")" \
        --arg s "$(v primary write -f -field=secret_id "auth/approle/role/${r%%:*}/secret-id")" \
        '{role_id: $r, secret_id: $s}' > "$STATE_DIR/approle-${r%%:*}.json")
    fi
  done

  # DR operation tokens: a batch token from this role on the cluster a DR
  # replica protects, as the HLD's script does (12-hourly, 24-hour TTL).
  v primary policy write dr-ops - >/dev/null <<'POL'
path "sys/replication/dr/secondary/promote"       { capabilities = ["update"] }
path "sys/replication/dr/secondary/update-primary" { capabilities = ["update"] }
path "sys/replication/dr/secondary/merkle-check"   { capabilities = ["update"] }
path "sys/replication/dr/secondary/reindex"        { capabilities = ["update"] }
path "sys/storage/raft/autopilot/state"            { capabilities = ["read"] }
POL
  local c
  for c in primary pr-sec; do
    v "$c" write auth/token/roles/dr-ops allowed_policies=dr-ops orphan=true renewable=false token_type=batch >/dev/null ||
      log "setup: token role on $c not written (replicated from the primary?)"
  done
}

# A periodic token per load generator's cluster for the signing and KV load
# (tokens are local to each PR cluster, so the PR secondary issues its own).
load_tokens() {
  local c
  for c in primary pr-sec; do
    [ -s "$STATE_DIR/load-token-$c" ] && TOKEN_OVERRIDE=$(cat "$STATE_DIR/load-token-$c") v "$c" token lookup >/dev/null 2>&1 && continue
    (umask 077 && v "$c" token create -orphan -policy=consul-sim -period=24h -display-name=perf-load -field=token > "$STATE_DIR/load-token-$c")
  done
}

main() {
  event setup start
  step "wait for all four clusters"
  wait_bootstrap
  # The delay between the sites goes on before replication starts, so
  # activation and every cut see the same link (latency.sh, SITE_RTT_MS).
  step "latency between the sites: ${SITE_RTT_MS:-12} ms round trip"
  /opt/perf/scripts/repl/latency.sh on "${SITE_RTT_MS:-12}"
  enable_primary primary performance
  enable_primary primary dr
  activate_secondary primary pr-sec performance
  wait_streaming pr-sec performance
  admin_token pr-sec
  activate_secondary primary primary-dr dr
  wait_streaming primary-dr dr
  enable_primary pr-sec dr
  activate_secondary pr-sec pr-sec-dr dr
  wait_streaming pr-sec-dr dr
  mounts
  load_tokens
  # Mounts and roles made on the primary must be visible on the PR secondary.
  local i
  for i in $(seq 1 60); do
    v pr-sec read auth/approle/role/consul-sim >/dev/null 2>&1 && v pr-sec read pki_perf/roles/leaf-nostore >/dev/null 2>&1 && break
    sleep 5
  done
  for c in $CLUSTERS; do event setup status cluster "$c" status "$(repl_status "$c")"; done
  event setup done
  log "setup: done"
}

main "$@"
