// 只读审计：找出「定义了但没有任何调用方」的打开类方法（openXxx / showXxx / maybeShowXxx）。
//
// 背景（2026-11-04 P4b 批 C-5）：`GroupType.openChipEditDialog` / `openGroupPanel` 两条链
//   全仓零调用，删掉后少了 96 行死代码。这类"死入口链"比"宿主化 controller"更值钱，
//   所以固化成审计工具，后续每批先跑一遍再动手。
//
// 用法：node scripts/audit-dead-open-methods.mjs [--json]
// 退出码：恒 0（这是审计报告，不是闸门）
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ETS = path.join(ROOT, 'entry/src/main/ets')
const asJson = process.argv.includes('--json')

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.ets')) out.push(p)
  }
  return out
}

const files = walk(ETS)
const sources = files.map((f) => ({
  rel: path.relative(ETS, f).split(path.sep).join('/'),
  text: fs.readFileSync(f, 'utf8'),
}))

// 定义：`private openXxx(...)` / `openXxx(...)`（含 async）；排除 @Builder 与生命周期
// 必须像「方法定义」：行首（无点号前缀）+ 以 { 结尾 + 可选返回类型
const DEF_RE = /^\s*(?:private\s+|public\s+|protected\s+|async\s+|static\s+)*(?:open|show|maybeShow)[A-Z]\w*\s*\([^)]*\)\s*(?::\s*[\w<>\[\]|. ]+)?\s*\{\s*$/gm
// 调用：`this.openXxx(` 或 `xxx.openXxx(`
const CALL_RE = /(?:this\.|[A-Za-z_$][\w$]*\??\.)(open|show|maybeShow)([A-Z]\w*)\s*\(/g

const defs = []
for (const { rel, text } of sources) {
  const lines = text.split(/\r?\n/)
  // 去掉块注释与行注释后再找定义（避免注释里的示例被误判）
  const stripped = text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' ')).replace(/\/\/[^\n]*/g, '')
  const sLines = stripped.split(/\r?\n/)
  sLines.forEach((line, i) => {
    DEF_RE.lastIndex = 0
    const m = DEF_RE.exec(line)
    if (!m) return
    const name = line.slice(m.index).match(/(?:open|show|maybeShow)[A-Z]\w*/)?.[0]
    if (!name) return
    defs.push({ rel, line: i + 1, name, raw: lines[i].trim() })
  })
}

// 统计每个名字的调用次数（排除定义行本身：定义行形如 `private openX(`，不含 `.` 前缀调用）
const callCount = new Map()
for (const { text } of sources) {
  CALL_RE.lastIndex = 0
  for (const m of text.matchAll(CALL_RE)) {
    const name = m[1] + m[2]
    callCount.set(name, (callCount.get(name) ?? 0) + 1)
  }
}
// 定义行自身会被 CALL_RE 误计（`this.openX()` 不会；但 `space.openX(` 之类不会出现在定义）
const dead = defs.filter((d) => (callCount.get(d.name) ?? 0) === 0)

if (asJson) {
  console.log(JSON.stringify(dead, null, 2))
  process.exit(0)
}

console.log(`扫描 ${files.length} 个 .ets；open/show/maybeShow 方法定义 ${defs.length} 个`)
console.log(`\n── 疑似零调用（需人工确认：可能被 @BuilderParam / 回调字段间接调用）: ${dead.length} 个 ──`)
for (const d of dead) console.log(`  ${d.rel}:${d.line}  ${d.name}()`)
console.log('\n注意：`@Builder`、回调字段（如 `onOpenSortPanel`）、以及父组件通过 builder 注入的调用不计入；')
console.log('      判定前必须再 grep 一遍方法名字符串（含注释说明"由谁来调"）。')
