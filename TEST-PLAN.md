# Test plan: Vault PKI for Consul service mesh leafs

## Overview

| Stage | Test | Question it answers | Time |
|---|---|---|---|
| 0 | Settle | Is the full-size cluster built, verified and quiet? | ~1–1.1 h |
| 1: Vault ceiling | T1 | What's Vault's `no_store` signing ceiling and knee across all 5 nodes? | ~1 h |
| | T3 | What rate can Vault sustain on Consul's own mount and role? | ~1–1.3 h |
| | T3r | Does T3's ceiling reproduce? Repeats at its last pass, midpoint and first fail, giving a range | ~0.7 h |
| | T3c | What can one Consul-style connection carry, compared with many? | ~0.7 h |
| 2: Consul ceiling | T5 | What's Consul's real leaf ceiling (agent → leader → Vault) with CSR limits removed? | ~1–1.3 h |
| | T5r | Does T5's ceiling reproduce? The same boundary repeats | ~0.7 h |
| | T6 | Where does signing land on Vault, directly, through Consul, and after an idle gap? | ~0.5 h |
| | Soak | Does the target rate hold for 2 h at ≥ 99.99% success, with no memory or file descriptor growth? (4 × 30 min segments) | ~2.4 h |
| | Burst | With `csr_max_per_second` set to the target, do 20,000 leafs in 1 minute and 100,000 in 10 minutes arrive? | ~0.3 h |
| | T3f | What do sidecars see when the Vault node Consul signs through hangs? | ~0.25 h |
| | T14 | What do sidecars see when the Consul leader hangs (election plus the new leader's CA setup)? 3 runs | ~0.35 h |
| | T2 | What does storing certificates cost compared with `no_store`? (Runs here, late: it leaves Raft state behind. Signs with a 2-minute TTL so its clean-up can tidy them away.) | ~0.5 h |
| 3: Vault scale-out | T9-V | Do 2 non-voters (redundancy zone spares, performance standbys) raise T3 and T3c? | ~1.5 h |
| | T12 | Under load, how long does a new zone spare take to join, and Autopilot to promote it when its zone's voter hangs? 3 runs, plus 1 in the active node's zone | ~0.8 h |
| | T15 | What does a rolling restart of every Vault node (the routine operation) cost sidecars? | ~0.4 h |
| | T13 | What does rotating Consul's signing CA under load do to sidecars and to client agents that restart? (Root rotation is out of scope.) Runs last: it leaves the signing CA rotated | ~0.5 h |
| *Own campaign* | T11 | What do Vault Raft commit time, leader cost and failover look like at 7, 5 and 3 voters? | ~9–11 h |

The tests run in the order of this table, as one unattended campaign
(`plan-1`, ~13.5–14.5 h). T11 shrinks Vault for good, so it runs as its own
unattended campaign on a fresh 7-voter build (`raft-1`, `--t11`). Moving
between the two campaigns needs a `terraform apply`, so fresh credentials.
`--with-t11` instead appends T11 to `plan-1` as Stage 4 (~21–25 h in one
run; see *Stage 4*).
*Read-out* explains how to interpret the comparisons, and *Results* records
the outcome of each test.

## Quick start

Run everything from your workstation with `scripts/run-campaign.sh`:

```bash
# refresh AWS credentials locally and in the HCP Terraform workspace (README, step 2)
export TF_CLOUD_ORGANIZATION=<your-org>
scripts/run-campaign.sh start plan-1       # Stage 0 rebuild (type "yes" at the plan), wait, verify, start the campaign
scripts/run-campaign.sh status plan-1      # check progress any time (or: follow plan-1)
# ~13.5-14.5 h later, with fresh credentials again:
scripts/run-campaign.sh finish plan-1      # download results to ./results/, then offer terraform destroy

# then T11 on its own build, the same way:
scripts/run-campaign.sh start raft-1 --t11
# ~9-11 h later:
scripts/run-campaign.sh finish raft-1
```

To run both in one unattended campaign instead, start with
`scripts/run-campaign.sh start plan-1 --with-t11` (see *Stage 4* for the
trade-offs).

**What `start` does:**
1. Runs the preflight checks.
2. Removes the smoke profile and makes sure the held non-voters are configured.
3. Runs the Stage 0 `terraform apply`. It replaces every instance and resets
   Vault's bootstrap flag, and it waits for you to confirm the plan.
4. Waits for all nodes to bootstrap, then verifies:
   - 5 Vault voters, with the non-voters held;
   - 5 Consul voters;
   - leaf TTL 168h;
   - root path `pki_mesh_int`;
   - one Autopilot redundancy zone per Vault voter (unless `vault_redundancy_zones = false`).
5. Refreshes `credentials.txt`, and starts `run-plan.sh` on loadgen-0.

**While it runs:** the campaign runs unattended on loadgen-0. Your laptop and
your credentials aren't needed until `finish`.

**Download before destroying.** `finish` downloads the results first, because
`terraform destroy` deletes the S3 bucket too.

The sections below explain each stage and test, and are the manual fallback.

## Goal

Confirm whether Vault and Consul can issue leaf certificates fast enough for
an example mesh, and find where the bottleneck is. The example mesh has **100,000
sidecars on Consul Dataplane**, a **7-day leaf TTL**, and needs 2× growth
headroom. The results set Consul's `csr_max_per_second` (default 50/s, too low
for the targets).

## Targets

See README → *Targets* for how these were sized.

| Target | Value |
|---|---|
| Leaf throughput through Consul | **≥ 350 leafs/s** sustained (a rolling server restart re-issues ~20,000 leafs in ~1 minute, ~333/s) |
| End-to-end leaf p99 at 350/s | **≤ 1 s**, errors < 0.1% |
| Vault sign p99 on Consul's intermediate at 350/s | **≤ 100 ms**, errors < 0.1% |
| Server CPU | Stress steps and boundary repeats: mean CPU over the steady state ≤ 90% on every Vault and Consul server. Soak: ≤ 80% |
| Soak at 350/s for 2 h | ≥ 99.99% success, p99 ≤ 1 s; server memory, Go heap and file descriptors grow ≤ 10% (a warning, not a failure) |
| Guardrails | 0 leader elections, Autopilot failure tolerance 2, Raft leader last contact p99 < 200 ms (T11: tolerance (N−1)/2, so 1 at 3 voters; its failover check is excluded). Checked after every test, and **fail** a stress step or boundary repeat when broken during its steady state |

## Environment

