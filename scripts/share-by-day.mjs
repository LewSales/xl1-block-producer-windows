#!/usr/bin/env node
// Daily block share, read from the dashboard's own chain scan (peers.json).
//
// Offline and read-only: it opens one file and prints. No RPC, no producer
// contact, safe on a host that is producing. The method is the one in
// docs/standards/methods/daily-share.md; this script is its reference
// implementation, so anyone with a peers.json can reproduce a table we publish.
//
//   node scripts/share-by-day.mjs --peers state/dashboard/peers.json --self <address>
//   node scripts/share-by-day.mjs --peers peers.json --self <address> --json
//
// A day counts as complete only when the scan covered all of it (UTC). Partial
// days are printed, marked, and excluded from the summary: comparing a partial
// day with a full one is how a share "decline" gets invented. A day on which
// the producer set changed is a transition: a newcomer active for six hours
// still counts in that day's even split, so its ratio is not comparable either.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const DAY = 86400e3
// A producer below this share of a day's blocks is listed but not counted as a
// participant: one stray block is not competition.
export const ACTIVE_MIN_SHARE = 0.01

export function dailyShare(peers, self) {
  if (peers?.v !== 3 || !peers.days) throw new Error('expected peers.json v3 with a days map')
  const since = Date.parse(peers.since)
  const until = Date.parse(peers.updatedAt)
  const me = self?.toLowerCase().replace(/^0x/, '')
  const rows = []
  let prev = null
  for (const day of Object.keys(peers.days).sort()) {
    const { scanned, counts } = peers.days[day]
    const start = Date.parse(`${day}T00:00:00Z`)
    const complete = start >= since && start + DAY <= until
    const active = Object.entries(counts).filter(([, n]) => n >= ACTIVE_MIN_SHARE * scanned).map(([a]) => a).sort()
    const selfBlocks = me ? counts[me] ?? 0 : null
    const even = active.length ? 1 / active.length : null
    const share = me && scanned ? selfBlocks / scanned : null
    const entered = prev ? active.filter((a) => !prev.includes(a)) : []
    const left = prev ? prev.filter((a) => !active.includes(a)) : []
    rows.push({
      day, complete, transition: entered.length + left.length > 0,
      comparable: complete && entered.length + left.length === 0, blocks: scanned, producers: active.length,
      evenSplitPct: even && round(even * 100),
      selfBlocks, selfSharePct: share === null ? null : round(share * 100),
      ratioToEven: share === null || !even ? null : round(share / even, 2),
      entered, left,
    })
    prev = active
  }
  return { self: me ?? null, coverage: { since: peers.since, until: peers.updatedAt }, rows,
    completeDays: rows.filter((r) => r.complete).length, comparableDays: rows.filter((r) => r.comparable).length }
}

const round = (x, d = 1) => Math.round(x * 10 ** d) / 10 ** d
const short = (a) => `${a.slice(0, 4)}…${a.slice(-4)}`

function print(r) {
  console.log(`coverage ${r.coverage.since} .. ${r.coverage.until} (UTC days; * partial, ~ producer set changed: neither is comparable)`)
  console.log('day          blocks  producers  even%   self%  ratio  entered / left')
  for (const x of r.rows) {
    const churn = [...x.entered.map((a) => `+${short(a)}`), ...x.left.map((a) => `-${short(a)}`)].join(' ')
    console.log(`${x.day}${!x.complete ? '*' : x.transition ? '~' : ' '}  ${String(x.blocks).padStart(6)}  ${String(x.producers).padStart(9)}  ${String(x.evenSplitPct ?? '-').padStart(5)}  ${String(x.selfSharePct ?? '-').padStart(6)}  ${String(x.ratioToEven ?? '-').padStart(5)}  ${churn}`)
  }
  console.log(`${r.completeDays} complete day(s), ${r.comparableDays} comparable`)
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const arg = (k) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : undefined }
  const file = arg('--peers')
  if (!file) { console.error('usage: share-by-day.mjs --peers <peers.json> [--self <address>] [--json]'); process.exit(2) }
  const r = dailyShare(JSON.parse(readFileSync(file, 'utf8')), arg('--self'))
  if (process.argv.includes('--json')) console.log(JSON.stringify(r, null, 2)); else print(r)
}
