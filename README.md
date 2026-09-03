# XL1 Block Producer — Windows

> **An independent community project by LewSales.** Not affiliated with, endorsed
> by, or supported by XYO Network. The producer itself is XYO's
> [`xl1-docker-images`](https://github.com/XYOracleNetwork/xl1-docker-images),
> run unmodified through their own compose file. Everything around it — the
> dashboard, the collector, the control script — is mine, and so are its bugs.

Runs a federated Sequence block producer on a Windows PC under Docker Desktop,
with the same dashboard as the Raspberry Pi bundle.

## Why this exists

A Raspberry Pi 3 B+ builds a block in roughly seventeen seconds against a
one-second budget. The chain finalizes past each candidate before it is
submitted, which the log reports as `behind-finalized-head`. No configuration
changes that. A desktop CPU is the fix.

## What runs what

```
  upstream/compose/node.yml  --profile preset      the producer, XYO's file, unmodified
  dashboard.yml                                    the dashboard, mine
  scripts/xl1-collect.ps1                          scheduled task, writes state/producer-status.json
  scripts/xl1-alert.ps1                            scheduled task, reads /api/status and notifies
  scripts/xl1ctl.ps1                               one command instead of two compose files
```

**The producer service is deliberately not redefined here.** Upstream's file
carries a warning that is easy to get wrong: a federated producer must not be
given a local store or a data volume, because the viewers would rebind to that
store and the node would fork its own private chain. Copying their service into
this repo would mean maintaining a copy of something XYO changes.

The two stacks are joined by nothing but a published port. Upstream publishes
the health port to Windows; the dashboard reaches it at
`host.docker.internal:9099`.

## Setup

Needs Docker Desktop (running), Git for Windows, and WSL for the image build.

```powershell
powershell -ExecutionPolicy Bypass -File .\Setup.ps1
```

It fetches upstream, builds the amd64 images natively (no emulation, unlike the
Pi's cross-build), creates the config from **upstream's own example**, and
registers the collector as a scheduled task.

Then fill in your credentials and start:

```powershell
notepad .\config\sequence-producer.env      # XL1_MNEMONIC + XL1_REWARD_ADDRESS
.\scripts\xl1ctl.ps1 start
.\scripts\xl1ctl.ps1 doctor
```

Dashboard: <http://127.0.0.1:8088>

## Before you start it — read this one

> **Never run two producers on one mnemonic.** If another machine is already
> producing with the *same* wallet, stop it before starting this one:
>
> ```
> ssh <other-host> "sudo systemctl disable --now xl1-producer"
> ```

**Different mnemonics are different nodes** and run side by side without
conflict — separate signing addresses, separate authorisation, separate rewards.
Check rather than assume: comparing the two `XL1_MNEMONIC` values by hash
settles it without printing either.

Where a second machine keeps running as a monitor, its dashboard still polls the
chain independently — chain height, reward balance and its own health keep
working. Only the container and node panels, which describe a producer it is no
longer running, go quiet.

## Commands

```powershell
.\scripts\xl1ctl.ps1 status       # containers, chain position, balance, last block
.\scripts\xl1ctl.ps1 logs -Follow
.\scripts\xl1ctl.ps1 addr         # which address the node signs as
.\scripts\xl1ctl.ps1 doctor       # exits non-zero when something is wrong
.\scripts\xl1ctl.ps1 backup       # zips config\ — unencrypted, treat as a password
.\scripts\xl1ctl.ps1 alert        # what the alerter would report right now
.\scripts\xl1ctl.ps1 alert -Test  # one notification through every configured channel
.\scripts\xl1ctl.ps1 stop
```

The dashboard's source is baked into `xl1-dashboard:local`, not bind-mounted, so
a change under `dashboard\` needs a rebuild before it shows up:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build.ps1 -DashboardOnly
.\scripts\xl1ctl.ps1 restart
```

### Run them from PowerShell, not from WSL

`docker compose` answers from an Ubuntu shell too, and the containers it starts
there look identical — until Docker Desktop restarts. Docker Desktop reaches a
Windows path (`C:\...`) through the permanent drive share, but a path handed to
it from inside WSL (`/mnt/c/...`) through a per-distro shim that exists only
while that distro is running. Docker Desktop starts its containers before WSL is
up, so after a reboot the shim is not there, the mount resolves to an empty
directory, and nothing says so: the dashboard reports a collector that is in
fact writing every thirty seconds, and the panels fed from that file go blank.

`xl1ctl.ps1 doctor` reports any container whose mounts came from a WSL path,
and `restart` recreates them — a plain `docker restart` keeps the dead mount.

## Which role reads the chain how

`XL1_ROLE` in `config\sequence-producer.env` picks one of two role presets, both
of them mounted by `compose\producer-tuning.yml`:

| | chain reads | mempool |
|---|---|---|
| `producer` | JSON-RPC | JSON-RPC |
| `producer-rest` | the REST CDNs — `blocks`, `state` and `indexes.sequence.xyo.space` | JSON-RPC |

This node runs `producer-rest`, and the reason is a night in September 2026. The
gateway's RPC schema began requiring an `$epoch` argument on viewer calls, and
every client older than that change failed on **every** call: the producer
stopped producing, the dashboard lost the chain, and the network dropped from a
block every ~50s to one every five minutes while operators rebuilt. A
`producer-rest` node reads the chain from the CDNs and would have kept building
through it — only submission goes over RPC.

Switching is an env edit and a restart:

```powershell
notepad .\config\sequence-producer.env      # XL1_ROLE=producer-rest
.\scripts\xl1ctl.ps1 restart
```

`presets\roles\producer-rest.json` is upstream's file with one field changed —
the same `blockProductionCheckInterval` override the RPC preset carries, for the
same reason. Every other binding is theirs.

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\Tests.ps1
```

Parses every script, checks the panel's inline script, exercises the alerter
against a fixture served over loopback, and runs the dashboard suite against a
stubbed SDK — no Docker, no producer, no network.
`tests\dashboard.test.mjs` is the same file as the Pi bundle's, because
`dashboard\` is the same source; keep it that way.

## Alerts

Nothing on the dashboard helps at 3am. `scripts\xl1-alert.ps1` runs every 60
seconds as the **XL1 Alerter** scheduled task, reads the dashboard's own
`/api/status`, and pushes what it finds to whichever channels are filled in:

```powershell
notepad .\config\alert.env       # ntfy topic, Discord/Slack webhook, email, dead-man URL
.\scripts\xl1ctl.ps1 alert -Test  # prove the channel works before you need it
```

It is the Pi bundle's `xl1-alert.sh` under a different scheduler — same variable
names, same condition keys, same transition rules — so an operator running both
machines configures them identically and gets messages that read the same.

It fires **on transitions, not on conditions**. Something that breaks is
reported once, repeated once per `XL1_ALERT_COOLDOWN` (6h) while it stays
broken, and reported again when it clears. An alerter that repeats every minute
is one nobody reads, which is the same as having none.

Two of the conditions are worth naming, because every other signal reads green
through both:

- **`not-producing`** — the node is up, healthy, reachable, and has not landed a
  block in `XL1_ALERT_STALL_BLOCKS` (90) chain blocks. Counted from the chain,
  never from the log: `Published block:` means *submitted*, and a node can
  submit all day without one being accepted.
- **`never-produced`** — the container came up and has never built a block at
  all, which is a different failure from producing and losing. `/livez` passes
  forever in that state, so the container is never unhealthy, never exits, and
  no restart policy recovers it. Only an operator does.

The one thing this cannot report is the PC dying, because a dead PC sends
nothing and so does a healthy one. That is what `XL1_ALERT_DEADMAN_URL` is for:
point it at a healthchecks.io or Uptime Kuma push monitor and the absence of a
ping becomes the alarm.

## Producer standings

A block is a bound witness and its producer is a signer, so the scan that counts
this node's own blocks already holds every block's signer list. The **Producer
standings** panel tallies the rest of those addresses at the same time: who else
is producing, how many blocks each has signed, and where this node ranks.

It is deliberately not a second poller. A leaderboard built from an independent
pass would drift from the *Share of chain* figure printed beside it, and two
numbers on one page disagreeing about the same blocks is worse than one number.

Three things about how it counts are worth knowing:

- **Shares divide by blocks actually read**, not by the height range. After an
  outage those differ, and dividing by the range would report a share the node
  never had. The sample size is printed under the table for that reason.
- **The scan never jumps a gap.** It walks forward in chunks of 200 — the
  gateway's cap — and advances its cursor only over blocks it genuinely read. A
  range the gateway declines is retried, not booked as empty.
- **Totals persist across restarts** in `state\dashboard\peers.json`, which is
  the same rw bind mount `dashboard.yml` gives the container for the trend
  store. The scan resumes where it stopped rather than re-scanning a fresh
  window, so a `restart: unless-stopped` bounce costs nothing.

If some blocks carry more than one signer, the share column can total over 100%.
The panel says so rather than normalising it away, which would make the number
tidier and wrong.

`DASH_PEERS_TOP` sets how many rows show; this node is always shown even when it
ranks below the cut.

### Naming the other producers

`DASH_PEER_LABELS` in `config\dashboard.env` maps addresses to names so the
table reads as people:

```
DASH_PEER_LABELS=a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4=Alice,9f3ac210=Bob
```

An entry may be a full 40-character address or a **prefix of at least eight hex
characters**. Prefixes are accepted because a prefix is what you actually have —
every block explorer truncates the address in a table.

The label never replaces the address; it sits beside the shortened hex, which
stays linked to the explorer. Three ways a label can fail, all of them reported
on the panel rather than dropped:

- **Ambiguous** — the prefix matches two observed producers. Left unlabelled. A
  wrong name against a row is worse than no name, because the hex at least
  invites you to check and a name does not.
- **Unmatched** — no producer in the sample starts with it. Said out loud,
  because a name missing from the table looks identical to a producer who has
  stopped.
- **Malformed** — not hex, no name, or a prefix under eight characters. Rejected
  with the reason.

Restart the dashboard after editing the file:

```powershell
.\scripts\xl1ctl.ps1 restart
```

## Differences from the Pi bundle

| | Pi | Windows |
|---|---|---|
| Service manager | systemd units | Docker Compose `restart: unless-stopped` |
| Collector | systemd timer, 30s | Task Scheduler, 30s |
| Alerter | `xl1-alert.timer`, 60s | Task Scheduler, 60s |
| Alert email | `mail`/`sendmail` if installed | needs an SMTP relay named in `alert.env` |
| Producer networking | `--network host` | published port + `host.docker.internal` |
| Host metrics | `/proc`, sysfs | `Get-CimInstance`, because a container sees the Docker VM |
| Image build | cross-built under QEMU | native amd64 |
| Undervoltage / throttle | reported | not applicable, and reported as absent rather than zero |

## What still applies

Producing blocks requires the producer's address to be authorised on the
network. An unauthorised node runs healthy and submits candidates that are never
accepted — and upstream is explicit that `Published block: …` in the log means
*candidate submitted*, not accepted. `xl1ctl.ps1 addr` shows the signing
address, which is the one that has to be on the list.

The producer receives **10% of the block reward**; the remainder funds the Step
Rewards Pool.

## Why this node wins fewer blocks than a Raspberry Pi

Because of how it reaches the internet, not because of the machine.

Measured 2026-09-02 against the same endpoint, from both nodes, as pure TCP
connect time — no TLS, no HTTP, no application:

| path | min | p50 | **p95** | max |
|---|---|---|---|---|
| Pi, Ethernet through the router | 40 ms | 54 ms | **59 ms** | 141 ms |
| This laptop, Wi-Fi to a phone hotspot | 55 ms | 71 ms | **162 ms** | 203 ms |

The median is only 1.3x worse. The p95 is 2.7x worse, and the p95 is what a
block race charges you for: a producing cycle makes several sequential RPC calls
and every one of them rolls the dice on that tail. It shows up downstream as a
`productionCycle` p95 near 8 seconds against the Pi's 2.4, and as 85-95% of lost
candidates reporting `head advanced first`. The node is not failing. It is late.

Put the laptop on the router — Ethernet, or the house Wi-Fi at minimum. Watch
the Candidate Race card afterwards: the `head advanced first` share should fall,
which is visible in minutes, long before a cumulative share percentage moves.

### Ruled out, so nobody re-investigates them

Every one of these was measured, not assumed:

- **CPU is 8x faster than the Pi.** sha256 of 1KB 0.0035 ms vs 0.0333, secp256k1
  sign 0.47 ms vs 3.13, a 1e6 busy loop 1.9 ms vs 15.8.
- **The process is not being starved.** Event-loop lag over 45 s: p99 2.1 ms,
  max 3.2 ms, zero stalls above 250 ms.
- **Not Docker Desktop's CPU limits.** The container sits at 0.03% of 16 cores
  with a load average of 0.05.
- **Not DNS.** 5-8 ms once cached.
- **Not connection churn.** One pooled TLS connection, reused, held for the
  whole sampling window.
- **Not power management.** Requests spaced 5 s apart — the producer's own
  rhythm — are *faster* than back-to-back ones.

An earlier version of this investigation concluded the machine was slow at local
work. That was wrong: it rested on a single burst of warm round trips that
happened to catch the hotspot on a good stretch, and on reading the median where
the tail is the thing that differs.