- **Consul Enterprise:** 2.0.1+ent, 5 voters.
- **Vault Enterprise:** 2.1.1+ent, 5 voters (plus 2 non-voters in T9-V).
- **Load and monitoring:** 2 × `r7i.4xlarge` load generators (16 vCPU, 128 GiB: see *T5 rerun*) and 1 × `m7i.xlarge` monitoring node.
- **Base image:** all instances run Ubuntu 24.04 (`ami_owner` / `ami_name_pattern`; Canonical's public image by default).
- **Instance size:** Vault and Consul servers are `m7i.2xlarge`, with gp3 volumes at 6000 IOPS.
- **Mesh PKI:**

```
enterprise root CA (simulated by Terraform) → Vault intermediate (pki_mesh_int) → Consul signing CA (connect_dc1_inter) → leafs
```

Leafs are issued with `no_store`.

**Changing the Vault license on a running cluster:**
1. Update `vault.hclic` and apply `tfc-bootstrap/`; this updates the
   `vault_license` workspace variable.
2. Apply `terraform/`; this updates the config secret that new nodes read.
3. On each node, write the license to `/etc/vault.d/vault.hclic`.
4. Reload the standbys with `systemctl reload vault`, and **restart** the
   active node.

In this environment, a reload (SIGHUP) on the active node hung its HTTP API
until Vault was restarted. The standbys reloaded normally. That's also why
the audit log rotates with `copytruncate` instead of reloading Vault.

## Run timeline and outputs

Every test follows the same timeline. Single runs (`run-k6.sh`,
`run-vault-benchmark.sh`) and `connection-test.sh` run as follows:

```
| baseline 5m idle | warm-up 2m | steady state 10m | cooldown 5m idle | → Grafana export
```

Multi-step tests (`stress-k6.sh`, `connection-test.sh`) are **chained**:
one baseline at the start, then each step back to back, one cooldown at the
end, and one export.

```
| baseline 5m | step 1: warm-up 2m + steady 10m | step 2: warm-up 2m + steady 10m | … | cooldown 5m | → export
```

- **Each step has a 2-minute warm-up, which starts at the previous step's
  rate,** so load doesn't dip between steps.
- **Steps hold 5 minutes until the busiest server's mean CPU reaches 50%,
  then 10 minutes** (`LOW_HOLD`, `FINE_CPU`). In plan-1, steady state arrived
  within 1–4 minutes (T3 at 6,400/s: client p99 7.06 → 7.69 ms over the hold,
  Vault CPU flat from the first minute), so the full hold matters only near
  the ceiling. Fixed-rate grids (`RATES`, T11) hold `HOLD` throughout.
- **p99 and errors come from the steady state only.** k6 runs each step as two
  scenarios, `warmup` and `steady`, and the pass criteria apply to `steady`.
- **Each step's windows become their own export phases**
  (`steady-r200`, `steady-w64`, …). `stats.md` compares each step with the
  idle baseline and cooldown.
- **Annotations** mark every step.
- **Every test starts with a 5-minute idle baseline and ends with a 5-minute
  idle cooldown.** Runs inside one test (boundary repeats, bursts, T12's
  repeats) are separated by 1 minute of cooldown plus 1 minute of baseline
  (`GROUP_GAP`), so each still has its own idle reference.

Each test's windows, and why some differ:

| Test | Baseline / cooldown | Warm-up | Steady state | Why it differs |
|---|---|---|---|---|
| T1, T2 | 5m / 5m | 2m per level | 10m per level | — |
| T3, T5 (stress) | 5m / 5m | 2m per step, from the previous rate | 5m below 50% server CPU, then 10m | Steady state arrives within 1–4 minutes; the full hold matters near the ceiling |
| T3r, T5r (3 runs) | 5m first / 5m last, 1m between | 2m | 10m | — |
| T3c (×2 in T9-V) | 5m / 5m | 15s per step | 60s per step | Compares connection modes, not sustained capacity |
| T6 (4 runs) | 1m / 1m per run | 30s | 2m | Answers *where* signing lands; the gap between runs is the test (> 90 s idle) |
| Soak (4 segments) | 5m first / 5m last, 1m between | 2m per segment | 4 × 30m | Long enough for drift and rare errors; segments keep the load generator's agent cache small (issue #8) |
| Burst (2 runs) | 5m first / 5m last, 1m between | none | 60s, 10m | A burst has no ramp by definition |
| T3f | 5m / 5m | 30s, then 2m steady before the freeze | freeze 60s + 2m after | An event under load, not a capacity measurement |
| T14 | 5m / 5m | 30s, then 90s steady before the first freeze | 3 × (freeze 60s, until healthy, 60s gap) | An event under load |
| T9-V T3 rerun | 5m / 5m | 2m per step | 10m every step | Starts at T3's last pass, already near the ceiling |
| T12 (3 + 1 runs) | 5m first / 5m last, 1m between | 30s, then 60s steady before the join | join ~1–2m, freeze until promoted + 30s | An event under load |
| T15 | 5m / 5m | 30s, then 2m steady before the first restart | per node: until healthy, then 60s | An event under load |
| T13 | 5m / 5m | the cache fill (~5m at 350/s), then 60s of foreground | signing CA 5m, then the agent check (up to ~5m with server restarts) | An event under load |
| T11, per size | 5m / 5m once per size | 2m per step | 5m | The repeats measure noise; repeat spread in raft-1 was tiny |
| t11smoke | 1m / 1m | 30s | 1m | A check that the measurements work, not a measurement |

**Server-side metrics, per stress step** (in `stress.json`, and at the last
passing rate in RESULTS.md), so the client's latency can be split without
opening Grafana:
- **`server_latency`:** Vault's sign route on Consul's intermediate and every
  Vault request (`vault.core.handle_request`), each as mean and p99. Consul
  2.0.1 exports no sign latency of its own (`consul_rpc_server_call` is
  absent), so for T5 the client's p99 minus Vault's sign p99 is Consul plus
  the network;
- **`vault_storage`:** Raft log appends including fsync
  (`vault.raft.boltdb.storeLogs`), BoltDB write transactions, the slowest
  Vault disk's write latency, and `/opt/vault/data` size and growth.

Every test also records Raft data size and growth (RESULTS.md's *Raft data*
column), which shows what each test leaves behind (T2's stored
certificates, for example). The failure tests (T3f, T12, T15) poll the NLB's
view of the affected node every 2 s. Metric names that don't exist in this
Vault or Consul version come back as null rather than failing the step.

Each run produces:

- **A Grafana export** from `loadgen-0` of all dashboard panels (PNGs,
  `metrics.csv`, per-phase `stats.md`).
- **Annotations** on the dashboard, marking the run.
- **Results** in `/opt/perf/results/` and in
  `s3://<perf_bucket>/results/<RUN_ID>-…/`.

After each test, run `summarise.sh <RUN_ID>` for one Markdown/CSV report in
milliseconds.

## Where commands run

The commands below run on **loadgen-0** as the `ubuntu` user, unless marked
*workstation*:

```bash
# workstation
aws ssm start-session --region ap-southeast-2 --target $(terraform -chdir=terraform output -json loadgen_instance_ids | jq -r '.[0]')
# on the load generator
sudo su - ubuntu
sync-assets.sh          # pull the latest scripts from S3 (after any terraform apply)
```

## Automated run (recommended)

After the Stage 0 apply, the whole campaign runs unattended from a single
command. It needs no further `terraform apply`, and it doesn't depend on your
credentials: the runner uses the instances' own IAM roles.

```bash
# 1. workstation: Stage 0 step 1 (full size + held non-voters), one apply
# 2. loadgen-0, as ubuntu:
run-plan.sh start plan-1          # settle → T1 → T3 → T3r → T3c → T5 → T5r → T6 → soak → burst → T3f → T2 → T9-V → T12 (~11.5–12.5 h)
run-plan.sh status plan-1         # progress, last log lines, RESULTS.md
run-plan.sh stop plan-1           # stop; Consul CSR limits are restored
# 3. workstation, when it's finished: terraform destroy (the runner can't)
```

- **settle** replaces the manual Stage 0 settle check:
  1. It runs any due apt jobs on every node now, and waits for the dpkg locks
     to clear.
  2. It **waits for security scans to finish**, up to 60 minutes
     (`SETTLE_SCANNER_WAIT`). See *Security scanner* below.
  3. It idles 10 minutes.
  4. It checks Prometheus that the last 5 minutes were quiet (the busiest
     host's CPU under 15%, no leader elections, and no scanner activity),
     retrying up to 3 times.
     If it still isn't quiet, it continues and records a warning in
     `RESULTS.md`.
- **T9-V** starts the **held** Vault non-voters over SSM. They're provisioned
  in Stage 0 with `vault_non_voters_start = false`, so they don't take part in
  T1–T6. The runner waits for them to join Raft as non-voters, lets them
  settle for 5 minutes, then reruns T3 (from T3's last passing rate) and T3c.
  Without held non-voters, T9-V is skipped. `run-plan.sh t9v plan-1` reruns
  it alone.
- **T12** then repeats a zone failure under load (see *T12*). Stage 4 (T11)
  runs only when `PLAN_TESTS` names it (`run-campaign.sh --with-t11`).
- **It survives disconnects** and **resumes:** re-running `start plan-1` skips
  completed tests. From the workstation, `scripts/run-campaign.sh resume plan-1`
  uploads and syncs the latest scripts first (only once the plan has
  stopped), so tests added later run on an existing plan.
- **Decisions between tests are automatic:**
  - T2 uses T1's knee, the last worker level that still added ≥ 10%
    throughput.
  - T3r and T5r repeat each stress test's boundary: one full run each at its
    last pass, the midpoint and its first fail, with the same pass criteria
    as a step. They're skipped if there's no boundary.
  - Consul's CSR limits are removed for T5, T5r, the soak and T3f, set to
    `BURST_CSR_RATE` for the burst test, and always restored.
- **After every test** it checks the guardrails (Consul and Vault leader
  elections, minimum Autopilot failure tolerance), runs `summarise.sh`,
  rewrites `RESULTS.md`, and uploads to `s3://<bucket>/results/<PLAN>-plan/`.
- **Settings default to this plan and can be overridden with env vars:**
  `T1_WORKERS`, `T3_START`/`T3_MAX`, `T5_START`/`T5_MAX`, `T3C_*`, `T6_*`,
  `SOAK_*`, `BURST_*`, `T3F_RATE`, `T12_*`, `SERVER_CPU_MAX`, `FINE_CPU`,
  `FINE_FACTOR`, `LOW_HOLD`,
  `SETTLE_APT`/`SETTLE_IDLE`/`SETTLE_MAX_CPU`, `P99_MS`, `MAX_ERROR_RATE`,
  and the usual `BASELINE`/`COOLDOWN`/`RAMP`/`HOLD`/`WARMUP`/`DURATION`.

The per-test sections below are the reference, and the manual fallback.

### Security scanner

Hardened base images often run a **security or inventory agent** (a
vulnerability scanner, for example). Its process stays resident but only uses
CPU while scanning. The image these tests were developed on had one. The first scan after boot runs for 30 minutes or
more, at 40–55% of a core on a small instance, and further scans follow its
schedule. A scan that lands on a Vault node or the Consul leader during a
steady state skews the results.

- Every node publishes **`perf_scanner_cpu_percent`** (the scanner processes'
  CPU, from `/proc`) and **`perf_scanner_active`** (≥ `scanner_active_cpu`, 5%
  of a core). Set `scanner_pattern` to the agent's process name; empty (the
  default) means no agent, and the metric stays 0.
- The dashboard shows **Security scanner active** per host, with CPU steal and
  I/O wait, in the Hosts row.
- `settle` waits for scans before T1. After every test, the runner records the
  hosts where a scanner ran, and **RESULTS.md flags those tests with 🔍** so
  you can re-run them (`PLAN_TESTS="t3" run-plan.sh start <plan>` after
  removing the test from `state.json`).
- **Pausing scans for the campaign** is cleaner, but that's for the owner of
  the agent's policy to decide.
- **After the Stage 0 rebuild, every node starts its first-boot scan at the
  same time.** On the smoke instances that took 30–40+ minutes, so settle can
  add up to about an hour before T1. It's unattended, so it costs time but
  needs nobody.

---

## Stage 0: Switch to full size and settle (~1–1.1 h)

1. **Remove the smoke profile, provision the held T9-V non-voters, and rebuild
   every instance** (*workstation*). Vault re-initialises, so reset the
   bootstrap flag and keep the init secret:
   ```bash
   rm terraform/smoke.auto.tfvars
   printf 'vault_non_voter_count  = 2\nvault_non_voters_start = false\n' > terraform/campaign.auto.tfvars
   export TF_CLOUD_ORGANIZATION=<your-org>
   cd terraform
   bash -c 'args=(); for n in 0 1 2 3 4; do args+=("-replace=aws_instance.vault[\"vault-$n\"]" "-replace=aws_instance.consul[\"consul-$n\"]"); done
            args+=("-replace=aws_instance.loadgen[0]" "-replace=aws_instance.monitoring[0]" "-replace=aws_ssm_parameter.vault_bootstrap")
            terraform plan "${args[@]}" && terraform apply "${args[@]}"'
   ```
   This also creates `loadgen-1` and the held non-voters `vault-nv-0` and
   `vault-nv-1`. Those have Vault installed but stopped: they aren't in Raft
   and show unhealthy on the NLB until T9-V starts them.

2. **Check the full-size cluster, once every node has finished bootstrapping (~3 min):**
   - `vault operator raft list-peers` on a Vault node shows 5 voters.
   - `consul operator raft list-peers` on a Consul server shows 5 voters.
   - `consul connect ca get-config` shows `LeafCertTTL: 168h` and
     `RootPKIPath: pki_mesh_int`.
   - Grafana shows every target `up`.
   - `./scripts/get-credentials.sh` (*workstation*) refreshes `credentials.txt`.

3. **Sanity run:**
   ```bash
   RUN_ID=s0 RATE=20 BASELINE=1m COOLDOWN=1m RAMP=30s HOLD=2m run-k6.sh /opt/perf/k6/consul-leaf.js
   summarise.sh s0
   ```
   Pass when there are 0 errors, the export has all panels, and the summary
   includes p99.

4. **Settle (~15–20 min) before T1.** `run-plan.sh` does this automatically
   (its `settle` step). The manual equivalent is below. A freshly built cluster isn't quiet yet:
   - after a rebuild, CPU and Vault sign p99 spike for 1–2 minutes;
   - on a fresh Ubuntu boot, `apt-daily` and `unattended-upgrades` often run
     within the first hour, using CPU and disk (the Consul and Vault packages
     are held, but the jobs still run);
   - the first read of each block on a root volume restored from the AMI
     snapshot is slower.

   Without a settle period, these land in T1's baseline or steady state.

   a. **Check first-boot setup and pending apt jobs on every node**
      (*workstation*):
      ```bash
      cat > /tmp/settle-check.sh <<'EOF'
      lock=$(fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 && echo held || echo free)
      next=$(systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-legend | awk '{print $2, $3, $NF}' | paste -sd ';')
      echo "$(hostname): cloud-init=$(cloud-init status | awk '{print $2}') dpkg-lock=$lock next-apt: $next"
      EOF
      IDS=$(aws ec2 describe-instances --region ap-southeast-2 \
        --filters Name=tag:Project,Values=cvperf Name=instance-state-name,Values=running \
        --query 'Reservations[].Instances[].InstanceId' --output text)
      CID=$(aws ssm send-command --region ap-southeast-2 --instance-ids $IDS --document-name AWS-RunShellScript \
        --parameters "$(jq -n --rawfile c /tmp/settle-check.sh '{commands: [$c]}')" --query Command.CommandId --output text)
      for id in $IDS; do
        aws ssm wait command-executed --region ap-southeast-2 --command-id $CID --instance-id $id 2>/dev/null
        aws ssm get-command-invocation --region ap-southeast-2 --command-id $CID --instance-id $id --query StandardOutputContent --output text
      done
      ```
      Every node should report `cloud-init=done` and `dpkg-lock=free`. If an apt
      timer is due within the next ~2 hours, either let it run now
      (`sudo systemctl start apt-daily.service apt-daily-upgrade.service` on
      every node, then wait for `dpkg-lock=free`), or, **only if policy allows**,
      stop the timers for the campaign
      (`sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer`) and start
      them again afterwards.

   b. **Leave the cluster idle for 10 minutes**, then confirm on the Grafana
      dashboard (last 15 min):
      - **Hosts:** CPU flat and low on every node, and Disk write IOPS flat.
      - **Leadership & quorum:** 0 leader elections, and Autopilot failure
        tolerance 2 on both clusters.
      - **Consul → Vault TCP connections:** 0, because there's no load.

   Then start T1. Its 5-minute baseline is a clean, known-quiet reference.

## Stage 1: Vault ceiling

### T1: Vault PKI baseline, `no_store` (~1 h)

Measures Vault's signing ceiling across **all 5 nodes**, and the knee (where
latency starts rising faster than throughput). It signs Consul-shaped CSRs
(EC P-256 + SPIFFE URI SAN) on a synthetic mount configured like Consul's:
`pki_perf`, an EC P-256 intermediate with a `leaf-nostore` role mirroring
Consul's `leaf-cert` role (`pki-perf-mount.sh create`).

The load comes from `vault-sign-load` with **32 independent clients** (32
connections), so the NLB spreads it across every Vault node. The result
records `vault_nodes_serving` and the per-node split to prove it, from the
`pki_perf` mount's route metric. In plan-1 that metric matched nothing (every
level reported 0 nodes), so the name is now matched by regex, and
`vault_nodes_busy` (Vault nodes over 10% mean CPU) shows the spread even if it
still doesn't.
vault-benchmark isn't used for T1: it multiplexes every worker over one
HTTP/2 connection, which the NLB pins to a single node. (In the first plan-1
attempt, vault-3 served all of T1.) The single-connection case, which is how
Consul's leader signs, is T3c.

