# Consul Enterprise + Vault Enterprise performance testing (AWS Sydney)

Self-managed **Vault Enterprise** and **Consul Enterprise** on EC2 in
`ap-southeast-2`. Each is a 5-voter Raft cluster that can also run non-voters.
Consul's service mesh (Connect) CA issues **leaf certificates from Vault's PKI
secrets engine** through a `no_store` role. The load tools are k6 and
[vault-benchmark](https://github.com/hashicorp/vault-benchmark), and
Prometheus + Grafana provide the monitoring. The environment is provisioned
through **HCP Terraform (TFC)**.

```
                         VPC 10.50.0.0/16  (3 AZs: 2a / 2b / 2c, private subnets, NAT egress)
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │  loadgen-N (k6, vault-benchmark, Consul client agent)                                    │
 │     │  /v1/agent/connect/ca/leaf/<svc>                     k6 / vault-benchmark (direct)  │
 │     ▼                                                                   │                 │
 │  Consul servers  consul-0..4 (voters) + consul-rr-N (read replicas)     │                 │
 │     │  ConnectCA.Sign -> forwarded to LEADER                            ▼                 │
 │     └── leader: Vault CA provider (AWS IAM auth) ──► vault.perf.internal (internal NLB)   │
 │                                                          │                                │
 │                    Vault vault-0..4 (voters) + vault-nv-N (non-voters / perf standbys)    │
 │                    Raft integrated storage · AWS KMS auto-unseal                          │
 │  monitoring: Prometheus (EC2 SD) + Grafana       access: SSM Session Manager only         │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

## What gets built

| Component | Default | Notes |
|---|---|---|
| Vault Enterprise | 5 × `m7i.2xlarge`, 100 GB gp3 (6000 IOPS) Raft volume | `2.1.1+ent`. Raft auto-join via EC2 tags, KMS auto-unseal, TLS, file audit device |
| Vault non-voters | `vault_non_voter_count = 0` | Autopilot redundancy zone spares (Enterprise, `vault_redundancy_zones = true`): voter *i* is in `zone-i`, and `vault-nv-N` joins `zone-N` as a non-voter that Autopilot promotes if that zone's voter fails. With `vault_redundancy_zones = false`, permanent non-voters (`retry_join_as_non_voter`). Either way, they run as performance standbys |
| Consul Enterprise | 5 × `m7i.2xlarge`, 100 GB gp3 data volume | `2.0.1+ent`, pinned (see [Consul version](#consul-version)). TLS, gossip encryption, ACLs (default deny), auto_encrypt for clients |
| Consul read replicas | `consul_read_replica_count = 0` | `read_replica = true` (Enterprise non-voting servers) |
| Connect CA | Vault provider, external root | Enterprise root CA (simulated by Terraform) → Vault intermediate (`pki_mesh_int`, Vault-managed) → Consul signing intermediate (`connect_<dc>_inter`) → leafs. The `leaf-cert` role uses `no_store=true`. Auth uses the Vault **AWS IAM auth method** (no static Vault token). See [Mesh PKI](#mesh-pki) |
| Load generators | 2 × `r7i.4xlarge` (memory for the client agent's leaf cache) | Consul client agent, k6 `2.3.0`, vault-benchmark `0.3.0`, Vault CLI |
| Monitoring | 1 × `m7i.xlarge` | Prometheus (EC2 service discovery) and Grafana, with a provisioned dashboard |
| Access | SSM Session Manager | No SSH and no public IPs on the nodes. By default, no inbound traffic from outside the VPC; an optional public ALB for Grafana (and the Vault and Consul UIs) is off unless `grafana_public_zone` is set |
| Base image | Ubuntu 24.04 | The latest Canonical image by default (`ami_owner`, `ami_name_pattern`; point them at your own hardened image), selected by `ami_arch` (`amd64` by default; instance types must match). Packages come from the HashiCorp APT repo, pinned and held |

The voters are placed round-robin across the 3 AZs (2/2/1). Each node is its
own `aws_instance`, not an ASG, so node IDs stay stable while you scale.

## Consul version

Consul is pinned to **2.0.1+ent** (`var.consul_version`) because the newer
2.0.x Enterprise releases have two upstream problems that distort performance
results:

| Version | Raft/Serf/memberlist metrics | Idle RPC stream EOFs |
|---|---|---|
| **2.0.1** | ✅ emitted | ✅ none |
| 2.0.2, 2.0.3 | ❌ dropped: release built without `hashicorpmetrics` ([#23812](https://github.com/hashicorp/consul/issues/23812)) | ✅ none |
| 2.0.4 | ❌ dropped | ❌ servers close idle RPC streams after `rpc_handshake_timeout` (5 s), so un-retried writes such as `ConnectCA.Sign` return 500 ([#23923](https://github.com/hashicorp/consul/issues/23923)) |

To test 2.0.4 anyway, set `consul_version = "2.0.4+ent"` and
`consul_rpc_handshake_timeout = "60s"`. That setting cut the idle-stream errors
by about 93% here. Note that 2.0.1 lacks the security fixes in 2.0.2–2.0.4.

## Mesh PKI

The hierarchy is **enterprise root CA → Vault intermediate → Consul**, as in a
typical enterprise PKI: the root CA belongs to the organisation and is never in
Vault. Terraform simulates the enterprise root CA here:

```
Enterprise root CA (ECDSA P-384, 10 yr)       simulated by Terraform ("Offline Mesh Root CA");
  │                                           key only in TFC state
  └─ Vault intermediate (P-256, 5 yr)         pki_mesh_int (Vault-managed)
       └─ Consul signing CA (1 yr)            connect_<dc>_inter (managed by Consul)
            └─ leaf certificates (7 days)     role leaf-cert, no_store=true
```

- **Replacing the root, or the Vault intermediate under it, belongs to the
  enterprise root CA's lifecycle and is out of scope.** In this design Consul
  also can't take over a new externally signed intermediate by rotation: Vault
  refuses the cross-sign (issue #12). Only Consul's own signing CA rotation is
  tested (T13).

- **`pki_mesh_int` is Consul's `root_pki_path` in Vault-managed mode.**
  Consul can only read it and call `root/sign-intermediate`. It cannot mount,
  change or rotate it.
- **`vault-0` creates both mounts at bootstrap.** It imports the intermediate
  bundle from the `<name>/vault/mesh-ca` secret, which holds the key,
  intermediate and root certificate but not the root key. It also sets the
  keyed issuer as the default and applies the Vault-managed policy from the
  Consul docs.
- **Consul manages everything inside `connect_<dc>_inter`.** That includes its
  signing CA, which it renews automatically, and the `leaf-cert` role.
- **The trust anchor for verifying leaf chains** is `terraform output -raw mesh_root_ca_pem`.
- **In production,** the Vault intermediate's key would be generated inside
  Vault and its CSR signed by the enterprise root CA. Terraform generating it
  here keeps the build single-pass, and doesn't change any signing path.

## Provisioning with HCP Terraform

All Vault and Consul configuration happens **on the instances**: `vault-0`
initialises Vault and configures AWS auth and the policy, and `consul-0` creates
the ACL tokens. TFC runs therefore never need network access to the private
clusters.

### 1. Bootstrap the workspace (once)

```bash
terraform login
cd tfc-bootstrap
cp terraform.tfvars.example terraform.tfvars   # org name + license file paths
terraform init && terraform apply
```

This creates the project and the `consul-vault-perf` workspace (CLI-driven,
working directory `terraform/`). It also sets `aws_region` and, if you give
license files, the sensitive `vault_license` and `consul_license` variables.
Otherwise, set those two variables in the TFC UI.

> Consul 2.x needs an **IBM Consul Enterprise license**.

### 2. Push AWS credentials

The workspace uses **static AWS credentials** as environment variables:
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` if they
are temporary (set them on the workspace or a variable set). The provider has no
`profile` set, because your local `default` profile doesn't exist inside a
TFC run.

If the credentials are temporary, check they will outlive a full apply (about
10–15 min).

### 3. Plan and apply

```bash
export TF_CLOUD_ORGANIZATION=<your-org>
cd terraform
terraform init
terraform apply
```

The whole repo is uploaded (see `.terraformignore`), so `perf/` is synced to S3
and pulled onto the load generators.

Bootstrap order after apply, which takes about 5–8 min:

1. The Vault nodes start and auto-join.
2. `vault-0` initialises Vault. The root token and recovery key go to
   `<name>/vault/init` in Secrets Manager.
3. `vault-0` enables AWS auth and the `consul-connect-ca` policy, then sets
   `/<name>/vault/bootstrap-status=complete`.
4. The Consul servers wait for that flag, then start. The first leader
   initialises the Vault CA provider.
5. `consul-0` creates the `agent`, `perf` and `metrics` ACL tokens.

To follow progress on a node, run `sudo tail -f /var/log/perf-bootstrap.log`
in an SSM session.

## Scaling voters and non-voters

```hcl
vault_non_voter_count     = 2   # adds vault-nv-0, vault-nv-1  (zone spares in zone-0, zone-1; perf standbys)
consul_read_replica_count = 2   # adds consul-rr-0, consul-rr-1 (read replicas)
```

Apply again. The new nodes auto-join as non-voters without touching the
existing voters. With redundancy zones (the default), Autopilot keeps one voter
per zone, so a spare stays a non-voter until its zone's voter fails (T12 in
TEST-PLAN.md measures this).

