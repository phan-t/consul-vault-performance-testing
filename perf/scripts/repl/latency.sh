#!/bin/bash
# Latency between the two sites (T17). Both sites are VPCs in Sydney, because
# Melbourne isn't allowed on the account, so without this the link between
# them is about 1 ms, and catch-up would look faster than across any real
# link between two data centres.
#
#   latency.sh on [rtt_ms]    on every Vault node, delay traffic to the other
#                             site's VPC by rtt_ms/2 (default SITE_RTT_MS, 12),
#                             so a round trip between the sites is about rtt_ms
#   latency.sh off            remove it
#   latency.sh measure        TCP connect time from primary to pr-sec on 8201
#                             (one round trip), median of 10, in ms
#
# tc netem on the node's interface: a prio qdisc whose fourth band has the
# delay, and a filter that sends only the other site's CIDR there. Traffic
# inside a site, and to the internet, isn't delayed. It's a fixed delay: no
# jitter, loss, or bandwidth limit, so the results describe a clean link.
. /opt/perf/scripts/repl/lib.sh

rules() { # rules <on|off> <peer cidr> <one-way ms>
  local cidr=$2 ms=$3 base probe
  base=${cidr%/*}
  probe=${base%.*}.10
  cat <<EOF
IF=\$(ip -o route get $probe | sed -n 's/.* dev \([^ ]*\).*/\1/p')
tc qdisc del dev \$IF root 2>/dev/null
if [ "$1" = on ]; then
  modprobe sch_netem 2>/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q "linux-modules-extra-\$(uname -r)" >/dev/null 2>&1; modprobe sch_netem; }
  tc qdisc add dev \$IF root handle 1: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 &&
  tc qdisc add dev \$IF parent 1:4 handle 40: netem delay ${ms}ms &&
  tc filter add dev \$IF protocol ip parent 1:0 prio 1 u32 match ip dst $cidr flowid 1:4 &&
  echo "\$IF: +${ms}ms to $cidr"
else
  echo "\$IF: no delay"
fi
EOF
}

apply() { # apply <on|off> <rtt_ms>
  local action=$1 rtt=$2 ms c out
  ms=$(awk -v r="$rtt" 'BEGIN { printf "%g", r / 2 }')
  for c in $CLUSTERS; do
    out=$(ssm_run "$(cl "$c" region)" 120 "$(rules "$action" "$(cl "$c" peer_cidr)" "$ms")" $(node_ids "$c"))
    echo "$out" | sed "s/^/  $c: /" >&2
    [ "$(grep -c '\[Success\]' <<<"$out")" -eq "$(wc -w <<<"$(node_ids "$c")")" ] || die "latency $action failed on $c: $out"
  done
}

measure() {
  local src ip
  src=$(node_ids primary | awk '{print $1}')
  ip=$(node_ips pr-sec | awk '{print $1}')
  ssm_run "$(cl primary region)" 60 "python3 -c '
import socket, statistics, time
t = []
for _ in range(10):
    s = time.perf_counter(); c = socket.create_connection((\"$ip\", 8201), timeout=5); t.append((time.perf_counter() - s) * 1000); c.close(); time.sleep(0.2)
print(round(statistics.median(t), 1))
'" "$src" | sed -E 's/^i-[0-9a-f]+ \[[A-Za-z]+\]: //' | tr -d ' '
}

case "${1:-}" in
on)
  rtt=${2:-${SITE_RTT_MS:-12}}
  if [ "$rtt" = 0 ]; then apply off 0; event latency rtt_ms 0; exit 0; fi
  apply on "$rtt"
  m=$(measure)
  log "latency: target ${rtt} ms round trip between the sites; measured ${m} ms (TCP connect, primary to pr-sec:8201)"
  event latency rtt_ms "$rtt" measured_ms "$m"
  ;;
off)
  apply off 0
  event latency rtt_ms 0 measured_ms "$(measure)"
  ;;
measure) measure ;;
*) sed -n '2,19p' "$0" >&2; exit 1 ;;
esac
