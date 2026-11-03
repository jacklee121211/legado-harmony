// 2026-11-03（P7/L1）：从 `database/AppDatabase/index.ets` 的实体快照里删掉 Legado 遗留死表。
// 快照是"JSON 风格的对象字面量"，按**表名 + 花括号配对**定位实体块，逐个剔除。
// 先 --dry-run 打印计划，再执行。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const FILE = path.join(ROOT, 'entry/src/main/ets/database/AppDatabase/index.ets')
const dry = process.argv.includes('--dry-run')

// 保留：books / book_groups / bookmarks / readDaily
const DEAD = new Set([
  'book_sources', 'chapters', 'replace_rules', 'searchBooks', 'search_keywords', 'cookies',
  'rssSources', 'rssArticles', 'rssReadRecords', 'rssStars', 'txtTocRules', 'httpTTS',
  'caches', 'ruleSubs', 'dictRules', 'keyboardAssists', 'servers',
  'rss_sources_history', 'works_lists', 'rss_source_group',
])

const text = fs.readFileSync(FILE, 'utf8')
const anchor = '"entities": ['
const arrStart = text.indexOf(anchor)
if (arrStart < 0) throw new Error('找不到 "entities": [')
// 数组内容起点（anchor 后第一个 { 的位置）
const contentStart = text.indexOf('{', arrStart + anchor.length)
if (contentStart < 0) throw new Error('找不到实体起点')
// 用花括号配对切出每个顶层实体对象
const blocks = []
let i = contentStart
while (i < text.length) {
  if (text[i] === '{') {
    let depth = 0
    let j = i
    let inStr = false
    let esc = false
    for (; j < text.length; j++) {
      const ch = text[j]
      if (inStr) {
        if (esc) { esc = false } else if (ch === '\\') { esc = true } else if (ch === '"') { inStr = false }
        continue
      }
      if (ch === '"') { inStr = true; continue }
      if (ch === '{') { depth++ } else if (ch === '}') {
        depth--
        if (depth === 0) { break }
      }
    }
    blocks.push({ start: i, end: j + 1, text: text.slice(i, j + 1) })
    i = j + 1
    // 跳到下一个可能的实体起点：遇到 ] 结束
    while (i < text.length && text[i] !== '{' && text[i] !== ']') { i++ }
    if (i < text.length && text[i] === ']') { break }
    continue
  }
  if (text[i] === ']') { break }
  i++
}

const nameOf = (b) => {
  const m = b.text.match(/"tableName":\s*"([^"]+)"/)
  return m ? m[1] : ''
}
const keep = []
const drop = []
for (const b of blocks) {
  const n = nameOf(b)
  if (!n) { keep.push(b); continue }
  if (DEAD.has(n)) { drop.push({ ...b, name: n }) } else { keep.push(b) }
}

console.log(`实体总数 ${blocks.length}，删除 ${drop.length}，保留 ${keep.length}`)
console.log('删除: ' + drop.map((d) => d.name).join(', '))
console.log('保留: ' + keep.map(nameOf).filter(Boolean).join(', '))

if (!dry) {
  // 逐个从后往前删（保持前面偏移有效）
  let out = text
  const sorted = drop.slice().sort((a, b) => b.start - a.start)
  for (const d of sorted) {
    // 连带前导缩进与尾随逗号/空白：实体之间以 "    },\r\n      {" 分隔
    let s = d.start
    let e = d.end
    // 向前吃掉空白与行首缩进
    while (s > 0 && (out[s - 1] === ' ' || out[s - 1] === '\r' || out[s - 1] === '\n' || out[s - 1] === '\t')) { s-- }
    // 向后吃掉空白 + 一个逗号（若存在）
    while (e < out.length && (out[e] === ' ' || out[e] === '\r' || out[e] === '\n' || out[e] === '\t')) { e++ }
    if (out[e] === ',') { e++ }
    out = out.slice(0, s) + out.slice(e)
  }
  fs.writeFileSync(FILE, out, 'utf8')
  console.log(`已写入：${text.split('\n').length} 行 → ${out.split('\n').length} 行`)
}
