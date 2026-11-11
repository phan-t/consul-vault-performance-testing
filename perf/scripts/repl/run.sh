#!/bin/bash
# T17 campaign (issue #23), unattended on loadgen-0. Started by the
# workstation's scripts/run-repl.sh.
#
#   run.sh start <plan>    run in the background (systemd unit perf-repl-<plan>)
#   run.sh run <plan>      run in the foreground
#   run.sh status <plan>   progress
#
# Order: setup, steady load at both sites, baseline, then the cuts with the
# ones that end soonest first, so a problem shows up before the long hold:
#   1. DR cut (primary <-> primary-dr): no effect on clients; promote the
#      lagging replica and count its missing writes; demote and reconnect.
#   2. Both (every link between the sites): PR secondary as for the PR cut,
#      both DR replicas fall behind; then all three catch up.
#   3. PR cut (primary <-> pr-sec), held PR_HOLD (4h): Table 6's PR row every
#      PROBE_EVERY, OPS-B, cross-cluster revocation, stale data, and the
#      planned changes; then the catch-up and every check after it.
# Each step is recorded in state.json, and a rerun skips completed steps.
#
# Settings (environment): SITE_RTT_MS (12), PR_HOLD (4h), BOTH_HOLD (15m), DR_HOLD (10m), FINAL_WAIT (10m),
# BASELINE (10m), SETTLE (5m), PROBE_EVERY (1h), CATCHUP_MAX (4h),
# KV_RATE (50), DAY_KEYS (50000), SIGN_RATE (350), SEC_KV_RATE (2),
# LOGIN_RATE (2), RENEW_RATE (5).
PLAN=${2:-repl-1}
export PLAN
. /opt/perf/scripts/repl/lib.sh
R=/opt/perf/scripts/repl
UNIT="perf-repl-$PLAN"
STATE="$RES/state.json"

PR_HOLD=${PR_HOLD:-4h}
BOTH_HOLD=${BOTH_HOLD:-15m}
DR_HOLD=${DR_HOLD:-10m}
FINAL_WAIT=${FINAL_WAIT:-10m}
BASELINE=${BASELINE:-10m}
SETTLE=${SETTLE:-5m}
PROBE_EVERY=${PROBE_EVERY:-1h}
CATCHUP_MAX=${CATCHUP_MAX:-4h}
LOAD_VARS="KV_RATE DAY_KEYS SIGN_RATE SEC_KV_RATE LOGIN_RATE RENEW_RATE LOAD_HOLD"
RUN_VARS="SITE_RTT_MS PR_HOLD BOTH_HOLD DR_HOLD FINAL_WAIT BASELINE SETTLE PROBE_EVERY CATCHUP_MAX MANIFEST_NEW MANIFEST_UPDATE MANIFEST_DELETE $LOAD_VARS"

[ -f "$STATE" ] || echo '{"steps": {}}' > "$STATE"
done_step() { jq -e --arg s "$1" '.steps[$s].status == "done"' "$STATE" >/dev/null; }
mark() { # mark <step> <status>
  local t
  t=$(mktemp)
  jq --arg s "$1" --arg st "$2" --arg ts "$(now)" '.steps[$s] = ((.steps[$s] // {}) + {status: $st, ($st): $ts})' "$STATE" > "$t" && mv "$t" "$STATE"
}
step() { # step <name> <function>: once per plan
  if done_step "$1"; then log "== $1: done already"; return 0; fi
  log "== $1"
  mark "$1" running
  event "step_start" step "$1"
  local aid
  aid=$(annotate "repl $PLAN: $1")
  "$2"
  annotate_end "$aid"
  event "step_done" step "$1"
  mark "$1" done
}
sleep_for() { local s; s=$(to_secs "$1"); log "waiting $1"; sleep "$s"; }

load_env() { local x out=""; for x in $LOAD_VARS; do [ -n "${!x:-}" ] && out+="$x='${!x}' "; done; printf '%s' "$out"; }

# --- steps ---------------------------------------------------------------

s_setup() { "$R/setup.sh"; }

# loadgen-1 needs the AppRole credentials and its cluster's load token, which
# setup made here.
s_share() {
  local tgz
  tgz=$(tar -C "$STATE_DIR" -czf - approle-consul-sim.json load-token-pr-sec | base64 -w0)
  loadgen1 "mkdir -p $STATE_DIR && chmod 700 $STATE_DIR && echo $tgz | base64 -d | tar -C $STATE_DIR -xzf - && ls $STATE_DIR" 60 >&2
}

s_prepare() {
  "$R/dr-promote.sh" token
  "$R/checks.sh" revoke-setup
  "$R/checks.sh" opsb-setup
  "$R/checks.sh" marker-write
  python3 "$R/verify.py" manifest-prepare
  # Control run, every link up: Table 6's operations and the control
  # revocation should all succeed on both PR clusters.
  "$R/checks.sh" probe primary control all
  "$R/checks.sh" probe pr-sec control all
  "$R/checks.sh" revoke pr-sec control control ok
  "$R/checks.sh" revoke-confirm control || true
}

