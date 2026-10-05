# Test plan: Vault PKI for Consul service mesh leafs

## Quick start

Run everything from your workstation with `scripts/run-campaign.sh`:

```bash
# refresh AWS credentials locally and in the HCP Terraform workspace (README, step 2)
export TF_CLOUD_ORGANIZATION=<your-org>
scripts/run-campaign.sh start plan-1       # Stage 0 rebuild (type "yes" at the plan), wait, verify, start the campaign
scripts/run-campaign.sh status plan-1      # check progress any time (or: follow plan-1)
# ~9-10 h later, with fresh credentials again:
scripts/run-campaign.sh finish plan-1      # download results to ./results/, then offer terraform destroy
```

The separate T11 campaign (Vault Raft latency at 7, 5 and 3 voters) runs the
same way with `--t11`: `scripts/run-campaign.sh start raft-1 --t11` (see T11).

**What `start` does:**
1. Runs the preflight checks.
2. Removes the smoke profile and makes sure the held non-voters are configured.
3. Runs the Stage 0 `terraform apply`. It replaces every instance and resets
   Vault's bootstrap flag, and it waits for you to confirm the plan.
4. Waits for all nodes to bootstrap, then verifies:
   - 5 Vault voters, with the non-voters held;
   - 5 Consul voters;
   - leaf TTL 168h;
   - root path `pki_mesh_int`.
5. Refreshes `credentials.txt`, and starts `run-plan.sh` on loadgen-0.

**While it runs:** the campaign runs unattended on loadgen-0. Your laptop and
your credentials aren't needed until `finish`.

**Download before destroying.** `finish` downloads the results first, because
`terraform destroy` deletes the S3 bucket too.

The sections below explain each stage and test, and are the manual fallback.

## Goal

Confirm whether Vault and Consul can issue leaf certificates fast enough for
an example mesh, and find where the bottleneck is. The example mesh has **60,000
sidecars on Consul Dataplane**, a **7-day leaf TTL**, and needs 2× growth
headroom. The results set Consul's `csr_max_per_second` (default 50/s, too low
for the targets).

## Targets

See README → *Targets* for how these were sized.

| Target | Value |
|---|---|
| Leaf throughput through Consul | **≥ 200 leafs/s** sustained |
| End-to-end leaf p99 at 200/s | **≤ 1 s**, errors < 0.1% |
| Vault sign p99 on Consul's intermediate at 200/s | **≤ 100 ms**, errors < 0.1% |
| Guardrails | 0 leader elections, Autopilot failure tolerance 2, Raft leader last contact p99 < 200 ms (T11: tolerance (N−1)/2, so 1 at 3 voters; its failover check is excluded) |

## Environment

