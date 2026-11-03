// ─────────────────────────────────────────────────────────────────────────────
// P5 纯函数单测 ②：common/shelf/CountLabel.ets
//
// 被测源码：entry/src/main/ets/common/shelf/CountLabel.ets（41 行，纯静态方法）
// 运行：    node scripts/tests/count-label.test.mjs
//
// ── 方式：源码文本提取 + 类型剥离 + 沙箱执行**真源码**（不是算法复刻）──────────
// 理由：`CountLabel` 是 2026-11-03 收敛出来的「计数文案唯一实现」，注释里列了收敛前
// 4 份各自拼的字符串（:5-10）。复刻一份到测试里 = 又造第 5 份，改文案时不会红。
// 这里直接跑 `stripTypeScriptTypes` 之后的真类体 ⇒ 文案一改（少个空格、换个量词）断言立刻红。
//
// ── 漂移防护 ─────────────────────────────────────────────────────────────────
//   L1 真源码执行；
//   L2 sentinel 钉住 3 个模板串原文（含 ` · ` 分隔符与「本/个分组」量词）；
//   L3 本文件无 import（`loadEtsModule` 会把它当零依赖模块，多余依赖出现即抛）。
//
// ── 口径来源（注释与调用点）─────────────────────────────────────────────────
//   · 分组卡片 `共12本 · 3个分组`，无子分组只 `共12本`  → CountLabel.ets:22-26，调用点 BookFolder.ets:757
//   · 批量页    `已选3本 · 2个分组`                    → CountLabel.ets:29-33，调用点 BookManagePage.ets:429
//   · 详情小字  `共12本`                               → CountLabel.ets:36-38，调用点 BookFolder.ets:723 / FolderInfoDialog.ets:271
// ─────────────────────────────────────────────────────────────────────────────
import { loadEtsModule, createRunner } from './_ets-harness.mjs'

const SRC = 'entry/src/main/ets/common/shelf/CountLabel.ets'
const mod = loadEtsModule(SRC)
const { CountLabel } = mod.exports
const t = createRunner('CountLabel 计数文案', { source: mod.source })

// ═══ 0. 漂移哨兵 ════════════════════════════════════════════════════════════
t.group('0. 漂移哨兵')
t.check('零依赖模块（源码无 import）', mod.imports.length === 0, '证据：CountLabel.ets:20-39 无 import')
t.check('默认导出与具名导出是同一个类', mod.exports.default === CountLabel, '证据：CountLabel.ets:41 `export default CountLabel`')
t.sentinel('groupCard 模板串仍是 `共N本 · M个分组`', /`共\$\{b\}本 · \$\{g\}个分组`/,
  '守 CountLabel.ets:25 —— 分隔符 ` · `（空格 + U+00B7 + 空格）是口径的一部分')
t.sentinel('selected 模板串仍是 `已选N本 · M个分组`', /`已选\$\{b\}本 · \$\{g\}个分组`/,
  '守 CountLabel.ets:32 —— 批量页前缀是「已选」不是「共」')
t.sentinel('groupCard 省略分支仍是 `共N本`', /: `共\$\{b\}本`/,
  '守 CountLabel.ets:25 冒号后的 else 分支')
t.sentinel('books() 仍是 `共N本` 且负数夹到 0', /共\$\{books > 0 \? books : 0\}本/,
  '守 CountLabel.ets:37')

// ═══ 1. groupCard：0 / 1 / N ════════════════════════════════════════════════
t.group('1. groupCard（分组卡片副标题）')
t.eq('0 本 0 分组 ⇒ `共0本`（不显示 0 个分组）', CountLabel.groupCard(0, 0), '共0本', '证据：CountLabel.ets:25 三元 `g > 0`')
t.eq('1 本 0 分组 ⇒ `共1本`（中文无复数变化）', CountLabel.groupCard(1, 0), '共1本', '证据：CountLabel.ets:25')
t.eq('12 本 3 分组 ⇒ 带分组半句', CountLabel.groupCard(12, 3), '共12本 · 3个分组', '证据：CountLabel.ets:25')
t.eq('1 本 1 分组 ⇒ 单数形态不变', CountLabel.groupCard(1, 1), '共1本 · 1个分组', '证据：CountLabel.ets:25')
t.eq('0 本 3 分组 ⇒ 仍显示分组半句', CountLabel.groupCard(0, 3), '共0本 · 3个分组', '证据：CountLabel.ets:23-25（只夹负数，0 保留）')
t.eq('负本数夹到 0', CountLabel.groupCard(-5, 0), '共0本', '证据：CountLabel.ets:23 `books > 0 ? books : 0`')
t.eq('负分组数夹到 0 ⇒ 省略半句', CountLabel.groupCard(12, -1), '共12本', '证据：CountLabel.ets:24-25')
t.eq('负数 × 负数 ⇒ 全 0', CountLabel.groupCard(-5, -1), '共0本', '证据：CountLabel.ets:23-25')

// ═══ 2. selected（批量页顶部）═══════════════════════════════════════════════
t.group('2. selected（批量页「已选…」）')
t.eq('什么都没选 ⇒ `已选0本`', CountLabel.selected(0, 0), '已选0本', '证据：CountLabel.ets:32')
t.eq('只选书 ⇒ `已选3本`', CountLabel.selected(3, 0), '已选3本', '证据：CountLabel.ets:32')
t.eq('选书 + 选分组 ⇒ 带分组半句', CountLabel.selected(3, 2), '已选3本 · 2个分组', '证据：CountLabel.ets:32')
t.eq('前缀是「已选」而非「共」', CountLabel.selected(12, 3).startsWith('已选'), true, '证据：CountLabel.ets:32')
t.eq('负数夹到 0', CountLabel.selected(-1, -1), '已选0本', '证据：CountLabel.ets:30-32')

// ═══ 3. books（详情小字）════════════════════════════════════════════════════
t.group('3. books（详情类小字）')
t.eq('0 本 ⇒ `共0本`', CountLabel.books(0), '共0本', '证据：CountLabel.ets:37')
t.eq('12 本 ⇒ `共12本`', CountLabel.books(12), '共12本', '证据：CountLabel.ets:37')
t.eq('负数夹到 0', CountLabel.books(-3), '共0本', '证据：CountLabel.ets:37')

// ═══ 4. 口径细节（不取整 / 无千分位 / 分隔符）═══════════════════════════════
t.group('4. 口径细节')
t.eq('分隔符是 ` · `（前后各一个空格）', CountLabel.groupCard(1, 1).slice(3, 6), ' · ',
  '证据：CountLabel.ets:25 模板中间是空格+·+空格')
t.eq('大数不加千分位', CountLabel.books(12345), '共12345本', '证据：CountLabel.ets:37 直接插值，无 toLocaleString')
t.eq('小数不取整（原样插入）', CountLabel.books(1.5), '共1.5本', '证据：CountLabel.ets:37 无 Math.round')
// 语义可疑点（已报告不改）：NaN/Infinity 走 `> 0` 为假的分支 → 显示「共0本」而不是报错。
t.eq('NaN ⇒ 兜底成 `共0本`（不抛错）', CountLabel.books(NaN), '共0本', '证据：CountLabel.ets:37 `NaN > 0` 为 false')
t.eq('Infinity ⇒ `共Infinity本`（无上限校验）', CountLabel.books(Infinity), '共Infinity本',
  '证据：CountLabel.ets:37 `Infinity > 0` 为 true，直接插值')

t.done()