# The status watcher, every second, for the whole run (restarted on a rerun).
ensure_watcher() {
  systemctl is-active --quiet perf-repl-status && return 0
  sudo systemctl reset-failed perf-repl-status 2>/dev/null || true
  sudo systemd-run --unit perf-repl-status --uid "$(id -u)" --gid "$(id -g)" --setenv=PLAN="$PLAN" \
    /bin/bash -lc "$R/status.sh watch 1" >/dev/null
}

# On a rerun after the load started: restart any load that has stopped, on
# both load generators, before the next cut.
ensure_load() {
  done_step load || return 0
  if "$R/load.sh" status | grep -qv ': active$'; then log "restarting load on loadgen-0"; "$R/load.sh" start-missing; fi
  loadgen1 "$(load_env)PLAN=$PLAN $R/load.sh start-missing" 120 >&2
}

s_load() {
  "$R/load.sh" start
  loadgen1 "$(load_env)PLAN=$PLAN /opt/perf/scripts/sync-assets.sh >/dev/null; $(load_env)PLAN=$PLAN $R/load.sh start" 120 >&2
  sleep_for "$BASELINE"
}

s_dr_cut() {
  local cut_ms
  "$R/cut.sh" on dr-primary
  cut_ms=$(cat "$STATE_DIR/cut-dr-primary-ms")
  event cut_start link dr-primary ms "$cut_ms"
  "$R/checks.sh" probe primary dr-cut all
  "$R/checks.sh" probe pr-sec dr-cut all
  sleep_for "$DR_HOLD"
  "$R/checks.sh" probe primary dr-cut-end all
  "$R/checks.sh" probe pr-sec dr-cut-end all
  "$R/dr-promote.sh" promote "$cut_ms"
  "$R/cut.sh" off dr-primary
  event cut_end link dr-primary
  "$R/dr-promote.sh" reconnect
  sleep_for "$SETTLE"
}

catch_up() { # catch_up <cluster> <dr|performance> <its primary> <label>
  local secs
  if secs=$(wait_caught_up "$1" "$2" "$3" "$(to_secs "$CATCHUP_MAX")"); then
    event catchup cluster "$1" type "$2" label "$4" secs "$secs" ok true
  else
    event catchup cluster "$1" type "$2" label "$4" ok false state "$(repl_state "$1" "$2")"
    log "catch-up: $1 ($2) not streaming after $CATCHUP_MAX"
  fi
}

s_both_cut() {
  "$R/cut.sh" on both
  event cut_start link both ms "$(cat "$STATE_DIR/cut-both-ms")"
  "$R/checks.sh" probe primary both-cut all
  "$R/checks.sh" probe pr-sec both-cut reads
  sleep_for "$BOTH_HOLD"
  "$R/checks.sh" probe primary both-cut-end all
  "$R/checks.sh" probe pr-sec both-cut-end reads
  "$R/cut.sh" off both
  event cut_end link both
  catch_up pr-sec performance primary both &
  catch_up primary-dr dr primary both &
  catch_up pr-sec-dr dr pr-sec both &
  wait
  for c in primary pr-sec; do event guards cluster "$c" label both counters "$("$R/status.sh" guards "$c" "$(cat "$STATE_DIR/cut-both-ms")")"; done
  sleep_for "$SETTLE"
}

s_pr_cut() {
  local hold every end next n=0
  "$R/cut.sh" on pr
  event cut_start link pr ms "$(cat "$STATE_DIR/cut-pr-ms")"
  "$R/checks.sh" probe primary pr-cut-0 all
  "$R/checks.sh" probe pr-sec pr-cut-0 reads
  "$R/checks.sh" opsb pr-cut-0
  "$R/checks.sh" revoke pr-sec cut pr-cut-0 fail
  "$R/checks.sh" marker-write
  "$R/checks.sh" marker-read pr-cut-0
  python3 "$R/verify.py" manifest-apply
  hold=$(to_secs "$PR_HOLD")
  every=$(to_secs "$PROBE_EVERY")
  end=$(($(now_s) + hold))
  next=$(($(now_s) + every))
  while [ "$(now_s)" -lt "$end" ]; do
    sleep 30
    if [ "$(now_s)" -ge "$next" ] && [ "$(now_s)" -lt "$((end - 60))" ]; then
      n=$((n + 1))
      "$R/checks.sh" probe pr-sec "pr-cut-$n" reads
      "$R/checks.sh" opsb "pr-cut-$n"
      "$R/checks.sh" marker-write
      "$R/checks.sh" marker-read "pr-cut-$n"
      next=$((next + every))
    fi
  done
  "$R/checks.sh" probe primary pr-cut-end all
  "$R/checks.sh" probe pr-sec pr-cut-end reads
  "$R/cut.sh" off pr
  event cut_end link pr
  catch_up pr-sec performance primary pr
  event guards cluster primary label pr counters "$("$R/status.sh" guards primary "$(cat "$STATE_DIR/cut-pr-ms")")"
}

