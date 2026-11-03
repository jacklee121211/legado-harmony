// AppStorage / PersistentStorage 键盘点（2026-11-03 P2 第一步：先取证再收敛）
//
// ⚠️ v2：第一版只认**字面量键**，把「通过常量间接写入」的键误判成"只读不写"
//   （例：`ShelfRefresh.sort()` 里 `AppStorage.setOrCreate(key, next)`，key 是变量；
//     `theme` 走 `ThemeStorageKey.THEME` 常量）。
//   ⇒ 先把全仓「标识符 → 字面量字符串」的常量表建出来，再解析实参。
//
// ⚠️ v3（2026-11-04，P2 批次 2）**修了三处统计缺陷 + 一个假闸门**，均为实证复现：
//   ① **双引号字面量完全没进统计**：`resolveArg` 只认 `'...'`
//      ⇒ `entryability/WindowAbility.ets:53` 的 `AppStorage.setOrCreate<number>("Paf.TopHeight", 56)`
//        等 9 个写点（`"Paf.TopHeight"` ×3、`"NavigationBarHeight"` ×5、`Co…`）统计为 0；
//        `common/utils/ComponetModifier.ets:7-8` 的 `AppStorage.get<number>("topRectHeight")` 也没算读。
//   ② **`@StorageLink` 被当成"只读"**：它是**双向绑定**，静态上只看得到 `@StorageLink('k')` 这一行，
//      但组件里 `this.k = v` 就是写。旧版把它记进 read ⇒ 6 个真活键被误判"只读不写"：
//      `setExtName` / `readerColorMode` / `SHELF_EXHIBIT_GRID` / `setHaptics` /
//      `setReaderInfoWin` / `setReaderStatusBar`。现在单独记 `twoWay`，不进死键候选。
//   ③ **幽灵键**：常量表把 `FolderInfoDialog.ets:117` 的
//      `const key: string = 'GROUP_SHARE_CURSOR_' + gid`（**拼接**）当成完整字面量
//      ⇒ 造出一个实际不存在的键 `GROUP_SHARE_CURSOR_`，并且把所有 `AppStorage.*(key)`
//        的实参都算到它头上，于是 `ShelfRefresh.bump(key)` 偷走了 `SHELF_SORT_TICK` 的写点。
//      ⇒ 现在常量只认「**整行恰好一个完整字面量**」（拼接/模板/函数调用一律不算），
//        且**函数形参名不参与常量解析**：形参传参的写入记为 `via-param`，不参与死键判定。
//   ④ **`--check` 是假闸门**：旧版 `checkMode` 声明了却从未使用（`grep -c checkMode` = 1），
//      `node scripts/audit-appstorage.mjs --check` 恒 exit 0 ⇒ check-all 里"键预算（只许降）"
//      实际上什么都没拦。现在 `--check` 真的比对 `KEY_BUDGET`。
//
// 分类口径（输出里直接给）：
//   · 死写：读 0 / 双向 0，但有写 ⇒ 删除候选（逐个人工自证零读取后才可删）
//   · 死读：写 0 / 双向 0，但有读 ⇒ 读的是一个**没人写**的键（等于硬编码默认值），需人决策
//   · 双向活键：有 `@StorageLink` ⇒ 由框架双向接管，**不判死**
//   · 活键：读>0 且 写>0
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// ── 存量预算（ratchet，只许降；`--check` 会真的拦）────────────────────────────
// 2026-11-03（P2 批次 1）：先删掉 9 个「只写不读」的死键（94 → 85），随后把 85 钉成预算。
// 2026-11-04（P2 批次 2）：工具修正后**真实键数**变了（85 − 1 幽灵 + 3 ezCustomTransition_* + 3 类作用域常量
//   − 1 错解析 = 91），再删掉 8 个已自证零读取的死写（91 → 83）⇒ 预算重钉为 83。
//   ⚠️ 旧版 `--check` 是**假闸门**（`checkMode` 声明后从未使用），预算 85 从未真的拦住任何东西；
//      现在 `--check` 会比对下面的数字并在超出时 exit 1。明细见交付报告与
//      `docs/重梳-测绘-2026-11-04.md`。
// 以后新增 AppStorage 键会直接让 node scripts/check-all.mjs 变红；要加键必须同步调这个数，
// 并在 PR 里说明「为什么不能用事件 / 局部状态」。
const KEY_BUDGET = 82
const checkMode = process.argv.includes('--check')
const listMode = process.argv.includes('--list')

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

