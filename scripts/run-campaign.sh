#!/usr/bin/env bash
# Run the whole test campaign (TEST-PLAN.md) from your workstation.
#
#   scripts/run-campaign.sh preflight            checks only; changes nothing
#   scripts/run-campaign.sh start  [PLAN]        Stage 0 (full-size rebuild, confirm the plan), wait for
#                                                bootstrap, verify, then start run-plan.sh on loadgen-0
#   scripts/run-campaign.sh continue [PLAN]      after an apply: wait for bootstrap, verify, start run-plan.sh
#   scripts/run-campaign.sh resume [PLAN]        after it finishes: sync the latest scripts and run any tests
#                                                the plan hasn't completed yet
#   scripts/run-campaign.sh status [PLAN]        progress of the campaign on loadgen-0
#   scripts/run-campaign.sh follow [PLAN]        print progress every 10 min until it finishes
#   scripts/run-campaign.sh finish [PLAN]        download results to ./results/, then offer terraform destroy
#
# PLAN defaults to plan-1. Before `start` and `finish`, refresh credentials
# locally and in the HCP Terraform workspace: the rebuild and destroy run there. Once
# started, the campaign runs on loadgen-0 with the instances' own IAM roles;
# your laptop and credentials aren't needed until `finish`.
#
# Options: --yes (terraform -auto-approve), --destroy (finish: destroy without asking),
#          --t11 (start: the T11 campaign, see above).
# run-plan.sh settings set in your environment are passed through to the
# campaign (start, continue, resume), e.g. only T5 and T5r, from 800/s:
#   PLAN_TESTS="settle t5 t5r" T5_START=800 scripts/run-campaign.sh start plan-2
#
# The main campaign ends with Stage 4: T11 (Vault Raft latency at 7, 5, 3 voters)
# after T9-V's non-voters are converted to voters (~17–21 h in all). It needs a
# Vault license without the pki-only module; verify checks this. To leave
# Stage 4 out: PLAN_TESTS="settle t1 t2 t3 t3c t5 t6 t3r t5r t9v".
#
# T11 can also run as its own campaign on a 7-voter build, run the same way
# (start, status/follow, finish):
#   scripts/run-campaign.sh start raft-1 --t11     # settle -> t11smoke -> t11v7 -> t11v5 -> t11v3
# --t11 writes terraform/raft.auto.tfvars (7 voters, no non-voters) and defaults
# PLAN_TESTS to the T11 sequence; a start without --t11 removes that profile, and
# finish removes it after a destroy.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TF="$ROOT/terraform"
export AWS_REGION=${AWS_REGION:-ap-southeast-2} AWS_PAGER=""

CMD=${1:-}
shift || true
PLAN=plan-1
YES=false
DESTROY=false
T11=false
for a in "$@"; do
  case "$a" in
  --yes) YES=true ;;
  --destroy) DESTROY=true ;;
  --t11) T11=true ;;
  -*) echo "unknown option $a" >&2; exit 1 ;;
  *) PLAN=$a ;;
  esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
tfo() { terraform -chdir="$TF" output -json | jq -r "$1"; }

# ssm <timeout_s> <command> <instance-id>... -> "<id> [Status]: <output>" per instance
ssm() {
  local timeout=$1 cmd=$2 cid id st deadline
  shift 2
  cid=$(aws ssm send-command --instance-ids "$@" --document-name AWS-RunShellScript \
    --parameters "$(jq -n --arg c "$cmd" --arg t "$timeout" '{commands: [$c], executionTimeout: [$t]}')" \
    --comment "run-campaign $PLAN" --query Command.CommandId --output text)
  deadline=$(($(date +%s) + timeout + 60))
  for id in "$@"; do
    while :; do
      st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
      case "$st" in Pending | InProgress | Delayed) ;; *) break ;; esac
      [ "$(date +%s)" -gt "$deadline" ] && { st=Timeout; break; }
      sleep 5
    done
    echo "$id [$st]: $(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text 2>/dev/null)"
  done
}
# run-plan.sh settings from the environment, as VAR='value' assignments.
plan_env() {
  local v out=""
  for v in PLAN_TESTS T1_WORKERS T1_CONNS T1_STEP T1_WARMUP T3_START T3_MAX T5_START T5_MAX \
    T3C_CONCURRENCY T3C_MULTI_CONNS T3C_STEP T6_RATE MEM_GUARD_PCT SETTLE_IDLE SETTLE_SCANNER_WAIT \
    BASELINE COOLDOWN RAMP HOLD \
    T11_KV_RATES T11_KV_REPEATS T11_PAYLOADS T11_PAYLOAD_RATE T11_RAMP T11_HOLD T11_KV_P99_MS T11_RESIZE_SETTLE T11_FAILOVER_REPEATS T11_FREEZE; do
    [ -n "${!v:-}" ] && out+="$v='${!v}' "
  done
  printf '%s' "$out"
}
loadgen0() { tfo '.loadgen_instance_ids.value[0]'; }
# Run a (multi-line) command on loadgen-0 as ubuntu with a login shell. The
# command is base64-encoded: AWS-RunShellScript runs /bin/sh (dash on Ubuntu),
# which can't parse bash's $'...' quoting.
on_loadgen() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  ssm "${2:-600}" "echo $b64 | base64 -d | sudo -u ubuntu bash -l" "$(loadgen0)" | sed -E 's/^i-[0-9a-f]+ \[[A-Za-z]+\]: //'
}

