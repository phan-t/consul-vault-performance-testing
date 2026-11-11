#!/usr/bin/env bash
# Run T17 (issue #23, Stage 6) from your workstation: four Vault clusters at
# two sites, from terraform-repl and its own HCP Terraform workspace
# (consul-vault-perf-repl), so the main build is untouched. Both sites are
# VPCs in Sydney, with latency added between them (SITE_RTT_MS, default 12 ms).
#
#   scripts/run-repl.sh preflight             checks only; changes nothing
#   scripts/run-repl.sh start [PLAN]          terraform apply (confirm the plan), wait for
#                                             bootstrap, then start the campaign on loadgen-0
#   scripts/run-repl.sh continue [PLAN]       after an apply: wait, then start the campaign
#   scripts/run-repl.sh status [PLAN]         progress on loadgen-0
#   scripts/run-repl.sh follow [PLAN]         print progress every 10 min until it finishes
#   scripts/run-repl.sh finish [PLAN]         download results to ./results/, then destroy
#
# Options: --dry-run (start: 3 voters per cluster and a 1-hour PR cut, PLAN
#          repl-dry; run it before the full run), --yes (terraform -auto-approve),
#          --destroy (finish: destroy without asking).
# Campaign settings from your environment are passed through, e.g. the KV
# load sized from DBS's figures:
#   KV_RATE=40 DAY_KEYS=120000 scripts/run-repl.sh start repl-1
# (SITE_RTT_MS, PR_HOLD, BOTH_HOLD, DR_HOLD, FINAL_WAIT, BASELINE, SETTLE, PROBE_EVERY, CATCHUP_MAX,
#  KV_RATE, DAY_KEYS, SIGN_RATE, SEC_KV_RATE, LOGIN_RATE, RENEW_RATE,
#  MANIFEST_NEW, MANIFEST_UPDATE, MANIFEST_DELETE; see perf/scripts/repl/run.sh.)
#
# The workspace needs the same AWS credential variables as the main one.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TF="$ROOT/terraform-repl"
export AWS_PAGER=""

CMD=${1:-}
shift || true
PLAN=repl-1
YES=false
DESTROY=false
DRY=false
for a in "$@"; do
  case "$a" in
  --yes) YES=true ;;
  --destroy) DESTROY=true ;;
  --dry-run) DRY=true ;;
  -*) echo "unknown option $a" >&2; exit 1 ;;
  *) PLAN=$a ;;
  esac
done
DRY_PROFILE="$TF/dryrun.auto.tfvars"
if $DRY && [ "$PLAN" = repl-1 ]; then PLAN=repl-dry; fi

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
tfo() { terraform -chdir="$TF" output -json | jq -r "$1"; }

ssm() { # ssm <region> <timeout_s> <command> <instance-id>...
  local region=$1 timeout=$2 cmd=$3 cid id st deadline
  shift 3
  cid=$(aws ssm send-command --region "$region" --instance-ids "$@" --document-name AWS-RunShellScript \
    --parameters "$(jq -n --arg c "$cmd" --arg t "$timeout" '{commands: [$c], executionTimeout: [$t]}')" \
    --comment "run-repl $PLAN" --query Command.CommandId --output text)
  deadline=$(($(date +%s) + timeout + 60))
  for id in "$@"; do
    while :; do
      st=$(aws ssm get-command-invocation --region "$region" --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
      case "$st" in Pending | InProgress | Delayed) ;; *) break ;; esac
      [ "$(date +%s)" -gt "$deadline" ] && { st=Timeout; break; }
      sleep 5
    done
    echo "$id [$st]: $(aws ssm get-command-invocation --region "$region" --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text 2>/dev/null)"
  done
}

on_loadgen0() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  ssm "$(tfo '.loadgens.value["loadgen-0"].region')" "${2:-600}" "echo $b64 | base64 -d | sudo -u ubuntu bash -l" \
    "$(tfo '.loadgens.value["loadgen-0"].id')" | sed -E 's/^i-[0-9a-f]+ \[[A-Za-z]+\]: //'
}