To check membership:

- Vault: `vault operator raft list-peers`, or `vault operator raft autopilot state`
- Consul: `consul operator raft list-peers`

`user_data` and the AMI are in `ignore_changes`, so edits never recycle a
running cluster by accident. To rebuild a node on purpose, use
`terraform apply -replace='aws_instance.vault["vault-3"]'`.

## Targets

The step-by-step run order, commands and a results template are in
[TEST-PLAN.md](TEST-PLAN.md).

These are sized for an example mesh: **100,000 service instances
with sidecars on Consul Dataplane (no client agents)**, a **7-day leaf TTL**,
and 2× growth headroom.

| Event | Leafs | Window | Rate needed |
|---|---|---|---|
| Renewals (7-day TTL, at ~75% of TTL) | 100,000 | continuous | ~0.22/s |
| AZ failure (⅓ of workloads reschedule) | ~33,000 | 5 min | ~111/s |
| **Rolling Consul server restart** (per server, 5 servers) | ~20,000 | ~1 min *(assumed)* | **~333/s** |
| Cold start / DR | 100,000 | 10 min | ~167/s |
| Cold start at 2× growth | 200,000 | 10 min | ~333/s |

With Dataplane, each Consul server issues and holds the leafs for the
proxies connected to it, in memory. When a server restarts, its dataplanes
reconnect elsewhere and their leafs are issued again. That makes rolling
server restarts the largest routine burst. This follows from how Consul
manages leafs and should be validated.