```bash
pki-perf-mount.sh create
MODES=multi LABEL="T1 Vault PKI baseline" CONCURRENCY="32 64 128 256" MULTI_CONNS=32 \
  STEP=10m STEP_WARMUP=2m SIGN_PATH=pki_perf/sign/leaf-nostore SIGN_TOKEN="$VAULT_TOKEN" \
  RUN_ID=t1 connection-test.sh
summarise.sh t1
```

The four concurrency levels are chained, each with a 2-minute warm-up and 10
minutes measured.

**Record:** throughput, p50/p95/p99 and nodes serving per level. The knee is
the concurrency after which throughput stops rising (< 10% more) but p99 keeps
climbing.

### T2: Cost of storing certificates (~0.5 h)

*Runs after T14, not here.* T2 stores about 1.2 million certificates (plan-1:
1,637/s for 12 minutes) and then removes them. Raft's database files never
shrink, so that state would sit under every Vault measurement after it.

**It signs with a 2-minute TTL** (`T2_LEAF_TTL`), so the stored certificates
expire right after the run. The TTL doesn't change what's measured, the cost of
writing each certificate to Raft. That lets the clean-up delete them:
1. it waits for the TTL to pass;
2. it runs a **PKI tidy on the active node directly** (`tidy_cert_store`).
   The tidy runs server-side, so the client can't cancel it, and it only
   deletes expired certificates, hence the short TTL;
3. it unmounts the now near-empty mount.

In plan-1 a plain unmount through the NLB never finished: every attempt was
redirected, dropped and cancelled, which blocked the campaign for 4 h 20 min
(issue #10). The clean-up now shows its errors and gives up after 60 minutes
(`CLEANUP_DEADLINE`). A clean-up failure is recorded in `values.t2.cleanup`,
and RESULTS.md shows it as "done (clean-up failed: …)": T2's measurement is
already saved by then.

Measures what `no_store` saves. Stored certificates are Raft writes, which
performance standbys forward to the active node.

```bash
MODES=multi LABEL="T2 store" CONCURRENCY=<T1 knee> MULTI_CONNS=32 STEP=10m STEP_WARMUP=2m \
  SIGN_PATH=pki_perf/sign/leaf-store SIGN_TOKEN="$VAULT_TOKEN" LEAF_TTL=2m RUN_ID=t2 connection-test.sh
STORED_TTL=2m pki-perf-mount.sh destroy   # wait out the TTL, tidy, unmount
summarise.sh t2
```

**Compare with T1** at the same concurrency: throughput, p99, Vault Raft
commit time and active-node CPU.

### T3: Vault cluster capacity on Consul's mount (~1–1.3 h)

A stress test of `connect_dc1_inter/sign/leaf-cert`, the role Consul created.
It uses many connections and a token with Consul's `consul-connect-ca` policy.
The rate starts at the 350/s target and doubles each step, then rises ×1.5 once the
busiest server's mean CPU reaches 50% (doubling is too coarse near the
ceiling). Steps hold 5 minutes below that, then 10. A step fails when, over
its steady state:
- p99 exceeds 100 ms, or errors exceed 0.1%;
- less than 95% of the planned rate is delivered. k6 stops the step as soon
  as that's certain, and marks it **VU-starved**: every k6 worker was busy, so
  its latency is the load generator's queue. VU-starved steps stay in
  `stress.json` but out of latency tables;
