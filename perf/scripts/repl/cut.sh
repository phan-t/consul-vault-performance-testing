#!/bin/bash
# Cut or restore a replication link (T17), by blocking port 8201 between the
# two clusters' nodes only.
#
#   cut.sh on|off|check <link>
#     pr          primary <-> pr-sec        (the PR link)
#     dr-primary  primary <-> primary-dr    (the primary's DR link)
#     dr-pr-sec   pr-sec  <-> pr-sec-dr     (the PR secondary's DR link)
#     both        all three: every link between the sites
#
# On each node of one cluster, an iptables chain drops port 8201 to and from
# the other cluster's node IPs (INPUT by source, OUTPUT by destination). 8201
# is also Raft and request forwarding inside each cluster, so blocking the
# port by itself, or a whole VPC range (pr-sec and primary-dr share the
# West site's), would break the clusters under test. The NLB keeps the
# client's IP, so connections through <cluster>:8201 are caught at the far
# end. Other ports (the API, monitoring) are untouched.
. /opt/perf/scripts/repl/lib.sh

pairs() {
  case "$1" in
  pr) echo "primary:pr-sec" ;;
  dr-primary) echo "primary:primary-dr" ;;
  dr-pr-sec) echo "pr-sec:pr-sec-dr" ;;
  both) echo "primary:pr-sec primary:primary-dr pr-sec:pr-sec-dr" ;;
  *) die "unknown link $1 (pr, dr-primary, dr-pr-sec, both)" ;;
  esac
}

# rules <chain> <on|off> <peer ips...>: the shell run on each node.
rules() {
  local chain=$1 action=$2 ip
  shift 2
  if [ "$action" = on ]; then
    printf 'iptables -N %s 2>/dev/null; iptables -F %s; ' "$chain" "$chain"
    for ip in "$@"; do
      printf 'iptables -A %s -s %s -p tcp --dport 8201 -j DROP; iptables -A %s -d %s -p tcp --dport 8201 -j DROP; ' "$chain" "$ip" "$chain" "$ip"
    done
    printf 'iptables -C INPUT -j %s 2>/dev/null || iptables -I INPUT 1 -j %s; ' "$chain" "$chain"
    printf 'iptables -C OUTPUT -j %s 2>/dev/null || iptables -I OUTPUT 1 -j %s; ' "$chain" "$chain"
  else
    printf 'iptables -D INPUT -j %s 2>/dev/null; iptables -D OUTPUT -j %s 2>/dev/null; iptables -F %s 2>/dev/null; iptables -X %s 2>/dev/null; ' \
      "$chain" "$chain" "$chain" "$chain"
  fi
  printf 'echo "%s %s: $(iptables -S %s 2>/dev/null | grep -c DROP) rules"' "$chain" "$action" "$chain"
}

# apply <a> <b> <on|off>: both ends of one link.
apply() {
  local a=$1 b=$2 action=$3 chain="RC_${1//-/_}_${2//-/_}" x y out
  for x in "$a:$b" "$b:$a"; do
    y=${x#*:}
    x=${x%%:*}
    out=$(ssm_run "$(cl "$x" region)" 60 "$(rules "$chain" "$action" $(node_ips "$y"))" $(node_ids "$x"))
    echo "$out" | sed "s/^/  $x: /" >&2
    grep -q '\[Success\]' <<<"$out" || die "cut $action failed on $x: $out"
    [ "$(grep -c '\[Success\]' <<<"$out")" -eq "$(wc -w <<<"$(node_ids "$x")")" ] || die "cut $action incomplete on $x"
  done
}

# check <a> <b>: can the first node of a reach port 8201 on b's nodes?
check() {
  local a=$1 b=$2 ips cmd
  ips=$(node_ips "$b")
  cmd="for ip in $ips; do timeout 3 bash -c \"</dev/tcp/\$ip/8201\" 2>/dev/null && echo open || echo blocked; done | sort | uniq -c | xargs"
  ssm_run "$(cl "$a" region)" 60 "$cmd" "$(node_ids "$a" | awk '{print $1}')" | sed -E 's/^i-[0-9a-f]+ \[[A-Za-z]+\]: //'
}

action=${1:?usage: cut.sh on|off|check <link>}
link=${2:?usage: cut.sh on|off|check <link>}
for p in $(pairs "$link"); do
  a=${p%%:*}
  b=${p#*:}
  case "$action" in
  on | off)
    apply "$a" "$b" "$action"
    r=$(check "$a" "$b")
    log "cut $action $a<->$b: $a reaches $b:8201: $r"
    if [ "$action" = on ] && grep -q open <<<"$r"; then die "cut on $a<->$b: still open ($r)"; fi
    if [ "$action" = off ] && grep -q blocked <<<"$r"; then die "cut off $a<->$b: still blocked ($r)"; fi
    event "cut_$action" link "$link" pair "$a<->$b" check "$r"
    ;;
  check) echo "$a -> $b:8201: $(check "$a" "$b")" ;;
  *) die "usage: cut.sh on|off|check <link>" ;;
  esac
done
