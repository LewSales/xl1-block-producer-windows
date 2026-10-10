# Independent reproducibility test

Part of the [Oxyon Producer Reference Standard v1.0](OXYON-PRODUCER-REFERENCE-STANDARD-v1.0.md), requirement **B-12**. A community exercise: this is not an official XYO standard or procedure.

**Purpose:** someone who has never spoken to us follows only the public repository, then reports what worked, what didn't, and what they had to guess. A failure here is a finding about **our documentation**, not about you.

**Rules for the tester:**
- Use only this repository, XYO's public `xl1-docker-images`, and the links they contain.
- Don't contact us during the test. Write every question down instead; each question is a result.
- Never send us, or paste anywhere, a recovery phrase, private key or env file. Nothing in this test needs them, except optional Part C, and there they stay on your machine.

| Part | Needs | Time | Touches a network? |
|---|---|---|---|
| A. Offline verification | Node.js ≥ 20, git | ~15 min | No |
| B. Image and runtime checks | Docker | ~20 min | Pulls/builds an image; runs no producer |
| C. Live producer (optional) | Your own key, authorised on a network | hours | Yes |

---

## Part A: Offline verification (no keys, no Docker)

| Step | Do | Expected | Record |
|---|---|---|---|
| A1 | Clone the repository; check out the commit you were given | — | commit hash |
| A2 | `node --test tests/config.test.mjs tests/standards.test.mjs tests/share-by-day.test.mjs` | All pass. On a non-git copy, two git checks report "skipped" | pass/fail counts |
| A3 | Read [`presets/roles/producer.json`](../../presets/roles/producer.json) and the standard's §5 | You can state where `blockProductionCheckInterval` comes from (origin category) and why | your one-line answer |
| A4 | `node scripts/share-by-day.mjs --peers docs/standards/examples/mainnet-daily-2026-10-07_10.json --self ca08120874f071739d932b24da41cc13299123b3` | Identical to the worked example in [Method M1](methods/daily-share.md#worked-example-oxyon-pi-node-mainnet-2026-10-07-to-2026-10-10) | match yes/no |
| A5 | From that output alone, say which days support a conclusion and why | Only 2026-10-08 is comparable | your answer |
| A6 | Break something on purpose: set `blockProductionCheckInterval` to `1000` in a copy, then rerun A2 | The config test fails and names the file | which test failed |
| A7 | Add a file `config/test.env.bak` (empty), then run `git status` | It does not appear (ignored) | yes/no |

## Part B: Image and runtime checks (Docker, no keys, no producer)

| Step | Do | Expected | Record |
|---|---|---|---|
| B1 | Build or pull the producer image with explicit versions (`Build.ps1 -CliVersion <x>`, or upstream's Dockerfile with `--build-arg`) | Build succeeds | CLI and Node versions, image ID |
| B2 | `docker run --rm --entrypoint xl1 <image> --version` | Prints the CLI version you asked for | output |
| B3 | Signal check (standard §8, "Graceful stop"): `docker run -d --name sigtest --entrypoint node <image> -e "setInterval(()=>{},1000)"`, then time `docker stop -t 8 sigtest` and read its exit code with `docker inspect sigtest --format '{{.State.ExitCode}}'`. Remove the container. Repeat with `--init` | Without `--init`: ~8 s, exit 137. With `--init`: ~1 s, exit 143 | both timings and codes |
| B4 | Render the compose config with an **empty** env file (so nothing secret is printed), with and without `XL1_HEALTH_HOST_PORT=127.0.0.1:9099` | Ports `:9099->9099`, then `127.0.0.1:9099->9099` | both port lines |

## Part C: Live producer (optional, your own key)

Only if you already hold a key authorised to produce on a network. This standard can't grant eligibility.

| Step | Do | Expected | Record |
|---|---|---|---|
| C1 | Copy `*.env.template` (and upstream's producer env example) to real `.env` files on your machine; fill them in | `git status` shows none of them | yes/no |
| C2 | Start the producer as the README describes | `/livez`, `/readyz`, `/healthz` return 200 | timings |
| C3 | Inside the container, compare the effective preset with the repository file | Identical | hash or values |
| C4 | Wait for production, then verify **on chain** that blocks signed by your producer address appear (dashboard "Blocks produced", or any explorer) | At least one finalized block, within the window your network's producer count implies | first block height and time |
| C5 | Run `scripts/share-by-day.mjs` on your own dashboard's `peers.json` | A table with your share; partial and transition days marked | the table (addresses are public) |
| C6 | Stop the producer and note how long the stop took and its exit code | Matches what B3 predicts for your setup | timing, code |

---

## Report template

Send this back. Do not include addresses other than public producer addresses, and never secrets.

```
Tester (name or handle, optional):
Date (UTC):
Repository commit:
OS / hardware:
Node.js / Docker versions:

Part A: A2 counts | A3 answer | A4 match | A5 answer | A6 failing test | A7 ignored?
Part B: B1 versions + image ID | B2 output | B3 timings/codes | B4 port lines
Part C: (optional) C1–C6 results

Questions I had to write down (every one is a documentation gap):
1.
Steps where the docs were wrong, missing, or ambiguous:
1.
Anything you could not reproduce:
1.
```

## How results are used

Each report is recorded against B-12 with its date and commit. **B-12 counts as met when at least one independent tester completes Parts A and B without contacting us** and every question they recorded has been answered in the docs. Results that disagree with ours are published alongside ours, not instead of them.
