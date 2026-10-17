#!/bin/bash
# T16 (issue #14), on a Consul server, as root (run-plan.sh sends it over SSM;
# each server fetches it from the perf assets in S3):
#   signing-path-node.sh up <haproxy|proxy|alb> <vault addr> <vault version> <vault node FQDN>...
#     (<vault addr>: the NLB, Vault Proxy's upstream; for alb, the ALB's URL, checked from here)
#   signing-path-node.sh down
#
# up starts the local endpoint the Consul leader's Vault CA provider is pointed
# at for the test, and a textfile metric for node_exporter:
#   proxy    Vault Proxy on https://127.0.0.1:8210, forwarding to <vault addr>
#            (the NLB) with keep-alives off: every request opens a connection,
#            and the NLB picks a Vault node for each.
#   haproxy  HAProxy on https://127.0.0.1:8211, balancing each HTTP/2 request
#            across every Vault node over long-lived HTTP/2 connections.
#   alb      nothing local (the ALB is in Terraform: var.vault_alb); metric only.
# Both listen with the Consul server certificate (localhost and 127.0.0.1 SANs),
# which Consul's ca_file (the perf-test CA) already trusts. The packages are
# installed here, at test time, so a default build is unchanged. The last line
# is "result=ok" or "result=fail <reason>".
#
# perf_signing_connections{kind}: consul_to_path (Consul to the path's port:
# 8210, 8211 or 443), path_to_vault (other processes to :8200), time_wait_to_vault
# (TIME_WAIT sockets to :8200, the cost of path A's connection per request).
# perf_process_cpu_seconds_total{process}: consul, vault (Vault Proxy), haproxy.
# The proxy runs on the leader's host, so host CPU alone can't tell them apart.
#
# down stops and disables everything up started and removes the metric. The
# packages stay installed, inert.
#
# up and down take a lock, so a down sent while an up is still running (a stop
# mid-install: SSM keeps running the up after its sender is gone) waits for it,
# then stops what it started, rather than racing it.
set -uo pipefail

PROXY_PORT=8210
HAPROXY_PORT=8211
CA=/etc/consul.d/tls/ca.crt
TEXTFILE=/var/lib/node_exporter/textfile
APT="apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold -y"
export DEBIAN_FRONTEND=noninteractive

fail() { echo "result=fail $*"; exit 1; }

# The same version as the Vault servers, from the HashiCorp repo already configured for Consul.
install_vault() {
  local want=$1 full
  dpkg -s vault-enterprise >/dev/null 2>&1 && return 0
  $APT update >/dev/null || return 1
  full=$(apt-cache madison vault-enterprise | awk -v v="$want" 'm == "" && ($3 == v || index($3, v "-") == 1) {m = $3} END {print m}')
  [ -n "$full" ] || { echo "no vault-enterprise matching $want"; return 1; }
  $APT install --no-install-recommends "vault-enterprise=$full" >/dev/null && apt-mark hold vault-enterprise >/dev/null
}

install_haproxy() {
  dpkg -s haproxy >/dev/null 2>&1 && return 0
  $APT update >/dev/null && $APT install --no-install-recommends haproxy >/dev/null || return 1
  # The package starts it with its stock config; this script owns it from here.
  systemctl stop haproxy
  cp -n /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig
}

start_proxy() {
  cat > /etc/perf-vault-proxy.hcl <<EOF
# T16 path A. A pure forwarder: no auto_auth, so Consul's own token passes through.
# warn: at info, Proxy logs every request, which would add CPU on the leader's host.
log_level = "warn"
vault {
  address = "$1"
  ca_cert = "$CA"
}
api_proxy {
  use_auto_auth_token = false
}
# Each forwarded request on its own connection (Go's HTTP/2 transport makes a
# connection single-use when keep-alives are off), so the NLB picks a node per sign.
disable_keep_alives = ["proxying"]
listener "tcp" {
  address       = "127.0.0.1:$PROXY_PORT"
  tls_cert_file = "/etc/consul.d/tls/server.crt"
  tls_key_file  = "/etc/consul.d/tls/server.key"
}
EOF
  cat > /etc/systemd/system/perf-vault-proxy.service <<'EOF'
[Unit]
Description=Vault Proxy (T16 signing path A)
After=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/bin/vault proxy -config=/etc/perf-vault-proxy.hcl
Restart=on-failure
LimitNOFILE=1048576
EOF
  systemctl daemon-reload
  systemctl restart perf-vault-proxy
}