// ── ① 常量表：**整行恰好一个完整字面量**才算（拼接 / 模板串 / 函数调用一律不算）
//
// 为什么必须是"整行"：`const key: string = 'GROUP_SHARE_CURSOR_' + gid` 这种拼接，
// 若只匹配"等号后面第一个字面量"，就会把半截值 `GROUP_SHARE_CURSOR_`（不是任何真实键）
// 塞进常量表，进而把所有以 `key` 为实参的读写都算到它头上。
//
// 支持形态（本工程实际出现的四种）：
//   `static readonly NAME: string = 'x';`
//   `public static NAME = 'x';`
//   `const NAME: string = 'x'`  /  `export const NAME = 'x'`
//   对象字面量式常量表 `  KEY_NAME: 'x',`
//
// ⚠️ 常量必须**按作用域**解析（v3 修的第二处精度问题）：
//   `NightMode.KEY` / `ThemeStorageKey.THEME` / `MySetConstants.SET_INFO_WIN` 是成员访问，
//   若只按**成员名**去一张全局表里查，`KEY`/`THEME` 这类短名会在十几个文件间互相覆盖
//   ⇒ 不是解析错值就是解析不出（旧版正是这样把 `Foo.KEY` 认成了别的类的常量）。
//   所以：`static/readonly` 成员记到「类名.成员名」，顶层 const 记到全局表；
//   成员访问先按「类名.成员名」精确命中，再退回无歧义的同名全局/静态常量。
const CLASS_CONST = new Map() // 'Class.NAME' -> value
const GLOBAL_CONST = new Map() // NAME -> { value, ambiguous }
const STATIC_BY_NAME = new Map() // NAME（跨类，仅当全仓唯一时才可用于兜底解析）

function markAmbiguous(prev) {
  prev.ambiguous = true
}
function putGlobal(name, value) {
  const prev = GLOBAL_CONST.get(name)
  if (!prev) GLOBAL_CONST.set(name, { value, ambiguous: false })
  else if (prev.value !== value) markAmbiguous(prev)
}
function putStatic(name, value) {
  const prev = STATIC_BY_NAME.get(name)
  if (!prev) STATIC_BY_NAME.set(name, { value, ambiguous: false })
  else if (prev.value !== value) markAmbiguous(prev)
}

// 允许行尾的 `;` / `,`（enum 成员）与行尾注释（`static readonly THEME: string = 'theme' // 主题key`）
const RE_ASSIGN_LITERAL = /^\s*(?:(?:export|public|private|protected|static|readonly)\s+)*(?:const|let|var)?\s*([A-Za-z_$][\w$]*)\s*(?::\s*string\s*)?=\s*(?:'([^']*)'|"([^"]*)")\s*[;,]?\s*(?:\/\/.*)?$/
const RE_OBJ_ENTRY = /^\s*([A-Z][A-Z0-9_]{2,})\s*:\s*(?:'([^']*)'|"([^"]*)")\s*,?\s*(?:\/\/.*)?$/
const RE_CLASS = /^\s*(?:export\s+)?(?:abstract\s+)?(?:class|enum)\s+([A-Za-z_$][\w$]*)/
const RE_STATIC_MOD = /^\s*(?:(?:export|public|private|protected)\s+)*(?:static|readonly)\b/

for (const { text } of sources) {
  let currentClass = null // 最近的 class 声明（本工程无嵌套类；静态常量按它归属）
  for (const line of text.split(/\r?\n/)) {
    const cm = line.match(RE_CLASS)
    if (cm) currentClass = cm[1]
    const m = line.match(RE_ASSIGN_LITERAL)
    if (m) {
      const value = m[2] !== undefined ? m[2] : m[3]
      if (RE_STATIC_MOD.test(line) && currentClass) {
        CLASS_CONST.set(`${currentClass}.${m[1]}`, value)
        putStatic(m[1], value)
      } else {
        putGlobal(m[1], value)
      }
      continue
    }
    const o = line.match(RE_OBJ_ENTRY)
    if (o) putGlobal(o[1], o[2] !== undefined ? o[2] : o[3])
  }
}

