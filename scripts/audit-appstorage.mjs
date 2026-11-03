// AppStorage / PersistentStorage 键盘点（2026-11-03 P2 第一步：先取证再收敛）
//
// ⚠️ v2（本轮修正）：第一版只认**字面量键**，把「通过常量间接写入」的键误判成"只读不写"
//   （例：`ShelfRefresh.sort()` 里 `AppStorage.setOrCreate(key, next)`，key 是变量；
//     `theme` 走 `ThemeStorageKey.THEME` 常量）。
//   ⇒ 现在先把全仓「标识符 → 字面量字符串」的常量表建出来，再解析实参。
//
// 分类建议（输出里直接给）：
//   · 死键：读 0 或 写 0（且无法通过常量解析）→ 可删（逐个人工复核）
//   · 活键：读>0 且 写>0 → 逐类判断能否事件化 / 改只读快照
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// ── 存量预算（ratchet，只许降）──────────────────────────────────────────────
// 2026-11-03（P2 批次 1）：先删掉 9 个「只写不读」的死键（94 → 85），随后把 85 钉成预算。
// 以后新增 AppStorage 键会直接让 node scripts/check-all.mjs 变红；要加键必须同步调这个数，
// 并在 PR 里说明「为什么不能用事件 / 局部状态」。
const KEY_BUDGET = 85
const checkMode = process.argv.includes('--check')

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ETS = path.join(ROOT, 'entry/src/main/ets')

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.ets') || e.name.endsWith('.ts')) out.push(p)
  }
  return out
}

const files = walk(ETS)
const sources = files.map((f) => ({ f, rel: path.relative(ETS, f).split(path.sep).join('/'), text: fs.readFileSync(f, 'utf8') }))

// ── ① 常量表：NAME = 'literal'（含 static readonly / export const / 普通 const）
const CONST = new Map()
for (const { text } of sources) {
  for (const m of text.matchAll(/(?:^|\s)(?:static\s+readonly\s+|const\s+|let\s+|var\s+)([A-Za-z_$][\w$]*)\s*(?::\s*string\s*)?=\s*'([^']+)'/g)) {
    CONST.set(m[1], m[2])
  }
  // 对象字面量式常量表：{ KEY: 'VALUE' }
  for (const m of text.matchAll(/^\s*([A-Z][A-Z0-9_]{2,})\s*:\s*'([^']+)'\s*,?\s*$/gm)) {
    if (!CONST.has(m[1])) CONST.set(m[1], m[2])
  }
}

/** 解析实参：字面量直接返回；标识符查常量表；取不到返回 null（计入 unresolved） */
function resolveArg(arg) {
  const a = arg.trim()
  const lit = a.match(/^'([^']+)'$/)
  if (lit) return lit[1]
  const ident = a.match(/^([A-Za-z_$][\w$]*)$/)
  if (ident) return CONST.has(ident[1]) ? CONST.get(ident[1]) : null
  // 形如 Foo.KEY（静态成员）——按成员名查常量表（本工程常量都是唯一命名）
  const member = a.match(/^[A-Za-z_$][\w$]*\.([A-Za-z_$][\w$]*)$/)
  if (member) return CONST.has(member[1]) ? CONST.get(member[1]) : null
  return null
}

const keys = new Map()
const unresolved = []
function bump(key, kind, where) {
  if (!keys.has(key)) keys.set(key, { read: [], write: [] })
  keys.get(key)[kind].push(where)
}

const reWrite = /AppStorage\.(?:setOrCreate|set)\s*(?:<[^>]*>)?\s*\(\s*([^,]+),/g
const reRead = /AppStorage\.get\s*(?:<[^>]*>)?\s*\(\s*([^)]+)\)/g
const reDecor = /@Storage(?:Prop|Link)\s*\(\s*([^)]+)\)/g
const rePersist = /PersistentStorage\.(?:persistProp|persistProps)\s*\(\s*([^,)]+)/g

for (const { rel, text } of sources) {
  const lines = text.split(/\r?\n/)
  lines.forEach((line, i) => {
    const t = line.trim()
    if (!t || /^(\/\/|\*|\/\*)/.test(t)) return
    const where = `${rel}:${i + 1}`
    for (const [re, kind] of [[reWrite, 'write'], [reRead, 'read'], [reDecor, 'read'], [rePersist, 'write']]) {
      for (const m of t.matchAll(re)) {
        const k = resolveArg(m[1])
        if (k === null) unresolved.push(`${where}  ${kind}  ← ${m[1].trim()}`)
        else bump(k, kind, where)
      }
    }
  })
}

const rows = [...keys.entries()]
  .map(([k, v]) => ({ key: k, r: v.read.length, w: v.write.length }))
  .sort((a, b) => (b.r + b.w) - (a.r + a.w) || a.key.localeCompare(b.key))

const dead = rows.filter((x) => x.r === 0 || x.w === 0)
console.log(`扫描 ${files.length} 个文件；常量表 ${CONST.size} 条；无法解析的实参 ${unresolved.length} 处`)
console.log(`唯一键 ${rows.length} 个 / 使用点 ${rows.reduce((n, x) => n + x.r + x.w, 0)} 个`)
if (unresolved.length) {
  console.log('\n── 无法解析（需人工确认是否动态键）──')
  for (const u of unresolved.slice(0, 20)) console.log('  ' + u)
  if (unresolved.length > 20) console.log(`  … 其余 ${unresolved.length - 20} 处`)
}
console.log(`\n── 死键（读0 或 写0）：${dead.length} 个 ──`)
for (const x of dead) console.log(`  ${x.r === 0 ? '只写不读' : '只读不写'}  ${x.key}（读 ${x.r} / 写 ${x.w}）`)
console.log(`\n── 活键（读>0 且 写>0，按使用点降序，前 32）──`)
for (const x of rows.filter((y) => y.r > 0 && y.w > 0).slice(0, 32)) {
  console.log(`  读${String(x.r).padStart(3)} 写${String(x.w).padStart(3)}  ${x.key}`)
}