- a Vault or Consul server's mean CPU exceeds 90% (`SERVER_CPU_MAX`);
- a guardrail breaks: a Consul or Vault leader election, or Autopilot failure
  tolerance below 2.

```bash
RUN_ID=t3 stress-k6.sh /opt/perf/k6/vault-sign-consul-mount.js
summarise.sh t3
```

**Record:** from `t3-loadgen-0-stress-vault-sign-consul-mount/stress.json`:
- `last_pass_rate` and the knee;
- the busiest host for each step;
- `sign_nodes`, which should show all Vault nodes serving.

If `loadgen-0` is the busiest host, rerun on both load generators
(*workstation*):

```bash
RUN_ID=t3b ./perf/scripts/run-everywhere.sh "stress-k6.sh /opt/perf/k6/vault-sign-consul-mount.js" <loadgen-0-id> <loadgen-1-id>
```

### T3c: Single vs multiple connections (~0.7 h)

Measures what **one** Consul-style HTTP/2 connection can carry, compared with
many. It uses Consul 2.0.1's own Vault client and sweeps concurrency
`1 8 32 64 128 256 512`, with 16 clients in multi mode.

```bash
RUN_ID=t3c connection-test.sh
summarise.sh t3c
```

**Record:** from `connection-test.json`:
- `single_max` and `multi_max`, and the ratio between them. Both are the best
  step **within the target** (no errors, p99 ≤ 100 ms), and `single_max` must
  use exactly one connection. At high concurrency Go's HTTP/2 client opens
  more: plan-1's raw single-mode maximum, 4,045/s, used 3 connections, 3
  Vault nodes and had p99 153 ms. The honest figure was 2,048/s at
  concurrency 64 (p99 63 ms). `single_max_any` and `multi_max_any` keep the
  raw maxima for reference;
- in single mode, whether a second connection or node appears at high
  concurrency.

## Stage 2: Consul ceiling

### T5: Consul leaf path, CSR limits removed (~1–1.3 h)

Measures Consul's real ceiling on the path agent → Consul leader → Vault. The
rate starts at the 350/s target (plan-1's steps below it only showed a flat line)
and steps like T3, with the agent restarted between steps to clear its leaf
cache. It stops on the same criteria as T3, with p99 over 1 s instead of
100 ms.

**Expect a single Vault node's CPU to set this ceiling.** Consul's leader signs
through one connection, so one Vault node: at 3,200/s that node ran at
98.7–99% in both plan-1 and plan-2. With the 90% CPU rule, T5's last pass
will likely move to 1,600/s. Each step records the Consul
leader's connections to Vault (`consul_vault_connections_max`) and how signing
is spread across Vault nodes.

```bash
consul-ca-limits.sh              # note the current limits (default 50/s, 0 concurrent)
consul-ca-limits.sh 0 0          # remove them so the ceiling found is the system's, not the limiter's
RUN_ID=t5 stress-k6.sh /opt/perf/k6/consul-leaf.js
consul-ca-limits.sh 50 0         # restore
summarise.sh t5
```

**Record:**
- `last_pass_rate` and the knee;
- the busiest host for each step (Consul leader, Vault node, or load
  generator);
- `consul_vault_connections_max` and `sign_nodes`;
- `loadgen_min_mem_pct`, the load generator's lowest free memory.

**Load generator memory.** The client agent caches every leaf it fetches,
about 12 KB each, and every request uses a new service name. One 12-minute
step at 6,400/s needs about 55 GB. In plan-1, the 32 GiB `c7i.4xlarge` load
generator ran out at 6,400/s, went dark for 28 minutes and set off a Consul
leader election, so T5's 6,400/s failure and T5r's 4,800/s failure measured
the load generator, not Consul. Now:
- The load generators are `r7i.4xlarge`: the same 16 vCPUs with 128 GiB.
- The agent is restarted before the first step as well as between steps.
- `run-k6.sh` stops k6 if free memory drops below 10% (`MEM_GUARD_PCT`) and
  exits 98. The step is recorded as **invalid**, neither a pass nor a fail,
  and the stress stops there. `RESULTS.md` shows it as "invalid: load
  generator out of memory".

### T5 rerun (after plan-1)

Reruns only T5 and T5r on a fresh environment, from 800/s, to find Consul's
real limit above plan-1's 3,200/s (*workstation*):

```bash
# refresh AWS credentials locally and in the HCP Terraform workspace (README, step 2)
PLAN_TESTS="settle t5 t5r" T5_START=800 scripts/run-campaign.sh start plan-2
scripts/run-campaign.sh follow plan-2
scripts/run-campaign.sh finish plan-2
```

`start` rebuilds every node (Stage 0), so this needs the full environment,
not just monitoring. Steps: 800, 1,600, 3,200, 6,400 and 12,800/s, about 12
minutes each, until one fails or is invalid. Then T5r at the midpoint of the
last pass and first fail. About 1 h for Stage 0 plus 1.5–2 h for settle, T5
and T5r.

### T6: Signing distribution (~0.5 h)

Shows where signing lands on Vault in four runs:
1. a direct-client control run;
2. a run through Consul;
3. an idle gap of more than 90 s;
4. another run through Consul.

The script removes Consul's CSR limits for its runs and restores them when it
finishes.

```bash
RUN_ID=t6 RATE=100 BASELINE=1m COOLDOWN=1m RAMP=30s HOLD=2m signing-distribution.sh
```

The runs are shortened on purpose. T6 answers *where* signing lands (its
placement across Vault nodes, and a node change after the idle gap), not
performance, so a 2-minute hold gives the same verdict. The idle gap between
the Consul runs is still well over 90 s: 1 minute of cooldown, the 150 s
`IDLE`, and 1 minute of baseline.

**Record:** from `distribution.json`:
- `expected_behaviour`: `confirmed`, `refuted` or `inconclusive`;
- each run's verdict and nodes serving;
- `busiest_node_changed_after_idle`.

### T3r and T5r: Boundary repeats (~0.7 h each)

Each runs straight after its stress test. A single stress run doesn't support
a `csr_max_per_second` recommendation: at the same 1,600/s, T5's p99 was
176 ms in plan-1 and 35 ms in plan-2. So each repeats the stress test's
boundary with one full run (2-minute warm-up, 10-minute hold) at:
- its last passing rate;
- the midpoint between that and the first failing rate;
- its first failing rate.

They use the same pass criteria as a stress step. The ceiling is then a
**range**:
- **confirmed:** the highest repeated rate that passed, with every repeated
  rate below it passing too;
- **failed_at:** the lowest rate that failed, in the stress test or a repeat.
  A stress failure that passes on repeat counts as noise.

If the stress test's last pass fails on repeat, RESULTS.md says it wasn't
reproduced. Manual equivalent, per rate:

```bash
RUN_ID=t3r-r<rate> RATE=<rate> BASELINE=1m COOLDOWN=1m run-k6.sh /opt/perf/k6/vault-sign-consul-mount.js
consul-ca-limits.sh 0 0
RUN_ID=t5r-r<rate> RATE=<rate> BASELINE=1m COOLDOWN=1m run-k6.sh /opt/perf/k6/consul-leaf.js
consul-ca-limits.sh 50 0
```

### Soak: the target rate for 2 hours (~2.4 h)

The stress steps hold each rate for 10 minutes. That's long enough to find a
ceiling, but too short to show slow memory growth or rare errors. The soak
runs the **350/s target through Consul** (`consul-leaf.js`, CSR limits removed
like T5) for **2 hours** on the 5 voters, before T9-V adds the non-voters.

**It runs as 4 segments of 30 minutes** (`SOAK_SEGMENT`), with the load
generator's Consul agent restarted before each. The agent caches every leaf it
fetches. In plan-1's single 2-hour run, from about 600,000 cached leafs (28
minutes in) it stalled every 5 minutes, and each stall was worse than the last.
That took the client p99 to 9.2 s while the servers sat idle: 0 errors in 2.48
million leafs and no growth (issue #8). Real agents, and Dataplane's servers,
hold far fewer leafs. The Vault and Consul servers don't restart between
segments, so growth, CPU and server-side latency are measured over the whole
2 hours. RESULTS.md also records the agent's largest cache
(`consul_leaf_certs_entries_count`).

It **fails** on:
- errors ≥ 0.01% over the whole soak, so success must be ≥ 99.99%;
- p99 over 1 s in any segment;
- less than 95% delivered in any segment;
- a Vault or Consul server's mean CPU over 80%.

It **warns** in RESULTS.md when, between the hold's first and last 15 minutes,
any Vault or Consul server grows by more than 10%:
- host memory used;
- Go heap (`vault_runtime_alloc_bytes`, `consul_runtime_alloc_bytes`);
- allocated file descriptors (`node_filefd_allocated`).

These are warnings, not failures: a heap that grows and then levels off is
normal, so read the Grafana memory panels before calling it a leak.

```bash
consul-ca-limits.sh 0 0
for i in 1 2 3 4; do
  sudo systemctl restart consul   # a fresh agent cache per segment
  RUN_ID=soak-s$i RATE=350 HOLD=30m MAX_ERROR_RATE=0.0001 run-k6.sh /opt/perf/k6/consul-leaf.js
done
consul-ca-limits.sh 50 0
```

Change it with `SOAK_RATE`, `SOAK_HOLD`, `SOAK_SEGMENT`, `SOAK_MAX_ERROR_RATE`,
`SOAK_CPU_MAX` and `SOAK_DRIFT_PCT`.

**For a stronger leak check,** run a long soak as its own plan, for example
`PLAN_TESTS="settle soak" SOAK_HOLD=10h scripts/run-campaign.sh start soak-1`
(~12 h, ~US$110). Note that this soak's leaf cache lives on the load
generator's agent. With Consul Dataplane, Consul servers hold it, so server
memory at 100,000–200,000 cached leafs isn't measured here.

### Burst: the target bursts with the CSR limit set (~0.3 h)

The 350/s target was sized for bursts: a rolling Consul server restart
re-issues about 20,000 sidecars' leafs in about a minute (README *Targets*). Every other test runs at a constant
rate with Consul's CSR limit removed. This one sets `csr_max_per_second` to
the value being recommended (`BURST_CSR_RATE`, default the 350/s target) and
sends, through Consul:
- **20,000 leafs in 60 s** (334/s): a rolling server restart;
- **100,000 leafs in 10 minutes** (167/s): the whole mesh.

Each run records leafs issued, failed, rate-limited
(`consul_csr_rate_limited`), p50, p99 and max. It passes on errors < 0.1% and
p99 ≤ 1 s. If the limiter's refusals reach the client as errors instead of
being retried by the agent, it fails, which is a finding about the limit
rather than a test bug. Change it with `BURST_CSR_RATE` and `BURST_SPECS`
(`<rate>:<duration> ...`).

```bash
consul-ca-limits.sh 350 0
RUN_ID=burst-r334 RATE=334 RAMP=0 HOLD=60s run-k6.sh /opt/perf/k6/consul-leaf.js
RUN_ID=burst-r167 RATE=167 RAMP=0 HOLD=10m run-k6.sh /opt/perf/k6/consul-leaf.js
consul-ca-limits.sh 50 0
```

### T3f: The Vault node Consul signs through hangs (~0.25 h)

Consul's leader signs through one connection, so one Vault node (T3c, T6).
This is the failure sidecars actually see, and DBS's "failover under load" on
the leaf path. Under 350/s of leafs through Consul (`T3F_RATE`, CSR limits
removed), `consul-vault-failover.sh`:
1. finds the Vault node Consul signs through: the most signs on Consul's
   intermediate over the last minute. It records whether that node is active;
2. freezes it with `SIGSTOP` for 60 s, then `SIGCONT`. If it's the active node,
   Vault also elects a new one;
3. waits for Autopilot to be healthy, then keeps the load 2 more minutes.

It records, over the freeze plus 60 s:
- **max_gap_s:** the longest time with no leaf issued at all;
- **failed_leafs** and **error_window_s** (first to last failure; k6's leaf
  timeout is 60 s);
- **recovered_s:** the end of the last disrupted 5-second window (any failure,
  or under 90% of the rate succeeding);
- **signer_after:** which Vault node signed most in the minute after the
  freeze. Did Consul move to another node, or wait for the frozen one?

```bash
consul-ca-limits.sh 0 0
RUN_ID=t3f RATE=350 consul-vault-failover.sh
consul-ca-limits.sh 50 0
```

T3f also polls the NLB's view of the frozen node every 2 s (`nlb.out_s`,
`nlb.back_s`): requests keep reaching it until the NLB's health checks (every
10 s, unhealthy after 2) take it out, so this shows how much of the gap is the
NLB rather than Vault or Consul.

