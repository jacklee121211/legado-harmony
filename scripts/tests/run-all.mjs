// ─────────────────────────────────────────────────────────────────────────────
// P5 纯函数单测汇总入口：把 `scripts/tests/*.test.mjs` 四个文件串起来跑，
// 供 `scripts/check-all.mjs` 作为**一个**检查项接入（check-all 里只加一条）。
//
// 用法：
//   node scripts/tests/run-all.mjs        → 全通过 exit 0；任一失败 exit 1（并回显失败文件的完整输出）
//   node scripts/tests/group-tree.test.mjs → 单文件也能独立跑（每个文件都有独立 exit 语义）
//
// 为什么串成入口而不是在 check-all 里加四条：check-all 的每一项是「一个可独立归因的闸门」，
// 这四条属于同一个闸门（P5 纯函数单测），分开加会让汇总表变长且不好定位回归面。
// ─────────────────────────────────────────────────────────────────────────────
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))

const TESTS = [
  { file: 'group-tree.test.mjs', name: 'GroupTree 建树/深度/防环/hasSiblingNamed' },
  { file: 'count-label.test.mjs', name: 'CountLabel 计数文案（共N本 · M个分组）' },
  { file: 'shelf-collection.test.mjs', name: 'ShelfCollection.resolve / batchEntryGroup' },
  { file: 'shelf-prefs.test.mjs', name: 'ShelfPrefs.effectiveColumns（sm/md/lg/xl + 手动档）' },
]

let failed = 0
const results = []

for (const tst of TESTS) {
  const abs = path.join(HERE, tst.file)
  const r = spawnSync(process.execPath, [abs], { encoding: 'utf8' })
  const ok = r.status === 0
  if (!ok) {
    failed++
  }
  // 摘出子进程的「断言 N 条：通过 X，失败 Y」汇总行，让这里也能看出覆盖面
  const summary = (r.stdout || '')
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l.startsWith('断言 ')) ?? ''
  results.push({ ...tst, ok, code: r.status, summary, stdout: r.stdout, stderr: r.stderr })
  console.log(`  ${ok ? '✅' : '❌'} ${tst.file.padEnd(28)} ${summary || `（exit ${r.status}）`}`)
}

if (failed > 0) {
  for (const r of results.filter((x) => !x.ok)) {
    console.log(`\n──── ✗ ${r.file}（exit ${r.code}）────`)
    if (r.stdout) console.log(r.stdout.trimEnd())
    if (r.stderr) console.error(r.stderr.trimEnd())
  }
  console.log(`\n❌ P5 纯函数单测失败 ${failed} 个文件（共 ${results.length} 个）`)
  process.exit(1)
}
console.log(`\n✅ P5 纯函数单测全部通过（${results.length}/${results.length} 个文件）`)
process.exit(0)
