// Apply the single-call EVM anchor (XYOracleNetwork/xl1-docker-images#11) to an installed
// @xyo-network/xl1-cli bundle, in place.
//
//   node patch-anchor.mjs <path/to/cli-min.mjs>
//
// Refuses unless the shipped two-call form occurs exactly once, so a CLI release that has
// already taken the fix (or reshaped the code) fails the build instead of being half-patched.
import fs from 'node:fs'

const file = process.argv[2]
if (!file) throw new Error('usage: node patch-anchor.mjs <cli-min.mjs>')

const SHIPPED = [
  'const blockNumber = await provider.getBlockNumber() ?? 0;',
  'const value = [blockNumber, asHash(assertEx$1((await provider.getBlock(blockNumber))?.hash, () => "Block hash not found"), true)];',
]
const PATCHED = [
  'const block = assertEx$1(await provider.getBlock("latest"), () => "Block hash not found");',
  'const value = [block.number, asHash(assertEx$1(block.hash, () => "Block hash not found"), true)];',
]

const src = fs.readFileSync(file, 'utf8')
// The two statements are consecutive lines; match them with whatever indentation the bundle uses.
const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const re = new RegExp(`([ \\t]*)${esc(SHIPPED[0])}(\\r?\\n)([ \\t]*)${esc(SHIPPED[1])}`, 'g')
const hits = [...src.matchAll(re)]
if (hits.length !== 1) throw new Error(`expected exactly 1 shipped anchor, found ${hits.length} — not patching`)

const out = src.replace(re, (_, i1, nl, i2) => `${i1}${PATCHED[0]}${nl}${i2}${PATCHED[1]}`)
if (out.includes(SHIPPED[0])) throw new Error('shipped form still present after patch')
fs.writeFileSync(file, out)
console.log(`patched ${file}: currentEthereumAnchor now makes one getBlock("latest") round trip`)