### T14: The Consul leader hangs (~0.35 h)

The other half of T3f. Every CSR is signed on the Consul leader, through its
Vault CA provider. A new leader has to set up its own provider (Vault login,
connection) before it signs anything, so leafs may stall for longer than the
election. Under 350/s of leafs through Consul (`T14_RATE`, CSR limits removed),
`consul-leader-failover.sh` freezes the Consul leader with `SIGSTOP` for 60 s,
3 times (`T14_REPEATS`; election timing is random), and records per repeat:
- **new_leader_s:** until another server leads (polled every 0.5 s);
- **max_gap_s:** the longest time with no leaf issued;
- **first_leaf_after_leader_s:** from the new leader to the first leaf after the
  gap. That's the cost of the new leader's CA setup;
- **failed_leafs** and **recovered_s**, as in T3f.

RESULTS.md gives the median and range over the repeats.

```bash
consul-ca-limits.sh 0 0
RUN_ID=t14 RATE=350 REPEATS=3 consul-leader-failover.sh
consul-ca-limits.sh 50 0
```

## Stage 3: Vault scale-out

### T9-V: Start 2 Vault non-voters, repeat T3 and T3c (~1.6 h)

`run-plan.sh` runs this automatically at the end, starting the held
non-voters from Stage 0. The manual steps are below, for a cluster
provisioned without them.

Shows whether performance standbys add `no_store` signing capacity for clients
with many connections, and confirms that the single Consul-style connection
still uses only one node.

1. **Add the non-voters** (*workstation*). This only creates `vault-nv-0` and
   `vault-nv-1`:
   ```bash
   echo 'vault_non_voter_count = 2' > terraform/scale.auto.tfvars
   terraform -chdir=terraform apply
   ```
2. **Wait for them to join as non-voters.** `vault operator raft list-peers`
   should show 5 voters and 2 non-voters, and Grafana should show 7 Vault
   targets.
3. **Rerun T3 and T3c:**
   ```bash
   sync-assets.sh
   RUN_ID=t9-t3 START=<T3 last_pass_rate> stress-k6.sh /opt/perf/k6/vault-sign-consul-mount.js; summarise.sh t9-t3
   RUN_ID=t9-t3c connection-test.sh; summarise.sh t9-t3c
   ```

Starting at T3's last passing rate skips the steps below it, which T3 already
measured. The question here is whether the ceiling moves up.

**Compare:**
- t9-t3 against t3: `last_pass_rate`, and `sign_nodes`, which should be 7.
- t9-t3c against t3c: `multi_max` should rise, and `single_max` should stay flat
  on one node.

### T12: Redundancy zone spares under load (~0.8 h)

The HLD's design: **Autopilot redundancy zones**, starting with 5 voters and
no non-voters, then adding non-voters as scale demands. Autopilot keeps
**one voter per zone**. A non-voter added to a zone that already has a voter
stays a non-voter (a spare, serving as a performance standby) until that
voter fails. Then Autopilot promotes it. So there are two times to measure:
how long a new spare takes to join, and how long promotion takes when it's
needed.

**The build matches that design** (`vault_redundancy_zones = true`, the
default): `vault-0`…`vault-4` are in `zone-0`…`zone-4`, one voter each, and
the held `vault-nv-0` and `vault-nv-1` join `zone-0` and `zone-1` as spares.
They set `autopilot_redundancy_zone`, **not** `retry_join_as_non_voter`, which
would make them permanent non-voters that Autopilot never promotes.
`run-campaign.sh` checks for 5 zones at the start, which also checks that the
license allows redundancy zones.

Under a constant signing load on Consul's mount, at half T3's last passing
rate (`T12_RATE`), `vault-zone-test.sh` picks a zone with a spare whose voter
isn't the active node, then:

1. **Join.** It re-adds the spare from scratch, the way a spare is added for
   scale: stop, `remove-peer`, empty its Raft data, start. It records:
   - **joined:** time until the spare appears in Autopilot's server list;
   - **healthy:** time until Autopilot reports it healthy;
   - its status 60 s later, which should still be non-voter.
2. **Zone failure.** It freezes the zone's voter with `SIGSTOP`: a hung node,
   unplanned, like T11's failover check. It records:
   - **unhealthy:** time until Autopilot marks the voter unhealthy;
   - **promoted:** time until the spare is a voter;
   - **demoted:** time until the frozen voter is a non-voter;
   - **restored:** time until failure tolerance is back to 2.

   It thaws the voter 30 s after that, or after 5 minutes (`T12_FREEZE_MAX`)
   if promotion never happens, and then records when Autopilot is healthy
   again and where the old voter ended up.

Times are polled every second, from the active node directly, so a poll never
hangs on the frozen node. For each phase, k6's per-request samples give the
client's view:
- failed requests;
- the error window, from the first failure to the last;
- the longest gap between successful requests.

Requests the NLB sends to the frozen node hang until k6's 30 s timeout, so the
error window includes the NLB health checks.

**Repeats.** One sample can't show the spread of two 10-second Autopilot timers
plus 1-second polling, so T12 runs **3 times** (`T12_REPEATS`), alternating
zones, each re-adding a spare and freezing a voter. RESULTS.md gives the
median and range of join, promotion, recovery and failed requests. Then
**one more run in the active node's zone** (`MODE=active`), where the freeze
also forces an election: the realistic worst case. T12's guardrails cover the
3 standby runs only, since the active run elects a new leader on purpose. If
the active node's zone has no spare, that run is skipped.

