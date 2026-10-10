// Offline checks on the configuration this repo ships. No Docker, no network,
// no producer: everything here reads files in the working tree, so it is safe to
// run on a host that is producing.
//
// What breaks silently if nobody checks:
//   - the two role presets drift apart (XL1_ROLE flips and the interval changes)
//   - a provider binding is dropped and the viewers rebind to a local store,
//     which forks a private chain (see compose/producer-tuning.yml)
//   - the poll interval leaves the range this repo has measurements for
//   - an operator file or its backup becomes committable
//
// Values in operator files are never printed: a failure names the file only.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'

const root = join(fileURLToPath(new URL('.', import.meta.url)), '..')
const preset = (name) => JSON.parse(readFileSync(join(root, 'presets', 'roles', name), 'utf8'))

// The range with evidence behind it: 3000 is the lowest value either node has
// run (2026-09-27 trial), 60000 is the image default. Anything outside needs
// a measurement first, not a test edit.
const INTERVAL_MIN = 3000
const INTERVAL_MAX = 60000

// Bindings each role must keep. BlockRunner/BlockValidationViewer on memory are
// upstream's own values; the rest must point at the network, never a local store.
const REQUIRED = {
  'producer.json': ['BlockViewer', 'FinalizationViewer', 'MempoolViewer', 'MempoolRunner', 'ChainContractViewer', 'BlockRunner', 'BlockValidationViewer'],
  'producer-rest.json': ['BlockViewer', 'FinalizationViewer', 'MempoolViewer', 'MempoolRunner', 'ChainContractViewer', 'BlockRunner', 'BlockValidationViewer'],
}
const LOCAL_OK = new Set(['BlockRunner', 'BlockValidationViewer'])

for (const name of Object.keys(REQUIRED)) {
  test(`${name}: parses and has one producer actor`, () => {
    const p = preset(name)
    assert.equal(p.actors?.length, 1)
    assert.equal(p.actors[0].name, 'producer')
    assert.equal(p.actors[0].accountPath, '0')
  })

  test(`${name}: interval is within the measured range`, () => {
    const { blockProductionCheckInterval: i, heartbeatInterval: h } = preset(name).actors[0]
    assert.ok(Number.isInteger(i) && i >= INTERVAL_MIN && i <= INTERVAL_MAX, `blockProductionCheckInterval ${i} outside ${INTERVAL_MIN}-${INTERVAL_MAX}`)
    assert.equal(h, 60000, 'heartbeatInterval differs from the value both nodes run')
  })

  test(`${name}: keeps every required binding, and only the allowed ones are local`, () => {
    const b = preset(name).providerBindings ?? {}
    for (const k of REQUIRED[name]) assert.ok(b[k]?.connection, `missing binding ${k}`)
    for (const [k, v] of Object.entries(b)) {
      if (v.connection === 'memory') assert.ok(LOCAL_OK.has(k), `${k} bound to memory would read a private store`)
    }
  })
}

test('both role presets carry the same actor settings', () => {
  // XL1_ROLE picks one of the two; switching role must not change timing.
  assert.deepEqual(preset('producer.json').actors, preset('producer-rest.json').actors)
})

// git ls-files / check-ignore: the only process this file runs, read-only.
const git = (...args) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' })
const inRepo = (() => { try { git('rev-parse', '--git-dir'); return true } catch { return false } })()

test('no operator config is tracked, only templates', { skip: !inRepo && 'not a git checkout' }, () => {
  const bad = git('ls-files').split('\n').filter((f) => /\.env(\.|$)/.test(f) && !f.endsWith('.env.template'))
  assert.deepEqual(bad, [], 'tracked operator config')
})

test('operator config and its backups are ignored', { skip: !inRepo && 'not a git checkout' }, () => {
  // Names only, checked against .gitignore; nothing is opened.
  const probes = ['config/x.env', 'config/x.env.bak', 'config/x.env.bak-reason', 'config/x.env.old']
  for (const f of probes) assert.doesNotThrow(() => git('check-ignore', '-q', f), `${f} would be committable`)
  assert.throws(() => git('check-ignore', '-q', 'config/x.env.template'), 'templates must stay committable')
  const present = readdirSync(join(root, 'config')).filter((f) => /\.env(\.|$)/.test(f) && !f.endsWith('.env.template'))
  for (const f of present) assert.doesNotThrow(() => git('check-ignore', '-q', `config/${f}`), `config/${f} is not ignored`)
})

test('templates hold no secret-shaped values', () => {
  // Shapes, not names: a 64-hex private key, or a 12+ word lowercase phrase.
  const dir = join(root, 'config')
  for (const f of readdirSync(dir).filter((n) => n.endsWith('.env.template'))) {
    for (const line of readFileSync(join(dir, f), 'utf8').split(/\r?\n/)) {
      const v = line.match(/^\s*[A-Za-z0-9_]+\s*=\s*(.*)$/)?.[1]?.replace(/^["']|["']$/g, '') ?? ''
      assert.ok(!/(^|[^0-9a-f])(0x)?[0-9a-f]{64}([^0-9a-f]|$)/i.test(v), `${f}: a value looks like a private key`)
      assert.ok(!/^([a-z]+\s+){11,}[a-z]+$/.test(v.trim()), `${f}: a value looks like a recovery phrase`)
    }
  }
})