preflight() {
  say "Preflight"
  for b in terraform aws jq; do command -v "$b" >/dev/null || die "$b not found"; done
  [ -n "${TF_CLOUD_ORGANIZATION:-}" ] || die "set TF_CLOUD_ORGANIZATION (e.g. export TF_CLOUD_ORGANIZATION=my-org)"
  echo "AWS identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" || true
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials missing or expired: refresh them (locally and in the workspace)"
  terraform -chdir="$TF" output -json >/dev/null 2>&1 || die "can't read HCP Terraform state: terraform init / terraform login / TF_CLOUD_ORGANIZATION"
  echo "HCP Terraform workspace: reachable"
  if [ -f "$TF/smoke.auto.tfvars" ]; then echo "smoke profile: present (start removes it → full size)"; else echo "smoke profile: absent (full size)"; fi
  if [ -f "$TF/raft.auto.tfvars" ]; then echo "raft profile: $(grep -E '^vault_voter_count' "$TF/raft.auto.tfvars" | tr -s ' ')"; fi
  if [ -f "$TF/campaign.auto.tfvars" ]; then
    echo "campaign profile: $(grep -E '^vault_non_voter' "$TF/campaign.auto.tfvars" | tr -s ' ' | paste -sd ';' -)"
  else
    echo "campaign profile: absent (start creates it: 2 held Vault non-voters)"
  fi
  echo "Note: AWS credentials in the HCP Terraform workspace must be fresh for the apply."
  echo "Checking user_data templates (syntax, helpers defined, size):"
  "$ROOT/scripts/check-templates.sh" || die "template check failed: fix terraform/templates before applying"
}

# T11 campaign profile: 7 Vault voters, no non-voters (T11 refuses to run with them).
RAFT_PROFILE="$TF/raft.auto.tfvars"
T11_TESTS="settle t11smoke t11v7 t11v5 t11v3"
t11_profile() {
  printf '# T11 campaign (TEST-PLAN.md): Vault Raft latency at 7, 5, 3 voters.\n# Overrides campaign.auto.tfvars (loaded later, alphabetically).\nvault_voter_count     = 7\nvault_non_voter_count = 0\n' > "$RAFT_PROFILE"
  echo "wrote terraform/raft.auto.tfvars (7 Vault voters, no non-voters)"
  PLAN_TESTS=${PLAN_TESTS:-$T11_TESTS}
  export PLAN_TESTS
}

