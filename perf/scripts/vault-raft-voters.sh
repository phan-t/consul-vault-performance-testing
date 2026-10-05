#!/bin/bash
# Vault Raft voter set, for T11 (Raft commit latency vs voter count).
#   vault-raft-voters.sh status       voters, leader, AZ spread, failure tolerance (JSON)
#   vault-raft-voters.sh shrink <N>   remove voters until N remain (N = 3 or 5)
#   vault-raft-voters.sh wait-healthy <N>  wait for N healthy voters, failure tolerance (N-1)/2
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
next_victim() {
  jq -r -n --argjson p "$(peers)" --argjson i "$(instances)" '
    ($i | map({(.node): .az}) | add // {}) as $az
    | [$p[] | select(.voter) | {node: .node_id, leader, az: ($az[.node_id] // "unknown")}] as $v
    | ($v | group_by(.az) | map({az: .[0].az, n: length}) | sort_by(.n, .az) | last.az) as $big
    | [$v[] | select(.az == $big and (.leader | not)) | .node]
    | sort_by(capture("(?<n>[0-9]+)$").n | tonumber) | last // empty'
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

case "${1:-}" in
status) status ;;
shrink) shrink "${2:-}" ;;
wait-healthy) wait_healthy "${2:?usage: vault-raft-voters.sh wait-healthy <N>}" ;;
*)
  echo "usage: vault-raft-voters.sh status|shrink <N>|wait-healthy <N>" >&2
  exit 1
  ;;
esac