run_env() {
  local v out=""
  for v in SITE_RTT_MS PR_HOLD BOTH_HOLD DR_HOLD FINAL_WAIT BASELINE SETTLE PROBE_EVERY CATCHUP_MAX KV_RATE DAY_KEYS SIGN_RATE SEC_KV_RATE \
    LOGIN_RATE RENEW_RATE MANIFEST_NEW MANIFEST_UPDATE MANIFEST_DELETE; do
    [ -n "${!v:-}" ] && out+="$v='${!v}' "
  done
  printf '%s' "$out"
}

# The dry run's defaults: short holds, and a KV rate that overflows the
# default buffer (16384 entries) within the hour.
dry_defaults() {
  : "${PR_HOLD:=1h}" "${BOTH_HOLD:=5m}" "${DR_HOLD:=5m}" "${BASELINE:=5m}" "${SETTLE:=2m}" "${PROBE_EVERY:=20m}" \
    "${KV_RATE:=50}" "${DAY_KEYS:=20000}" "${CATCHUP_MAX:=1h}"
  export PR_HOLD BOTH_HOLD DR_HOLD BASELINE SETTLE PROBE_EVERY KV_RATE DAY_KEYS CATCHUP_MAX
}

preflight() {
  say "Preflight"
  for b in terraform aws jq; do command -v "$b" >/dev/null || die "$b not found"; done
  [ -n "${TF_CLOUD_ORGANIZATION:-}" ] || die "set TF_CLOUD_ORGANIZATION"
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials missing or expired: refresh them (locally and in the workspace)"
  # The sites' regions (terraform-repl var.regions; both Sydney by default).
  for r in ${REPL_REGIONS:-ap-southeast-2}; do
    for t in m7i.2xlarge r7i.4xlarge m7i.xlarge; do
      n=$(aws ec2 describe-instance-type-offerings --region "$r" --location-type availability-zone \
        --filters "Name=instance-type,Values=$t" --query 'length(InstanceTypeOfferings)' --output text 2>/dev/null || echo 0)
      echo "  $r $t: offered in $n AZs"
      [ "$n" -ge 3 ] || die "$t is offered in only $n AZs in $r"
    done
  done
  terraform -chdir="$TF" init -input=false >/dev/null || die "terraform init failed in terraform-repl (terraform login? workspace created by tfc-bootstrap?)"
  echo "HCP Terraform workspace: reachable"
  if [ -f "$DRY_PROFILE" ]; then echo "dry-run profile: present (3 voters per cluster)"; else echo "dry-run profile: absent (5 voters per cluster)"; fi
  "$ROOT/scripts/check-templates.sh" || die "template check failed"
}

wait_bootstrap() {
  say "Waiting for every node to bootstrap (up to 30 min)"
  local start r ids out total done_n outputs
  outputs=$(terraform -chdir="$TF" output -json)
  start=$(date +%s)
  while :; do
    total=0
    done_n=0
    for r in $(jq -r '.regions.value | [.[]] | unique | .[]' <<<"$outputs"); do
      ids=$(jq -r --arg r "$r" '[(.clusters.value[] | select(.region == $r) | .nodes[].id),
        (.loadgens.value[] | select(.region == $r) | .id)]
        + (if $r == .regions.value.east then [.monitoring_instance_id.value] else [] end) | .[]' <<<"$outputs")
      [ -n "$ids" ] || continue
      out=$(ssm "$r" 60 'grep -q "bootstrap done" /var/log/perf-bootstrap.log 2>/dev/null && echo done || echo waiting' $ids 2>/dev/null || true)
      total=$((total + $(wc -w <<<"$ids")))
      done_n=$((done_n + $(grep -c 'done' <<<"$out" || true)))
    done
    echo "  $(date -u +%H:%M:%S) $done_n/$total nodes bootstrapped"
    [ "$total" -gt 0 ] && [ "$done_n" -eq "$total" ] && break
    [ $(($(date +%s) - start)) -gt 1800 ] && die "nodes not bootstrapped after 30 min"
    sleep 30
  done
}

