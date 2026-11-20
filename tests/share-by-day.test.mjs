// scripts/share-by-day.mjs is the reference implementation of the daily-share
// method in docs/standards. These cases pin the parts that decide whether a
// conclusion is allowed: completeness, transitions, and the participant floor.
// Synthetic data only.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { dailyShare } from '../scripts/share-by-day.mjs'

const A = 'a'.repeat(40), B = 'b'.repeat(40), C = 'c'.repeat(40), D = 'd'.repeat(40)
const peers = (days, since = '2026-01-01T00:00:00Z', updatedAt = '2026-01-05T12:00:00Z') => ({ v: 3, since, updatedAt, days })

test('a day the scan did not fully cover is partial, never comparable', () => {
  const r = dailyShare(peers({
    '2026-01-01': { scanned: 100, counts: { [A]: 50, [B]: 50 } },
    '2026-01-05': { scanned: 40, counts: { [A]: 10, [B]: 30 } },
  }, '2026-01-01T03:00:00Z'), A)
  assert.deepEqual(r.rows.map((x) => [x.complete, x.comparable]), [[false, false], [false, false]])
  assert.equal(r.comparableDays, 0)
})

test('share, even split and ratio are computed against active producers', () => {
  const r = dailyShare(peers({ '2026-01-02': { scanned: 200, counts: { [A]: 100, [B]: 60, [C]: 40 } } }), A)
  const [x] = r.rows
  assert.equal(x.selfSharePct, 50)
  assert.equal(x.evenSplitPct, 33.3)
  assert.equal(x.ratioToEven, 1.5)
  assert.equal(x.comparable, true)
})

test('a producer under 1% of the day is not counted as a participant', () => {
  const r = dailyShare(peers({ '2026-01-02': { scanned: 1000, counts: { [A]: 500, [B]: 495, [D]: 5 } } }), A)
  assert.equal(r.rows[0].producers, 2)
})

test('a change in the producer set marks a transition day, not comparable', () => {
  const r = dailyShare(peers({
    '2026-01-02': { scanned: 100, counts: { [A]: 50, [B]: 50 } },
    '2026-01-03': { scanned: 100, counts: { [A]: 40, [B]: 40, [C]: 20 } },
    '2026-01-04': { scanned: 100, counts: { [A]: 34, [B]: 33, [C]: 33 } },
  }), A)
  assert.deepEqual(r.rows.map((x) => x.transition), [false, true, false])
  assert.deepEqual(r.rows[1].entered, [C])
  assert.deepEqual(r.rows.map((x) => x.comparable), [true, false, true])
})

test('without --self the table still describes the network', () => {
  const r = dailyShare(peers({ '2026-01-02': { scanned: 10, counts: { [A]: 5, [B]: 5 } } }))
  assert.equal(r.rows[0].selfSharePct, null)
  assert.equal(r.rows[0].producers, 2)
})

test('an unknown file shape is refused rather than guessed at', () => {
  assert.throws(() => dailyShare({ v: 2, days: {} }), /v3/)
})

test('the worked example in the method doc is what the sample data produces', async () => {
  // R-04: the published table must be recomputable by anyone from the
  // published input. Parse the doc's table and recompute it.
  const { readFileSync } = await import('node:fs')
  const { fileURLToPath } = await import('node:url')
  const at = (p) => fileURLToPath(new URL(p, import.meta.url))
  const doc = readFileSync(at('../docs/standards/methods/daily-share.md'), 'utf8')
  const sample = JSON.parse(readFileSync(at('../docs/standards/examples/mainnet-daily-2026-10-07_10.json'), 'utf8'))
  const self = doc.match(/--self ([0-9a-f]{40})/)?.[1]
  assert.ok(self, 'the doc must name the address it evaluated')
  const rows = [...doc.matchAll(/^(\d{4}-\d{2}-\d{2})([*~ ]?)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/gm)]
  assert.ok(rows.length >= 3, 'worked-example table not found')
  const got = Object.fromEntries(dailyShare(sample, self).rows.map((r) => [r.day, r]))
  for (const [, day, mark, blocks, producers, even, share, ratio] of rows) {
    const r = got[day]
    assert.ok(r, `${day} not in the sample`)
    assert.equal(r.blocks, Number(blocks), `${day} blocks`)
    assert.equal(r.producers, Number(producers), `${day} producers`)
    assert.equal(r.evenSplitPct, Number(even), `${day} even split`)
    assert.equal(r.selfSharePct, Number(share), `${day} share`)
    assert.equal(r.ratioToEven, Number(ratio), `${day} ratio`)
    assert.equal(mark.trim(), !r.complete ? '*' : r.transition ? '~' : '', `${day} marker`)
  }
})
