// 2026-11-03（P1/R1）：把另外 6 个"一律 push(READER)"的入口改成走 `ReaderEntry`。
// 每条都是**精确字符串替换**（同一文件内替换次数必须等于预期，否则报错不写）。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const dry = process.argv.includes('--dry-run')
const IMP = "import { ReaderEntry } from '../../common/reader/ReaderEntry'"

const JOBS = [
  {
    file: 'entry/src/main/ets/pages/Index.ets',
    importAnchor: /^import .*from '\.\.\/common\/router\/AppRouter'.*$/m,
    importLine: "import { ReaderEntry } from '../common/reader/ReaderEntry'",
    subs: [
      { from: "      if (!AppRouter.push(RouteName.READER, rp)) {", to: "      if (!ReaderEntry.open(this.getUIContext(), rp.bookData, { param: rp })) {", expect: 1 },
      { from: "      if (!AppRouter.push(RouteName.READER, rp)) {", to: "      if (!ReaderEntry.open(this.getUIContext(), rp.bookData, { param: rp })) {", expect: 1 },
    ],
  },
  {
    file: 'entry/src/main/ets/pages/view/BookDetailPage.ets',
    importAnchor: /^import AppRouter.*from '.*AppRouter'.*$/m,
    importLine: "import { ReaderEntry } from '../../common/reader/ReaderEntry'",
    subs: [
      { from: '                    AppRouter.push(RouteName.READER, rp)', to: '                    ReaderEntry.open(this.getUIContext(), rp.bookData, { param: rp })', expect: 1 },
      { from: '            AppRouter.push(RouteName.READER, rp)', to: '            ReaderEntry.open(this.getUIContext(), rp.bookData, { param: rp })', expect: 1 },
      { from: '          AppRouter.push(RouteName.READER, rp)', to: '          ReaderEntry.open(this.getUIContext(), rp.bookData, { param: rp })', expect: 1 },
    ],
  },
  {
    file: 'entry/src/main/ets/pages/view/myCenter/MyCenter.ets',
    importAnchor: /^import AppRouter.*from '.*AppRouter'.*$/m,
    importLine: "import { ReaderEntry } from '../../../common/reader/ReaderEntry'",
    subs: [
      { from: "    AppRouter.push(RouteName.READER, { bookData: book } as ReaderRouteParam)", to: "    ReaderEntry.open(this.getUIContext(), book)", expect: 1 },
    ],
  },
  {
    file: 'entry/src/main/ets/pages/view/myCenter/ReadStatsPage.ets',
    importAnchor: /^import AppRouter.*from '.*AppRouter'.*$/m,
    importLine: "import { ReaderEntry } from '../../../common/reader/ReaderEntry'",
    subs: [
      { from: "    AppRouter.push(RouteName.READER, { bookData: row.book } as ReaderRouteParam)", to: "    ReaderEntry.open(this.getUIContext(), row.book)", expect: 1 },
    ],
  },
]

const report = []
for (const job of JOBS) {
  const p = path.join(ROOT, job.file)
  if (!fs.existsSync(p)) { report.push(`[skip] 不存在 ${job.file}`); continue }
  let t = fs.readFileSync(p, 'utf8')
  const orig = t
  let ok = true
  for (const s of job.subs) {
    const n = t.split(s.from).length - 1
    if (n !== s.expect) { report.push(`[${job.file}] 期望 ${s.expect} 处、实际 ${n} 处：${s.from.slice(0, 50)}`); ok = false; continue }
    t = t.split(s.from).join(s.to)
    report.push(`[${job.file}] ✓ ${n} 处：${s.from.trim().slice(0, 44)}`)
  }
  if (!ok) { report.push(`[${job.file}] 跳过写入（有未匹配）`); continue }
  if (!t.includes(job.importLine)) {
    const m = t.match(job.importAnchor)
    if (m) { t = t.replace(m[0], m[0] + '\n' + job.importLine); report.push(`[${job.file}] + import`) }
    else report.push(`[${job.file}] ⚠️ 找不到 import 锚点，未加 import（构建会报未定义）`)
  }
  if (t !== orig) { if (!dry) fs.writeFileSync(p, t, 'utf8'); report.push(`[${job.file}] 写入（${t.length - orig.length} 字符）`) }
}
console.log(report.join('\n'))
console.log(`\n${dry ? '[dry-run] ' : ''}完成`)
