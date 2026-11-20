// node --test anchor-bundle.test.mjs   (STOCK=<stock cli-min.mjs> PATCHED=<patched cli-min.mjs>)
//
// Lifts currentEthereumAnchor / cachedEthereumAnchor out of the real bundles (stock and patched)
// and runs the xl1-docker-images#11 behaviour cases against both. Only assertEx and asHash are
// stood in for; the method bodies under test are the bytes the producer runs.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { describe, test } from 'node:test'

function liftMethods(file) {
  const src = fs.readFileSync(file, 'utf8')
  const pick = (name) => {
    const start = src.indexOf(`\t\t${name}() {`)
    assert.ok(start > 0, `${name} not found in ${file}`)
    // Methods in this bundle close with a line that is exactly two tabs and a brace.
    const end = src.indexOf('\n\t\t}', start)
    return src.slice(start, end + 4).trim()
  }
  const body = `${pick('cachedEthereumAnchor')}\n${pick('async currentEthereumAnchor')}`
  // eslint-disable-next-line no-new-func
  return new Function('assertEx$1', 'asHash', `return class {\n${body}\n}`)
}
const assertEx = (v, msg) => { if (v === undefined || v === null) throw new Error(msg()); return v }
const asHash = (h, strict) => {
  const bare = typeof h === 'string' ? h.replace(/^0x/, '') : undefined
  if (!/^[0-9a-f]{64}$/.test(bare ?? '')) { if (strict) throw new Error('bad hash'); return undefined }
  return bare
}

const HASH = n => `0x${n.toString(16).padStart(64, '0')}`
const bare = h => h.slice(2)
function mockProvider(tip, { lagging = false } = {}) {
  const calls = []
  return {
    calls,
    async getBlockNumber() { calls.push('getBlockNumber'); return tip.n },
    async getBlock(tag) {
      calls.push(`getBlock:${tag}`)
      if (tag === 'latest') return { number: tip.n, hash: HASH(tip.n) }
      if (lagging && tag === tip.n) return null
      return { number: tag, hash: HASH(tag) }
    },
  }
}
function makeViewer(Cls, provider, ttl = 0) {
  const v = new Cls()
  v.ethProvider = provider
  v.options = { ethereumAnchorCacheTtlMs: ttl }
  return v
}

const variants = [
  ['stock', liftMethods(process.env.STOCK)(assertEx, asHash)],
  ['patched', liftMethods(process.env.PATCHED)(assertEx, asHash)],
]
for (const [name, Cls] of variants) {
  describe(name, () => {
    test('anchor is the tip number with that block\'s own hash', async () => {
      assert.deepEqual(await makeViewer(Cls, mockProvider({ n: 11_790_001 })).currentEthereumAnchor(), [11_790_001, bare(HASH(11_790_001))])
    })
    test('a null block fails with the same message', async () => {
      const v = makeViewer(Cls, { getBlockNumber: async () => 7, getBlock: async () => null })
      await assert.rejects(v.currentEthereumAnchor(), /Block hash not found/)
    })
    test('a block without a hash fails loudly', async () => {
      const v = makeViewer(Cls, { getBlockNumber: async () => 7, getBlock: async () => ({ number: 7, hash: null }) })
      await assert.rejects(v.currentEthereumAnchor(), /Block hash not found|bad hash/)
    })
    test('ttl 0 reads a fresh tip on every call (never a stale anchor)', async () => {
      const tip = { n: 100 }
      const v = makeViewer(Cls, mockProvider(tip))
      assert.equal((await v.currentEthereumAnchor())[0], 100)
      tip.n = 101
      assert.equal((await v.currentEthereumAnchor())[0], 101)
    })
    test('ttl > 0 keeps its caching behaviour', async () => {
      const tip = { n: 100 }
      const p = mockProvider(tip)
      const v = makeViewer(Cls, p, 60_000)
      await v.currentEthereumAnchor()
      const n = p.calls.length
      tip.n = 101
      assert.equal((await v.currentEthereumAnchor())[0], 100)
      assert.equal(p.calls.length, n)
    })
    test('concurrent reads share one in-flight fetch', async () => {
      const p = mockProvider({ n: 5 })
      const v = makeViewer(Cls, p)
      const [a, b] = await Promise.all([v.currentEthereumAnchor(), v.currentEthereumAnchor()])
      assert.deepEqual(a, b)
      assert.equal(p.calls.length, name === 'stock' ? 2 : 1)
    })
    test('round trips per anchor', async () => {
      const p = mockProvider({ n: 9 })
      await makeViewer(Cls, p).currentEthereumAnchor()
      assert.deepEqual(p.calls, name === 'stock' ? ['getBlockNumber', 'getBlock:9'] : ['getBlock:latest'])
    })
    test('lagging load-balanced backend', async () => {
      const run = makeViewer(Cls, mockProvider({ n: 12 }, { lagging: true })).currentEthereumAnchor()
      if (name === 'stock') await assert.rejects(run, /Block hash not found/)
      else assert.equal((await run)[0], 12)
    })
  })
}