**Zones aren't AZs here.** Nodes are placed in subnets by index, so
`vault-nv-0` is in a different AZ from `zone-0`'s voter, `vault-0`. T12 tests
Autopilot's zone mechanism, not losing an AZ, where a zone's voter and spare
would fail together. Whether DBS's zones map to AZs decides which of those
matters.

**Promotion isn't instant by design.** Autopilot waits until the voter has been
out of contact for longer than `last_contact_threshold`, and the spare must have
been healthy for `server_stabilization_time` (both 10 s by default). If
`promoted` is missing, the spare was never promoted within 5 minutes. That's
a finding, not a test bug: check the Autopilot configuration.

```bash
RUN_ID=t12-1 RATE=<T3 last pass / 2> vault-zone-test.sh               # repeat 1
RUN_ID=t12-2 RATE=<...> EXCLUDE_ZONE=<zone of repeat 1> vault-zone-test.sh
RUN_ID=t12-active RATE=<...> MODE=active vault-zone-test.sh
```

T12 is skipped on a build without zones. Nothing after it depends on the
zones' original layout.

### T15: Rolling restart of Vault under load (~0.4 h)

The routine, planned operation (patching, config changes, the shape of an
upgrade), and the planned counterpart to T3f and T12. Under 350/s of leafs
through Consul (`T15_RATE`, CSR limits removed), `vault-rolling-restart.sh`
restarts every Vault node in Raft with `systemctl restart vault`, one at a
time, the active node last (a graceful restart: it steps down first). After
each, it waits for Autopilot to be healthy with failure tolerance restored,
then 60 s. Per node it records:
- **healthy_s:** restart to healthy;
- **max_gap_s** and **failed_leafs** for the sidecars;
- **signer_before / signer_after:** did restarting the node Consul signs
  through move Consul's connection?
- **nlb:** when the NLB stopped and resumed sending it requests.

With redundancy zones, a restart that outlasts Autopilot's thresholds can
promote the zone's spare, so the layout before and after is recorded. Runs
after T12, with the spares in the cluster, as production would be.

```bash
consul-ca-limits.sh 0 0
RUN_ID=t15 RATE=350 vault-rolling-restart.sh
consul-ca-limits.sh 50 0
```

### T13: Signing CA rotation under load (~0.5 h)

Consul renews its signing CA, the intermediate that signs leafs, on its own at
half its TTL, and operators rotate it by changing `IntermediatePKIPath`. T13
checks what that does to sidecars and to client agents. It runs **last**,
because it leaves the signing CA rotated.

**Root rotation is out of scope.** Consul's root here is a Vault intermediate
under the enterprise root CA, so replacing it belongs to that CA's lifecycle.
In plan-1 it also turned out that Consul can't rotate an externally signed root
in this design: Vault refuses the cross-sign (issue #12, closed as out of
scope). Only a root change forces every leaf to be re-issued. The load of a full
re-issue is covered by the burst test: 100,000 leafs in 10 minutes at the
350/s limit.

Under a constant 50/s of new leafs (`T13_RATE`: new sidecars keep arriving),
with the CSR limit set to the recommended 350/s, `ca-rotation-test.sh`:
1. **fills the local agent's cache with 100,000 leafs** (`T13_CACHED`), at
   350/s. The agent keeps them fresh, as Dataplane's servers would for their
   proxies;
2. **rotates the signing CA:** mounts `connect_<dc>_next_inter`, lets Consul's
   policy use it, and points `IntermediatePKIPath` at it. Consul creates a new
   signing CA under the same root. It watches 5 minutes: did signing continue,
   and were cached leafs re-issued? In plan-1, signing switched in 15 s and
   **0 of 100,000** were re-issued. Existing leafs still verify against the old
   signing CA and move to the new one at their normal renewal;
3. **checks a client agent (issue #11):** in plan-1, after the rotation, a
   restarted client agent's `auto_encrypt` certificate, now signed by the new
   signing CA, was rejected by every server (`tls: unknown certificate
   authority`). T13 restarts the local agent and records whether it reconnects
   within 90 s (`AGENT_WAIT`). If it's locked out, it restarts the Consul
   servers one at a time, followers first and the leader last, each until
   Autopilot is healthy, which was the workaround in plan-1. Then it restarts
   the agent again and records how long it takes to reconnect.

It records: when signing moved to the new CA, leafs re-issued (Vault's signs
on Consul's intermediates minus the foreground's), the new leafs' failures,
p99 and longest gap during the rotation, and the agent check: locked out or
not, how long the server restarts took, and reconnect time after them.

```bash
RUN_ID=t13 CACHED=100000 CSR_LIMIT=350 RATE=50 ca-rotation-test.sh
```

`ROTATIONS="signing root"` (`T13_PHASES` in `run-plan.sh`) also runs the root rotation, kept for reference only.
It needs a next mesh intermediate in `<name>/vault/mesh-ca-next`, which the
build no longer creates, and in this design Vault refuses its cross-sign.

## Stage 4: Vault Raft latency vs voter count

**T11 normally runs as its own campaign** on a fresh 7-voter build
(`run-campaign.sh start raft-1 --t11`, ~9–11 h). That campaign is unattended
too; moving between the two needs a `terraform apply`, so fresh credentials.
Running T11 on its own:
- gives a clean 7-voter baseline, without Stages 1–3's history;
- lets each campaign be rerun without the other, which matters because the
  shrink is one-way: a T11 failure late in a combined run means a rebuild;
- lets the two run in parallel if they're in separate environments.

**Stage 4 runs T11 on the main build instead,** for one unattended run
(`run-campaign.sh start plan-1 --with-t11`, ~21–25 h in all). It converts T9-V's
spares to voters (T11 grow), then runs T11 as below.

### T11 grow: Convert the non-voters to voters (~0.2 h)

T11 needs 7 voters and no non-voters. After T9-V and T12, the main build has
5 voters and 2 non-voters. Usually those are `vault-nv-0` and `vault-nv-1`, but
after T12 one of them may be the frozen voter, now a spare. `t11grow` turns
whichever running nodes aren't voters into voters with
`vault-raft-voters.sh convert`. On each one, over SSM, it:

1. stops Vault (`systemctl disable --now vault`), then runs
   `vault operator raft remove-peer`;
2. empties the Raft data directory, `/opt/vault/data`;
3. sets `retry_join_as_non_voter = false` in `/etc/vault.d/vault.hcl` and,
   with redundancy zones, gives the node a zone of its own (`t11-<node>`), so
   Autopilot can make it a voter;
4. starts Vault. Each node rejoins Raft as a non-voter, and Autopilot
   promotes it once it has been healthy for `server_stabilization_time`
   (10 s by default);
5. waits for Autopilot to report 7 healthy voters, failure tolerance 3, then
   idles 2 minutes.

Nodes are placed in subnets by index, so the 7 voters are spread 3/2/2 across
the AZs, the same as a 7-voter build.

**Promotion timing comes for free.** While the nodes start, `convert` polls
`list-peers` every second and records, per node:
- **joined:** time from the start command until the node appears in Raft;
- **promoted:** time until it's a voter;
- **join to promotion:** the difference, which is mostly Autopilot's
  stabilization time.

These go in `state.json` (`values.t11grow`) and the t11grow row of RESULTS.md.
The times start before the SSM command, so they include its delivery and the
data wipe, about 1–2 s.

The EC2 `Voter` tags don't change. `shrink` removes `vault-nv-*` first, so T11
at 5 voters runs on `vault-0`…`vault-4`, the same nodes as Stages 1–3.
If `t11grow` fails, `t11smoke` and `t11v*` refuse to run, and the results from
Stages 0–3 aren't affected.

**Compared with a fresh 7-voter build** (`--t11`): these voters have run
Stages 1–3 first. Every T11 size writes to its own new KV mount, and
`t11smoke` runs before the long runs. Even so, compare commit times with
raft-1's only with that difference in mind.

### T11: Vault Raft commit time, leader cost and failover at 7, 5 and 3 voters (~7.7–10.7 h; ~9–11 h as its own campaign)

Measures what each extra pair of voters costs on every Vault write. It looks
at the mechanism as well as the end result:
- **Fan-out:** the leader sends every entry to N−1 followers, so its network and
  CPU work per write should scale about 2 : 4 : 6.
- **Quorum:** the leader waits for the 1st, 2nd or 3rd fastest follower ack.
- **Saturation:** because of the fan-out, a bigger cluster's commit time should
  bend upward at a lower rate.

`no_store` signing never writes to Raft, so T11 drives Raft with write
workloads:

- **KV v2 writes** (`vault-kv-write.js`): 1 KiB values on a fresh KV v2 mount
  per size (`kv_perf_t11v7`, …; `max_versions=1`, keys cycled over 10,000, so
  the data set stays the same size). Every write goes through Raft on the active node (standbys forward
  it), so this isolates Raft. The smoke check records Raft applies per write.
  - **The same rate grid at every size:** 200, 400, 600, 800, 1,000, 1,200
    and 1,600/s. In raft-1, every size saturated at 1,600/s (delivered 0.60,
    p99 27 s), so 2,400–12,800/s were never reached, and 800 → 1,600 was too
    coarse to separate the sizes. The grid stops at the first failing rate.
  - **It stops at saturation, not at T3's 100 ms.** A step fails on
    p99 > 1 s (`T11_KV_P99_MS`), errors ≥ 0.1%, < 95% delivered (VU-starved,
    left out of the latency tables), or a guardrail break (failure tolerance
    below (N−1)/2). T3's 100 ms
    is Vault's *signing* target; KV writes have no target, and KV v2 on 7
    voters was already about 130 ms p99 at 200/s in the smoke check. With
    100 ms the grid would stop at its first step.
  - **Run twice** (`T11_KV_REPEATS=2`), to measure run-to-run noise. A difference
    between sizes counts only when it's larger than the spread between repeats.
- **Payload sweep:** 16 KiB and 32 KiB values at 400/s (1 KiB at 400/s is the
  grid step), **run twice** like the grid, so every payload comparison has a
  noise estimate. Bigger entries multiply what the leader sends to each follower,
  so this is where commit latency is most likely to separate by size. Keys cycle
  over 200, so the large values add only a few MB per size.
  - **Not 64 KiB:** in raft-1, 84% of 64 KiB writes failed in all six runs, and
    fast (p50 56 ms), so the step measured errors, not latency. The cause
    wasn't recorded. `vault-kv-write.js` now logs the first failures' status
    and body, so a failing payload run shows why.
- **No stored-certificate signing.** T2 already measures the cost of storing
  certificates. In T11, deleting the stored certificates between sizes took
  about 15 minutes per 18,000 and, when a delete was cancelled, hung the active
  node's API.

- **Failover** (`vault-failover-test.sh`): under 20 KV writes/s, it freezes the
  active node with `SIGSTOP` for 60 s, then `SIGCONT`: a hung or crashed
  leader that comes back. This repeats **5 times** (`T11_FAILOVER_REPEATS`),
  because election timing is random: in raft-1, 3 repeats at 5 voters spread
  7.9–14.6 s, wider than the gap between the sizes' medians. Compare the
  sizes' ranges, not just their medians. It records:
  - **new active:** time until another voter answers `/v1/sys/health` as active.
    In the raft-1 run, followers detected the frozen leader after 5–7 s and a
    new node was active after 8–11 s. The 60 s freeze leaves ample room;
  - **write gap:** the longest time with no successful write, from k6's
    per-request samples;
  - **failed writes:** requests the NLB sent to the frozen node time out after 10 s.
  - **leadership logs:** after each repeat, every voter's Vault log for the
    failover window (journald, fetched over SSM) goes to
    `logs/repeat-<i>/<node>.log`. A merged `timeline.log` puts every node's
    leadership lines in one sequence, timed from the freeze. It breaks the
    failover into stages:
    - **detected:** the first heartbeat timeout;
    - **elected:** the election is won;
    - **active:** the new active node's post-unseal setup is complete;
    - **old step-down:** the frozen node steps down after `SIGCONT`.

Every step records:
- Vault `commitTime`: the mean from `_sum`/`_count`, and p50/p99 from the
  leader's quantiles;
- Raft applies/s and leader last contact p99;
- the client p50/p99;
- **leader cost:** the active node's network bytes sent and CPU per write,
  from node_exporter.

**Leader placement is recorded, not controlled.** The leader doesn't move
within a size until the failover check, so each size has one placement.
RESULTS.md shows the leader, its AZ and how many voters share that AZ (the acks
it can get without crossing AZs), so you can see whether placement could explain
a latency difference. Pinning the leader to one AZ wouldn't make the sizes
equal anyway: it would share that AZ with 0, 1 or 2 other voters.

**One build, shrunk in place.** T11 needs 7 voters (3/2/2 over the three AZs).
In the main campaign, `t11grow` provides them. As its own campaign, T11
needs a Stage 0 with **`vault_voter_count = 7`**. Each size starts by
shrinking Vault with `vault-raft-voters.sh shrink <N>`, which:

1. picks a voter from the AZ with the most voters, never the active node, so the
   layout matches a fresh build of that size (5 = 2/2/1, 3 = 1/1/1);
2. stops Vault on it over SSM (`systemctl disable --now vault`), then runs
   `vault operator raft remove-peer`;
3. waits for Autopilot to report healthy with failure tolerance (N−1)/2.

Each size writes to a fresh, empty KV mount of its own, so every size starts
from the same data. Earlier sizes' mounts are left in place (idle, about 25 MB
each) rather than unmounted: an unmount deletes every key through Raft, which
is slow, and a cancelled one hung the active node in testing. After a shrink it idles 2 minutes while the NLB health
checks and Autopilot catch up. Then it runs one **chained** timeline, like T3
and T5:

