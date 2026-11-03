// ReaderConst 常量守护（2026-11-04 P3/P4 收尾新增）。
//
// 为什么单独测常量：`ReaderConst.ets` 是**排版标定 / 进度滑条 / 字体族名**的唯一真源，
//   其中 `HL_CALIB_KEY`、`RS_SETTING_VER` 是**线上存量值** —— 改一个字符，老用户的标定数据
//   就读不到、`readerSetting` 迁移会重跑。这类"字面量即契约"的东西适合用断言钉死。
//
// ⚠️ 本文件断言的**就是当前真值**（与 `ReaderPage3` 搬迁前逐字一致，见 docs §A-1）。
//   如果哪天确实要改这些值 → 修改常量 + 同步本测试 + 写迁移，三件事一起做；
//   只改常量不改测试，闸门会红（这是故意的）。
//
// 跑法：node scripts/tests/reader-const.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readSource } from './_ets-harness.mjs'

// ReaderConst.ets 只有 `export const`，没有 import、没有类 ⇒ 直接解析文本最稳，
// 不必进 vm（避免 `@kit.*` 之类的解析风险）。
const SRC = readSource('entry/src/main/ets/common/reader/ReaderConst.ets')

function constOf(name) {
  const m = new RegExp(String.raw`export const ${name}:\s*\w+\s*=\s*([^;]+);`).exec(SRC)
  assert.ok(m, `ReaderConst.ets 里找不到 ${name}`)
  return m[1].trim()
}

function numOf(name) {
  const raw = constOf(name)
  // 支持 `100 * PROGRESS_UNIT_PER_PCT` 这种表达式：先把已知常量替换成数字，再按 * 分段求值
  const js = raw.replace(/PROGRESS_UNIT_PER_PCT/g, constOf('PROGRESS_UNIT_PER_PCT'))
  const v = js.split('*').map((p) => Number(p.trim())).reduce((a, b) => a * b, 1)
  assert.ok(Number.isFinite(v), `${name} 不是可求值数字: ${raw}`)
  return v
}

function strOf(name) {
  const raw = constOf(name)
  const m = /^'([^']*)'$/.exec(raw)
  assert.ok(m, `${name} 不是单引号字符串: ${raw}`)
  return m[1]
}

test('进度滑条刻度：1% = 10 单位，上限 = 100%', () => {
  assert.equal(numOf('PROGRESS_UNIT_PER_PCT'), 10)
  assert.equal(numOf('PROGRESS_UNIT_MAX'), 1000)
})

test('进度气泡时序：宽 176vp / 显示 1200ms / 保持 700ms', () => {
  assert.equal(numOf('PROGRESS_TIP_W'), 176)
  assert.equal(numOf('PROGRESS_TIP_MS'), 1200)
  assert.equal(numOf('PROGRESS_HOLD_MS'), 700)
})

test('高亮标定默认值与上下界（行高倍率区间必须是 1.05–1.60）', () => {
  assert.equal(constOf('HL_DEV_DEFAULT'), 'false')
  assert.equal(numOf('HL_ADVANCE_RATIO'), 1.0)
  assert.equal(numOf('HL_INDENT_SLOTS'), 2)
  assert.equal(numOf('HL_DEF_TOP_PX'), 230)
  assert.equal(numOf('HL_DEF_WIDTH_RATIO'), 0.861)
  assert.equal(numOf('HL_DEF_LINE_MUL'), 1.258)
  assert.equal(numOf('HL_LINE_MUL_MIN'), 1.05)
  assert.equal(numOf('HL_LINE_MUL_MAX'), 1.6)
  assert.equal(numOf('HL_BOTTOM_RESERVED_PX'), 0)
})

test('线上存量键名与迁移版本号（改了老数据就丢，必须走迁移）', () => {
  assert.equal(strOf('HL_CALIB_KEY'), 'TtsHlCalibV3')
  assert.equal(numOf('RS_SETTING_VER'), 2)
})

test('系统 CJK 字体族名：真机实测为「鸿蒙黑体」（不是 HarmonyOS Sans SC）', () => {
  assert.equal(strOf('SYSTEM_CJK_FONT_NAME'), '鸿蒙黑体')
})
