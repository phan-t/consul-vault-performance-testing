# ---- common helpers (inlined into every node's user_data; plain bash) ------
# Target OS: Ubuntu 24.04.
# Expects ARCH (amd64|arm64) and NODE_EXPORTER_URL to be set by the template.
set -euo pipefail
exec > >(tee -a /var/log/perf-bootstrap.log) 2>&1
echo "=== bootstrap start $(date -Is) ==="

export DEBIAN_FRONTEND=noninteractive
# Hardened images may mount /tmp noexec; run installers from here instead.
WORKDIR=/opt/bootstrap
mkdir -p "$WORKDIR"

imds() {
  local token
  token=$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
  curl -sS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

PRIVATE_IP=$(imds local-ipv4)

retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge 30 ]; then
      echo "command failed after $n attempts: $*"
      return 1
    fi
    sleep 10
  done
}

http_code() {
  curl -s -o /dev/null -w '%{http_code}' "$@" || true
}

# apt that waits for the dpkg lock (unattended-upgrades often holds it at boot).
apt_get() {
  apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold -y "$@"
}

apt_install() {
  retry apt_get install --no-install-recommends "$@"
}

# AWS CLI v2 (skipped if the image already ships it).
ensure_awscli() {
  command -v aws >/dev/null 2>&1 && return
  local a
  case "$ARCH" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) a=$ARCH ;; esac
  retry curl -sSL -o "$WORKDIR/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-$a.zip"
  unzip -q -o "$WORKDIR/awscliv2.zip" -d "$WORKDIR"
  "$WORKDIR/aws/install" --update
}

get_secret() {
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text
}

base_packages() {
  retry apt_get update
  apt_install ca-certificates curl gnupg jq unzip xfsprogs logrotate
  ensure_awscli
}

install_hashicorp_repo() {
  base_packages
  retry curl -fsSL -o "$WORKDIR/hashicorp.gpg" https://apt.releases.hashicorp.com/gpg
  gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg "$WORKDIR/hashicorp.gpg"
  echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
    > /etc/apt/sources.list.d/hashicorp.list
  retry apt_get update
}

# install_pkg <name> <version>: version like "2.0.1+ent" (matched against the
# repo, e.g. 2.0.1+ent-1) or empty for the latest.
install_pkg() {
  local name=$1 version=$2 full
  if [ -n "$version" ]; then
    # awk must read all input: exiting early SIGPIPEs apt-cache, which fails
    # the pipeline under pipefail and silently aborts the script.
    full=$(apt-cache madison "$name" | awk -v v="$version" 'm == "" && ($3 == v || index($3, v "-") == 1) {m = $3} END {print m}')
    if [ -z "$full" ]; then
      echo "no $name version matching $version in the apt repo"
      return 1
    fi
    apt_install "$name=$full"
    apt-mark hold "$name"
  else
    apt_install "$name"
  fi
}

# trust_ca <pem-file> <name>: add a CA to the system trust store.
trust_ca() {
  cp "$1" "/usr/local/share/ca-certificates/$2.crt"
  update-ca-certificates >/dev/null
}

# Format + mount the first non-root EBS disk (Nitro exposes it as NVMe).
mount_data_volume() {
  local mnt=$1 owner=$2 root_disk dev uuid
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
  for _ in $(seq 1 30); do
    dev=$(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}' | grep -v "/dev/$root_disk" | head -1 || true)
    [ -n "$dev" ] && break
    sleep 5
  done
  if [ -z "$dev" ]; then
    echo "no data volume found; using root volume for $mnt"
    mkdir -p "$mnt"
    chown -R "$owner:$owner" "$mnt"
    return
  fi
  blkid "$dev" >/dev/null 2>&1 || mkfs.xfs -f "$dev"
  mkdir -p "$mnt"
  uuid=$(blkid -s UUID -o value "$dev")
  grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $mnt xfs defaults,noatime,nofail 0 2" >> /etc/fstab
  systemctl daemon-reload
  mount -a
  chown -R "$owner:$owner" "$mnt"
}