replace_args() {
  local a=() state
  # Only what exists: on a fresh build (nothing in state) this is empty and the apply just creates.
  state=$(terraform -chdir="$TF" state list 2>/dev/null || true)
  # Every existing server, voter or not; nodes a larger voter count adds are created, not replaced.
  for k in $(tfo '.vault_nodes.value // {} | keys[]'); do a+=("-replace=aws_instance.vault[\"$k\"]"); done
  for k in $(tfo '.consul_nodes.value // {} | keys[]'); do a+=("-replace=aws_instance.consul[\"$k\"]"); done
  # Every existing load generator (not just [0]): a stale one keeps old user_data.
  for i in $(tfo '.loadgen_instance_ids.value // [] | keys[]'); do a+=("-replace=aws_instance.loadgen[$i]"); done
  grep -qx 'aws_instance.monitoring\[0\]' <<<"$state" && a+=("-replace=aws_instance.monitoring[0]")
  grep -qx 'aws_ssm_parameter.vault_bootstrap' <<<"$state" && a+=("-replace=aws_ssm_parameter.vault_bootstrap")
  [ ${#a[@]} -gt 0 ] && printf '%s\n' "${a[@]}"
  return 0
}

wait_bootstrap() {
  say "Waiting for every node to bootstrap (up to 30 min)"
  local ids pending start out
  ids=$(tfo '[(.vault_nodes.value, .consul_nodes.value) | to_entries[] | .value.id] + .loadgen_instance_ids.value + [.monitoring_instance_id.value] | .[]')
  start=$(date +%s)
  while :; do
    # Held non-voters finish bootstrap too (they just don't start Vault).
    out=$(ssm 60 'grep -q "bootstrap done" /var/log/perf-bootstrap.log 2>/dev/null && echo done || echo waiting' $ids 2>/dev/null || true)
    pending=$(grep -c -v 'done' <<<"$out" || true)
    echo "  $(date -u +%H:%M:%S) $(grep -c 'done' <<<"$out" || true)/$(wc -w <<<"$ids" | tr -d ' ') nodes bootstrapped"
    [ "$pending" -eq 0 ] && break
    [ $(($(date +%s) - start)) -gt 1800 ] && die "nodes not bootstrapped after 30 min:\n$(grep -v done <<<"$out")"
    sleep 30
  done
}

# Voter count to expect: terraform/*.auto.tfvars, else the variable's default (5).
want_voters() { # want_voters vault|consul
  local v
  v=$(cat "$TF"/*.auto.tfvars 2>/dev/null | sed -nE "s/^ *$1_voter_count *= *([0-9]+).*/\\1/p" | tail -1)
  echo "${v:-5}"
}

# Does this run include T11 (the default plan's Stage 4, or the --t11 campaign)?
runs_t11() { [ -z "${PLAN_TESTS:-}" ] || grep -qE '(^| )t11' <<<"$PLAN_TESTS"; }

verify() {
  say "Verifying the cluster"
  local out vv cv
  out=$(on_loadgen '. /opt/perf/scripts/env.sh >/dev/null 2>&1
v=$(vault operator raft list-peers -format=json | jq "[.data.config.servers[] | select(.voter)] | length")
nv=$(vault operator raft list-peers -format=json | jq "[.data.config.servers[] | select(.voter | not)] | length")
c=$(CONSUL_HTTP_TOKEN=$CONSUL_OPERATOR_TOKEN consul operator raft list-peers | tail -n +2 | grep -c true)
ttl=$(CONSUL_HTTP_TOKEN=$CONSUL_OPERATOR_TOKEN consul connect ca get-config | jq -r ".Config.LeafCertTTL // .Config.leaf_cert_ttl")
root=$(CONSUL_HTTP_TOKEN=$CONSUL_OPERATOR_TOKEN consul connect ca get-config | jq -r ".Config.RootPKIPath // .Config.root_pki_path")
# T11 writes to KV mounts, which a pki-only license refuses.
kv=refused
vault secrets enable -path=kv_license_probe kv >/dev/null 2>&1 && vault secrets disable kv_license_probe >/dev/null 2>&1 && kv=ok
echo "vault_voters=$v vault_nonvoters=$nv consul_voters=$c leaf_ttl=$ttl root=$root kv_mounts=$kv"')
  echo "  $out"
  vv=$(want_voters vault); cv=$(want_voters consul)
  grep -q "vault_voters=$vv vault_nonvoters=0 consul_voters=$cv leaf_ttl=168h root=pki_mesh_int" <<<"$out" ||
    die "unexpected cluster state (want $vv Vault voters, 0 non-voters (held), $cv Consul voters, leaf TTL 168h, root pki_mesh_int)"
  if runs_t11 && ! grep -q "kv_mounts=ok" <<<"$out"; then
    die "the Vault license refuses KV mounts (pki-only module), so T11 can't run. Use a full Vault Enterprise license and rebuild, or leave out Stage 4:
  PLAN_TESTS=\"settle t1 t2 t3 t3c t5 t6 t3r t5r t9v\" scripts/run-campaign.sh continue $PLAN"
  fi
  echo "  cluster OK: held non-voters not yet joined (T9-V starts them)"
}

start() {
  preflight
  say "Stage 0: full-size rebuild ($PLAN)"
  if [ -f "$TF/smoke.auto.tfvars" ]; then rm "$TF/smoke.auto.tfvars"; echo "removed terraform/smoke.auto.tfvars"; fi
  if $T11; then
    t11_profile
  elif [ -f "$RAFT_PROFILE" ]; then
    rm "$RAFT_PROFILE"; echo "removed terraform/raft.auto.tfvars (start without --t11 builds the 5-voter plan)"
  fi
  if [ ! -f "$TF/campaign.auto.tfvars" ]; then
    printf '# Test campaign: T9-V non-voters provisioned but held (see TEST-PLAN.md)\nvault_non_voter_count  = 2\nvault_non_voters_start = false\n' > "$TF/campaign.auto.tfvars"
    echo "created terraform/campaign.auto.tfvars"
  fi
  ARGS=()
  while IFS= read -r x; do ARGS+=("$x"); done < <(replace_args) # portable (macOS bash 3.2 lacks mapfile)
  if [ ${#ARGS[@]} -eq 0 ]; then echo "Nothing to replace: building a fresh environment."; else
  echo "Replacing every instance and resetting Vault's bootstrap flag (Vault re-initialises)."; fi
  echo "Check the plan: instances become m7i.2xlarge / r7i.4xlarge / m7i.xlarge; loadgen-1 is created."
  if $YES; then
    terraform -chdir="$TF" apply -auto-approve ${ARGS[@]+"${ARGS[@]}"}
  else
    terraform -chdir="$TF" apply ${ARGS[@]+"${ARGS[@]}"}
  fi
  after_apply
}

after_apply() {
  if $T11 || [ -f "$RAFT_PROFILE" ]; then PLAN_TESTS=${PLAN_TESTS:-$T11_TESTS}; export PLAN_TESTS; fi
  wait_bootstrap
  verify
  say "Refreshing credentials.txt"
  "$ROOT/scripts/get-credentials.sh" || echo "  (get-credentials.sh failed; re-run it later)"
  say "Starting the campaign on loadgen-0"
  [ -n "$(plan_env)" ] && echo "  with: $(plan_env)"
  on_loadgen "/opt/perf/scripts/sync-assets.sh >/dev/null && cd /opt/perf && $(plan_env)run-plan.sh start $PLAN" 120
  cat <<EOF

The campaign is running unattended on loadgen-0 (${PLAN_TESTS:-settle → T1 … T5r → T9-V → Stage 4: T11 at 7, 5, 3 voters, ~17–21 h}).
  Progress:  scripts/run-campaign.sh status $PLAN    (or follow $PLAN)
  Grafana:   $(tfo '.grafana_url.value // empty')
  When done: refresh AWS credentials, then scripts/run-campaign.sh finish $PLAN
EOF
}

resume() {
  if $T11 || [ -f "$RAFT_PROFILE" ]; then PLAN_TESTS=${PLAN_TESTS:-$T11_TESTS}; export PLAN_TESTS; fi
  # Syncing while run-plan.sh runs would change scripts under it: only resume a stopped plan.
  if on_loadgen "systemctl is-active perf-plan-$PLAN" 30 | grep -qx active; then
    die "perf-plan-$PLAN is still running; resume after it finishes"
  fi
  # Upload perf/ the way terraform apply does (s3.tf), without an apply; the next apply re-uploads the same files.
  say "Uploading perf/ to s3://$(tfo .perf_bucket.value)/assets/perf/"
  aws s3 sync --only-show-errors "$ROOT/perf/" "s3://$(tfo .perf_bucket.value)/assets/perf/" --exclude 'results/*' --exclude '*__pycache__*'
  say "Syncing scripts and resuming $PLAN on loadgen-0 (completed tests are skipped)"
  on_loadgen "/opt/perf/scripts/sync-assets.sh >/dev/null && cd /opt/perf && $(plan_env)run-plan.sh start $PLAN" 120
  echo "  Progress: scripts/run-campaign.sh follow $PLAN"
}

status() {
  on_loadgen "cd /opt/perf && run-plan.sh status $PLAN"
}

follow() {
  local out
  while :; do
    out=$(on_loadgen "systemctl is-active perf-plan-$PLAN; cd /opt/perf && run-plan.sh status $PLAN | sed -n '2,20p'")
    clear 2>/dev/null || true
    echo "$(date -u +%H:%M:%SZ) $PLAN"; echo "$out" | sed -n '2,20p'
    head -1 <<<"$out" | grep -q '^active' || break
    sleep 600
  done
  say "Campaign finished"; status
}

finish() {
  preflight
  say "Downloading results for $PLAN"
  local b
  b=$(tfo .perf_bucket.value)
  mkdir -p "$ROOT/results"
  aws s3 sync --only-show-errors "s3://$b/results/" "$ROOT/results/" --exclude '*' --include "$PLAN-*"
  echo "  $(find "$ROOT/results" -path "*$PLAN-*" -type f | wc -l | tr -d ' ') files in results/ (RESULTS.md: results/$PLAN-plan/RESULTS.md)"
  [ -f "$ROOT/results/$PLAN-plan/RESULTS.md" ] && cat "$ROOT/results/$PLAN-plan/RESULTS.md"
  if ! $DESTROY; then
    read -r -p $'\nDestroy the environment now (terraform destroy; deletes the S3 bucket too)? [y/N] ' r
    [[ "$r" =~ ^[Yy] ]] || { echo "Not destroyed. Run: terraform -chdir=terraform destroy"; return 0; }
  fi
  if $YES || $DESTROY; then terraform -chdir="$TF" destroy -auto-approve; else terraform -chdir="$TF" destroy; fi
  if [ -f "$RAFT_PROFILE" ]; then rm "$RAFT_PROFILE"; echo "removed terraform/raft.auto.tfvars (the next build is the 5-voter plan)"; fi
}

case "$CMD" in
preflight) preflight ;;
start) start ;;
continue) after_apply ;;
resume) resume ;;
status) status ;;
follow) follow ;;
finish) finish ;;
*) sed -n '2,18p' "$0"; exit 1 ;;
esac