| Target | Value |
|---|---|
| **Leaf throughput through Consul** | **≥ 350 leafs/s** sustained (~333/s needed, rounded up) |
| End-to-end leaf p99 at 350/s | **≤ 1 s**, errors < 0.1% (`consul-leaf.js` thresholds) |
| Vault sign p99 on Consul's intermediate at 350/s | **≤ 100 ms**, errors < 0.1% (`vault-sign-consul-mount.js` thresholds) |
| Guardrails at 350/s | 0 leader elections, Autopilot failure tolerance stays at 2, Raft leader last contact p99 < 200 ms |
| Stretch | The actual ceilings of the Vault path (T3) and the Consul path (T5) |

- **The limits are configurable per run:** `P99_MS` and `MAX_ERROR_RATE`
  (default `0.001`) override the k6 thresholds.
- **Stress tests start at the target:** `stress-k6.sh` starts at 350/s for
  `vault-sign-consul-mount.js` and `consul-leaf.js`, per load generator
  (`TARGET_RATE` in `run-plan.sh` moves every target-derived rate).
- **The main decision these results feed** is Consul's `csr_max_per_second`.
  The default of 50/s would take about 33 minutes for a 100,000-leaf cold
  start, and about 7 minutes per server restart. Set it to what both the
  Consul leader and Vault sustain within these targets.

**What the current tests model for Dataplane:**
- `consul-leaf.js` measures the **signing path** (Consul leader → Vault)
  accurately.
- Key and CSR generation happens on the load generator's client agent. With
  Dataplane it happens on the **Consul servers**, so server CPU during
  real-world bursts will be higher than these tests show.
- The registration burst (`consul-register-burst.js`) models client-agent
  behaviour, which Dataplane doesn't have.

## Running the tests

Open a shell on a load generator. The `access` output has the exact commands:

```bash
aws ssm start-session --region ap-southeast-2 --target <loadgen-id>
sudo su - ubuntu       # environment comes from /etc/profile.d/perf.sh
```