install_node_exporter() {
  useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true
  mkdir -p /var/lib/node_exporter/textfile
  retry curl -sSL -o "$WORKDIR/node_exporter.tgz" "$NODE_EXPORTER_URL"
  tar -xzf "$WORKDIR/node_exporter.tgz" -C "$WORKDIR"
  install -m 0755 "$WORKDIR"/node_exporter-*/node_exporter /usr/local/bin/node_exporter
  cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus node_exporter
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.systemd --collector.processes --collector.textfile.directory=/var/lib/node_exporter/textfile
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now node_exporter
  install_scanner_metric
}

# perf_scanner_active / perf_scanner_cpu_percent: hardened images often ship
# security/inventory agents (e.g. a vulnerability scanner) whose processes stay
# resident but only use CPU while scanning. The metric measures the matching
# processes' CPU between samples (from /proc), and reports active when it is at
# least SCANNER_ACTIVE_CPU % of one core. run-plan.sh waits for scans before
# testing and flags tests they overlapped.
install_scanner_metric() {
  printf 'SCANNER_PATTERN=%s\nSCANNER_ACTIVE_CPU=%s\n' "$SCANNER_PATTERN" "$SCANNER_ACTIVE_CPU" > /etc/default/perf-scanner-metric
  cat > /usr/local/bin/perf-scanner-metric <<'EOF'
#!/bin/sh
. /etc/default/perf-scanner-metric
d=/var/lib/node_exporter/textfile
st=/var/lib/node_exporter/perf_scanner.state
now=$(cut -d' ' -f1 /proc/uptime)
tot=0
# An empty pattern would match every process: no pattern = no scanner (0).
[ -n "$SCANNER_PATTERN" ] && for p in $(pgrep -f -- "$SCANNER_PATTERN"); do
  t=$(awk '{print $14 + $15}' "/proc/$p/stat" 2>/dev/null) && tot=$((tot + ${t:-0}))
done
pct=0
if [ -f "$st" ]; then
  read -r pn pt < "$st"
  pct=$(awk -v n="$now" -v pn="$pn" -v t="$tot" -v pt="$pt" -v hz="$(getconf CLK_TCK)" \
    'BEGIN { dt = n - pn; dd = t - pt; if (dt > 0 && dd >= 0) printf "%.1f", dd * 100 / hz / dt; else print 0 }')
fi
echo "$now $tot" > "$st"
act=$(awk -v p="$pct" -v m="$SCANNER_ACTIVE_CPU" 'BEGIN { print (p >= m) ? 1 : 0 }')
printf '# HELP perf_scanner_active 1 while security scanner processes use >= SCANNER_ACTIVE_CPU %% of a core.\n# TYPE perf_scanner_active gauge\nperf_scanner_active %s\n# HELP perf_scanner_cpu_percent CPU used by security scanner processes (%% of one core).\n# TYPE perf_scanner_cpu_percent gauge\nperf_scanner_cpu_percent %s\n' "$act" "$pct" > "$d/perf_scanner.prom.tmp"
mv "$d/perf_scanner.prom.tmp" "$d/perf_scanner.prom"
EOF
  chmod 0755 /usr/local/bin/perf-scanner-metric
  printf '[Unit]\nDescription=Publish security scanner activity for node_exporter\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/perf-scanner-metric\n' \
    > /etc/systemd/system/perf-scanner-metric.service
  printf '[Unit]\nDescription=Publish security scanner activity every 10s\n\n[Timer]\nOnBootSec=10s\nOnUnitActiveSec=10s\nAccuracySec=1s\n\n[Install]\nWantedBy=timers.target\n' \
    > /etc/systemd/system/perf-scanner-metric.timer
  systemctl daemon-reload
  systemctl enable --now perf-scanner-metric.timer
}
tune_os() {
  cat > /etc/sysctl.d/90-perf.conf <<'SYSCTL'
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
SYSCTL
  sysctl --system >/dev/null
  cat > /etc/security/limits.d/90-perf.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
LIMITS
}

# Raise the open-files limit for a systemd service.
service_nofile() {
  mkdir -p "/etc/systemd/system/$1.service.d"
  printf '[Service]\nLimitNOFILE=1048576\n' > "/etc/systemd/system/$1.service.d/90-perf.conf"
  systemctl daemon-reload
}
# ---- end common helpers -----------------------------------------------------