// ── ② 每文件的**函数形参名**集合（形参名不得进常量解析）────────────────────────
//
// 用括号配对扫描，只把「后面紧跟 `=>` 或 `{`」的括号内容当参数表，并跳过 if/for/while/…
// 这类控制语句。目的是认出 `private static bump(key: string): number {` 里的 `key`
// ⇒ `AppStorage.setOrCreate(key, next)` 记为 via-param，而不是解析成某个同名常量。
const CONTROL_KW = new Set(['if', 'for', 'while', 'switch', 'catch', 'return', 'typeof', 'new', 'await', 'with', 'do', 'else'])
function collectParamNames(text) {
  const names = new Set()
  let i = -1
  while ((i = text.indexOf('(', i + 1)) !== -1) {
    const before = text.slice(Math.max(0, i - 64), i)
    const idm = before.match(/([A-Za-z_$][\w$]*)\s*$/)
    if (idm && CONTROL_KW.has(idm[1])) continue
    // 括号配对
    let depth = 0
    let j = i
    for (; j < text.length; j++) {
      const c = text[j]
      if (c === '(') depth++
      else if (c === ')') {
        depth--
        if (depth === 0) break
      }
    }
    if (j >= text.length) break
    const after = text.slice(j + 1, j + 48)
    // 参数表后面：可选返回类型，然后必须是 `=>` 或 `{`
    if (/^\s*(?::[^;{=]*)?(?:=>|\{)/.test(after)) {
      for (const raw of text.slice(i + 1, j).split(',')) {
        const m = raw.trim().match(/^([A-Za-z_$][\w$]*)/)
        if (m && !['const', 'let', 'var', 'readonly', 'public', 'private', 'protected', 'static'].includes(m[1])) {
          names.add(m[1])
        }
      }
    }
    i = j
  }
  return names
}

// ── ③ 实参解析 → 键名 / via-param / 解析不出 ───────────────────────────────────
/** @returns {{key:string}|{viaParam:true,raw:string}|{ambiguous:true,raw:string}|{raw:string}} */
function resolveArg(arg, paramNames) {
  const a = arg.trim()
  const lit = a.match(/^'([^']+)'$/) || a.match(/^"([^"]+)"$/)
  if (lit) return { key: lit[1] }
  const ident = a.match(/^([A-Za-z_$][\w$]*)$/)
  if (ident) {
    // 形参优先：`bump(key)` 里的 key 是函数形参，绝不能拿同名常量顶替
    if (paramNames.has(ident[1])) return { viaParam: true, raw: a }
    const g = GLOBAL_CONST.get(ident[1])
    if (g) return g.ambiguous ? { ambiguous: true, raw: a } : { key: g.value }
    const s = STATIC_BY_NAME.get(ident[1])
    if (s) return s.ambiguous ? { ambiguous: true, raw: a } : { key: s.value }
    return { raw: a }
  }
  // 形如 Foo.KEY（静态成员）：先按「类名.成员名」精确命中，再退回同名常量
  const member = a.match(/^([A-Za-z_$][\w$]*)\.([A-Za-z_$][\w$]*)$/)
  if (member) {
    const exact = CLASS_CONST.get(`${member[1]}.${member[2]}`)
    if (exact !== undefined) return { key: exact }
    const g = GLOBAL_CONST.get(member[2])
    if (g) return g.ambiguous ? { ambiguous: true, raw: a } : { key: g.value }
    const s = STATIC_BY_NAME.get(member[2])
    if (s) return s.ambiguous ? { ambiguous: true, raw: a } : { key: s.value }
    return { raw: a }
  }
  return { raw: a }
}

const keys = new Map() // key -> { read:[], write:[], twoWay:[] }
const viaParam = [] // 形参传参的 AppStorage 写入（不参与死键判定）
const unresolved = [] // 真解析不出（含常量歧义）

function record(key, kind, where) {
  if (!keys.has(key)) keys.set(key, { read: [], write: [], twoWay: [] })
  keys.get(key)[kind].push(where)
}

const reWrite = /AppStorage\.(?:setOrCreate|set)\s*(?:<[^>]*>)?\s*\(\s*([^,]+),/g
const reRead = /AppStorage\.get\s*(?:<[^>]*>)?\s*\(\s*([^)]+)\)/g
// `@StorageLink` 是**双向绑定**（用户一改就写回去）⇒ 单独记 twoWay，不能只算 read
const reLink = /@StorageLink\s*\(\s*([^)]+)\)/g
const reProp = /@StorageProp\s*\(\s*([^)]+)\)/g
const rePersist = /PersistentStorage\.(?:persistProp|persistProps)\s*\(\s*([^,)]+)/g

for (const { rel, text } of sources) {
  const paramNames = collectParamNames(text)
  const lines = text.split(/\r?\n/)
  lines.forEach((line, i) => {
    const t = line.trim()
    if (!t || /^(\/\/|\*|\/\*)/.test(t)) return
    const where = `${rel}:${i + 1}`
    for (const [re, kind] of [[reWrite, 'write'], [reRead, 'read'], [reLink, 'twoWay'], [reProp, 'read'], [rePersist, 'write']]) {
      for (const m of t.matchAll(re)) {
        const r = resolveArg(m[1], paramNames)
        if (r.key !== undefined) {
          record(r.key, kind, where)
        } else if (r.viaParam) {
          viaParam.push(`${where}  ${kind}  ← 形参 ${m[1].trim()}`)
        } else if (r.ambiguous) {
          unresolved.push(`${where}  ${kind}  ← ${m[1].trim()}（常量歧义）`)
        } else {
          unresolved.push(`${where}  ${kind}  ← ${m[1].trim()}`)
        }
      }
    }
  })
}

