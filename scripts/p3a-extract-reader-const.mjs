// P3 批 A-1：把 ReaderPage3 的模块级常量块（245..327）搬到 common/reader/ReaderConst.ets
// 目的：ReaderPage3 减重、常量有单一来源（后续外部重复定义再逐个改为 import）。
// 安全性：只搬 `const`，值逐字保留；搬完主文件用 import 引用，行为零变化。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SRC = path.join(ROOT, 'entry/src/main/ets/pages/view/Reader/ReaderPage3.ets')
const OUT = path.join(ROOT, 'entry/src/main/ets/common/reader/ReaderConst.ets')
const dry = process.argv.includes('--dry-run')

const FROM = 245 // HL_DEV_DEFAULT
const TO = 326 // SYSTEM_CJK_FONT_NAME
const EXPECT_FIRST = 'HL_DEV_DEFAULT'
const EXPECT_LAST = "SYSTEM_CJK_FONT_NAME: string = '鸿蒙黑体'"

const raw = fs.readFileSync(SRC, 'utf8')
const nl = raw.includes('\r\n') ? '\r\n' : '\n'
const lines = raw.split(/\r?\n/)

if (!lines[FROM - 1].includes(EXPECT_FIRST)) throw new Error(`L${FROM} 断言失败：${lines[FROM - 1]}`)
if (!lines[TO - 1].includes(EXPECT_LAST)) throw new Error(`L${TO} 断言失败：${lines[TO - 1]}`)

const block = lines.slice(FROM - 1, TO)
// 给每个顶层 `const ` 加 export（缩进为空的行首）
const exported = block.map((l) => (l.startsWith('const ') ? 'export ' + l : l))
const names = block
  .filter((l) => l.startsWith('const '))
  .map((l) => l.slice('const '.length).split(/[:\s=]/)[0])
if (names.length === 0) throw new Error('没找到任何 const，断言失败')
if (names.some((n) => !/^[A-Z][A-Z0-9_]*$/.test(n))) throw new Error('存在非全大写常量名，需人工确认：' + names.join(','))

const header = [
  '// 阅读器**模块级常量**（2026-11-04 P3 批 A-1：从 `ReaderPage3.ets` 搬出，值逐字未改）。',
  '//',
  '// 为什么要独立成模块：这些是「排版标定 / 进度滑条 / 字体族名」的**唯一真源**，',
  '//   原先散在 1.2 万行的 ReaderPage3 顶部，外部还有 4 处重复定义（ReaderPager / CalibMode /',
  '//   MySetPage / ReaderCustomBg）。搬到这里之后，外部一律改为 import，杜绝"两处各留一份"。',
  '//',
  '// ⚠️ 改这里等于改排版标定与滑条行为：`HL_CALIB_KEY` 是线上存量键名（改了老用户的标定值就读不到），',
  '//   `RS_SETTING_VER` 是 readerSetting 迁移版本号（改默认值必须 +1 并补迁移，见原注释）。',
  '//',
  '// 回退：把这批常量搬回 ReaderPage3.ets 顶部并把本文件删掉（git revert 对应提交即可）。',
  '',
  ...exported,
  '',
].join(nl)

const importLine = `import { ${names.join(', ')} } from '../../../common/reader/ReaderConst';`
const replacement = [
  `// 2026-11-04（P3 批 A-1）：本段的模块级常量已搬到 \`common/reader/ReaderConst.ets\`（单一真源），`,
  `//   值逐字未改；下方用 import 引用。外部重复定义（ReaderPager / CalibMode / MySetPage / ReaderCustomBg）`,
  `//   后续逐个改为从同一模块 import。`,
  importLine,
]

const next = [...lines.slice(0, FROM - 1), ...replacement, ...lines.slice(TO)]
const before = lines.length
const after = next.length

console.log(`  常量个数：${names.length}`)
console.log(`  ${names.join(', ')}`)
console.log(`  ReaderPage3：${before} → ${after} 行（−${before - after}）`)
console.log(`  新模块：${header.split(/\r?\n/).length} 行`)

if (!dry) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true })
  fs.writeFileSync(OUT, header, 'utf8')
  fs.writeFileSync(SRC, next.join(nl), 'utf8')
  console.log('  ✓ 已写入')
} else {
  console.log('  [dry-run] 未写入')
}
