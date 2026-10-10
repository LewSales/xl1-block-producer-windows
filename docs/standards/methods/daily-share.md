# Method M1: Daily share and ratio to even split

Part of the [Oxyon Producer Reference Standard v1.0](../OXYON-PRODUCER-REFERENCE-STANDARD-v1.0.md). A community method, not an XYO metric.

## Question it answers

Is a producer's share of finalized blocks changing because of something the operator did, or because the competition changed?

## Inputs

- A chain scan that attributes each finalized block to its producer address, bucketed by UTC day, with the scan's coverage (`since`, `updatedAt`). The reference dashboard writes this as `peers.json` (v3: `days[<YYYY-MM-DD>] = { scanned, counts: { <address>: blocks } }`).
- The producer address you are evaluating (public, on chain).

No RPC calls are made by the method itself. The scan is already performed by the collector, at a bounded rate, independent of the method.

## Definitions

| Term | Definition |
|---|---|
| Complete day | The UTC day lies wholly inside the scan's coverage |
| Active producer | ≥ 1% of that day's blocks |
| Even split | 1 ÷ active producers |
| Daily share | your blocks ÷ blocks scanned that day |
| Ratio to even split | daily share ÷ even split |
| Transition day | The set of active producers differs from the previous day |
| Comparable day | Complete and not a transition |

## Procedure

1. Run `node scripts/share-by-day.mjs --peers <peers.json> --self <address>` (add `--json` for machine-readable output).
2. Discard partial (`*`) and transition (`~`) days from any conclusion. Print them, but label them.
3. Compare **ratio to even split** across comparable days. Compare raw share only between days with the same active set.
4. Before attributing a change to your own configuration, check that it took effect on a known date, that comparable days exist on both sides, and that nothing else changed (producer set, network, CLI version).
5. Classify each statement as **observed fact**, **correlation**, **hypothesis** or **unknown**.

## Limits

- A newcomer active for part of a day inflates that day's producer count, so even split is too low and the ratio too high. Hence transition days are excluded.
- UTC-day resolution needs several days on each side of a change. Hourly resolution is a planned revision.
- Share depends on rules that operators don't control (for example, how ties between candidates are broken). A share change is not automatically a performance change.
- Different networks are never comparable.

## Worked example: Oxyon Pi node, Mainnet, 2026-10-07 to 2026-10-10

Output of the reference implementation on the node's own scan. The addresses are public producer addresses.

```
day          blocks  producers  even%   self%  ratio  entered / left
2026-10-07*    8967          6   16.7    22.6   1.36
2026-10-08    11824          6   16.7    22.2   1.33
2026-10-09~    9367          9   11.1    19.5   1.75  +2152…cc91 +a656…dae9 +c3d1…979f
2026-10-10*    5014          9   11.1      13   1.17
2 complete day(s), 1 comparable
```

Reading it under this method:

- **Observed fact:**
  - Raw share went 22.6 → 22.2 → 19.5 → 13.0%.
  - The active producer set grew from 6 to 9 on 2026-10-09. One of the three newcomers is the same operator's second key.
- **Observed fact: changes on the node itself during the window** (from the host's service journal and package log; presets unchanged since 2026-09-27):

  | When (UTC) | Change |
  |---|---|
  | 2026-10-08 02:35 | CLI 5.5.0 → 5.6.1 (operator update) |
  | 2026-10-09 00:10–00:12 | unattended OS upgrade included Docker Engine 29.8.2 → 29.9.0 and containerd 2.3.6 → 2.4.1. The producer was stopped and restarted (~72 s without production; cycles overran their period during the upgrade) |

- **Correlation:** the fall in raw share coincides with the growth of the producer set, *and* with a CLI upgrade and an engine upgrade on the node.
- **Hypothesis:** most of the fall comes from more competitors. It is not yet separable from the two node-side changes.
- **Unknown:** whether the ratio to even split has changed. The only comparable day (2026-10-08, ratio 1.33) already ran almost entirely on 5.6.1. 2026-10-10 is partial (1.17, labelled, not concluded on).
- **Next measurement:** three or more comparable days with nine active producers and no node-side change, then compare the ratio with 1.33. A 72-second restart can't explain a multi-point daily change (it is about 0.1% of a day), but it is recorded rather than assumed away.
