// 设置**纯记录层**单测（2026-11-04 渲染侧 S2-a 新增）。
//
// 守三件事：
//   ① **形状真源**：13 个字段与 SDK `readerCore.ReaderSetting` 声明同集合，且默认值与
//      `ReaderPage3` 里那份 `@State readerSetting` 字面量**逐字段一致**（页面改了默认值而这里没跟 ⇒ 红）；
//   ② **编解码语义**：脏数据被拒/回退、多余键（含 `@ObservedV2` 的 `__ob_` 外壳）被丢弃、往返一致；
//   ③ **`__ob_` 防线**：落盘出口只吐普通对象，`hasLeakedObservingKeys()` 能识别泄漏。
//
// 跑法：node scripts/tests/read-setting-record.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadEtsModule, readSource } from './_ets-harness.mjs'

// ── 依赖注入：本模块只 import 一个常量（单一真源在 ReaderConst），从**源码文本**取真值注入 ──
const CONST_SRC = readSource('entry/src/main/ets/common/reader/ReaderConst.ets')
const fontNameMatch = /export const SYSTEM_CJK_FONT_NAME:\s*string\s*=\s*'([^']+)'/.exec(CONST_SRC)
assert.ok(fontNameMatch, 'ReaderConst.ets 里找不到 SYSTEM_CJK_FONT_NAME')
const SYSTEM_CJK_FONT_NAME = fontNameMatch[1]

const mod = loadEtsModule('entry/src/main/ets/common/reader/ReadSettingRecord.ets', {
  bindings: { SYSTEM_CJK_FONT_NAME }
})
const M = mod.exports

// ── 页面真值：S2-a 之后默认值**只存在于记录层**，页面必须改为调用它（单一真源）──
const PAGE_SRC = readSource('entry/src/main/ets/pages/view/Reader/ReaderPage3.ets')

/** 迁移前的默认值（原 `ReaderPage3.ets:1799-1828` 的 `@State readerSetting` 字面量，值逐字未改） */
const EXPECTED_DEFAULTS = {
  fontSize: 18,
  fontWeight: 400,
  fontColor: '#000000',
  fontPath: '/system/fonts/HarmonyOS_Sans_SC.ttf',
  lineHeight: 1.9,
  nightMode: false,
  themeColor: 'rgba(248, 249, 250, 1)',
  themeBgImg: '',
  flipMode: '0'
}

/** SDK 声明的字段集合（取证：sdk/default/hms/ets/api/@hms.core.readerservice.readerComponent.d.ets:69-200） */
const SDK_FIELDS = [
  'fontName', 'fontSize', 'fontWeight', 'fontColor', 'fontPath', 'lineHeight', 'nightMode',
  'themeColor', 'themeBgImg', 'flipMode', 'scaledDensity', 'viewPortWidth', 'viewPortHeight'
]

const DEF = M.defaultReadSettingRecord(3.375, 1320, 2848)

// ══════════════════════════════════════════════════════════════════════════════
// 一、形状真源
// ══════════════════════════════════════════════════════════════════════════════

test('字段集合与 SDK ReaderSetting 声明一致（13 个，同名同序）', () => {
  // ⚠️ 不能直接 deepEqual：这个数组是在 vm 沙箱里创建的，跨 realm 的原型不同，
  //   assert/strict 的 deepEqual 会因原型不等而失败（实测踩过）。比内容即可。
  assert.equal(JSON.stringify([...M.READ_SETTING_FIELDS]), JSON.stringify(SDK_FIELDS),
    '证据：SDK @hms.core.readerservice.readerComponent.d.ets:69-200 的 13 个 optional 字段')
  assert.equal(M.READ_SETTING_FIELDS.length, 13)
})

test('默认记录 = 迁移前页面的 readerSetting 默认字面量（逐字段，值不得漂移）', () => {
  for (const key of Object.keys(EXPECTED_DEFAULTS)) {
    assert.equal(DEF[key], EXPECTED_DEFAULTS[key],
      `${key} 与迁移前默认值不一致：记录=${JSON.stringify(DEF[key])} 迁移前=${JSON.stringify(EXPECTED_DEFAULTS[key])}`)
  }
  assert.equal(DEF.fontName, SYSTEM_CJK_FONT_NAME,
    '记录的默认族名必须等于 ReaderConst.SYSTEM_CJK_FONT_NAME（真机实测 = 鸿蒙黑体）')
  // 3 个运行时字段来自入参，不得写死
  assert.equal(DEF.scaledDensity, 3.375)
  assert.equal(DEF.viewPortWidth, 1320)
  assert.equal(DEF.viewPortHeight, 2848)
})