start_haproxy() {
  local n servers=""
  for n in "$@"; do
    servers+="  server ${n%%.*} $n:8200 verifyhost $n"$'\n'
  done
  cat /etc/consul.d/tls/server.crt /etc/consul.d/tls/server.key > /etc/haproxy/t16.pem
  chmod 0600 /etc/haproxy/t16.pem
  cat > /etc/haproxy/haproxy.cfg <<EOF
# T16 path B: balance each HTTP/2 request across every Vault node.
# No per-request logging: at thousands of signs/s, syslog would add CPU to the
# leader's host that the test would count against the path.
global
  log /dev/log local0 notice
  maxconn 50000
  user haproxy
  group haproxy
  # Vault's (Go's) limit, not HAProxy's default of 100: Consul then opens a
  # second connection at the same concurrency as it does to Vault directly.
  tune.h2.max-concurrent-streams 250

defaults
  mode http
  timeout connect 5s
  # Longer than Go's 90 s idle-connection timeout, so Consul closes idle
  # connections first: a sign (a POST) on a connection already closed isn't retried.
  timeout client 120s
  timeout server 120s
  timeout http-keep-alive 120s

resolvers vpc
  parse-resolv-conf
  hold valid 10s

frontend t16_vault
  bind 127.0.0.1:$HAPROXY_PORT ssl crt /etc/haproxy/t16.pem alpn h2,http/1.1
  default_backend t16_vault_nodes

backend t16_vault_nodes
  balance roundrobin
  http-reuse always
  option httpchk
  http-check send meth GET uri /v1/sys/health?standbyok=true&perfstandbyok=true
  http-check expect status 200
  # Held spares (stopped) fail the check and get no traffic, as on the NLB.
  default-server ssl verify required ca-file $CA alpn h2 check check-alpn http/1.1 inter 2s fall 2 rise 2 resolvers vpc init-addr last,libc,none
$servers
EOF
  haproxy -c -q -f /etc/haproxy/haproxy.cfg || return 1
  systemctl enable --now haproxy >/dev/null 2>&1
  systemctl restart haproxy
}