```
| baseline 5m | KV grid ×2 | payload 16K, 32K ×2 | failover ~13m | cooldown 5m | → one export
```

- **Every step keeps the plan's 2-minute warm-up.** It absorbs carry-over, and
  T11 has the riskiest handovers: from the failing last step of one KV run
  into the next run's 200/s, and from 32 KiB writes into the failover's load.
- **Every step holds 5 minutes, not the plan's 10.** The repeats, not longer
  holds, measure the noise, and at these rates even 5 minutes puts tens of
  thousands of writes behind every p99. When you compare a T11 step with T3 at
  the same rate, remember that T3's p99 covers twice as long a window. With
  `T11_HOLD=10m`, the campaign takes about 15 h.
- **One Grafana export per size,** like a chained stress test. The individual
  runs skip their own export (which would leave unloaded gaps mid-timeline),
  and `t11_export` exports the whole size once. Its phases are named
  `steady-kv1-r200`, `steady-kv16384b1-r400`, `failover-1`
  and so on.

Each part's warm-up absorbs any carry-over from the part before. A size takes
about 2.4–3.4 h, depending on where the grid stops: each step is 7 min plus a
short pause for the metrics scrape, and there are up to 24 steps.
T11's guardrails cover the time from the resize to the start of the failover
check, which elects new leaders on purpose. They expect failure tolerance
(N−1)/2, so 3 voters passes at 1.

The shrink is **one-way**: a removed node keeps its old Raft data. To go back
to 7 voters, rebuild. That's why T11 is the last stage, and nothing may run
after it. It refuses to run with Vault non-voters in Raft, so in the main
campaign it runs only after `t11grow` has converted them.

**As its own campaign,** run it like the main campaign, from your workstation:

```bash
# refresh AWS credentials locally and in the HCP Terraform workspace (README, step 2)
export TF_CLOUD_ORGANIZATION=<your-org>
scripts/run-campaign.sh start raft-1 --t11   # build (type "yes" at the plan), wait, verify, start
scripts/run-campaign.sh status raft-1        # any time (or: follow raft-1)
# ~9-11 h later, with fresh credentials again:
scripts/run-campaign.sh finish raft-1        # download results, then offer terraform destroy
```

`--t11` does the following:
1. Writes `terraform/raft.auto.tfvars`: 7 Vault voters, no non-voters (it
   overrides `campaign.auto.tfvars`).
2. Builds the environment. With nothing in state it creates everything;
   otherwise it replaces every instance, like the main campaign.
3. Verifies 7 Vault voters, 0 non-voters and 5 Consul voters.
4. Starts `settle → t11smoke → t11v7 → t11v5 → t11v3` unattended on loadgen-0.

`finish` removes the profile after the destroy, and a `start` without `--t11`
removes it too, so the next build is the 5-voter plan again.

**`t11smoke` (~15 min) runs first and protects the long run.** It's a short
T11 at 7 voters, with no shrink: 1-minute holds, two KV rates, one 16 KiB run,
and one failover. Then it checks what T11 depends on:
- **Hard checks:** Autopilot's `Healthy` and `FailureTolerance`, that the
  writes succeed and reach Raft (applies/s at least 25% of the write rate:
  Vault batches concurrent writes, about 0.7 applies per KV v2 write at
  200/s), the
  leader's placement, Raft commit time, leader cost per write, and failover timing. If
  any is missing, the smoke check fails and `t11v*` refuse to run, so a broken
  measurement costs about 1.5 h instead of 9–11 h. Fix it, then
  `scripts/run-campaign.sh resume raft-1`.
- **Soft checks**, recorded as warnings in RESULTS.md: the `vault_raft_apply`
  metric, the failover stages from the logs, and millisecond write-gap timing.

`run-plan.sh` runs Stage 4 (`t11grow`, `t11smoke`, `t11v*`) only when
`PLAN_TESTS` names it. `--t11` sets `PLAN_TESTS` to
`settle t11smoke t11v7 t11v5 t11v3`, and `--with-t11` to the main tests plus
Stage 4. To
tune it, set `T11_KV_RATES`, `T11_KV_REPEATS`, `T11_PAYLOADS`,
`T11_PAYLOAD_RATE`, `T11_RAMP`, `T11_HOLD`, `T11_KV_P99_MS`,
`T11_RESIZE_SETTLE`, `T11_FAILOVER_REPEATS` and `T11_FREEZE`. Manual equivalent for one size, on loadgen-0:

