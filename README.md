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
.\scripts\xl1ctl.ps1 stop
```

The dashboard's source is baked into `xl1-dashboard:local`, not bind-mounted, so
a change under `dashboard\` needs a rebuild before it shows up:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build.ps1 -DashboardOnly
.\scripts\xl1ctl.ps1 restart
```

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\Tests.ps1
```

Parses every script, checks the panel's inline script, and runs the dashboard
suite against a stubbed SDK — no Docker, no producer, no network.
`tests\dashboard.test.mjs` is the same file as the Pi bundle's, because
`dashboard\` is the same source; keep it that way.

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