# After the PR catch-up: the data, with the load stopped so the WAL indexes
# and Merkle roots can settle.
s_verify() {
  # The load stops here, for good: logins and renewals write tokens and
  # leases, which DR replicates, so the DR WAL indexes and Merkle roots only
  # settle without them. (k6 can't pause an arrival-rate scenario once it has
  # started.) The checks below don't need the load.
  "$R/load.sh" stop
  loadgen1 "PLAN=$PLAN $R/load.sh stop" 120 >&2
  sleep 15
  for c in $CLUSTERS; do event final_status cluster "$c" status "$(repl_status "$c")"; done
  # Each secondary against its primary, at the same WAL index: background
  # writes (tidy, CRL rebuilds) keep the roots moving, so one pair of samples
  # taken a moment apart rarely matches.
  for x in "pr-sec performance primary last_performance_wal" "primary-dr dr primary last_dr_wal" "pr-sec-dr dr pr-sec last_dr_wal"; do
    read -r sc t pc f <<<"$x"
    # Up to FINAL_WAIT: under load a DR replica can run minutes behind.
    t0=$(now_s)
    while :; do
      p=$(repl_status "$pc"); s=$(repl_status "$sc")
      pw=$(jq -r --arg t "$t" --arg f "$f" '.[$t][$f] // 0' <<<"$p"); sw=$(jq -r --arg t "$t" '.[$t].last_remote_wal // 0' <<<"$s")
      [ "$pw" = "$sw" ] && break
      [ $(($(now_s) - t0)) -ge "$(to_secs "$FINAL_WAIT")" ] && break
      sleep 2
    done
    event final_pair secondary "$sc" type "$t" secs "$(($(now_s) - t0))" primary_wal "$pw" secondary_wal "$sw" \
      primary_root "$(jq -r --arg t "$t" '.[$t].merkle_root // ""' <<<"$p")" secondary_root "$(jq -r --arg t "$t" '.[$t].merkle_root // ""' <<<"$s")"
  done
  python3 "$R/verify.py" manifest-check pr-sec || true
  python3 "$R/verify.py" writes-final pr-sec "$RES/load-loadgen-0/kv/k6.log" || true
  "$R/checks.sh" revoke pr-sec cut after-pr ok
  "$R/checks.sh" revoke-confirm cut || true
  "$R/checks.sh" opsb after-pr ok
  "$R/checks.sh" probe pr-sec after-pr all
}

s_finish() {
  "$R/load.sh" stop
  loadgen1 "PLAN=$PLAN $R/load.sh stop; PLAN=$PLAN bash -lc '. $R/lib.sh; upload_results'" 300 >&2
  sudo systemctl stop perf-repl-status 2>/dev/null || true
  aws s3 sync --only-show-errors --region "$PERF_BUCKET_REGION" \
    "s3://$PERF_BUCKET/results/$(basename "$RES")/load-loadgen-1/" "$RES/load-loadgen-1/" || true
  python3 "$R/summarise.py" "$RES" > "$RES/RESULTS.md" || log "summarise failed (results are still saved)"
  upload_results
}

run() {
  event run_start plan "$PLAN" settings "$(for x in $RUN_VARS; do printf '%s=%s ' "$x" "${!x:-}"; done)"
  ensure_watcher
  step setup s_setup
  step share s_share
  step prepare s_prepare
  ensure_load
  step load s_load
  step dr-cut s_dr_cut
  step both-cut s_both_cut
  step pr-cut s_pr_cut
  step verify s_verify
  step finish s_finish
  event run_done plan "$PLAN"
  log "== $PLAN done: $RES/RESULTS.md"
}

case "${1:-}" in
start)
  if systemctl is-active --quiet "$UNIT"; then echo "$UNIT is already running"; exit 1; fi
  env_args=(--setenv=PLAN="$PLAN")
  for x in $RUN_VARS; do [ -n "${!x:-}" ] && env_args+=("--setenv=$x=${!x}"); done
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
  sudo systemd-run --unit "$UNIT" --uid "$(id -u)" --gid "$(id -g)" --working-directory /opt/perf \
    "${env_args[@]}" /bin/bash -lc "$R/run.sh run '$PLAN' >> '$RES/run.log' 2>&1"
  echo "started $UNIT; follow with: run.sh status $PLAN"
  ;;
run)
  run
  ;;
status)
  echo "plan: $PLAN ($(systemctl is-active "$UNIT" 2>/dev/null || true))"
  jq -r '.steps | to_entries[] | "  \(.key): \(.value.status)"' "$STATE"
  echo
  "$R/status.sh" show 2>/dev/null || true
  echo
  tail -8 "$RES/run.log" 2>/dev/null || true
  [ -f "$RES/RESULTS.md" ] && { echo; cat "$RES/RESULTS.md"; }
  ;;
*)
  sed -n '2,26p' "$0"
  exit 1
  ;;
esac
