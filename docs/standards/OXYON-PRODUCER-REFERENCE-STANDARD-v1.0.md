# Oxyon Producer Reference Standard v1.0

| | |
|---|---|
| **Version** | 1.0 (draft) |
| **Date** | 2026-10-10 |
| **Status** | Draft for review. Not yet published. |
| **Applies to** | XL1 block producers run with `@xyo-network/xl1-cli` 5.6.x in Docker, on Mainnet or Sequence |
| **Maintainer** | Oxyon (LewSales), independent community project |

> **This is a community reference, not an official XYO standard.** It is written and maintained independently. It is not affiliated with, endorsed by, or supported by XYO Network. The compliance levels below are Oxyon-defined reference levels, **not XYO certifications**. Network rules (eligibility, staking, allowlists, protocol behaviour) are set by XYO; where this document and XYO's own documentation disagree, XYO's documentation wins.

---

## Contents

1. [Scope](#1-scope)
2. [The Seven Laws as engineering requirements](#2-the-seven-laws-as-engineering-requirements)
3. [Reference architecture](#3-reference-architecture)
4. [Installation and reproducibility](#4-installation-and-reproducibility)
5. [Configuration provenance](#5-configuration-provenance)
6. [Mainnet and Sequence](#6-mainnet-and-sequence)
7. [Security and secrets](#7-security-and-secrets)
8. [Runtime health and reliability](#8-runtime-health-and-reliability)
9. [Observability and metric definitions](#9-observability-and-metric-definitions)
10. [Performance benchmarking methodology](#10-performance-benchmarking-methodology)
11. [Incident response and recovery](#11-incident-response-and-recovery)
12. [Update and rollback](#12-update-and-rollback)
13. [Evidence and verification](#13-evidence-and-verification)
14. [Compliance levels and checklist](#14-compliance-levels-and-checklist)
15. [Known limitations and future revisions](#15-known-limitations-and-future-revisions)

Appendix A: [Selected configuration of the Oxyon reference nodes](#appendix-a-selected-configuration-of-the-oxyon-reference-nodes)
Appendix B: [Methods](#appendix-b-methods)

Requirement keywords: **MUST** is required for the level it belongs to. **SHOULD** is expected unless you record why not. **MAY** is optional.

---

## 1. Scope

**In scope:**
- operating an XL1 producer container safely;
- configuring it reproducibly;
- observing it truthfully;
- changing it with evidence and a way back.

**Out of scope:**
- XL1 protocol design;
- staking economics;
- choosing which network to join;
- anything that alters candidate construction, submission timing or consensus behaviour.

This standard does not recommend tuning those. If you think one needs changing, raise it upstream (XYO's `xl1-docker-images` tracker) with evidence.

The standard is written so that it outlives its examples. Version numbers, hosts and intervals appear only in [Appendix A](#appendix-a-selected-configuration-of-the-oxyon-reference-nodes), as a dated record of one operator's choices. They are not recommendations for yours.

## 2. The Seven Laws as engineering requirements

Oxyon's [Seven Laws](https://oxyon.io/about/#laws) bind everything Oxyon builds. For producer operations each law becomes a concrete rule:

| Law | Oxyon's wording | What it requires of a producer operator |
|---|---|---|
| 01 | Belief must be earned | Every performance, security and reliability claim cites its evidence: a measurement window, a command, a file. "Fastest" or "best" without a comparable measurement is not allowed. |
| 02 | Nothing comes from nowhere | Record where every configuration value came from (image default, upstream code default, measured, chosen), with versions, hardware and measurement windows. Never publish secrets or infrastructure details that help an attacker. |
| 03 | Trust must be explained | A recommended setting states why, what was measured, what is still unknown, and how to reproduce it. |
| 04 | Behind every record is a person | Collect the least telemetry that does the job. Keep operator identities, addresses and credentials out of public output. Attribute a producer key to a person only with defensible evidence; otherwise it is "unknown". |
| 05 | The mission outlives the methods | Keep configuration modular, versioned and portable. A new CLI version, Docker release or host must not require rewriting the standard. |
| 06 | People remain responsible | Automation may detect and recommend. Any automation that changes production (updates, reboots, restarts) is a documented, operator-approved policy, never a silent default. |
| 07 | Solve causes, not symptoms | Find the cause before you optimise. Don't hide a problem behind a green dashboard, and don't tune speculatively to chase share. |

## 3. Reference architecture

```
                 ┌──────────────── host ────────────────────────────────┐
 XYO RPC / REST  │  producer container (upstream image, pinned version) │
 EVM RPC  ◀──────┼─ outbound HTTPS only                                 │
                 │    presets (bind-mounted, read-only, from git)       │
                 │    secrets (env file, never in git)                  │
                 │    health :9099 ─► published to 127.0.0.1 only       │
                 │                                                      │
                 │  collector (timer) ─► status/trend files (bounded)   │
                 │  dashboard ─► reads files + loopback health          │
                 │  alerter   ─► reads the same files                   │
                 └──────────────┬───────────────────────────────────────┘
                                │ push (scheduled), never pull-on-visit
                                ▼
                     public status data (projection: no host identity)
```

Principles:

1. **The producer is never in the observability path.** Collectors read the producer's loopback health and statistics endpoints and the chain. Dashboards read the collectors' files. A dashboard visitor causes no request to the producer and no RPC call.
2. **Federated producer, no local chain store.** The producer role presets bind viewers to the network (RPC/REST). Binding a viewer to a local store makes the node quietly follow a private chain. Only `BlockRunner` and `BlockValidationViewer` use `memory`, as upstream ships them.
3. **Outbound only.** In the producer roles described here, the producer needs no inbound port. *Evidence:* on the reference nodes, nothing inside the producer container listens on anything except the health/statistics ports, and producers without any published peer port produce normally on both networks (Appendix A).
4. **One container per (key, network) pair.** Two keys on two networks means four containers, not four keys.

## 4. Installation and reproducibility

An operator who has never spoken to us MUST be able to go from a clean host to a verified producer using only the repository:

| Step | Requirement | Verification |
|---|---|---|
| 4.1 | Build or pull the image with an **explicit** CLI version and Node version (no `latest`) | `docker image inspect` shows the version labels; the CLI reports the expected version inside the container |
| 4.2 | Record the image ID or digest you run | It appears in your provenance record (§5) |
| 4.3 | Copy each `*.env.template` to `*.env` and fill it in locally | `git status` shows no `.env` files; the repo's config test passes |
| 4.4 | Use the role presets from the repository, mounted read-only | The effective preset inside the container equals the file in git (compare hashes or values) |
| 4.5 | Start the producer and wait for health | `/livez`, `/readyz`, `/healthz` return 200 |
| 4.6 | **Verify on chain, not in logs** | Within your network's expected window, blocks signed by your producer address appear in the finalized chain. A "published" log line means *submitted*, not *accepted* |
| 4.7 | Run the repository's offline tests | All pass (they read files only, so they are safe on a producing host) |

**Reproducibility test.** The standard is only met if a third party can complete 4.1 to 4.7 from the documentation alone. Record who tried and what they had to ask (see §14, B-12).

## 5. Configuration provenance

Every value that affects production MUST carry its origin. Use these categories:

| Origin | Meaning | Example |
|---|---|---|
| **upstream-image** | As shipped in XYO's image presets | `blockProductionCheckInterval: 60000` in the image's `producer.json` |
| **upstream-code** | A default or bound in the CLI source | the CLI code default of 10000; 5000 as `MIN_POLL_INTERVAL_MS` in a stream the producer role does not bind |
| **measured** | Chosen because a comparable measurement supported it | 60000 → 5000 on one node: 0.5–2% → 13.6% share (14 h window, six producers) |
| **selected** | An operator choice, with its reason, not proven optimal | 3000 on the reference nodes (Appendix A) |

The provenance record for a node lists the following, with no secrets and no addresses beyond the public producer address:
- CLI version and Node version;
- image ID or digest;
- host class (CPU, RAM, storage type, network medium);
- network and role;
- each non-default preset value with its origin;
- the date it took effect;
- the evidence link.

A bind-mounted preset is live configuration. If presets are mounted from a git working tree, **a branch switch changes what the next restart runs.** Keep the selected values committed, and test that they are (the reference repo pins them in `tests/config.test.mjs`).

## 6. Mainnet and Sequence

| Topic | Rule |
|---|---|
| Network selection | Explicit in the env (`XL1_NETWORK`, and the chain ID where the role needs it). Never inferred. |
| Separation | One container per (key, network). Separate env files, separate container names, separate health ports. Health ports for extra containers are published to loopback only. |
| Same key on both networks | Possible (the reference nodes do it). Keep each pair in its own container. Running **the same key twice on the same network** is untested here: don't. |
| Eligibility | Set by XYO (stake, allowlist). A green health check does **not** mean the producer is eligible or producing. Only finalized blocks prove production (§9). |
| Comparisons | Never compare share across networks. Producer sets, block times and rules differ. |
| Role choice | `producer-rest` reads the chain from REST and keeps only mempool submission on RPC; `producer` reads everything over RPC. Both role presets SHOULD carry identical actor timing, so switching role changes the data path, not the cadence. |

## 7. Security and secrets

| ID | Requirement |
|---|---|
| S-1 | Secrets (recovery phrase, keys, RPC credentials) live only in env files on the host, readable by the operator account. Never in git, images, logs, dashboards or tickets. |
| S-2 | Git ignores `*.env` **and** `*.env.*` (backups such as `x.env.bak` are the same secret), with `!*.env.template`. A test proves it, including for files present on disk. |
| S-3 | Templates contain placeholders only. A test rejects values shaped like a private key or a recovery phrase. |
| S-4 | Anyone in the `docker` group can read container env with `docker inspect`. Treat docker access as secret access. |
| S-5 | Publish health and statistics ports to `127.0.0.1` unless a remote reader needs them. Remote access goes through a private overlay network or SSH, not the LAN or internet. |
| S-6 | Publish no port the role doesn't use. Prove it is unused before removing it, by checking listeners inside the container. Don't remove it just because it is unfamiliar. |
| S-7 | Dashboards on a LAN interface are restricted by host firewall to the LAN and overlay. Remember that on Linux, Docker-published ports bypass `ufw` rules. |
| S-8 | Public status output is a projection: no hostnames, internal addresses, paths or problem text that reveals infrastructure. A test proves it. |
| S-9 | Key exposure is handled by a written decision (rotate, or accept and monitor) with its reasoning. It is not reflexive. |

## 8. Runtime health and reliability

| Area | Requirement | Why |
|---|---|---|
| Restart | Container or service restarts on failure (`Restart=always` under systemd, or `unless-stopped`) | Power loss and crashes are the common failure |
| Memory | On small hosts, cap the Node heap (`--max-old-space-size`), with swap as an OOM backstop at low swappiness | GC spikes otherwise push a 1 GB host into swap. Docker `--memory` limits may be silently unenforced on some kernels |
| Logs | Rotation on every container (for example `max-size 10m`, `max-file 3`, via daemon defaults or per service) | Unbounded logs fill disks weeks later |
| Health | Liveness and readiness endpoints probed on loopback | Detects a dead process. It does **not** detect "alive but not producing" |
| Production liveness | An alert on "no finalized blocks from this address for N expected intervals", from chain data | The only signal that matches the goal |
| Alert truth | Every alert maps to a cause an operator can act on. An alert that fires while the chain shows normal production is a defect to fix, not to mute | Law 07 |
| Unattended change | OS updates, reboots and producer updates are written policies: what triggers them, when, how it is announced, how it is undone | Law 06 |
| Container runtime upgrades | Treat Docker Engine or containerd package upgrades as a **producer restart**, not a background patch. Hold them from unattended upgrades, or schedule them | On a reference node, an unattended OS upgrade that included the engine restarted the producer mid-production |
| Graceful stop | Check that a stop ends with a clean exit, not SIGKILL (exit 137). If the process ignores SIGTERM, run it under an init (`--init`) or record why not | A killed producer may drop an in-flight candidate. On the reference Pi, every stop so far has ended in exit 137 |
| Thermal | Small boards: record temperature and throttle flags. Overclocks have a written rollback | Throttling silently lengthens cycles |
| Headroom | Record free memory, swap use and disk. Act on trends, not single readings | — |

## 9. Observability and metric definitions

| Metric | Definition | Source | Notes |
|---|---|---|---|
| **Accepted block** | A finalized block whose producer address is yours | chain scan | The only measure of production |
| **Daily share** | Accepted blocks ÷ finalized heights, per complete UTC day | chain scan | See Method M1 |
| **Ratio to even split** | Daily share × number of active producers that day | chain scan | Normalises for competitor count |
| **Active producer** | A producer with ≥ 1% of a day's blocks | chain scan | One stray block is not competition |
| **Complete day** | A UTC day the scan covered from start to end | scanner coverage | Partial days are excluded from conclusions |
| **Comparable day** | A complete day on which the active producer set did not change | derived | Only comparable days support a trend |
| `blockProductionChecks` | Poll ticks executed | producer statistics endpoint | — |
| `concurrentChecksSkipped` | Ticks skipped because the previous cycle was still running | same | Nonzero and rising means the interval is shorter than the cycle |
| `rejectedPublishes` | Candidate submissions the endpoint refused | same | SHOULD be 0 |
| `failedChecks` | Ticks that errored | same | — |
| `productionCycle` p50/p95 | Duration of one tick | same | Compare only at equal interval and producer set |
| `headFetch`, `mempool*`, `timePayloadGeneration` | Segment durations | same | Locate where a slow cycle spends its time |
| "Published block" log line | A submission | logs | **Not** acceptance; never use it as production |

Telemetry follows Law 04: collect what these definitions need, keep files bounded, and publish only the projection.

## 10. Performance benchmarking methodology

A change to anything that affects production MUST come with:

1. **Hypothesis**, with the mechanism you think explains it.
2. **Baseline** of at least three comparable days (§9), or a stated, shorter window with the reason.
3. **One change at a time**, recorded with its effective time.
4. **Measurement** over the same number of comparable days after the change.
5. **Normalisation.** Report ratio to even split, not raw share, whenever the producer set differs.
6. **Classification** of every statement: *observed fact*, *correlation*, *hypothesis*, or *unknown*.
7. **Rollback**, written before the change.

What this standard already knows about XL1 production (each with its evidence status):

- **Observed (one node, Sequence, CLI 5.3–5.5):**
  - At a 60000 ms interval, a node learns of a new head about half an interval late, on a network with ~53 s blocks.
  - Moving to 5000 ms took share from 0.5–2% to 13.6% across six producers.
  - The size of the effect, plus the mechanism, makes causation likely.
- **Observed (forensic window, 2026-09-27):**
  - Among equal-score candidates, the newest valid candidate wins: the 2nd eligible arrival won 57% of heights, the 1st won 26%.
  - So **speed alone does not decide wins**, and "faster" tuning is not monotonic with share.
  - Reported upstream as `xl1-docker-images` issue #12.
- **Observed (forensic window, 2026-09-27; measured with the producer's own `fetch` inside both containers):**
  - After more than 4 s idle, each request to the RPC/REST endpoints costs about +120 to +150 ms (a new connection).
  - At intervals of 3500 ms or less, connections stay warm.
  - This is a mechanism, measured directly. It explains why intervals above 4 s are slower per tick. It does not by itself prove a share gain.
- **Unknown:** the effect on share of moving between 3000 and 5000 ms. No controlled comparison exists, because the producer set changed during every trial window.

Don't benchmark resource-intensive workloads on a producing host without the operator's approval, and never during a comparison window.

## 11. Incident response and recovery

| Symptom | First checks | Known causes |
|---|---|---|
| Health green, no accepted blocks | Effective preset inside the container; eligibility; chain scan for your address | Preset mounts lost → image default 60000 ms; ineligible; network change |
| All producers on a network stop | Upstream status; RPC schema or endpoint change | 2026-09-02: an RPC schema change stopped producers reading the chain over RPC. The REST role kept reading |
| Cycle p95 jumps | Segment timings (`headFetch`, `timePayloadGeneration`) | EVM/RPC endpoint latency, host throttling, swap |
| Container restarting | `docker logs` (rotated), memory, disk | OOM, full disk |
| Alert fires, chain normal | The alert's input versus chain truth | Defective alert: fix its cause |

Recovery order:
1. Confirm on chain.
2. Change one thing.
3. Verify on chain.
4. Record it.

Keep a written DR note listing what must be restored (env files from the operator's own backup, presets from git, image by version) and what never leaves the host.

## 12. Update and rollback

1. **Never upgrade solely because a newer version exists.** Read the release, classify it (required / recommended / optional / experimental / deferred), and record why.
2. Build or pull with explicit versions. Keep the outgoing image **tagged** for rollback; a dangling image ID is not a rollback target.
3. Update one node at a time. Verify health, then **verify on chain** (§4.6), before the next.
4. Rollback is one documented command that restores the previous tagged image and presets. Test it before you need it.
5. Automatic updates are allowed only as a written policy (Law 06). The policy states the trigger (for example, a release manifest you control), the verification, and the rollback.

## 13. Evidence and verification

Every published claim carries:
- **What**: the statement, classified as fact, correlation, hypothesis or unknown;
- **Window**: start and end (UTC), plus the complete and comparable days used;
- **Source**: the command, file or endpoint, and the tool version;
- **Reproduction**: how someone else can recompute it (Appendix B);
- **Limits**: what it does not show.

Producer attribution to a person or organisation needs a citable, first-hand statement or a public record. A relayed claim stays labelled "reported". Everything else is "unknown".

## 14. Compliance levels and checklist

Three Oxyon-defined levels. Each includes the previous one. **These are not XYO certifications.** A level is claimed only when every MUST item is verified, with evidence linked.

### Baseline: safe, documented, reproducible operation

| ID | Requirement | Law | Verify by |
|---|---|---|---|
| B-01 | Image built or pulled with explicit CLI and Node versions; image ID recorded | 02 | provenance record |
| B-02 | Role presets from git, read-only mounts; effective values match git | 02, 05 | hash or value comparison inside the container |
| B-03 | Selected preset values committed and pinned by a test | 03 | config test |
| B-04 | No secrets tracked; `*.env` and `*.env.*` ignored; templates clean | 04 | config test |
| B-05 | Health ports on loopback unless a remote reader is documented | 04 | `docker ps` ports |
| B-06 | No published port without a documented use | 04, 07 | listener check inside the container |
| B-07 | Log rotation on every container | 08 | container log config |
| B-08 | Restart policy set | 08 | service or container config |
| B-09 | Production verified on chain, not from logs | 01 | chain scan |
| B-10 | Unattended updates and reboots are written policies, or disabled | 06 | policy document |
| B-11 | Rollback documented with a tagged previous image | 06 | image list + runbook |
| B-12 | Reproducibility test: a third party completed §4 from the docs | 03 | signed-off record |
| B-13 | Non-affiliation disclaimer present in public material | 01 | docs check |

### Observed: Baseline plus reliable metrics and explainable performance

| ID | Requirement | Law | Verify by |
|---|---|---|---|
| O-01 | Collector records chain-derived share and producer statistics to bounded files | 01, 04 | files + size bounds |
| O-02 | Metric definitions as in §9, published with the data | 03 | docs |
| O-03 | Production-liveness alert based on chain data | 07 | alert config + test |
| O-04 | No standing false alerts: each active alert agrees with chain truth | 07 | alert history versus chain |
| O-05 | Public output is a projection without host identity, enforced by test | 04 | test |
| O-06 | Visitors cause no producer or RPC load | 04, 07 | architecture + Worker/collector review |
| O-07 | Host headroom (memory, swap, disk, thermal) recorded | 08 | collector output |

### Research: Observed plus reproducible benchmarking and checkable findings

| ID | Requirement | Law | Verify by |
|---|---|---|---|
| R-01 | Benchmarks follow §10, with comparable-day windows | 01, 07 | report |
| R-02 | Every finding classified fact / correlation / hypothesis / unknown | 03 | report |
| R-03 | Methods and reference implementations published (Appendix B) | 03, 05 | repository |
| R-04 | Raw inputs (chain-derived, no secrets) available for recomputation | 02 | data export |
| R-05 | An independent recomputation matched | 01 | third-party record |

## 15. Known limitations and future revisions

- v1.0 is drawn from two hosts (one Raspberry Pi 3 B+, one Windows laptop with Docker Desktop) and CLI 5.6.1. Other hardware may behave differently.
- The daily-share method uses UTC days. Hourly resolution would allow shorter comparable windows. Planned.
- XL1 eligibility and staking rules are evolving. §6 defers to XYO.
- The tie-break behaviour (§10) may change upstream. If it does, re-measure before reusing anything here.
- Reproducibility test B-12 has not yet been performed by a third party.

Revisions follow semantic versioning:
- **Patch:** wording and evidence updates.
- **Minor:** new requirements at an existing level.
- **Major:** a changed requirement, or a changed level definition.

Each revision records what changed and why, in the history below.

| Version | Date | Change |
|---|---|---|
| 1.0 (draft) | 2026-10-10 | First draft |

---

## Appendix A: Selected configuration of the Oxyon reference nodes

A dated record of one operator's choices, given for transparency, **not as recommendations**. Verified 2026-10-10.

| | Pi node | Windows node(s) |
|---|---|---|
| Hardware | Raspberry Pi 3 Model B+ (1 GB RAM), microSD; overclocked 1500 MHz (rollback recorded) | Intel Core i7-13620H laptop, 16 GB RAM, Docker Desktop (WSL2) |
| Docker | 29.9.0 | Desktop engine 29.8.0 |
| Image | `xl1:5.6.1`: CLI 5.6.1, Node 24.14.1 | `xl1:5.6.1`: CLI 5.6.1, Node 26.9.0 |
| Containers | 1: Mainnet | 3: one Sequence (main), one Sequence (extra), one Mainnet (extra) |
| Role | `producer-rest` | `producer-rest` |
| `blockProductionCheckInterval` | 3000 (selected; trial since 2026-09-27) | **3000 (selected 2026-10-10)** |
| `heartbeatInterval` | 60000 (upstream value) | 60000 |
| Heap cap | `--max-old-space-size=512` | none (16 GB host) |
| Logs | rotated 10 MB × 3 | producers not yet rotated (Baseline gap, see below) |
| Peer port 30303 | published, nothing listening (Baseline gap) | not published |

**Why 3000 on Windows.** *Selected* (§5):
- It is the lowest value either node has run.
- It sits under the measured 4-second keep-alive cliff (§10), so every tick reuses a warm connection.
- Over 24 h at 3000 on the Windows main node (2026-10-09/10): 49,817 checks, `concurrentChecksSkipped` 7, `failedChecks` 0, `rejectedPublishes` 0; `productionCycle` p50 324 ms, p95 1077 ms.

No controlled comparison with 4000 or 5000 exists. 3000 is not claimed to be optimal.

**Level claimed: none yet.** Known Baseline gaps:
- B-06 (Pi peer port);
- B-07 (Windows producer log rotation);
- B-10 (unattended-update policies to be written down; the Pi's OS updates currently include the container runtime);
- B-11 (two Windows containers run an untagged image);
- B-12 (no third-party reproduction yet).

## Appendix B: Methods

- **M1: Daily share and ratio to even split:** [`methods/daily-share.md`](methods/daily-share.md). Reference implementation: [`scripts/share-by-day.mjs`](../../scripts/share-by-day.mjs).
- **M2: Producer statistics snapshot:** [`scripts/xl1-perf-snapshot.ps1`](../../scripts/xl1-perf-snapshot.ps1). Read-only; reads the loopback statistics endpoint and the collector's files.