| # | Layer | Command | What it isolates |
|---|---|---|---|
| 1 | Vault PKI baseline | `pki-perf-mount.sh create`, then `MODES=multi CONCURRENCY=64 MULTI_CONNS=32 SIGN_PATH=pki_perf/sign/leaf-nostore SIGN_TOKEN="$VAULT_TOKEN" connection-test.sh` | Vault signing throughput for a Consul-shaped CSR (EC P-256 + SPIFFE SAN), `no_store=true`, on a synthetic mount, over 32 connections spread across every Vault node |
| 1b | Cost of storing certs | the same with `SIGN_PATH=pki_perf/sign/leaf-store` | `no_store=false`, to quantify the no_store gain |
| 2 | Vault on the real Consul mount | `RATE=500 run-k6.sh /opt/perf/k6/vault-sign-consul-mount.js` | `connect_dc1_inter/sign/leaf-cert` via the NLB, without Consul |
| 3 | End-to-end mesh leaf | `RATE=100 run-k6.sh /opt/perf/k6/consul-leaf.js` | Client agent → Consul leader → Vault. Unique service names force real signing |

- For k6 tests, `RATE` is iterations per second **per load generator**. `RAMP`
  (default `2m`) and `HOLD` (default `10m`) control the stages.
- **Steady-state tests share a timing profile:** a 5-minute idle baseline, a
  2-minute warm-up, a 10-minute measured window, and a 5-minute idle cooldown.
  See [Test timeline and results](#test-timeline-and-results).
  - For k6, the warm-up is the ramp (`RAMP=2m`, `HOLD=10m`).
  - For vault-benchmark, the warm-up is a separate 2-minute run whose results
    are discarded (`WARMUP=2m`, `DURATION=10m`).

  Keep the two tools aligned when you change these, so their results stay
  comparable. The burst scenario (B) measures a fixed amount of work, and the
  renewal fleet (B′) follows the leaf TTL, so neither uses this profile.
- To run a test on all load generators at once, use
  `perf/scripts/run-everywhere.sh` from your workstation with the same
  `RUN_ID`.
- After changing anything under `perf/`, run `terraform apply` to upload it to
  S3, then `sync-assets.sh` on each load generator.

### Test timeline and results

Every run of `run-k6.sh` or `run-vault-benchmark.sh` follows the same
timeline, so the steady state can always be compared with a known quiet
period before and after it:

```
| baseline (5m idle) | warm-up (2m) | steady state (10m) | cooldown (5m idle) |
  BASELINE             RAMP / WARMUP   HOLD / DURATION      COOLDOWN
```

- **Grafana annotations** mark each run on the dashboard: a start/end region
  plus a steady-state marker, in the **Perf tests** annotation layer.
- **The Grafana export** runs on `loadgen-0` after the cooldown (`EXPORT=auto`;
  set `EXPORT=1` or `EXPORT=0` to force it on or off). It covers the whole
  window and is driven by the live **Consul + Vault Perf** dashboard, so every
  panel and query is included, and new panels are picked up automatically.
- **Client-side k6 metrics** are pushed to Prometheus with remote write and
  shown in the *Load generators* row. Per-request URL tags are dropped to keep
  Prometheus cardinality low.

Each run directory (`/opt/perf/results/<RUN_ID>-<node>-<tool>-<test>/`,
uploaded to `s3://<perf_bucket>/results/`) contains:

| File | Contents |
|---|---|
| `params.json`, `phases.json` | Test parameters, and phase start/end times (epoch ms) |
| `summary.json` (k6) / `result.json` (vault-benchmark) | Client-side results. k6 now includes p99. vault-benchmark latencies are in ns. |
| `k6.log` / `vault-benchmark.log`, `warmup.log` | Tool output |
| `grafana/dashboard.png` | Full dashboard for the run window |
| `grafana/panels/NN-<panel>.png` | Every panel, rendered for the run window |
| `grafana/metrics.csv` | Every dashboard query's time series (panel, series, UTC time, value, labels) |
| `grafana/stats.json`, `grafana/stats.md` | Per-series count/mean/min/max/p50/last for **baseline / warmup / steady / cooldown** |
| `grafana/links.txt` | Grafana link for the same window |

To combine all load generators and tools for one run into a single report:

```bash
summarise.sh <RUN_ID>     # writes <RUN_ID>-summary/summary.md + summary.csv, uploaded to S3
```

The report normalises everything to **milliseconds**:
- **Client-side:** a row per node. Where several nodes ran, a combined row
  sums throughput and reports a request-weighted mean and the worst node's
  percentiles.
- **Server-side:** every dashboard query, with baseline / warmup / steady /
  cooldown means (the max across instances) and the steady-state max.

To open the dashboard, port-forward 3000 (see the `access` output), or use the
public URL if enabled, and go to **Perf Testing → Consul + Vault Perf**.

### Consul leaf scenarios (no apps or Envoy needed)

Root rotation isn't modelled. The root is the enterprise root CA and Vault
holds an intermediate under it, so Consul never rotates the root itself.

Consul signs a leaf through Vault whenever something in the mesh needs one. It
does **not** sign one when you register a plain service. These scenarios generate
that signing load without deploying any workload:

| Scenario | Command | Models |
|---|---|---|
| **A. Direct leaf requests** | `RATE=100 run-k6.sh /opt/perf/k6/consul-leaf.js` | Raw signing throughput and latency. Every new service name is one Vault signing (layer 3 above) |
| **B. Sidecar registration burst** | `COUNT=5000 RATE=100 run-k6.sh /opt/perf/k6/consul-register-burst.js` | A rollout. Each registered sidecar definition makes the agent fetch a leaf at once; `leaf_ready_ms` = registration → cert available |
| **B'. Renewal fleet** | `consul-ca-limits.sh --leaf-ttl 1h`, then B with `CLEANUP=false` | Steady renewals. The agent renews every leaf at ~60–90% of the TTL, so 5,000 sidecars at 1 h ≈ 5,000 signings/hour |

- `perf-cleanup.sh [prefix]` deregisters perf services left on an agent.
- Burst sidecars get explicit ports and one passing TTL check. Without that,
  the default auto-assigned port range (21000–21255) fits only 256 sidecars,
  and the default TCP checks against a non-existent Envoy would flap and add
  catalog writes.

### Stress testing

`stress-k6.sh` reruns a k6 script at a rising rate until a pass criterion
fails. Each step is an ordinary `run-k6.sh` run (`RUN_ID=<RUN_ID>-r<rate>`), and
the rate doubles after every passing step.

```bash
consul-ca-limits.sh 0 0                                   # mesh path: find the system's ceiling, not the limiter's
START=50 stress-k6.sh /opt/perf/k6/consul-leaf.js
START=200 stress-k6.sh /opt/perf/k6/vault-sign-consul-mount.js
```

- A step fails when the script's k6 thresholds fail, or when k6 delivers less
  than `MIN_ACHIEVED` (default `0.95`) of the iterations it should have
  started. In an open model, dropped iterations mean every VU was waiting.
- `FACTOR` (default `2`), `MAX` (default `12800`), `STEP_GAP` (extra pause
  between steps, default `0`) and the usual `RAMP`/`HOLD` apply. For
  `consul-leaf.js`, the client agent is restarted between steps to clear its
  leaf cache (`RESTART_AGENT`).
- **Steps are chained:** one 5-minute baseline, then each step back to back
  (2-minute warm-up and 10-minute steady state, about 12 minutes per step),
  then one cooldown and one Grafana export.
  - Each step's warm-up and steady windows are separate export phases
    (`steady-r<rate>`).
  - A doubling sequence from 50 to 12800 (9 steps) takes about 2 hours.
- `sweep-vault-benchmark.sh` chains vault-benchmark worker levels the same way
  (`WORKERS_LIST`, phases `steady-w<N>`).
- Per-step Prometheus measurements (peak CPU, signs per Vault node) cover the
  step's **steady state**, read from its `phases.json`.
- `stress.json` records each step (thresholds, delivered fraction, failure
  rate, p50/p95/p99, busiest hosts' peak CPU and sign requests per Vault node
  from Prometheus), the last passing rate, why it stopped, and the knee: the
  first pair of steps where p95 grew faster than the rate.
- For `consul-leaf.js`, watch `sign_nodes` across steps. If Consul's signing
  spreads to more nodes at high rates, the leader has opened a second
  connection (see *Consul signing distribution*).
- If the busiest host is the load generator itself, the ceiling is the
  generator's. Raise `MAX_VUS` or run on every load generator.

### Consul signing distribution

Performance standbys, including non-voters, sign `no_store` requests locally,
so direct clients spread across every Vault node. The Consul leader is expected
not to: it is Vault's only Consul client, its Vault API client multiplexes
requests over one pooled HTTP/2 connection, and the NLB picks a target per TCP
connection. `signing-distribution.sh` checks this.

```bash
RATE=100 signing-distribution.sh
```

1. **control:** `vault-sign-consul-mount.js` at `RATE`, direct clients.
2. **mesh-1:** `consul-leaf.js` at `RATE`, through the agent and the leader.
3. No load for `IDLE` (default `150s`), so the leader's idle connection closes
   (90 s in the Go transport).
4. **mesh-2:** `consul-leaf.js` again.

Consul's CSR limits are removed for the test and restored on exit. After each
run, Prometheus gives sign requests per Vault node on Consul's intermediate
over the hold, overall and per minute. `distribution.json` holds each run's
per-node shares, the busiest node per minute, and a verdict:

- `spread`: every Vault node took at least 1% of sign requests.
- `concentrated`: the busiest node took at least `SHARE` (default `0.9`) in
  every minute.
- `mixed`: neither.

The expected behaviour is `confirmed` when the control is spread and both mesh
runs are concentrated, and `refuted` when a mesh run is spread.
`busiest_node_changed_after_idle` shows whether a new connection landed
elsewhere.

Two things can move Consul's signing off its node. After more than 90 s idle,
the next burst opens a new connection, paying a fresh TCP and TLS handshake,
and may land elsewhere. Under heavy load, Go's HTTP/2 client opens a second
connection once the first reaches the server's concurrent-stream limit, so a
stress run may show signing spread at high rates. The leader's other Vault
calls (token renewal at about two thirds of its TTL, the hourly CA fetch) are
too sparse to keep the connection open. Then compare capacity with and without non-voters:

1. With `vault_non_voter_count = 0`, run
   `START=50 stress-k6.sh /opt/perf/k6/consul-leaf.js`.
2. Set `vault_non_voter_count = 2`, apply, and wait for the non-voters to
   join (`vault operator raft list-peers`).
3. Rerun the same stress test and compare `last_pass_rate`.

Run the distribution test with the non-voters in place so there are more
nodes for the traffic to spread across.

### Single connection vs many (T3c)

The Consul leader is Vault's only Consul client. It sends every signing request
over **one pooled HTTP/2 connection**, which the NLB pins to **one Vault node**.
`connection-test.sh` measures whether that connection is a ceiling. It uses
`vault-sign-load`, a small Go tool (`perf/tools/vault-sign-load`, built on the
load generator on first use) with **the same Vault client Consul 2.0.1 uses**
(`hashicorp/vault/api v1.16.0`, HTTP/2 transport).

```bash
connection-test.sh                                   # CONCURRENCY="1 8 32 64 128 256 512", MULTI_CONNS=16, STEP=60s
```

- **Two modes, each swept across concurrency:**
  - **single:** one shared client, so requests are multiplexed over one
    connection, as the Consul leader does.
  - **multi:** `MULTI_CONNS` independent clients, so separate connections
    spread across Vault nodes.
- **What each step records:**
  - throughput, p50/p95/p99, errors, and distinct TCP connections;
  - **which Vault nodes served it**, from Vault's metrics (behind the NLB, the
    client only sees the NLB's addresses).
- **Setup:** it signs on Consul's real intermediate, with a token carrying
  Consul's `consul-connect-ca` policy. Client retries are off, so errors are
  counted rather than hidden.
- **Output:** `connection-test.json`, and a table ending in single max,
  multi max, and the ratio between them.

Reading it, with T5 (Consul's own ceiling):

| Result | Meaning |
|---|---|
| Consul's ceiling ≈ single-connection ceiling | The single connection (one Vault node) is the bottleneck |
| Consul's ceiling well below single-connection ceiling | The limit is Consul-side (leader RPC, rate limiter, key generation) |
| Single ≪ multi | Vault's no_store scale-out can't help Consul while the leader uses one connection |

**Direct evidence of the connection count:**
- `perf_vault_connections` is published by every Consul server (`ss`, every
  5 s, via node_exporter's textfile collector). It gives the established
  connections to Vault `:8200`.
- The dashboard shows it, with the busiest Vault node's share and Consul
  server CPU, under **Consul Connect CA**.
- `stress-k6.sh` records its maximum for each step.
- Idle, every server shows 0 (the connection closes). Under load, only the
  leader shows it.

### Things that will shape your numbers

- **Consul's CSR rate limit.** `csr_max_per_second` defaults to **50/s**, so
  test 3 plateaus there and returns rate-limit errors, counted in
  `consul_csr_rate_limited`. Change it at runtime without rotating the CA:
  - `consul-ca-limits.sh` shows the current limits
  - `consul-ca-limits.sh 0 0` removes the limits
  - `consul-ca-limits.sh 0 64` caps concurrency at 64
  - `consul-ca-limits.sh --leaf-ttl 1h` shortens the leaf TTL, for renewal load

  You can also set `var.consul_connect_ca` before the first apply.
- **Only the Consul leader signs.** `ConnectCA.Sign` is a write RPC, so
  followers and read replicas forward it to the leader. Read replicas scale
  Consul reads, not leaf issuance. For the mesh path, the leader's CPU and its
  Vault round-trip latency are the ceiling.
- **Vault horizontal scale with `no_store`.** Performance standbys, including
  non-voters, sign `no_store` requests locally. Direct clients (tests 1–2)
  therefore spread across every node behind the NLB. Consul's leader reuses a
  pooled HTTP/2 connection to Vault, so its traffic is expected to land on a
  single Vault node at a time. Watch *Vault sign requests (Consul
  intermediate)* per node, or run `signing-distribution.sh`.
- **Audit device.** It is on by default (`vault_audit_enabled`) to keep things
  realistic, with log rotation every 5 minutes at 1 GB. Turn it off to measure
  the audit overhead.
- **Consul 2.0.2–2.0.4 (and late 1.22.x) Enterprise binaries drop Raft,
  Serf and memberlist metrics.** Examples are `consul_raft_commitTime`,
  `consul_raft_state_*` and `consul_raft_leader_lastContact`; they exist only
  as empty placeholders. This has been confirmed:
  - Consul moved its metric sinks to `hashicorp/go-metrics`
    ([#23635](https://github.com/hashicorp/consul/pull/23635)).
  - The raft, serf and memberlist libraries report through
    `go-metrics/compat`, which only uses the new registry when the binary is
    built with the `hashicorpmetrics` tag.
  - The release builds omit that tag, so those metrics go to a registry with
    no sinks.
  - Upstream: issue [#23812](https://github.com/hashicorp/consul/issues/23812)
    and fix [#23813](https://github.com/hashicorp/consul/pull/23813), both open.

  No config option or sink can work around this. The only fixes are Consul
  **2.0.1+ent** or a release that includes #23813. Metrics Consul emits itself
  are unaffected: `consul_kvs_apply`, `consul_txn_apply`, `consul_fsm_*`,
  `consul_rpc_request`, `consul_server_isLeader` and `consul_autopilot_*`. The
  dashboard therefore uses those:
  - Leaf signing rate comes from `consul_fsm_ca_leaf{op="increment-index"}`.
  - Raft throughput comes from `deriv(consul_raft_last_index)`.
  - Leadership comes from `consul_server_isLeader`.
  - Signing latency comes from the Vault side.

  `consul_rpc_server_call` is also absent, and that is not explained by this
  build issue. Regenerate the dashboard with `python3 scripts/gen-dashboard.py`.
- **Agent leaf cache.** Test 3 leaves every issued leaf in the client agent's
  cache. For very large runs, restart the agent between runs
  (`sudo systemctl restart consul`).

## Security notes (test environment)

- The root token, the Consul management token and every TLS key are in
  Secrets Manager **and in TFC state**. The load generators can read the Vault
  root token and the Consul management token (`operator_token`). Don't reuse
  this setup for production.
- Secrets use `recovery_window_in_days = 0`, and the S3 bucket uses
  `force_destroy`, so `terraform destroy` really cleans up.

## Layout

```
tfc-bootstrap/          TFC project/workspace + license variables (local state)
terraform/              Environment (TFC workspace, working dir)
  templates/            user_data for vault, consul-server, loadgen, monitoring (+ common.sh)
  files/                Grafana dashboard
perf/
  k6/                   consul-leaf.js, vault-sign-consul-mount.js, lib/common.js
  vault-benchmark/      pki_sign profiles (no_store vs store)
  scripts/              run-k6.sh, run-vault-benchmark.sh, stress-k6.sh, signing-distribution.sh,
                        connection-test.sh, consul-ca-limits.sh, run-everywhere.sh, summarise.sh
  tools/vault-sign-load Go load tool using Consul's Vault client (single vs multi connection)
```

## License

[MPL-2.0](LICENSE). Vault Enterprise and Consul Enterprise themselves need their own licenses (see above).
