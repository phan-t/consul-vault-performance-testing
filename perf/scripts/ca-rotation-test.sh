#!/bin/bash
# T13: Consul CA rotation under load, with the CSR limit set.
#   RUN_ID=t13 CACHED=100000 CSR_LIMIT=350 ca-rotation-test.sh
#
# A root rotation makes every sidecar's leaf invalid, so the whole mesh is
# re-issued at once, paced only by Consul's CSR limit: the biggest leaf storm
# in normal operation. Under a constant foreground load of new leafs
# (consul-leaf.js at RATE, default 50/s: new sidecars keep arriving), it:
#   0. sets Consul's CSR limit to CSR_LIMIT (the recommended value) and fills
#      the local agent's leaf cache with CACHED leafs (default 100,000, the
#      mesh) at PREFILL_RATE. The agent keeps those leafs fresh, as Dataplane's
#      servers would for their proxies, so a root change re-issues all of them;
#   1. signing CA rotation: mounts connect_<dc>_next_inter, lets Consul's policy
#      use it and points IntermediatePKIPath at it. Consul creates a new signing
#      CA under the same root. Watches WATCH (5m): did signing continue, and were
#      cached leafs re-issued (they shouldn't need to be)?
#   2. root rotation: mounts the next mesh intermediate (pki_mesh_int_next,
#      from the <name>/vault/mesh-ca-next secret, signed by the same offline
#      root) and points RootPKIPath at it. Consul's active root changes, and
#      every cached leaf is re-issued: the storm. Watches until 95% of CACHED
#      were re-issued, the sign rate is back to the foreground rate for a
#      minute, or STORM_MAX (30m).
# Records per phase: time until signing moved to the new CA, re-issued leafs
# (Vault signs on Consul's intermediates minus the foreground's), the storm's
# duration and peak sign rate, and the foreground's failures, p99 and longest
# gap with no new leaf (k6 per-request samples). Leaves the CA rotated: run it
# last. Writes <RUN_ID>-<node>-t13/t13.json, points.csv.gz, phases.json.
. /opt/perf/scripts/lib.sh
export CONSUL_HTTP_TOKEN="$CONSUL_OPERATOR_TOKEN"

RATE=${RATE:-50}
CACHED=${CACHED:-100000}
PREFILL_RATE=${PREFILL_RATE:-350}
CSR_LIMIT=${CSR_LIMIT:-350}
WATCH=${WATCH:-5m}
STORM_MAX=${STORM_MAX:-30m}
NEXT_INTER="connect_${CONSUL_DATACENTER}_next_inter"
NEXT_ROOT="pki_mesh_int_next"
ROOT_BEFORE=""

OUT="$RESULTS_DIR/$RUN_ID-$PERF_NODE-t13"
mkdir -p "$OUT"
cat > "$OUT/params.json" <<P
{"tool":"ca-rotation-test","run_id":"$RUN_ID","node":"$PERF_NODE","rate":$RATE,"cached":$CACHED,"prefill_rate":$PREFILL_RATE,"csr_limit":$CSR_LIMIT,"watch":"$WATCH","storm_max":"$STORM_MAX","baseline":"$BASELINE","cooldown":"$COOLDOWN"}
P
PROM=$(prom_url)

