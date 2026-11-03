// 2026-11-03（Ⅱ-5）：把代码里的「文件夹」表述统一成「分组」。
// 依据：用户原话「分组和文件夹实际上是一样的，表述不同，为了统一，我们全都改成分组，以后没有文件夹表述」。
//
// 安全边界（重要）：
//   · 只处理 entry/src/main/ets 下的 .ets；
//   · **跳过文件系统语义**的文件（ZipWriter / ReaderFontLib）与含 rawfile/沙箱/zip/mimetype 的行，
//     那些「文件夹」指真实目录，改成「分组」会胡说；
//   · 内部哨兵 `'文件夹'` 一并改成 `'分组'`（它只在 IndexShelf/GroupType 两处比较，运行期值，无持久化）。
//
// 用法：node scripts/fix-folder-wording.mjs --dry-run   （只打印计划）
//       node scripts/fix-folder-wording.mjs             （执行）
import fs, { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SRC = path.join(ROOT, 'entry/src/main/ets')
const dry = process.argv.includes('--dry-run')

const SKIP_FILES = new Set(['ZipWriter.ets', 'ReaderFontLib.ets'])
const SKIP_LINE = /rawfile|沙箱|mimetype|\bzip\b|zip 包|压缩包/i

const RULES = [
  ['个文件夹', '个分组'],
  ['子文件夹', '子分组'],
  ['文件夹', '分组'],
]

function walk(dir, out) {
  const { readdirSync, statSync } = fs
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name)
    const st = statSync(p)
    if (st.isDirectory()) walk(p, out)
    else if (name.endsWith('.ets')) out.push(p)
  }
  return out
}

const files = walk(SRC, [])
let totalChanged = 0
const plan = []

for (const f of files) {
  if (SKIP_FILES.has(path.basename(f))) continue
  const raw = readFileSync(f, 'utf8')
  if (!raw.includes('文件夹')) continue
  const lines = raw.split(/\r?\n/)
  let changed = 0
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (!line.includes('文件夹')) continue
    if (SKIP_LINE.test(line)) continue
    let next = line
    for (const [from, to] of RULES) next = next.split(from).join(to)
    if (next !== line) {
      plan.push(`${path.relative(SRC, f)}:${i + 1}\n    - ${line.trim()}\n    + ${next.trim()}`)
      lines[i] = next
      changed++
    }
  }
  if (changed > 0) {
    totalChanged += changed
    if (!dry) writeFileSync(f, lines.join('\r\n'), 'utf8')
  }
}

console.log(plan.join('\n'))
console.log(`\n${dry ? '[dry-run] ' : ''}将/已改动 ${totalChanged} 行，涉及 ${new Set(plan.map(p => p.split(':')[0])).size} 个文件`)