```bash
vault-raft-voters.sh status                 # voters, leader, AZ spread, failure tolerance
vault-raft-voters.sh shrink 5
export KV_MOUNT=kv_perf_t11v5; kv-perf-mount.sh create
export RAMP=2m HOLD=5m P99_MS=1000
G="200 400 600 800 1000 1200 1600"
RUN_ID=t11v5-kv1 RATES="$G" COOLDOWN=0 stress-k6.sh /opt/perf/k6/vault-kv-write.js
RUN_ID=t11v5-kv2 RATES="$G" BASELINE=0 COOLDOWN=0 stress-k6.sh /opt/perf/k6/vault-kv-write.js
for r in 1 2; do for b in 16384 32768; do
  RUN_ID=t11v5-kv${b}b$r RATES=400 VALUE_BYTES=$b KEYS=200 BASELINE=0 COOLDOWN=0 \
    stress-k6.sh /opt/perf/k6/vault-kv-write.js
done; done
REPEATS=5 BASELINE=0 RUN_ID=t11v5-failover vault-failover-test.sh
```

(Run by hand, each command exports its own Grafana window. `run-plan.sh` makes
one export per size instead. Use the manual steps only as a fallback, like the
main campaign's per-test sections.)

**Record:** `RESULTS.md` has a T11 section with the leader's placement per
size, then four tables. Each column is a voter count:
1. **Commit time,** per grid rate: commit mean and p99, and client p99. Each
   value is the mean of the repeats ± half their range.
2. **Leader cost per write,** per grid rate: KB sent, CPU ms, and the ratio to
   the 3-voter value. Expect about 2× at 5 voters and 3× at 7.
3. **Payload sweep:** commit time, client p99 and KB per write at 1, 16 and
   32 KiB (mean of the repeats ± half their range).
4. **Failover:** new active and write gap (median / max), failed writes, and
   the stages from the logs.

**How to read it:**
- **Leader cost (2)** is the mechanism. If KB/write scales with N−1, the extra
  voters are doing the work you'd expect.
- **Commit time (1, 3)** shows whether that work turns into latency. Look at the
  high rates and the large payloads.
- **Count a difference only when it's bigger than the ± spread.** Check the
  leader placement before blaming the voter count.

---

## Read-out

| Comparison | If… | Then… |
|---|---|---|
| T5 vs T3c single | T5 ≈ single-connection ceiling | The single connection (one Vault node) is Consul's bottleneck |
| T5 vs T3c single | T5 well below single | The Consul leader is the bottleneck (RPC, Raft, CPU) |
| T3c single vs T3 / T3c multi | Single ≪ multi | Vault's scale-out doesn't reach the Consul path |
| T9-V vs T3 / T3c | Multi rises, single flat | Non-voters help direct clients only |
| T5 vs targets | T5 ≥ 350/s within p99 ≤ 1 s | `csr_max_per_second` can be raised to the target |
| Burst vs targets | 20,000 in 60 s and 100,000 in 10 min arrive, p99 ≤ 1 s, with the limit set | The recommended limit absorbs the sized bursts |
| T13 signing CA rotation | No re-issue, no new-leaf failures | Signing CA rotation is safe for sidecars |
| T13 agent check | Restarted agent locked out until the servers restart | After a signing CA rotation, restart the Consul servers before any client agent restarts (issue #11) |
| T14 vs T3f | Consul leader gap ≫ Vault node gap | The Consul leader's CA setup, not Vault, dominates recovery |
| T3f | Long gap, Consul waits for the frozen node | A hung Vault node stalls every sidecar's renewal until it recovers: weigh this in Vault health checks and timeouts |
| T12 promotion vs T11 failover | Promotion ≈ Autopilot's two 10 s timers | Zone spares restore failure tolerance in about 20 s; a longer or missing promotion points at the Autopilot configuration |
| T11 7 vs 5 vs 3 voters | Commit time and KV ceiling flat | Voter count is free for Vault writes: choose it for failure tolerance |
| T11 7 vs 5 vs 3 voters | Commit p99 rises with voters | Each voter pair costs that much on every write: weigh it against the extra failure tolerance |
| T11 failover | Write gap differs by voter count | Election time depends on cluster size; otherwise it's the heartbeat/election timeout, whatever the size |

The **recommended `csr_max_per_second`** is the lower of Consul's confirmed
ceiling from T5r (the low end of its range) and Vault's single-connection rate
from T3c (`single_max`, one connection, within 100 ms), confirmed by the burst
test with that limit set. The report should also state the headroom above
350/s, and how long a full re-issue of 100,000 leafs takes at that limit
(about 5 minutes at 350/s; the burst test covers that load).

## Results

| Test | RUN_ID | Result | p99 | Bottleneck / notes |
|---|---|---|---|---|
| T1 32 / 64 / 128 / 256 concurrency | t1 | | | |
| T2 store | t2 | | | |
| T3 Vault cluster | t3 | last pass: | | |
| T3c single / multi | t3c | single: / multi: | | |
| T5 Consul path | t5 | last pass: | | |
| T6 distribution | t6 | expected_behaviour: | | |
| T3 / T5 boundary repeats | t3r / t5r | ceiling range: / | | |
| Soak, 350/s for 2 h | soak | success: ; growth: | | |
| Burst, CSR limit set | burst | 12k/60 s: ; 60k/10 min: | | rate-limited: |
| T3f, Consul's Vault node frozen | t3f | max gap: ; failed: ; recovered: | | moved: ; NLB out/back: |
| T14, Consul leader frozen (×3) | t14 | new leader: ; max gap: ; first leaf after: | | failed: |
| T9-V Vault + 2 non-voters | t9-t3 / t9-t3c | | | |
| T12 zone spare: join / promotion under load (3 + active) | t12 | healthy (median, range): ; promoted: ; restored: | | failed requests: ; NLB out/back: |
| T15 Vault rolling restart | t15 | failed leafs: ; max gap: ; slowest healthy: | | NLB out/back: |
| T13 signing CA rotation, 100,000 cached | t13 | switched: ; re-issued: | new-leaf p99: | agent: locked out? ; reconnected after server restart: |
| T11 grow: non-voter → voter | t11grow | joined: / ; promoted: / | | |
| T11 Vault Raft 7 / 5 / 3 voters | t11v7 / t11v5 / t11v3 | KV last pass: / / ; write gap: / / | commit p99: / / | |

## Time and cost

| Stage | Time |
|---|---|
| Stage 0 (incl. settle) | ~1–1.1 h |
| Stage 1: T1, T3 (adaptive steps), T3r, T3c | ~3.4–3.7 h |
| Stage 2: T5 (adaptive, from 350/s), T5r, T6, soak, burst, T3f, T14, T2 | ~5.8–6.1 h |
| Stage 3: T9-V, T12 (3 runs + active zone), T15, T13 | ~3.2 h |
| **Main campaign** (`plan-1`) | **~13.5–14.5 h (~US$125–145 at ~US$9–10/h)** |
| T11 as its own campaign (`raft-1 --t11`): Stage 0, smoke check, T11 at 7, 5, 3 voters | ~9–11 h (~US$85–105) |
| *Or Stage 4 on the main build* (`--with-t11`): T11 grow, smoke check, T11 | *+7.7–10.7 h, ~21–25 h in one run* |

Against the previous plan (~10–11 h without Stage 4), the boundary repeats
(+1.4 h), burst, T3f, T14, T15, T13, T12 repeats and 5 failover repeats add
time; 5-minute holds below the knee, starting at the target and the T11 grid
without unreachable rates take some back. Every number behind the
`csr_max_per_second` recommendation now has at least two samples.

Stage 4 needs no extra instances: it reuses T9-V's two nodes. The nodes it
shrinks away keep running, and billing, until the destroy. Chaining the
multi-step tests saves about 4 h compared with running every step with its
own idle windows and export.

## Not in this plan

- **Consul Dataplane load tool** (issue #1): server-side key generation and
  cold-start/server-restart bursts, and Consul server memory with the leaf
  cache on the servers (100,000–200,000 leafs).
- **Planned failover** (`vault operator step-down`): an unplanned hang is the
  harder case and is covered by T3f, T11, T12 and T14; T15 covers planned
  restarts.
- **Root CA rotation:** the root is the enterprise root CA's, and its lifecycle
  sits with that CA. In this design Consul can't rotate an externally signed
  root anyway (issue #12, closed).
- **Full Vault outage and recovery backlog** (issue #2).
- **Audit device cost, and audit metrics per step** (issue #3).
- **Raft snapshots under load** (issue #4).
- **Network degradation between the Consul leader and Vault** (issue #5).
- **Go runtime metrics and Consul CA expiry gauges** (issue #6).
- **Leaf correctness under load:** SPIFFE SAN, TTL, chain (issue #7).
- **Performance Replication lag** to a secondary cluster (DBS's plan): this
  build is one cluster in one region.
- **T5 with non-voters:** would measure, not infer, that non-voters don't raise
  Consul's ceiling.
- **Agent-based burst and renewal tests (T7, T8).**
- **Consul read replicas (T10).**