# Total Vault signs on Consul's intermediates (old and new mounts) right now.
signs_now() {
  prom_query "$PROM" "sum(${SIGN_METRIC})" "$(date +%s)" | jq -r '.[0].value[1] // "0" | tonumber | floor'
}
active_root() { curl -sf -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}/v1/agent/connect/ca/roots" | jq -r .ActiveRootID; }
# set_ca <jq filter on .Config>: change Consul's CA config, keeping everything else.
set_ca() {
  consul connect ca get-config | jq "{Provider, Config: (.Config | $1)}" > "$OUT/ca-config-new.json"
  consul connect ca set-config -config-file "$OUT/ca-config-new.json"
  rm -f "$OUT/ca-config-new.json"
}
# Let Consul's token use a new mount, like the bootstrap policy does for the originals.
allow_path() { # allow_path <mount> root|intermediate
  local pol
  pol=$(vault policy read consul-connect-ca)
  if [ "$2" = root ]; then
    pol+="
path \"/sys/mounts/$1\" { capabilities = [\"read\"] }
path \"/$1/\" { capabilities = [\"read\"] }
path \"/$1/root/sign-intermediate\" { capabilities = [\"update\"] }"
  else
    pol+="
path \"/sys/mounts/$1\" { capabilities = [\"read\"] }
path \"/sys/mounts/$1/tune\" { capabilities = [\"update\"] }
path \"/$1/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }"
  fi
  vault policy write consul-connect-ca - <<<"$pol" >/dev/null
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
# watch_phase <signing|root> <t0 ms> <signs at t0> <max s> <stop when re-issued >= this>:
# polls every 15 s; prints JSON {switched_s, reissued_approx, peak_signs_per_s, duration_s, storm_seen}.
watch_phase() {
  local name=$1 t0=$2 s0=$3 max=$4 goal=$5 now s el reissued rate prev=$3 tprev=$2 peak=0 started=false quiet=0 sw=null
  while :; do
    sleep 15
    now=$(now_ms); s=$(signs_now)
    el=$(((now - t0) / 1000))
    rate=$(((s - prev) * 1000 / (now - tprev > 0 ? now - tprev : 1)))
    prev=$s; tprev=$now
    reissued=$((s - s0 - RATE * el))
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

# --- 1. signing CA rotation --------------------------------------------------
root0=$(active_root)
mount_once "$NEXT_INTER" "Consul signing CA after T13 rotation" 8760h
allow_path "$NEXT_INTER" intermediate
A0=$(now_ms); a_s0=$(signs_now)
echo "$(date -u +%H:%M:%S) rotating the signing CA: IntermediatePKIPath -> $NEXT_INTER"
set_ca "del(.intermediate_pki_path) | .IntermediatePKIPath = \"$NEXT_INTER\""
a=$(watch_phase signing "$A0" "$a_s0" "$(to_secs "$WATCH")" 0)
A1=$(now_ms)
a=$(jq -c --arg r0 "$root0" --arg r1 "$(active_root)" '. + {active_root_changed: ($r0 != $r1)}' <<<"$a")
echo "  signing CA rotation: $a"

# --- 2. root rotation --------------------------------------------------------
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
root1=$(active_root)
ROOT_BEFORE=$root1
B0=$(now_ms); b_s0=$(signs_now)
echo "$(date -u +%H:%M:%S) rotating the root: RootPKIPath -> $NEXT_ROOT"
set_ca "del(.root_pki_path) | .RootPKIPath = \"$NEXT_ROOT\""
b=$(watch_phase root "$B0" "$b_s0" "$(to_secs "$STORM_MAX")" $((CACHED * 95 / 100)))
B1=$(now_ms)
b=$(jq -c --arg r0 "$root1" --arg r1 "$(active_root)" '. + {active_root_changed: ($r0 != $r1)}' <<<"$b")
echo "  root rotation: $b"
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
    root_rotation: ($b + {foreground: $c.root,
      expected_storm_s: (($cached / $lim) | round)})}' > "$OUT/t13.json"
jq -c . "$OUT/t13.json"

idle cooldown "$COOLDOWN"
T4=$(now_ms)
jq -n --argjson t0 "$T0" --argjson t1 "$T1" --argjson p1 "$P1" --argjson a0 "$A0" --argjson a1 "$A1" \
  --argjson b0 "$B0" --argjson b1 "$B1" --argjson t3 "$T3" --argjson t4 "$T4" \
  '[{name: "baseline", start: $t0, end: $t1}, {name: "prefill", start: $t1, end: $p1},
    {name: "rotate-signing", start: $a0, end: $a1}, {name: "rotate-root", start: $b0, end: $b1},
    {name: "cooldown", start: $t3, end: $t4}] | map(select(.end > .start))' > "$OUT/phases.json"
export_grafana "$OUT" "T13 CA rotation ($RUN_ID)"
upload_results "$OUT"
