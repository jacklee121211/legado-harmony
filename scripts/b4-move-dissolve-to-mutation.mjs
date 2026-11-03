// 2026-11-03（B4 收尾 · 第二半）：把「分组级联删书」的三个方法从 bookGroupUtils 搬进 GroupMutation。
// 目的：bookGroupUtils 里那 3 处 `BooksDao.moveBooksToGroup`（分组域写操作）从此归 GroupMutation 表达。
// 先 --dry-run 看计划，再执行。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const UTIL = path.join(ROOT, 'entry/src/main/ets/common/utils/bookGroupUtils.ets')
const MUT = path.join(ROOT, 'entry/src/main/ets/common/group/GroupMutation.ets')
const dry = process.argv.includes('--dry-run')

const utilRaw = fs.readFileSync(UTIL, 'utf8')
const nl = utilRaw.includes('\r\n') ? '\r\n' : '\n'
const utilLines = utilRaw.split(/\r?\n/)

// 1-based 闭区间（含）
const SPANS = [
  { name: 'delGroupById', from: 58, to: 119 },
  { name: 'dissolveGroup', from: 133, to: 221 },
  { name: 'dissolveGroups', from: 233, to: 243 },
  { name: 'dissolveIfEmpty', from: 279, to: 312, drop: true }, // 已无真实调用方 → 直接删除
]

// 断言：每个 span 的首行确实是该方法定义
for (const s of SPANS) {
  const head = utilLines[s.from - 1] ?? ''
  if (!head.includes(s.name)) throw new Error(`span 对不上：L${s.from} 期望 ${s.name}，实际「${head}」`)
}

const moveText = []
for (const s of SPANS) {
  if (s.drop) { console.log(`drop ${s.name}（无调用方）L${s.from}-${s.to}`); continue }
  let block = utilLines.slice(s.from - 1, s.to).join(nl)
  block = block.replace(/^\s{2}async /, '  static async ')
  block = block.replace(/this\.dissolveGroup\(/g, 'GroupMutation.dissolveGroup(')
  block = block.replace(/this\.delGroupById\(/g, 'GroupMutation.delGroupById(')
  block = block.replace(/await this\.refreshHiddenGroupIds\(\)/g, 'await GroupStore.refresh()')
  moveText.push(block)
  console.log(`move ${s.name} L${s.from}-${s.to} → GroupMutation（${block.split(/\r?\n/).length} 行）`)
}

// 2) 写进 GroupMutation：插到最后一个 `}` 之前
const mutRaw = fs.readFileSync(MUT, 'utf8')
const mutNl = mutRaw.includes('\r\n') ? '\r\n' : '\n'
const lastBrace = mutRaw.lastIndexOf('}')
let mutBody = mutRaw.slice(0, lastBrace)
const tail = mutRaw.slice(lastBrace)
const banner = [
  '',
  '  // ═══════════════════════════════════════════════════════════════════════════',
  '  // 2026-11-03（B4 收尾）：**分组级联删书**的三个方法从 `bookGroupUtils` 搬到这里。',
  '  //   原因：它们原先在 `bookGroupUtils` 里直接 `BooksDao.moveBooksToGroup(...)`（3 处），',
  '  //   而分组域写操作的**归属**应该是 `GroupMutation`；搬过来后「分组解散/删除时书去哪」',
  '  //   只有一个表达位置，也不必让 `bookGroupUtils` 反向 import 写入口（避免循环依赖）。',
  '  //   `dissolveIfEmpty`（空分组自动解散）同期删除 —— `EMPTY_AUTO_DISSOLVE=false` 之后已无调用方。',
  '  // ═══════════════════════════════════════════════════════════════════════════',
  '',
].join(mutNl)
mutBody = mutBody + banner + moveText.join(mutNl + mutNl) + mutNl
const nextMut = mutBody + tail

// 3) GroupMutation 里原来那三处「委托 bookGroupUtils」改成调自己
let mut2 = nextMut
  .replace('await bookGroupUtils.dissolveGroup(groupId, mode, false)', 'await GroupMutation.dissolveGroup(groupId, mode, false)')
  .replace('await bookGroupUtils.delGroupById(ids, false)', 'await GroupMutation.delGroupById(ids, false)')
  .replace('await bookGroupUtils.dissolveGroups(groupIds, mode, false)', 'await GroupMutation.dissolveGroups(groupIds, mode, false)')
// 加 GroupTree import（moved 的 dissolveGroup 用到类型）
if (!mut2.includes("from './GroupTree'")) {
  mut2 = mut2.replace("import { GroupStore } from './GroupStore'", "import { GroupStore } from './GroupStore'" + mutNl + "import { GroupTree } from './GroupTree'")
}

// 4) 从 bookGroupUtils 删掉这些 span（自下而上）
const nextUtilLines = utilLines.slice()
const delSpans = SPANS.slice().sort((a, b) => b.from - a.from)
for (const s of delSpans) {
  // 连带把方法后紧邻的一个空行也删掉
  let to = s.to
  if ((nextUtilLines[to] ?? '').trim() === '') { to = to + 1 }
  nextUtilLines.splice(s.from - 1, to - s.from + 1)
}
const nextUtil = nextUtilLines.join(nl)

console.log(`GroupMutation: ${mutRaw.split(/\r?\n/).length} → ${mut2.split(/\r?\n/).length} 行`)
console.log(`bookGroupUtils: ${utilLines.length} → ${nextUtilLines.length} 行`)
console.log('残留 bookGroupUtils. 委托:', (mut2.match(/bookGroupUtils\.(dissolveGroup|delGroupById|dissolveGroups)/g) ?? []).length)

if (!dry) {
  fs.writeFileSync(MUT, mut2, 'utf8')
  fs.writeFileSync(UTIL, nextUtil, 'utf8')
  console.log('已写入两个文件')
} else {
  console.log('[dry-run] 未写入')
}
