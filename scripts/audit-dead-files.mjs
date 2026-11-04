// 只读审计 + 闸门：找出「全仓零 import」的 .ets 死文件（2026-11-04 新增）。
//
// 为什么需要：这一轮（§67）连删了 `requestUtils.ets`(90 行) 与 `SearchConfig.ets`(59 行)，
//   都是"文件还在、但没有任何文件 import 它"的死代码；`ImportBookListDialog.ets` 也是同类。
//   人肉 grep 容易漏，做成闸门后新长出来的死文件立刻变红。
//
// 判活规则（任一命中即视为活）：
//   1. 被别的 .ets 以 `from '<路径>/<basename>'` 或 `from './<basename>'` 形式 import
//   2. 被 `main_pages.json` 的 pages 列表引用（路由页）
//   3. 被 `module.json5` 引用（ability / extensionAbility 入口）
//   4. 位于允许清单目录（入口与平台约定文件）
//   5. 同目录同名 `.d.ts`？不存在这种约定，忽略
//
// 用法：
//   node scripts/audit-dead-files.mjs            # 报告（exit 0）
//   node scripts/audit-dead-files.mjs --check    # 闸门：有未允许的死文件即 exit 1
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ETS = path.join(ROOT, 'entry/src/main/ets')
const checkMode = process.argv.includes('--check')

// ── 允许清单：入口与平台约定（不是死代码，只是没人 import）
const ALLOW = [
  'entryability/', // UIAbility 入口（module.json5 引用）
  'pages/Index.ets', // 首页（main_pages.json 引用）
  'common/books/BookNaming.ets', // 有单测与调用方，但被动态?（保守放行，见 §67 记录）
]

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.ets')) out.push(p)
  }
  return out
}

const files = walk(ETS)
const rels = files.map((f) => path.relative(ETS, f).split(path.sep).join('/'))

// 收集全部 import 目标（相对路径 / 绝对别名都归一成 basename + 路径片段）
const importTargets = new Set()
const importRe = /from\s+'([^']+)'/g
for (const f of files) {
  const text = fs.readFileSync(f, 'utf8')
  for (const m of text.matchAll(importRe)) {
    const spec = m[1]
    const base = path.basename(spec).replace(/\.ets$/, '')
    importTargets.add(base)
  }
}

// 平台清单引用
function readIfExists(rel) {
  const p = path.join(ROOT, rel)
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : ''
}
const pagesJson = readIfExists('entry/src/main/resources/base/profile/main_pages.json')
const moduleJson = readIfExists('entry/src/main/module.json5')

const dead = []
for (const rel of rels) {
  const base = path.basename(rel).replace(/\.ets$/, '')
  if (ALLOW.some((a) => (a.endsWith('/') ? rel.startsWith(a) : rel === a))) continue
  if (importTargets.has(base)) continue
  if (pagesJson.includes(base)) continue
  if (moduleJson.includes(base)) continue
  const lines = fs.readFileSync(path.join(ETS, rel), 'utf8').split(/\r?\n/).length
  dead.push({ rel, lines })
}

dead.sort((a, b) => b.lines - a.lines)

// RATCHET（2026-11-04 首次实测 = 13 个 / 918 行 → 批 C-14 删 6 个后 = 7 个 / 649 行，明细见 docs §68/§69）：
//   只许降不许升 —— 新长出来的死文件会让 CI 变红。
//   每删掉一个必须同步下调这个数，并把原因写进 docs。
const DEAD_FILE_BUDGET = 7

if (checkMode) {
  if (dead.length <= DEAD_FILE_BUDGET) {
    const tail = dead.length === DEAD_FILE_BUDGET
      ? ''
      : `（比预算少 ${DEAD_FILE_BUDGET - dead.length} 个，可下调 DEAD_FILE_BUDGET）`
    console.log(`✅ 零 import 死文件 ${dead.length} / 预算 ${DEAD_FILE_BUDGET}（只许降）${tail}`)
    process.exit(0)
  }
  console.log(`❌ 零 import 死文件 ${dead.length} 个 > 预算 ${DEAD_FILE_BUDGET}（新增死文件：删掉它，不要调高预算）：`)
  for (const d of dead) console.log(`   ${d.rel}  (${d.lines} 行)`)
  process.exit(1)
}

console.log(`扫描 ${rels.length} 个 .ets；零 import 死文件 ${dead.length} 个：`)
let total = 0
for (const d of dead) {
  total += d.lines
  console.log(`  ${String(d.lines).padStart(4)} 行  ${d.rel}`)
}
console.log(`合计 ${total} 行`)