const rows = [...keys.entries()]
  .map(([k, v]) => ({ key: k, r: v.read.length, w: v.write.length, t: v.twoWay.length }))
  .sort((a, b) => (b.r + b.w + b.t) - (a.r + a.w + a.t) || a.key.localeCompare(b.key))

const total = rows.length
const deadWrites = rows.filter((x) => x.w > 0 && x.r === 0 && x.t === 0)
const deadReads = rows.filter((x) => x.r > 0 && x.w === 0 && x.t === 0)
const onlyTwoWay = rows.filter((x) => x.r === 0 && x.w === 0 && x.t > 0) // 只有 @StorageLink（双向绑定，仍是活键）
const live = rows.filter((x) => !deadWrites.includes(x) && !deadReads.includes(x) && !onlyTwoWay.includes(x))

const ambigCount = [...GLOBAL_CONST.values(), ...STATIC_BY_NAME.values()].filter((c) => c.ambiguous).length
console.log(`扫描 ${files.length} 个文件；常量表 ${CLASS_CONST.size}（类静态）+ ${GLOBAL_CONST.size}（全局）条，其中歧义 ${ambigCount} 条；无法解析的实参 ${unresolved.length} 处；形参 via-param ${viaParam.length} 处`)
console.log(`唯一键 ${total} 个 / 使用点 ${rows.reduce((n, x) => n + x.r + x.w + x.t, 0)} 个（读 ${rows.reduce((n, x) => n + x.r, 0)} / 写 ${rows.reduce((n, x) => n + x.w, 0)} / 双向 ${rows.reduce((n, x) => n + x.t, 0)}）`)

if (unresolved.length) {
  console.log('\n── 无法解析（需人工确认是否动态键）──')
  for (const u of unresolved.slice(0, 20)) console.log('  ' + u)
  if (unresolved.length > 20) console.log(`  … 其余 ${unresolved.length - 20} 处`)
}
if (viaParam.length) {
  console.log('\n── 形参传参（via-param，不参与死键判定）──')
  for (const v of viaParam.slice(0, 20)) console.log('  ' + v)
  if (viaParam.length > 20) console.log(`  … 其余 ${viaParam.length - 20} 处`)
}

console.log(`\n── 死写（读0 / 双向0，但有写）：${deadWrites.length} 个 ⇒ 删除候选 ──`)
for (const x of deadWrites) console.log(`  读 0 写 ${String(x.w).padStart(2)} 双向 0  ${x.key}`)
console.log(`\n── 死读（写0 / 双向0，但有读）：${deadReads.length} 个 ⇒ 读的是没人写的键，需人决策 ──`)
for (const x of deadReads) console.log(`  读 ${String(x.r).padStart(2)} 写 0 双向 0  ${x.key}`)
if (onlyTwoWay.length) {
  console.log(`\n── 仅双向（无 AppStorage.get/set，只有 @StorageLink）：${onlyTwoWay.length} 个 ──`)
  for (const x of onlyTwoWay) console.log(`  读 0 写 0 双向 ${x.t}  ${x.key}`)
}
console.log(`\n── 活键（${live.length} 个，按使用点降序，前 32）──`)
for (const x of live.slice(0, 32)) {
  console.log(`  读 ${String(x.r).padStart(3)} 写 ${String(x.w).padStart(3)} 双向 ${String(x.t).padStart(3)}  ${x.key}`)
}

// `--list`：把全部键按字典序打出来（报告/对账用，不影响默认输出）
if (listMode) {
  console.log(`\n── 全部 ${total} 个键（字典序）──`)
  for (const x of [...rows].sort((a, b) => a.key.localeCompare(b.key))) {
    console.log(`  ${x.key}\t读${x.r}\t写${x.w}\t双向${x.t}`)
  }
}

// ── ④ 预算闸门（旧版漏了这段，`--check` 形同虚设）────────────────────────────
if (checkMode) {
  if (total > KEY_BUDGET) {
    console.error(`\n❌ AppStorage 唯一键 ${total} > 预算 ${KEY_BUDGET}（ratchet 只许降）`)
    console.error('   新增全局键会让 CI 变红。要么改用事件 / 局部状态，要么在 scripts/audit-appstorage.mjs')
    console.error('   里明确上调并说明理由。键明细：node scripts/audit-appstorage.mjs --list')
    process.exit(1)
  }
  if (total < KEY_BUDGET) {
    console.log(`\n提示：唯一键 ${total} < 预算 ${KEY_BUDGET}，可把 KEY_BUDGET 下调到 ${total}（只许降）`)
  }
  console.log(`\n✅ AppStorage 键预算通过：${total} / ${KEY_BUDGET}`)
}
