#!/bin/bash
# T13: Consul signing CA rotation under load, with the CSR limit set.
#   RUN_ID=t13 CACHED=100000 CSR_LIMIT=350 ca-rotation-test.sh
#
# Consul renews its signing CA (the intermediate that signs leafs) on its own,
# and operators rotate it by changing IntermediatePKIPath. Root rotation is out
# of scope: Consul's root here is a Vault intermediate under the enterprise
# root CA, whose lifecycle belongs to that CA (issue #12). Under a constant
# foreground load of new leafs (consul-leaf.js at RATE, default 50/s: new
# sidecars keep arriving), it:
#   0. sets Consul's CSR limit to CSR_LIMIT (the recommended value) and fills
#      the local agent's leaf cache with CACHED leafs (default 100,000, the
#      mesh) at PREFILL_RATE. The agent keeps those leafs fresh, as Dataplane's
#      servers would for their proxies;
#   1. signing CA rotation: mounts connect_<dc>_next_inter, lets Consul's policy
#      use it and points IntermediatePKIPath at it. Consul creates a new signing
#      CA under the same root. Watches WATCH (5m): did signing continue, and were
#      cached leafs re-issued? (plan-1: switched in 15 s, 0 of 100,000 re-issued.)
#   2. client agent check (issue #11): after the rotation a restarted client
#      agent's auto_encrypt certificate, signed by the new signing CA, was
#      rejected by every server ("tls: unknown certificate authority"). It
#      restarts the local agent and records whether it reconnects within
#      AGENT_WAIT (90s); then restarts the Consul servers one at a time
#      (followers first, leader last, each until Autopilot is healthy), restarts
#      the agent again and records how long it takes to reconnect.
# ROTATIONS="signing root" also runs a root rotation (RootPKIPath to the next mesh
# intermediate). It needs a next intermediate bundle in <name>/vault/mesh-ca-next,
# which the build no longer creates, and in this design Vault refuses the
# cross-sign (issue #12), so it's kept only for reference.
# Records: time until signing moved to the new CA, re-issued leafs (Vault signs
# on Consul's intermediates minus the foreground's), the foreground's failures,
# p99 and longest gap with no new leaf during the rotation (k6 per-request
# samples), and the agent check. Leaves the CA rotated: run it last.
# Writes <RUN_ID>-<node>-t13/t13.json, points.csv.gz, phases.json.
. /opt/perf/scripts/lib.sh
export CONSUL_HTTP_TOKEN="$CONSUL_OPERATOR_TOKEN"

RATE=${RATE:-50}
CACHED=${CACHED:-100000}
PREFILL_RATE=${PREFILL_RATE:-350}
CSR_LIMIT=${CSR_LIMIT:-350}
WATCH=${WATCH:-5m}
STORM_MAX=${STORM_MAX:-30m}
# Which rotations to run: "signing" (default) or "signing root" (see above).
# Not PHASES: lib.sh uses that name for the export's phase list (it starts as
# "[]", which made plan-2's T13 skip the rotation).
ROTATIONS=${ROTATIONS:-signing}
AGENT_WAIT=${AGENT_WAIT:-90}
NEXT_INTER="connect_${CONSUL_DATACENTER}_next_inter"
NEXT_ROOT="pki_mesh_int_next"
ROOT_BEFORE=""

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-t13"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"ca-rotation-test","run_id":"$RUN_ID","node":"$PERF_NODE","rotations":"$ROTATIONS","rate":$RATE,"cached":$CACHED,"prefill_rate":$PREFILL_RATE,"csr_limit":$CSR_LIMIT,"watch":"$WATCH","storm_max":"$STORM_MAX","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P
PROM=$(prom_url)

