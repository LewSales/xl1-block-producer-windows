// Checks on docs/standards: the reference standard is public material, so it
// is held to the rules it states. Offline: files only, external links are
// listed for a human, never fetched.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join, dirname, resolve, relative } from 'node:path'

const root = join(fileURLToPath(new URL('.', import.meta.url)), '..')
const dir = join(root, 'docs', 'standards')
const walk = (d) => readdirSync(d).flatMap((n) => statSync(join(d, n)).isDirectory() ? walk(join(d, n)) : [join(d, n)])
const docs = walk(dir).filter((f) => f.endsWith('.md'))
const read = (f) => readFileSync(f, 'utf8')
const standard = docs.find((f) => /OXYON-PRODUCER-REFERENCE-STANDARD-v\d+\.\d+\.md$/.test(f))

// GitHub's heading anchors: lowercase, punctuation dropped, spaces to hyphens.
const slug = (h) => h.trim().toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s/g, '-')
const anchors = (text) => new Set([...text.matchAll(/^#{1,6}\s+(.+)$/gm)].map((m) => slug(m[1])))
const links = (text) => [...text.replace(/```[\s\S]*?```/g, '').matchAll(/\]\(([^)\s]+)\)/g)].map((m) => m[1])

test('the standard exists and its title matches its file name', () => {
  assert.ok(standard, 'docs/standards/OXYON-PRODUCER-REFERENCE-STANDARD-vX.Y.md missing')
  const v = standard.match(/v(\d+\.\d+)\.md$/)[1]
  assert.match(read(standard), new RegExp(`^# Oxyon Producer Reference Standard v${v.replace('.', '\\.')}\\b`))
})

for (const f of docs) {
  const name = relative(root, f)
  const text = read(f)

  test(`${name}: relative links and anchors resolve`, () => {
    for (const href of links(text)) {
      if (/^(https?:|mailto:)/.test(href)) continue
      const [path, hash] = href.split('#')
      const target = path ? resolve(dirname(f), path) : f
      assert.ok(existsSync(target), `broken link ${href}`)
      if (hash && target.endsWith('.md')) assert.ok(anchors(read(target)).has(hash), `missing anchor #${hash} in ${relative(root, target)}`)
    }
  })

  test(`${name}: nothing secret-shaped or infrastructure-revealing`, () => {
    assert.doesNotMatch(text, /(^|[^0-9a-f])(0x)?[0-9a-f]{64}([^0-9a-f]|$)/i, 'private-key-shaped value')
    // Loopback is a recommendation, not an address of ours.
    assert.doesNotMatch(text.replaceAll('127.0.0.1', ''), /\b(?:\d{1,3}\.){3}\d{1,3}\b/, 'an IPv4 address')
    assert.doesNotMatch(text, /[A-Z]:\\Users\\|\/home\/[a-z]/i, 'a local user path')
    assert.doesNotMatch(text, /\.ts\.net\b|tailscale0?\s*ip/i, 'an overlay-network identifier')
    assert.doesNotMatch(text, /\b(mnemonic|recovery phrase)\s*[:=]\s*\S/i, 'a secret assignment')
  })

  test(`${name}: no unearned claims`, () => {
    // Negations ("not an official XYO standard") are the disclaimer, not a claim.
    const claims = text.replace(/\bnot (an? )?official XYO \w+/gi, '')
    assert.doesNotMatch(claims, /\bwe are (the )?(fastest|best)\b|\bguarantee[sd]?\b|\bofficial XYO (standard|certification|distribution)\b/i)
    if (!/not an official XYO standard|community method, not an XYO metric/.test(text)) assert.fail('non-affiliation statement missing')
  })
}

test('the standard states all seven laws and the three levels', () => {
  const text = read(standard)
  for (let n = 1; n <= 7; n++) assert.match(text, new RegExp(`^\\| 0${n} \\|`, 'm'), `law 0${n} missing`)
  for (const level of ['Baseline', 'Observed', 'Research']) assert.match(text, new RegExp(`^### ${level}:`, 'm'), `${level} level missing`)
  assert.match(text, /not XYO certifications/)
})

test('no compliance level is claimed while known gaps are listed', () => {
  const text = read(standard)
  const claim = text.match(/\*\*Level claimed: ([^.*]+)\.?\*\*/)?.[1]
  assert.ok(claim, 'Appendix A must state the level claimed')
  if (/Known Baseline gaps/.test(text)) assert.match(claim, /^none/, 'a level is claimed while Baseline gaps are listed')
})

test('Appendix A records the interval the presets actually carry', () => {
  const preset = JSON.parse(readFileSync(join(root, 'presets', 'roles', 'producer.json'), 'utf8'))
  const value = preset.actors[0].blockProductionCheckInterval
  const row = read(standard).match(/^\| `blockProductionCheckInterval` \|.*\|(.*)\|$/m)
  assert.ok(row, 'interval row missing from Appendix A')
  assert.match(row[1], new RegExp(`\\b${value}\\b`), `Windows column does not say ${value}`)
})

test('external links, listed for a human check', () => {
  const ext = [...new Set(docs.flatMap((f) => links(read(f)).filter((h) => /^https?:/.test(h))))]
  for (const h of ext) assert.match(h, /^https:\/\//, `insecure link ${h}`)
  console.log(`external links (not fetched): ${ext.join(', ') || 'none'}`)
})