test('页面默认值改为调用记录层（单一真源，页面不再自己写一份字面量）', () => {
  assert.match(PAGE_SRC, /@State readerSetting: readerCore\.ReaderSetting = defaultReadSettingRecord\(/,
    '证据：S2-a 后页面默认值必须由 ReadSettingRecord.defaultReadSettingRecord() 产出')
  assert.match(PAGE_SRC, /from '\.\.\/\.\.\/\.\.\/common\/reader\/ReadSettingRecord'/,
    '页面对记录层的 import 必须存在（否则又退化成两份真值）')
  // 页面不应再出现"直接写字面量默认值"的老形态
  assert.equal(/readerSetting: readerCore\.ReaderSetting = \{/.test(PAGE_SRC), false,
    '页面里不应再残留 readerSetting 的字面量默认值（与记录层重复）')
})

test('scaledDensity 非法（<=0 / NaN）时兜底为 1', () => {
  assert.equal(M.defaultReadSettingRecord(0, 1, 1).scaledDensity, 1, '证据：页面 :1823-1825 的三元兜底')
  assert.equal(M.defaultReadSettingRecord(-2, 1, 1).scaledDensity, 1)
  assert.equal(M.defaultReadSettingRecord(Number.NaN, 1, 1).scaledDensity, 1)
})

// ══════════════════════════════════════════════════════════════════════════════
// 二、编解码语义
// ══════════════════════════════════════════════════════════════════════════════

test('空/undefined 输入 → 全部回退到 fallback', () => {
  assert.deepEqual(M.fromReadSettingRecord(undefined, DEF), DEF)
  assert.deepEqual(M.fromReadSettingRecord(null, DEF), DEF)
  assert.deepEqual(M.fromReadSettingRecord({}, DEF), DEF)
})

test('脏数据逐字段回退（不静默造值）', () => {
  const dirty = {
    fontSize: '18',            // 字符串 ⇒ 回退
    fontWeight: null,          // null ⇒ 回退
    nightMode: 'true',         // 字符串 ⇒ 回退
    lineHeight: 2.4,           // 合法 ⇒ 采纳
    scaledDensity: 0,          // 非法 ⇒ 回退
    fontPath: 123              // 类型不符 ⇒ 回退
  }
  const r = M.fromReadSettingRecord(dirty, DEF)
  assert.equal(r.fontSize, DEF.fontSize)
  assert.equal(r.fontWeight, DEF.fontWeight)
  assert.equal(r.nightMode, DEF.nightMode)
  assert.equal(r.scaledDensity, DEF.scaledDensity)
  assert.equal(r.fontPath, DEF.fontPath)
  assert.equal(r.lineHeight, 2.4, '合法字段必须被采纳')
})

test('多余键被丢弃：含 @ObservedV2 的 __ob_ 外壳键与历史脏字段', () => {
  const polluted = Object.assign({}, DEF, {
    '__ob_fontSize': 22,
    '__ob_lineHeight': 2.2,
    'legacySortOrder': '最近阅读',
    'webdavUrl': 'http://x'
  })
  const r = M.fromReadSettingRecord(polluted, DEF)
  assert.equal(Object.keys(r).length, 13, '输出必须恰好 13 个键（证据：SDK 接口只有 13 个字段）')
  assert.equal(M.hasLeakedObservingKeys(r), false, '输出不得含 __ob_ 键')
  assert.equal(JSON.stringify(r).includes('legacySortOrder'), false)
})

test('往返一致：from(to(x)) === x', () => {
  const samples = [
    DEF,
    M.fromReadSettingRecord({ fontSize: 28, lineHeight: 1.4, nightMode: true,
      themeColor: '#202224', fontColor: '#ffffff' }, DEF),
    M.fromReadSettingRecord({ fontName: '宋体', fontSize: 12, flipMode: '3' }, DEF)
  ]
  for (const s of samples) {
    const back = M.fromReadSettingRecord(M.toReadSettingRecord(s, DEF), DEF)
    assert.equal(M.readSettingRecordEquals(back, s), true,
      `往返不一致：${JSON.stringify(s)} → ${JSON.stringify(back)}`)
  }
})

// ══════════════════════════════════════════════════════════════════════════════
// 三、类型体检（复刻并加深页面 :4133-4144 的那道"丢弃重建"判据）
// ══════════════════════════════════════════════════════════════════════════════

test('isValidReadSettingRecord：正常记录通过，被污染/缺字段的记录被拒', () => {
  assert.equal(M.isValidReadSettingRecord(DEF), true)
  // 页面历史事故形态：持久位里不是"带 fontSize/lineHeight 的对象"
  assert.equal(M.isValidReadSettingRecord({ fontName: '鸿蒙黑体' }), false,
    '证据：ReaderPage3.ets:4133-4144 的判据（只查 fontSize/lineHeight 的 number 性）')
  assert.equal(M.isValidReadSettingRecord(null), false)
  assert.equal(M.isValidReadSettingRecord(undefined), false)
  assert.equal(M.isValidReadSettingRecord('fontSize=18'), false)
  // 逐字段类型全查（比页面那道更严，见 ReadSettingRecord.ets 注释）
  const badBool = Object.assign({}, DEF, { nightMode: 1 })
  assert.equal(M.isValidReadSettingRecord(badBool), false)
  const badNum = Object.assign({}, DEF, { viewPortWidth: '1320' })
  assert.equal(M.isValidReadSettingRecord(badNum), false)
})

// ══════════════════════════════════════════════════════════════════════════════
// 四、__ob_ 防线
// ══════════════════════════════════════════════════════════════════════════════

test('hasLeakedObservingKeys：能识别 V2 外壳键，正常记录不误报', () => {
  assert.equal(M.hasLeakedObservingKeys({ '__ob_fontSize': 18 }), true,
    '证据：FAQ faqs-arkui-1587「@ObservedV2与@Trace装饰的对象key都带有__ob_」')
  assert.equal(M.hasLeakedObservingKeys(DEF), false)
  assert.equal(M.hasLeakedObservingKeys(null), false)
  assert.equal(M.hasLeakedObservingKeys(undefined), false)
})

test('落盘出口形态：13 键、无 __ob_、无函数值（可直接交给 Preferences/引擎）', () => {
  const out = M.toReadSettingRecord(DEF, DEF)
  const json = JSON.stringify(out)
  assert.equal(Object.keys(out).length, 13)
  assert.equal(json.includes('__ob_'), false)
  assert.equal(json.includes('function'), false)
  // 交给 ReaderKit 的接口全是 optional 字段 ⇒ 这里只需保证键名与 SDK 一致
  for (const k of SDK_FIELDS) {
    assert.ok(Object.prototype.hasOwnProperty.call(out, k), `输出缺字段 ${k}`)
  }
})