- **Consul Enterprise:** 2.0.1+ent, 5 voters.
- **Vault Enterprise:** 2.1.1+ent, 5 voters (plus 2 non-voters in T9-V).
- **Load and monitoring:** 2 × `r7i.4xlarge` load generators (16 vCPU, 128 GiB: see *T5 rerun*) and 1 × `m7i.xlarge` monitoring node.
- **Base image:** all instances run Ubuntu 24.04 (`ami_owner` / `ami_name_pattern`; Canonical's public image by default).
- **Instance size:** Vault and Consul servers are `m7i.2xlarge`, with gp3 volumes at 6000 IOPS.
- **Mesh PKI:**

```
offline root → Vault intermediate (pki_mesh_int) → Consul signing CA (connect_dc1_inter) → leafs
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

- **Each step keeps its full 2-minute warm-up and 10-minute steady state.**
  The warm-up absorbs any carry-over from the previous step.
- **Each step's windows become their own export phases**
  (`steady-r200`, `steady-w64`, …). `stats.md` compares each step with the
  idle baseline and cooldown.
- **Annotations** mark every step.
- **Exceptions:**
  - **T3c** uses 15 s + 60 s steps, because it compares connection modes and
    doesn't measure steady-state capacity.
  - **T6** uses 30 s + 2 min runs with 1-minute idles, because it answers
    *where* signing lands.
  - **T11** keeps the 2-minute warm-up but holds 5 minutes, and repeats its
    runs to measure noise instead (see T11).

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
run-plan.sh start plan-1          # settle → T1 → T2 → T3 → T3c → T5 → T6 → T3r → T5r → T9-V (~8–9 h)
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
- **It survives disconnects** and **resumes:** re-running `start plan-1` skips
  completed tests. From the workstation, `scripts/run-campaign.sh resume plan-1`
  uploads and syncs the latest scripts first (only once the plan has
  stopped), so tests added later run on an existing plan.
- **Decisions between tests are automatic:**
  - T2 uses T1's knee, the last worker level that still added ≥ 10%
    throughput.
  - The refinements use the midpoint between each stress test's last pass and
    first fail. They pass only if the thresholds pass and ≥ 95% was delivered,
    and they're skipped if there's no boundary.
  - Consul's CSR limits are removed for T5 and T5r and always restored.
- **After every test** it checks the guardrails (Consul and Vault leader
  elections, minimum Autopilot failure tolerance), runs `summarise.sh`,
  rewrites `RESULTS.md`, and uploads to `s3://<bucket>/results/<PLAN>-plan/`.
- **Settings default to this plan and can be overridden with env vars:**
  `T1_WORKERS`, `T3_START`/`T3_MAX`, `T5_START`/`T5_MAX`, `T3C_*`, `T6_*`,
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
records `vault_nodes_serving` and the per-node split to prove it.
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

### T2: Cost of storing certificates (~0.4 h)

Measures what `no_store` saves. Stored certificates are Raft writes, which
performance standbys forward to the active node.

```bash
MODES=multi LABEL="T2 store" CONCURRENCY=<T1 knee> MULTI_CONNS=32 STEP=10m STEP_WARMUP=2m \
  SIGN_PATH=pki_perf/sign/leaf-store SIGN_TOKEN="$VAULT_TOKEN" RUN_ID=t2 connection-test.sh
pki-perf-mount.sh destroy   # drop the stored certificates before T3
summarise.sh t2
```

**Compare with T1** at the same concurrency: throughput, p99, Vault Raft
commit time and active-node CPU.

### T3: Vault cluster capacity on Consul's mount (~0.9–1.3 h)

A stress test of `connect_dc1_inter/sign/leaf-cert`, the role Consul created.
It uses many connections and a token with Consul's `consul-connect-ca` policy.
The rate starts at 200/s and doubles each step until p99 exceeds 100 ms,
errors exceed 0.1%, or less than 95% of the planned rate is delivered. The
steps are chained, at about 12 minutes each.

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
- `single_max` and `multi_max`, and the ratio between them;
- in single mode, whether a second connection or node appears at high
  concurrency.

## Stage 2: Consul ceiling

### T5: Consul leaf path, CSR limits removed (~0.9–1.3 h)

Measures Consul's real ceiling on the path agent → Consul leader → Vault. The
rate starts at 50/s and doubles each step (chained, about 12 minutes per step,
plus the agent restart that clears its leaf cache). Each step records the Consul
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

### Refinement runs (~0.5 h)

The stress tests double the rate at each step, so a ceiling is only known to
within a factor of 2. Run one steady run between each test's last passing and
first failing rate:

```bash
RUN_ID=t3r RATE=<between T3 pass/fail> run-k6.sh /opt/perf/k6/vault-sign-consul-mount.js; summarise.sh t3r
consul-ca-limits.sh 0 0
RUN_ID=t5r RATE=<between T5 pass/fail> run-k6.sh /opt/perf/k6/consul-leaf.js; summarise.sh t5r
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

## Separate campaign: Vault Raft latency vs voter count

### T11: Vault Raft commit time, leader cost and failover at 7, 5 and 3 voters (~9–11 h incl. Stage 0)

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
  - **License:** T11 needs a Vault license without the `pki-only` module. A
    PKI-only license refuses `kv` mounts ("mounts of type kv are not supported
    by license"), and `t11smoke` fails on its writes-reach-Raft check.
  - **The same rate grid at every size:** 200, 400, 800, 1,600, 2,400, 3,200,
    4,800, 6,400, 9,600 and 12,800/s. That's T3's rates up to its 12,800/s
    maximum, plus midpoints near saturation. The grid stops at the first
    failing rate, so unreached rates cost nothing.
  - **It stops at saturation, not at T3's 100 ms.** A step fails on
    p99 > 1 s (`T11_KV_P99_MS`), errors ≥ 0.1% or < 95% delivered. T3's 100 ms
    is Vault's *signing* target; KV writes have no target, and KV v2 on 7
    voters was already about 130 ms p99 at 200/s in the smoke check. With
    100 ms the grid would stop at its first step.
  - **Run twice** (`T11_KV_REPEATS=2`), to measure run-to-run noise. A difference
    between sizes counts only when it's larger than the spread between repeats.
- **Payload sweep:** 16 KiB and 64 KiB values at 400/s (1 KiB at 400/s is the
  grid step), **run twice** like the grid, so every payload comparison has a
  noise estimate. Bigger entries multiply what the leader sends to each follower,
  so this is where commit latency is most likely to separate by size. 64 KiB at
  400/s writes about 26 MB/s, well under the volume's 250 MB/s. Keys cycle over
  200, so the large values add only about 13 MB per size.
- **No stored-certificate signing.** T2 already measures the cost of storing
  certificates. In T11, deleting the stored certificates between sizes took
  about 15 minutes per 18,000 and, when a delete was cancelled, hung the active
  node's API.

- **Failover** (`vault-failover-test.sh`): under 20 KV writes/s, it freezes the
  active node with `SIGSTOP` for 60 s, then `SIGCONT`: a hung or crashed
  leader that comes back. This repeats 3 times, because election timing is
  random. It records:
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

**One build, shrunk in place.** T11 needs its own Stage 0 with
**`vault_voter_count = 7`** (3/2/2 over the three AZs). Each size starts by
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
| baseline 5m | KV grid ×2 | payload 16K, 64K ×2 | failover ~8m | cooldown 5m | → one export
```

- **Every step keeps the plan's 2-minute warm-up.** It absorbs carry-over, and
  T11 has the riskiest handovers: from the failing last step of one KV run
  into the next run's 200/s, and from 64 KiB writes into the failover's load.
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
to 7 voters, rebuild. Run T11 on its own build, never before other tests. It
refuses to run with Vault non-voters in Raft, so don't combine it with T9-V.

**Run it like the main campaign,** from your workstation:

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

T11 is opt-in: `run-plan.sh` only runs `t11smoke` and `t11v*` when `PLAN_TESTS`
names them (`--t11` sets it). To
tune it, set `T11_KV_RATES`, `T11_KV_REPEATS`, `T11_PAYLOADS`,
`T11_PAYLOAD_RATE`, `T11_RAMP`, `T11_HOLD`, `T11_KV_P99_MS`,
`T11_RESIZE_SETTLE`, `T11_FAILOVER_REPEATS` and `T11_FREEZE`. Manual equivalent for one size, on loadgen-0:

```bash
vault-raft-voters.sh status                 # voters, leader, AZ spread, failure tolerance
vault-raft-voters.sh shrink 5
export KV_MOUNT=kv_perf_t11v5; kv-perf-mount.sh create
export RAMP=2m HOLD=5m P99_MS=1000
G="200 400 800 1600 2400 3200 4800 6400 9600 12800"
RUN_ID=t11v5-kv1 RATES="$G" COOLDOWN=0 stress-k6.sh /opt/perf/k6/vault-kv-write.js
RUN_ID=t11v5-kv2 RATES="$G" BASELINE=0 COOLDOWN=0 stress-k6.sh /opt/perf/k6/vault-kv-write.js
for r in 1 2; do for b in 16384 65536; do
  RUN_ID=t11v5-kv${b}b$r RATES=400 VALUE_BYTES=$b KEYS=200 BASELINE=0 COOLDOWN=0 \
    stress-k6.sh /opt/perf/k6/vault-kv-write.js
done; done
REPEATS=3 BASELINE=0 RUN_ID=t11v5-failover vault-failover-test.sh
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
   64 KiB (mean of the repeats ± half their range).
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
| T5 vs targets | T5 ≥ 200/s within p99 ≤ 1 s | `csr_max_per_second` can be raised to the target |
| T11 7 vs 5 vs 3 voters | Commit time and KV ceiling flat | Voter count is free for Vault writes: choose it for failure tolerance |
| T11 7 vs 5 vs 3 voters | Commit p99 rises with voters | Each voter pair costs that much on every write: weigh it against the extra failure tolerance |
| T11 failover | Write gap differs by voter count | Election time depends on cluster size; otherwise it's the heartbeat/election timeout, whatever the size |

The **recommended `csr_max_per_second`** is the lower of Consul's sustained
rate from T5/t5r and Vault's single-connection rate from T3c, within the
targets. The report should also state the headroom above 200/s.

## Results

| Test | RUN_ID | Result | p99 | Bottleneck / notes |
|---|---|---|---|---|
| T1 32 / 64 / 128 / 256 concurrency | t1 | | | |
| T2 store | t2 | | | |
| T3 Vault cluster | t3 | last pass: | | |
| T3c single / multi | t3c | single: / multi: | | |
| T5 Consul path | t5 | last pass: | | |
| T6 distribution | t6 | expected_behaviour: | | |
| T3 / T5 refined | t3r / t5r | | | |
| T9-V Vault + 2 non-voters | t9-t3 / t9-t3c | | | |
| T11 Vault Raft 7 / 5 / 3 voters | t11v7 / t11v5 / t11v3 | KV last pass: / / ; write gap: / / | commit p99: / / | |

## Time and cost

| Stage | Time |
|---|---|
| Stage 0 (incl. settle) | ~1–1.1 h |
| Stage 1: T1 sweep, T2, T3 (chained), T3c | ~3–3.4 h |
| Stage 2: T5 (chained), T6 (short runs), refinement | ~1.9–2.3 h |
| Stage 3: T9-V (T3 from its last pass, T3c) | ~1.6 h |
| **Total** | **~7.7–8.7 h (~US$75–85 at ~US$9–10/h)** |
| *Separate campaign* (`run-campaign.sh start raft-1 --t11`): Stage 0, T11 smoke check, T11 at 7, 5, 3 voters | *~9–11 h, plus 2 more Vault nodes until the shrink* |

That's about one long working day. Chaining the multi-step tests saves about
4 h compared with running every step with its own idle windows and export. No
step loses warm-up or steady-state time.

## Not in this plan

- **Consul Dataplane load tool** (issue #1): server-side key generation and
  cold-start/server-restart bursts.
- **T5 with non-voters:** would measure, not infer, that non-voters don't raise
  Consul's ceiling.
- **Pinned-node failover (T3f).**
- **Agent-based burst and renewal tests (T7, T8).**
- **Consul read replicas (T10).**