start_metric() {
  printf 'PORT=%s\n' "$1" > /etc/default/perf-signing-path
  cat > /usr/local/bin/perf-signing-path <<'EOF'
#!/bin/sh
. /etc/default/perf-signing-path
d=/var/lib/node_exporter/textfile
c2p=$(ss -Htnp state established "( dport = :$PORT )" | grep -c '"consul"')
p2v=$(ss -Htnp state established '( dport = :8200 )' | grep -vc '"consul"')
tw=$(ss -Htn state time-wait '( dport = :8200 )' | wc -l)
hz=$(getconf CLK_TCK)
{
  echo '# HELP perf_signing_connections T16 signing path connections (consul_to_path, path_to_vault, time_wait_to_vault).'
  echo '# TYPE perf_signing_connections gauge'
  echo "perf_signing_connections{kind=\"consul_to_path\"} $c2p"
  echo "perf_signing_connections{kind=\"path_to_vault\"} $p2v"
  echo "perf_signing_connections{kind=\"time_wait_to_vault\"} $tw"
  echo '# HELP perf_process_cpu_seconds_total CPU time of the signing path processes on this host.'
  echo '# TYPE perf_process_cpu_seconds_total counter'
  for p in consul vault haproxy; do
    t=0
    for pid in $(pgrep -x "$p"); do
      v=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null) && t=$((t + ${v:-0}))
    done
    awk -v p="$p" -v t="$t" -v hz="$hz" 'BEGIN { printf "perf_process_cpu_seconds_total{process=\"%s\"} %.2f\n", p, t / hz }'
  done
} > "$d/perf_signing.prom.tmp"
mv "$d/perf_signing.prom.tmp" "$d/perf_signing.prom"
EOF
  chmod 0755 /usr/local/bin/perf-signing-path
  printf '[Unit]\nDescription=Publish T16 signing path metrics for node_exporter\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/perf-signing-path\n' \
    > /etc/systemd/system/perf-signing-path.service
  printf '[Unit]\nDescription=Publish T16 signing path metrics every 5s\n\n[Timer]\nOnActiveSec=1s\nOnUnitActiveSec=5s\nAccuracySec=1s\n\n[Install]\nWantedBy=timers.target\n' \
    > /etc/systemd/system/perf-signing-path.timer
  systemctl daemon-reload
  systemctl enable --now perf-signing-path.timer >/dev/null 2>&1
  systemctl restart perf-signing-path.timer
}

# health <url>: Vault's health through the endpoint, retried for up to 60 s
# (HAProxy marks its backends up after two checks).
health() {
  local i code
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$CA" "$1/v1/sys/health?standbyok=true&perfstandbyok=true")
    [ "$code" = 200 ] && return 0
    sleep 2
  done
  echo "health through $1: HTTP $code"
  return 1
}

down() {
  systemctl disable --now perf-vault-proxy >/dev/null 2>&1
  rm -f /etc/systemd/system/perf-vault-proxy.service
  if dpkg -s haproxy >/dev/null 2>&1; then
    systemctl disable --now haproxy >/dev/null 2>&1
    [ -f /etc/haproxy/haproxy.cfg.orig ] && cp /etc/haproxy/haproxy.cfg.orig /etc/haproxy/haproxy.cfg
    rm -f /etc/haproxy/t16.pem
  fi
  systemctl disable --now perf-signing-path.timer >/dev/null 2>&1
  rm -f "$TEXTFILE/perf_signing.prom"
  systemctl daemon-reload
  echo "result=ok"
}

exec 9>/run/signing-path-node.lock
flock -w 900 9 || fail "another signing-path-node.sh still running after 900 s"

case "${1:-}" in
up)
  path=${2:?path}; addr=${3:?vault addr}; version=${4:?vault version}
  shift 4
  case "$path" in
  proxy)
    install_vault "$version" || fail "installing vault-enterprise $version"
    start_proxy "$addr"
    start_metric "$PROXY_PORT"
    health "https://127.0.0.1:$PROXY_PORT" || fail "Vault Proxy not answering: $(journalctl -u perf-vault-proxy -n 3 --no-pager -o cat | tr '\n' ' ')"
    ;;
  haproxy)
    [ $# -gt 0 ] || fail "no Vault nodes given"
    install_haproxy || fail "installing haproxy"
    start_haproxy "$@" || fail "haproxy config invalid: $(haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | tail -2 | tr '\n' ' ')"
    start_metric "$HAPROXY_PORT"
    health "https://127.0.0.1:$HAPROXY_PORT" || fail "HAProxy not answering: $(journalctl -u haproxy -n 3 --no-pager -o cat | tr '\n' ' ')"
    ;;
  alb)
    start_metric 443
    health "$addr" || fail "ALB not answering (is var.vault_alb set?)"
    ;;
  *) fail "unknown path $path" ;;
  esac
  echo "result=ok"
  ;;
down) down ;;
*) echo "usage: signing-path-node.sh up <haproxy|proxy|alb> <vault addr> <vault version> <node>... | down" >&2; exit 2 ;;
esac