start() {
  $DRY && dry_defaults
  preflight
  if $DRY; then
    printf '# Dry run for T17 (scripts/run-repl.sh --dry-run): 3 voters per cluster.\nvault_voter_count = 3\n' > "$DRY_PROFILE"
    echo "wrote terraform-repl/dryrun.auto.tfvars (3 voters per cluster)"
  elif [ -f "$DRY_PROFILE" ]; then
    rm "$DRY_PROFILE"; echo "removed terraform-repl/dryrun.auto.tfvars (full size: 5 voters per cluster)"
  fi
  say "Build ($PLAN)"
  echo "Check the plan: two site VPCs (peered), four Vault clusters (20 nodes, or 12 for the dry run), two load generators, monitoring."
  if $YES; then terraform -chdir="$TF" apply -auto-approve; else terraform -chdir="$TF" apply; fi
  after_apply
}

after_apply() {
  $DRY && dry_defaults
  wait_bootstrap
  say "Starting $PLAN on loadgen-0"
  [ -n "$(run_env)" ] && echo "  with: $(run_env)"
  on_loadgen0 "/opt/perf/scripts/sync-assets.sh >/dev/null && cd /opt/perf && $(run_env)PLAN=$PLAN /opt/perf/scripts/repl/run.sh start $PLAN" 120
  cat <<EOF

$PLAN is running unattended on loadgen-0: setup, DR cut, both cut, then the PR cut (${PR_HOLD:-4h}).
  Progress:  scripts/run-repl.sh status $PLAN    (or follow $PLAN)
  When done: scripts/run-repl.sh finish $PLAN    (downloads results, then destroys: don't leave it idle)
EOF
}

status() { on_loadgen0 "/opt/perf/scripts/repl/run.sh status $PLAN" 120; }

follow() {
  local out
  while :; do
    out=$(on_loadgen0 "systemctl is-active perf-repl-$PLAN; /opt/perf/scripts/repl/run.sh status $PLAN | sed -n '2,14p'" 120)
    clear 2>/dev/null || true
    echo "$(date -u +%H:%M:%SZ) $PLAN"
    echo "$out" | sed -n '2,14p'
    head -1 <<<"$out" | grep -q '^active' || break
    sleep 600
  done
  say "Campaign finished"
  status
}

finish() {
  preflight
  say "Downloading results for $PLAN"
  local b
  b=$(tfo .perf_bucket.value)
  mkdir -p "$ROOT/results"
  aws s3 sync --only-show-errors --region "$(tfo .regions.value.east)" "s3://$b/results/" "$ROOT/results/" --exclude '*' --include "$PLAN-*"
  echo "  $(find "$ROOT/results" -path "*$PLAN-*" -type f | wc -l | tr -d ' ') files in results/$PLAN-repl/"
  [ -f "$ROOT/results/$PLAN-repl/RESULTS.md" ] && cat "$ROOT/results/$PLAN-repl/RESULTS.md"
  if ! $DESTROY; then
    read -r -p $'\nDestroy the replication build now (terraform destroy; deletes its S3 bucket too)? [y/N] ' r
    [[ "$r" =~ ^[Yy] ]] || { echo "Not destroyed. Each idle hour costs about US\$14. Run: terraform -chdir=terraform-repl destroy"; return 0; }
  fi
  if $YES || $DESTROY; then terraform -chdir="$TF" destroy -auto-approve; else terraform -chdir="$TF" destroy; fi
  [ -f "$DRY_PROFILE" ] && rm "$DRY_PROFILE" && echo "removed terraform-repl/dryrun.auto.tfvars"
  return 0
}

case "$CMD" in
preflight) preflight ;;
start) start ;;
continue) after_apply ;;
status) status ;;
follow) follow ;;
finish) finish ;;
*) sed -n '2,24p' "$0"; exit 1 ;;
esac