# Vault signs on Consul's intermediates (old and new mounts) in the last <s>
# seconds. increase() copes with series appearing or resetting (a raw sum once
# dropped by thousands when a series vanished).
signs_in() {
  prom_query "$PROM" "sum(increase(${SIGN_METRIC}[${1}s]))" "$(date +%s)" | jq -r '.[0].value[1] // "0" | tonumber | floor'
}
active_root() { curl -sf -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}/v1/agent/connect/ca/roots" | jq -r .ActiveRootID; }
# set_ca <jq filter on .Config> [force]: change Consul's CA config, keeping
# everything else. "force" adds ForceWithoutCrossSigning (see the root rotation).
set_ca() {
  consul connect ca get-config | jq --arg f "${2:-}" \
    "{Provider, Config: (.Config | $1)} + (if \$f == \"force\" then {ForceWithoutCrossSigning: true} else {} end)" > "$OUT/ca-config-new.json"
  consul connect ca set-config -config-file "$OUT/ca-config-new.json"
  rm -f "$OUT/ca-config-new.json"
}
# Let Consul's token use a new mount, like the bootstrap policy does for the
# originals. A root mount also gets root/sign-self-issued: on a root rotation
# Consul has the OLD root cross-sign the new one (plan-1's first T13 failed
# with 403 on pki_mesh_int/root/sign-self-issued).
allow_path() { # allow_path <mount> root|intermediate
  local pol line add=""
  pol=$(vault policy read consul-connect-ca)
  if [ "$2" = root ]; then
    set -- "$1" "path \"/sys/mounts/$1\" { capabilities = [\"read\"] }" \
      "path \"/$1/\" { capabilities = [\"read\"] }" \
      "path \"/$1/root/sign-intermediate\" { capabilities = [\"update\"] }" \
      "path \"/$1/root/sign-self-issued\" { capabilities = [\"sudo\", \"update\"] }"
  else
    set -- "$1" "path \"/sys/mounts/$1\" { capabilities = [\"read\"] }" \
      "path \"/sys/mounts/$1/tune\" { capabilities = [\"update\"] }" \
      "path \"/$1/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }"
  fi
  shift
  # Only paths the policy doesn't have yet (no duplicate path blocks).
  for line in "$@"; do
    grep -qF "${line%% \{*}" <<<"$pol" || add+=$'\n'"$line"
  done
  [ -n "$add" ] && vault policy write consul-connect-ca - <<<"$pol$add" >/dev/null
  return 0
}
# switched: has the rotation taken effect? signing: the new mount has signs;
# root: Consul's active root ID changed.
switched() { # switched signing|root
  if [ "$1" = signing ]; then
    [ "$(prom_query "$PROM" "sum({__name__=~\"vault_route_update_${NEXT_INTER//[^A-Za-z0-9]/_}_+count\"})" "$(date +%s)" |
      jq -r '.[0].value[1] // "0" | tonumber | floor')" -gt 0 ]
  else
    [ "$(active_root)" != "$ROOT_BEFORE" ]
  fi
}
mount_once() { # mount_once <path> <description> <max lease ttl>
  vault secrets list -format=json | jq -e --arg p "$1/" 'has($p)' >/dev/null ||
    vault secrets enable -path="$1" -description="$2" pki
  vault secrets tune -max-lease-ttl="$3" "$1"
}
# watch_phase <signing|root> <t0 ms> <unused> <max s> <stop when re-issued >= this>:
# polls every 15 s; prints JSON {switched_s, reissued_approx, peak_signs_per_s, duration_s, storm_seen}.
watch_phase() {
  local name=$1 t0=$2 max=$4 goal=$5 now el reissued rate peak=0 started=false quiet=0 sw=null
  while :; do
    sleep 15
    now=$(now_ms)
    el=$(((now - t0) / 1000))
    rate=$(($(signs_in 30) / 30))
    reissued=$(($(signs_in "$((el > 15 ? el : 15))") - RATE * el))
    [ "$reissued" -lt 0 ] && reissued=0
    [ "$rate" -gt "$peak" ] && peak=$rate
    if [ "$sw" = null ] && switched "$name"; then sw=$el; fi
    echo "  $name: ${el}s signs/s=$rate re-issued~$reissued" >&2
    if [ "$rate" -gt $((RATE * 3 / 2)) ]; then started=true; quiet=0; elif $started; then quiet=$((quiet + 1)); fi
    { [ "$goal" -gt 0 ] && [ "$reissued" -ge "$goal" ]; } && break
    { $started && [ "$quiet" -ge 4 ]; } && break
    [ "$el" -ge "$max" ] && break
  done
  jq -n -c --argjson sw "$sw" --argjson r "$reissued" --argjson p "$peak" --argjson d "$el" --argjson st "$started" \
    '{switched_s: $sw, reissued_approx: $r, peak_signs_per_s: $p, duration_s: $d, storm_seen: $st}'
}

consul-ca-limits.sh "$CSR_LIMIT" 0 >/dev/null
restart_consul_agent
T0=$(now_ms)
idle baseline "$BASELINE"
T1=$(now_ms)
AID=$(annotate "T13 CA rotation (run $RUN_ID, $CACHED cached leafs, CSR limit $CSR_LIMIT/s)" "perf,t13,$RUN_ID" "$T1")

# --- 0. fill the agent's cache -----------------------------------------------
prefill_s=$((CACHED / PREFILL_RATE))
echo "$(date -u +%H:%M:%S) prefilling $CACHED leafs at $PREFILL_RATE/s (${prefill_s}s)"
RUN_ID="$RUN_ID-prefill" RATE="$PREFILL_RATE" RAMP=0 HOLD="${prefill_s}s" BASELINE=0 COOLDOWN=0 EXPORT=0 \
  run-k6.sh /opt/perf/k6/consul-leaf.js --no-thresholds > "$OUT/prefill.log" 2>&1 || true
P1=$(now_ms)

stop_k6() { pkill -TERM -f -- "k6 run -e RUN_ID=$RUN_ID -e PERF_NODE=$PERF_NODE " 2>/dev/null || true; }
RAMP=10s HOLD=4h RATE=$RATE K6_CSV_TIME_FORMAT=unix_milli BASELINE=0 COOLDOWN=0 EXPORT=0 \
  run-k6.sh /opt/perf/k6/consul-leaf.js --out "csv=$OUT/points.csv" --no-thresholds > "$OUT/k6.log" 2>&1 &
k6_pid=$!
trap stop_k6 EXIT
sleep 70

# agent_back <max s>: restart the local agent; print the seconds until it has a
# leader again, or null if it doesn't within <max s> (locked out).
agent_back() {
  local t0 i l
  sudo systemctl restart consul
  t0=$(now_ms)
  for i in $(seq 1 "$1"); do
    l=$(curl -s --max-time 2 "${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}/v1/status/leader" || true)
    case "$l" in *:8300*) echo $(((($(now_ms) - t0) + 500) / 1000)); return 0 ;; esac
    sleep 1
  done
  echo null
}
# consul_rolling_restart: restart every Consul server, followers first and the
# leader last, each until Autopilot is healthy again (asked of another server's
# HTTPS API: the local agent may be locked out). Prints the seconds it took.
consul_rolling_restart() {
  local inst t0 leader n id ip i h
  inst=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=consul" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].{node: Tags[?Key==`Node`]|[0].Value, id: InstanceId, ip: PrivateIpAddress}' --output json)
  srv_api() { # srv_api <skip ip> <path>
    local x
    for x in $(jq -r '.[].ip' <<<"$inst"); do
      [ "$x" = "$1" ] && continue
      curl -sk --max-time 5 -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "https://$x:8501$2" && return 0
    done
    return 1
  }
  t0=$(now_ms)
  leader=$(srv_api none /v1/status/leader | tr -d '"' | cut -d: -f1 || true)
  while read -r n id ip; do
    echo "$(date -u +%H:%M:%S) restarting Consul server $n" >&2
    ssm_run 120 'systemctl restart consul && echo ok' "$id" >/dev/null
    for i in $(seq 1 60); do
      sleep 5
      h=$(srv_api "$ip" /v1/operator/autopilot/health | jq -r '.Healthy' 2>/dev/null || true)
      [ "$h" = true ] && break
    done
  done < <(jq -r --arg l "$leader" '[.[] | select(.ip != $l)] + [.[] | select(.ip == $l)] | .[] | "\(.node) \(.id) \(.ip)"' <<<"$inst")
  echo $((($(now_ms) - t0) / 1000))
}

# --- 1. signing CA rotation --------------------------------------------------
A0=$(now_ms); A1=$A0; AG1=$A0; a='{"skipped": true}'
if grep -qw signing <<<"$ROTATIONS"; then
root0=$(active_root)
mount_once "$NEXT_INTER" "Consul signing CA after T13 rotation" 8760h
allow_path "$NEXT_INTER" intermediate
A0=$(now_ms)
echo "$(date -u +%H:%M:%S) rotating the signing CA: IntermediatePKIPath -> $NEXT_INTER"
set_ca "del(.intermediate_pki_path) | .IntermediatePKIPath = \"$NEXT_INTER\""
a=$(watch_phase signing "$A0" 0 "$(to_secs "$WATCH")" 0)
A1=$(now_ms)
a=$(jq -c --arg r0 "$root0" --arg r1 "$(active_root)" '. + {active_root_changed: ($r0 != $r1)}' <<<"$a")
echo "  signing CA rotation: $a"

# --- 2. client agent check (issue #11) -----------------------------------------
echo "$(date -u +%H:%M:%S) restarting the client agent after the rotation (up to ${AGENT_WAIT}s)"
before=$(agent_back "$AGENT_WAIT")
echo "  agent reconnected: ${before} s (null = locked out)"
rr=null; after=null
if [ "$before" = null ]; then
  rr=$(consul_rolling_restart)
  after=$(agent_back "$AGENT_WAIT")
  echo "  Consul servers restarted in ${rr} s; agent reconnected after: ${after} s"
fi
AG1=$(now_ms)
a=$(jq -c --argjson b "$before" --argjson rr "$rr" --argjson af "$after" \
  '. + {agent_check: {reconnected_s: $b, locked_out: ($b == null), servers_restarted_s: $rr, reconnected_after_server_restart_s: $af}}' <<<"$a")
fi

# --- 3. root rotation (out of scope by default; see the header) -----------------
B0=$(now_ms); B1=$B0; b='{"skipped": true, "reason": "out of scope: enterprise root CA (issue #12)"}'
if grep -qw root <<<"$ROTATIONS"; then
mount_once "$NEXT_ROOT" "Next mesh intermediate CA (T13 root rotation)" 43800h
aws secretsmanager get-secret-value --secret-id "$PERF_NAME/vault/mesh-ca-next" --query SecretString --output text |
  jq -r .pem_bundle > "$OUT/bundle.pem"
vault write -format=json "$NEXT_ROOT/config/ca" pem_bundle=@"$OUT/bundle.pem" >/dev/null
shred -u "$OUT/bundle.pem" 2>/dev/null || rm -f "$OUT/bundle.pem"
for id in $(vault list -format=json "$NEXT_ROOT/issuers" | jq -r '.[]'); do
  [ -n "$(vault read -format=json "$NEXT_ROOT/issuer/$id" | jq -r '.data.key_id // empty')" ] &&
    vault write "$NEXT_ROOT/config/issuers" default="$id" >/dev/null
done
allow_path "$NEXT_ROOT" root
# Consul cross-signs the new root with the current one: allow that on the current root too.
cur_root=$(consul connect ca get-config | jq -r '.Config.RootPKIPath // .Config.root_pki_path')
allow_path "$cur_root" root
root1=$(active_root)
ROOT_BEFORE=$root1
B0=$(now_ms); b_s0=0
# Without cross-signing: Consul cross-signs a new root with the old one through
# Vault's root/sign-self-issued, which only accepts self-issued certificates.
# Here (as in the HLD) Consul's root is a Vault intermediate under an offline
# root, so is the new one, and Vault refuses ("given certificate is not
# self-issued", plan-1). Rotating needs ForceWithoutCrossSigning, which Consul
# documents can cause connection failures until every proxy has a new leaf.
CROSS_SIGN=${CROSS_SIGN:-false}
echo "$(date -u +%H:%M:%S) rotating the root: RootPKIPath -> $NEXT_ROOT (cross-signing: $CROSS_SIGN)"
set_ca "del(.root_pki_path) | .RootPKIPath = \"$NEXT_ROOT\"" "$([ "$CROSS_SIGN" = true ] || echo force)"
b=$(watch_phase root "$B0" "$b_s0" "$(to_secs "$STORM_MAX")" $((CACHED * 95 / 100)))
B1=$(now_ms)
b=$(jq -c --arg r0 "$root1" --arg r1 "$(active_root)" --arg cs "$CROSS_SIGN" \
  '. + {active_root_changed: ($r0 != $r1), cross_signed: ($cs == "true")}' <<<"$b")
echo "  root rotation: $b"
fi
sleep 30

stop_k6
wait "$k6_pid" 2>/dev/null || true
trap - EXIT
T3=$(now_ms)
annotate_end "$AID" "$T3"

# Foreground (new leafs) per phase, from k6's per-request samples.
client=$(python3 - "$OUT/points.csv" "$A0" "$A1" "$B0" "$B1" <<'PY'
import csv, json, sys
pts, a0, a1, b0, b1 = sys.argv[1], *map(int, sys.argv[2:])
ok, bad, dur = [], [], []
for row in csv.DictReader(open(pts)):
    t = float(row["timestamp"]); t = t if t > 1e11 else t * 1000
    if row.get("name") != "leaf":
        continue
    if row.get("metric_name") == "http_reqs":
        (ok if row.get("status") == "200" else bad).append(t)
    elif row.get("metric_name") == "http_req_duration":
        dur.append((t, float(row["metric_value"])))
ok.sort()
def phase(a, b):
    o = [t for t in ok if a <= t <= b]
    f = [t for t in bad if a <= t <= b]
    d = sorted(v for t, v in dur if a <= t <= b)
    gaps = [y - x for x, y in zip(o, o[1:])]
    return {"requests": len(o) + len(f), "failed": len(f),
            "p99_ms": round(d[int(len(d) * 0.99)], 1) if d else None,
            "max_gap_s": round(max(gaps) / 1000, 2) if gaps else None}
print(json.dumps({"signing": phase(a0, a1), "root": phase(b0, b1)}))
PY
) || client='{}'
gzip -f "$OUT/points.csv"
jq -n --argjson rate "$RATE" --argjson cached "$CACHED" --argjson lim "$CSR_LIMIT" --argjson a "$a" --argjson b "$b" \
  --argjson c "${client:-{\}}" --argjson pf "$(((P1 - T1) / 1000))" \
  '{foreground_rate: $rate, cached: $cached, csr_limit: $lim, prefill_s: $pf,
    signing_rotation: ($a + {foreground: $c.signing}),
    root_rotation: (if $b.skipped then $b else ($b + {foreground: $c.root,
      expected_storm_s: (($cached / $lim) | round)}) end)}' > "$OUT/t13.json"
jq -c . "$OUT/t13.json"

idle cooldown "$COOLDOWN"
T4=$(now_ms)
jq -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson p1 "$P1" --argjson a0 "$A0" --argjson a1 "$A1" \
  --argjson ag1 "$AG1" --argjson b0 "$B0" --argjson b1 "$B1" --argjson t3 "$T3" --argjson t4 "$T4" \
  '[{name: "baseline", start: $t0, end: $t1}, {name: "prefill", start: $t1, end: $p1},
    {name: "rotate-signing", start: $a0, end: $a1}, {name: "agent-check", start: $a1, end: $ag1},
    {name: "rotate-root", start: $b0, end: $b1},
    {name: "cooldown", start: $t3, end: $t4}] | map(select(.end > .start))' > "$OUT/phases.json"
# export_grafana exports lib.sh's PHASES (and rewrites phases.json from it).
PHASES=$(jq -c . "$OUT/phases.json")
export_grafana "$OUT" "T13 CA rotation ($RUN_ID)"
upload_results "$OUT"
