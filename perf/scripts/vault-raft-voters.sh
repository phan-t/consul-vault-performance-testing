#!/bin/bash
# Vault Raft voter set, for T11 (Raft commit latency vs voter count).
#   vault-raft-voters.sh status       voters, leader, AZ spread, failure tolerance (JSON)
#   vault-raft-voters.sh shrink <N>   remove voters until N remain (N = 3 or 5)
#   vault-raft-voters.sh wait-healthy <N>  wait for N healthy voters, failure tolerance (N-1)/2
#   vault-raft-voters.sh convert      turn the vault-nv-* non-voters into voters (JSON timings)
#
# shrink removes one voter at a time, always from the AZ with the most voters
# and never the active node, so the layout matches a fresh build of that size
# (7 = 3/2/2 -> 5 = 2/2/1 -> 3 = 1/1/1 over 3 AZs). Each node is stopped over
# SSM first (systemctl disable --now vault, so it can't rejoin or call
# elections) and then removed with `vault operator raft remove-peer`. Waits for
# Autopilot to report healthy with failure tolerance (N-1)/2.
#
# One-way: a removed node keeps its old Raft data and can't simply rejoin. To
# get back to 7 voters, rebuild (terraform apply -replace).
#
# convert (Stage 4: T11 after T9-V and T12 on the main build) rejoins every
# running Vault instance that isn't a Raft voter (zone spares, permanent
# non-voters, held nodes, or a voter T12 demoted) as a voter: stop Vault,
# remove-peer (if it's in Raft), wipe its Raft data, set
# retry_join_as_non_voter = false and, with redundancy zones, a zone of its own
# (t11-<node>; Autopilot keeps one voter per zone), start Vault. Each node
# rejoins as a non-voter and Autopilot promotes it once it has been healthy for
# server_stabilization_time, so convert records, per node, the time from start
# to joining Raft and to promotion (polled every second). 5 voters + 2 more give
# 7 voters spread 3/2/2, like a 7-voter build. The EC2 Voter tag doesn't
# change; shrink removes vault-nv-* first, leaving vault-0..4.
# Needs: root VAULT_TOKEN (env.sh), SSM Run Command on the Vault instances.
. /opt/perf/scripts/lib.sh

peers() { vault_retry vault operator raft list-peers -format=json | jq -c '.data.config.servers'; }
autopilot() { vault_retry vault operator raft autopilot state -format=json; }

# Vault instances: [{node, id, az}] from EC2 tags (Node = Raft node_id).
instances() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PERF_NAME" "Name=tag:Role,Values=vault" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].{node: Tags[?Key==`Node`]|[0].Value, id: InstanceId, az: Placement.AvailabilityZone}' \
    --output json
}

