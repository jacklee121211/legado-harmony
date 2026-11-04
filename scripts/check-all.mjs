// 一键跑全部**可本地验证**的质量闸门（2026-11-03 新增，P1 工程能力）。
//
// 设计原则：
//   · 只跑"纯静态/纯逻辑"的检查 —— 不依赖 DevEco SDK、不依赖真机，因此能在 CI（ubuntu）跑；
//   · `devecocli build` 与 `MCP check` 不在本脚本内（本地开发必跑，CI 无 SDK 跑不了）；
//   · 任一检查非 0 退出 ⇒ 本脚本非 0 退出（CI 直接红）。
//
// 用法：node scripts/check-all.mjs
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))

const CHECKS = [
  // 单一通路闸门（零预算规则 + ratchet 存量账）
  { script: 'check-single-path.mjs', name: '单一通路（写入口/树/计数/事件出口…）' },
  // 弹窗闸门（禁裸 open / 旧 API / controller 预算）
  { script: 'check-dialog-usage.mjs', name: '弹窗统一（DialogHost）' },
  // 事件合并语义的逻辑测试（复刻 GroupEvents.emitFromBump 算法，4 条断言）
  { script: 'verify-group-event-coalescing.mjs', name: '事件合并逻辑（4 断言）' },
  // AppStorage 键预算（ratchet，只许降）：新增全局键会让 CI 变红
  { script: 'audit-appstorage.mjs', args: ['--check'], name: 'AppStorage 键预算（80，只许降）' },
  // 零调用 open/show 方法（死入口）：新增死入口会让 CI 变红
  { script: 'audit-dead-open-methods.mjs', args: ['--check'], name: '死入口（零调用 open 方法）' },
  // 零 import 死文件（新增死文件即红；预算 13 → 7 → 5 → 0，只许降）
  { script: 'audit-dead-files.mjs', args: ['--check'], name: '死文件（零 import，预算 0 只许降）' },
  // P5 纯函数单测（2026-11-03 起；2026-11-04 增 ReadSettingRecord）= GroupTree / CountLabel /
  // ShelfCollection / ShelfPrefs / ReaderConst / BookNaming / 迁移 SQL / 设置记录层，共 8 个文件。
  // 入口是 tests/run-all.mjs —— 它串跑 tests/*.test.mjs（各自可独立执行）。
  // 这些测试用 `node:module.stripTypeScriptTypes` 直接执行 `entry/src/main/ets/**` 的**真源码**
  // （不 import .ets、不依赖 SDK/真机），但仍要求 **Node >= 22.13**（该 API 的起始版本）。
  // ⚠️ CI 目前是 node-version: "20"（.github/workflows/quality-gates.yml），会以清晰的
  //    「需要 Node >= 22.13」信息失败 —— 需把该 workflow 的 node 版本升到 22（不在本文件改动范围）。
  { script: 'tests/run-all.mjs', name: 'P5 纯函数单测（8 文件，含设置记录层）' },
]

let failed = 0
const results = []

for (const c of CHECKS) {
  const abs = path.join(HERE, c.script)
  const r = spawnSync(process.execPath, [abs, ...(c.args ?? [])], { encoding: 'utf8' })
  const ok = r.status === 0
  if (!ok) {
    failed++
  }
  results.push({ name: c.name, script: c.script, ok, code: r.status })
  // 失败时把子进程输出原样打出来，方便定位（成功时只打一行摘要）
  if (!ok) {
    console.log(`\n──── ✗ ${c.script} ────`)
    if (r.stdout) console.log(r.stdout.trimEnd())
    if (r.stderr) console.error(r.stderr.trimEnd())
  }
}

console.log('\n═══ 质量闸门汇总 ═══')
for (const r of results) {
  console.log(`  ${r.ok ? '✅' : '❌'} ${r.name.padEnd(34)} ${r.script}（exit ${r.code}）`)
}
if (failed === 0) {
  console.log(`\n✅ 全部通过（${results.length}/${results.length}）`)
  process.exit(0)
}
console.log(`\n❌ 失败 ${failed} 项（共 ${results.length} 项）`)
process.exit(1)