status() {
  local p a
  p=$(peers)
  a=$(autopilot 2>/dev/null || echo '{}')
  jq -n -c --argjson p "$p" --argjson i "$(instances)" --argjson a "$a" '
    ($i | map({(.node): .az}) | add // {}) as $az
    | [$p[] | select(.voter)] as $v
    | {voters: ($v | length), non_voters: ([$p[] | select(.voter | not)] | length),
       leader: ([$p[] | select(.leader) | .node_id] | first),
       leader_az: ($az[[$p[] | select(.leader) | .node_id] | first] // null),
       # Other voters in the same AZ as the leader: acks it gets without crossing AZs.
       leader_az_peers: (([$p[] | select(.leader) | .node_id] | first) as $l
         | [$v[] | select(.node_id != $l and $az[.node_id] == $az[$l])] | length),
       voter_nodes: [$v[].node_id] | sort,
       az_spread: ($v | map($az[.node_id] // "unknown") | group_by(.) | map({(.[0]): length}) | add // {}),
       healthy: ($a.Healthy // $a.healthy), failure_tolerance: ($a.FailureTolerance // $a.failure_tolerance)}'
}

# Pick the next voter to remove: from the AZ with the most voters (ties: the
# AZ name sorting last), the highest-numbered node that isn't the leader.
# Converted vault-nv-* nodes sort above vault-*, so they go first and 5 voters
# is vault-0..4 again.
next_victim() {
  jq -r -n --argjson p "$(peers)" --argjson i "$(instances)" '
    ($i | map({(.node): .az}) | add // {}) as $az
    | [$p[] | select(.voter) | {node: .node_id, leader, az: ($az[.node_id] // "unknown")}] as $v
    | ($v | group_by(.az) | map({az: .[0].az, n: length}) | sort_by(.n, .az) | last.az) as $big
    | [$v[] | select(.az == $big and (.leader | not)) | .node]
    | sort_by([test("-nv-"), (capture("(?<n>[0-9]+)$").n | tonumber)]) | last // empty'
}

wait_healthy() { # wait_healthy <voters>
  local want=$1 ft=$((($1 - 1) / 2)) n=0 s
  until s=$(status) && [ "$(jq -r .voters <<<"$s")" -eq "$want" ] &&
    [ "$(jq -r .healthy <<<"$s")" = true ] && [ "$(jq -r .failure_tolerance <<<"$s")" -eq "$ft" ]; do
    n=$((n + 1))
    [ "$n" -gt 60 ] && { echo "Autopilot not healthy with $want voters (failure tolerance $ft) after 10 minutes: $s" >&2; return 1; }
    sleep 10
  done
  echo "$s"
}

shrink() {
  local want=${1:?usage: vault-raft-voters.sh shrink <N>} have victim id
  case "$want" in 3 | 5) ;; *) echo "N must be 3 or 5" >&2; exit 1 ;; esac
  have=$(status | jq -r .voters)
  [ "$have" -ge "$want" ] || { echo "only $have voters; can't shrink to $want (build with vault_voter_count = 7)" >&2; exit 1; }
  while [ "$have" -gt "$want" ]; do
    victim=$(next_victim)
    [ -n "$victim" ] || { echo "no removable voter found" >&2; exit 1; }
    id=$(instances | jq -r --arg n "$victim" '.[] | select(.node == $n) | .id')
    echo "$(date -u +%H:%M:%S) removing $victim ($id): stop Vault, then remove-peer"
    ssm_run 120 'systemctl disable --now vault && echo stopped' "$id"
    vault_retry vault operator raft remove-peer "$victim"
    wait_healthy $((have - 1)) >/dev/null
    have=$((have - 1))
  done
  echo "$(date -u +%H:%M:%S) $want voters: $(status)"
}

convert() {
  local nv ids p have want t0 now out bg node i=0 timing='{}'
  p=$(peers)
  nv=$(jq -c --argjson p "$p" '[.[] | select(.node as $n | any($p[]; .node_id == $n and .voter) | not) | {node, id}]' <<<"$(instances)")
  [ "$(jq length <<<"$nv")" -gt 0 ] || { echo "every running Vault instance is already a voter; nothing to convert" >&2; return 1; }
  ids=$(jq -r '.[].id' <<<"$nv")
  have=$(jq '[.[] | select(.voter)] | length' <<<"$p")
  want=$((have + $(jq length <<<"$nv")))
  echo "$(date -u +%H:%M:%S) converting $(jq -r '[.[].node] | join(", ")' <<<"$nv") to voters ($have -> $want)" >&2
  # Stop first, so a removed node can't keep calling for votes or rejoin with old data.
  ssm_run 120 'systemctl disable --now vault && echo stopped' $ids >&2
  for node in $(jq -r '.[].node' <<<"$nv"); do
    if jq -e --arg n "$node" 'any(.[]; .node_id == $n)' <<<"$p" >/dev/null; then
      vault_retry vault operator raft remove-peer "$node" >&2
    fi
  done
  # Empty Raft data (keep lost+found on the data volume), flip the join mode,
  # start. SSM runs in the background so polling starts with it: t0 includes
  # SSM delivery and the wipe (a second or two), not the poll interval.
  out=$(mktemp)
  t0=$(now_ms)
  ssm_run 300 'set -e
find /opt/vault/data -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
sed -i -E "s/^([[:space:]]*retry_join_as_non_voter[[:space:]]*=[[:space:]]*)true/\1false/" /etc/vault.d/vault.hcl
grep -Eq "^[[:space:]]*retry_join_as_non_voter[[:space:]]*=[[:space:]]*false" /etc/vault.d/vault.hcl
node=$(sed -nE "s/^[[:space:]]*node_id[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\\1/p" /etc/vault.d/vault.hcl)
sed -i -E "s/^([[:space:]]*autopilot_redundancy_zone[[:space:]]*=[[:space:]]*)\".*\"/\\1\"t11-$node\"/" /etc/vault.d/vault.hcl
systemctl enable --now vault && echo converted' $ids > "$out" &
  bg=$!
  # Per node: when it first appears in Raft (as a non-voter) and when Autopilot promotes it.
  until jq -e --argjson nv "$nv" '[$nv[].node] - [to_entries[] | select(.value.promoted_ms) | .key] | length == 0' <<<"$timing" >/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 600 ] && { echo "not all converted nodes promoted after 10 minutes: $timing" >&2; cat "$out" >&2; return 1; }
    if ! kill -0 "$bg" 2>/dev/null && [ "$(grep -c converted "$out")" -lt "$(jq length <<<"$nv")" ]; then
      cat "$out" >&2; echo "convert failed on some nodes" >&2; return 1
    fi
    sleep 1
    p=$(vault operator raft list-peers -format=json 2>/dev/null | jq -c '.data.config.servers') || continue
    now=$(now_ms)
    timing=$(jq -c --argjson p "$p" --argjson nv "$nv" --argjson now "$now" '. as $t
      | reduce ($nv[].node) as $n ($t;
          ([$p[] | select(.node_id == $n)] | first) as $s
          | if $s == null then .
            else .[$n].joined_ms //= $now | if $s.voter then .[$n].promoted_ms //= $now else . end end)' <<<"$timing")
  done
  wait "$bg" || true
  cat "$out" >&2; rm -f "$out"
  wait_healthy "$want" >/dev/null
  jq -n -c --argjson t "$timing" --argjson t0 "$t0" --argjson s "$(status)" '{
    nodes: [$t | to_entries[] | {node: .key,
      joined_s: ((.value.joined_ms - $t0) / 1000),
      promoted_s: ((.value.promoted_ms - $t0) / 1000),
      join_to_promotion_s: ((.value.promoted_ms - .value.joined_ms) / 1000)}],
    cluster: $s}'
}

case "${1:-}" in
status) status ;;
shrink) shrink "${2:-}" ;;
wait-healthy) wait_healthy "${2:?usage: vault-raft-voters.sh wait-healthy <N>}" ;;
convert) convert ;;
*)
  echo "usage: vault-raft-voters.sh status|shrink <N>|wait-healthy <N>|convert" >&2
  exit 1
  ;;
esac
