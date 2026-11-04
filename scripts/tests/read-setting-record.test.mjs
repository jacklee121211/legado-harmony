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

// ══════════════════════════════════════════════════════════════════════════════
// 五、S2-b-1：边界投影 pickReadSettingFields（只剔垃圾键，不改值）
// ══════════════════════════════════════════════════════════════════════════════

test('pickReadSettingFields：剔除 __ob_/脏键，13 个已知字段的值逐字段原样透传', () => {
  const live = Object.assign({}, DEF, { fontSize: 28, lineHeight: 1.05,
    '__ob_fontSize': 99, '__ob_themeColor': '#ff0000', legacySort: '更新排序' })
  const picked = M.pickReadSettingFields(live)
  assert.ok(picked !== null, '合法记录必须返回投影对象')
  assert.equal(Object.keys(picked).length, 13)
  assert.equal(M.hasLeakedObservingKeys(picked), false, '投影结果不得含 __ob_ 键')
  assert.equal(M.readSettingRecordEquals(picked, DEF), false, '投影不应把被改过的值还原成默认')
  assert.equal(picked.fontSize, 28, '值必须原样透传（不做纠正）')
  assert.equal(picked.lineHeight, 1.05)
  assert.equal(Object.prototype.hasOwnProperty.call(picked, 'legacySort'), false)
})

test('pickReadSettingFields：不满足 13 字段类型时返回 null（调用方原样透传，保持既有行为）', () => {
  assert.equal(M.pickReadSettingFields({ fontName: '鸿蒙黑体' }), null,
    '证据：页面 history `:4133-4144` 的"持久位被污染"形态')
  assert.equal(M.pickReadSettingFields(null), null)
  assert.equal(M.pickReadSettingFields(undefined), null)
  assert.equal(M.pickReadSettingFields('fontSize=18'), null)
  const missingPort = Object.assign({}, DEF)
  delete missingPort.viewPortWidth
  assert.equal(M.pickReadSettingFields(missingPort), null, '缺运行时字段也应原样透传而不是补值')
})

test('页面边界已收口：22 处一律走 settingForBoundary()，不再直接交 readerSetting', () => {
  const sites = (PAGE_SRC.match(/setPageConfig\(this\.settingForBoundary\(\)\)/g) ?? []).length
  assert.equal(sites, 16, `setPageConfig 边界点应全部走投影（实测 ${sites}）`)
  const puts = (PAGE_SRC.match(/putSync\(`ReaderSetting_[^`]*`, this\.settingForBoundary\(\)\)/g) ?? []).length
  assert.equal(puts, 6, `ReaderSetting_ 落盘点应全部走投影（实测 ${puts}）`)
  // 旧的直传写法必须为 0（注释里提到可以，但 `(this.readerSetting)` 这种调用形态不行）
  assert.equal((PAGE_SRC.match(/setPageConfig\(this\.readerSetting\)/g) ?? []).length, 0)
  assert.equal((PAGE_SRC.match(/, this\.readerSetting\)/g) ?? []).length, 0)
  // 单一出口方法必须存在
  assert.match(PAGE_SRC, /private settingForBoundary\(\): readerCore\.ReaderSetting \{/,
    '证据：S2-b-1 的边界出口必须留在页面上（引擎要纯接口对象）')
})

// ══════════════════════════════════════════════════════════════════════════════
// 六、S2-b-2：`@ObservedV2` 模型壳的接线约定（只能静态断言 —— 装饰器让 harness 无法加载该文件）
// ══════════════════════════════════════════════════════════════════════════════

const STATE_SRC = readSource('entry/src/main/ets/common/reader/ReadSettingState.ets')

test('模型壳：@ObservedV2 装饰 class、13 个 @Trace 字段与 SDK 字段一一对应', () => {
  assert.match(STATE_SRC, /@ObservedV2\s*\nexport class ReadSettingState/, '证据：官方 arkts-new-observedv2-and-trace「@ObservedV2仅能装饰class」')
  for (const k of SDK_FIELDS) {
    const re = new RegExp(String.raw`@Trace ${k}: `)
    assert.match(STATE_SRC, re, `模型缺少 @Trace 字段 ${k}`)
  }
  // @Trace 数量 = 13（多一个少一个都要显式面对）
  assert.equal((STATE_SRC.match(/@Trace /g) ?? []).length, 13)
  // @Trace 不支持 Function ⇒ 模型里不许出现回调字段（本轮约定）
  assert.equal(/@Trace\s+\w+\s*:\s*\(/.test(STATE_SRC), false, '证据：@Trace不支持观察Function类型')
})

test('模型壳：snapshot() 是唯一外部出口，且逐字段显式拷贝（天然不含 __ob_）', () => {
  assert.match(STATE_SRC, /snapshot\(\): ReadSettingRecord \{/, '模型必须提供 snapshot() 纯对象出口')
  // snapshot 内部不得整对象外抛（禁止 `return this` / `JSON.stringify(this)`）
  assert.equal(/return this\s*;/.test(STATE_SRC), false, '禁止把模型实例本身交出去')
  assert.equal(/JSON\.stringify\(this\)/.test(STATE_SRC), false, '证据：FAQ faqs-arkui-1587 —— __ob_ 会被序列化出来')
  // 13 个字段在 snapshot 里都要出现（逐字段拷贝，不是 spread）
  const snapStart = STATE_SRC.indexOf('snapshot(): ReadSettingRecord {')
  const snapEnd = STATE_SRC.indexOf('\n  }', snapStart)
  const snap = STATE_SRC.slice(snapStart, snapEnd)
  for (const k of SDK_FIELDS) {
    assert.match(snap, new RegExp(String.raw`${k}: this\.${k}`), `snapshot 漏字段 ${k}`)
  }
})

test('页面侧：模型必须是普通成员（不能套 @State/@Prop/@Link，否则编译报错）', () => {
  assert.match(PAGE_SRC, /private settingState: ReadSettingState = new ReadSettingState\(this\.readerSetting\)/,
    '证据：arkts-v1-v2-mixusage 限制条件 2「V1不支持用装饰器接收@ObservedV2装饰的class」')
  // 反向断言：不许出现带装饰器的持有形态
  assert.equal(/(@State|@Prop|@Link|@StorageLink)\s+settingState/.test(PAGE_SRC), false,
    '模型实例不能加任何 V1 装饰器')
  // 边界出口必须过一遍模型（S2-b-2/S2-c 的"迁移期同步"）
  assert.match(PAGE_SRC, /this\.settingState\.syncFromExcept\(this\.readerSetting, this\.MIGRATED_SETTING_FIELDS\)/,
    '边界投影应先把当前值同步进模型（跳过已迁字段）')
  assert.match(PAGE_SRC, /pickReadSettingFields\(this\.settingState\.snapshot\(\)\)/,
    '边界必须取模型快照后再走白名单兜底')
})

// ══════════════════════════════════════════════════════════════════════════════
// 七、S2-c：字段迁移棘轮（直写点只许降）+ 迁移规范
// ══════════════════════════════════════════════════════════════════════════════

/** 总直写点基线：迁移前 67；迁移期因为"模型→快照"也要写一行，总数不降反略升 ⇒ 单看它没意义 */
const RATCHET_DIRECT_WRITES = 63
/**
 * **真正的进度计**：还没有迁到模型的字段，其直写点数量（只许降）。
 *
 * 为什么不用"直写点总数"当棘轮：迁移期每个已迁字段都要多一行 `readerSetting.X = settingState.X`
 * （模型 → 页面快照，供 259 个未改的读点使用），于是"总数"在迁移期**不降反升**。
 * 实测：迁了 6 个字段后总数 63（迁移前 67），其中 21 行是"模型→快照"同步，
 * 真正还没迁的字段只剩 42 处 —— 这个 42 才是可下降的度量。
 *
 * 迁移流水（实测，每次 = 该字段的赋值点数）：
 *   fontSize / lineHeight / fontName / fontPath / fontWeight / nightMode → 42
 *   themeColor（8）→ 34
 *   themeBgImg（10：9 运行期 + 1 装载期接续）→ 24
 *   flipMode（4：2 运行期 switchReadMode + 接续 + loadReadMode 派生）→ 20
 *   scaledDensity / viewPortWidth / viewPortHeight（2 + 3 + 3）→ 12
 *   fontColor（12，此前一直漏登记 —— 见施工记录 §89）→ **0**
 *
 * ⚠️ 2026-11-04：本值已到 0，即 13 个字段全部迁完。此时**不要**把这条棘轮删掉：
 *    它仍是"有人新写 `this.readerSetting.X = 非模型值`"的防线（新写点必须走模型或边界出口）。
 */
const RATCHET_UNMIGRATED_WRITES = 0

/**
 * 去掉注释后的页面源码。
 * ⚠️ 必须剔注释再数：迁移期我在注释里写了"必须写成 `this.readerSetting.fontSize = this.settingState.fontSize`"
 *    这种**示例代码**，裸正则会把注释也算成写点（实测因此一次多计了 1~2 处）。
 */
const PAGE_CODE = PAGE_SRC
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/(^|[^:])\/\/.*$/gm, '$1')

test('棘轮：页面直写 readerSetting 的点数只许降（当前基线 63）', () => {
  const direct = (PAGE_CODE.match(/this\.readerSetting\.\w+\s*=[^=]/g) ?? []).length
  assert.ok(direct <= RATCHET_DIRECT_WRITES,
    `直写点从 ${RATCHET_DIRECT_WRITES} 涨到 ${direct} 了：新写点必须走模型或 settingForBoundary()，`
    + `不要直接改 @State readerSetting（迁移期只许降）`)
  // 若降了：提示同步下调基线（这条不是失败，是提醒）
  if (direct < RATCHET_DIRECT_WRITES) {
    console.log(`     ℹ️ 直写点已降到 ${direct}，请把 RATCHET_DIRECT_WRITES 同步下调到 ${direct}`)
  }
})

test('进度计：未迁字段的直写点只许降（迁移期的真实进度指标）', () => {
  let unmigrated = 0
  for (const raw of PAGE_CODE.split('\n')) {
    const m = /^this\.readerSetting\.(\w+)\s*=(?!=)\s*(.*)$/.exec(raw.trim())
    if (!m) continue
    if (!m[2].startsWith(`this.settingState.${m[1]}`)) unmigrated++
  }
  assert.ok(unmigrated <= RATCHET_UNMIGRATED_WRITES,
    `未迁字段的直写点从 ${RATCHET_UNMIGRATED_WRITES} 涨到 ${unmigrated}：`
    + `新写点请先迁到模型（或走 settingForBoundary()），不要直接改 @State readerSetting`)
  console.log(`     ℹ️ 未迁字段直写点 = ${unmigrated}（基线 ${RATCHET_UNMIGRATED_WRITES}，迁完会降到 0）`)
  if (unmigrated < RATCHET_UNMIGRATED_WRITES) {
    console.log(`     ℹ️ 已下降，请把 RATCHET_UNMIGRATED_WRITES 同步下调到 ${unmigrated}`)
  }
})

test('迁移规范：已迁字段在页面里只能"模型→快照"单向写，不能再出现直写', () => {
  const migrated = /private MIGRATED_SETTING_FIELDS: string\[\] = \[([^\]]*)\]/.exec(PAGE_SRC)
  assert.ok(migrated, '找不到 MIGRATED_SETTING_FIELDS 数组（迁移登记处）')
  const fields = migrated[1].split(',').map((s) => s.trim().replace(/['"]/g, '')).filter((s) => s.length > 0)
  assert.ok(fields.length >= 1, '至少应有一个字段已迁（本轮样板 = fontSize）')

  for (const f of fields) {
    // ① 不允许 `this.readerSetting.<f> = 任意其它值`（只允许 `= this.settingState.<f>`）
    //   ⚠️ 这里**刻意不用正则**：本字段迁移检查我连续写错两版正则
    //     （`\s*` 含换行导致跨行误判；`String.raw` 里 `[ \t]` 变成"反斜杠+t" 字符集），
    //     两次都让合规代码被判违规。改用逐行 split 取值 —— 语义直白、不受回溯影响。
    const okHits = []
    const badHits = []
    for (const rawLine of PAGE_CODE.split('\n')) {
      const line = rawLine.trim()
      const prefix = `this.readerSetting.${f}`
      const at = line.indexOf(prefix)
      if (at < 0) {
        continue
      }
      const rest = line.slice(at + prefix.length)
      // `=(?!=)`：只认赋值；否则 `=== / ==` 比较会被误判成写点（实测把
      // `if (… && this.readerSetting.fontPath === undefined` 判成了违规）。
      const m = /^[ \t]*=(?!=)[ \t]*(.*)$/.exec(rest)
      if (m === null) {
        continue // 不是赋值（比较运算 / 纯读取）
      }
      const rhs = m[1]
      if (rhs.startsWith(`this.settingState.${f}`)) {
        okHits.push(line)
      } else {
        badHits.push(line)
      }
    }
    assert.equal(badHits.length, 0,
      `字段 ${f} 已迁到模型，页面里的写点必须写成 "this.readerSetting.${f} = this.settingState.${f}"；`
      + `违规 ${badHits.length} 处：${badHits.join(' | ')}`)
    // ② 必须存在"模型 → 快照"的同步（否则 259 个读点会读到旧值）
    assert.ok(okHits.length > 0, `字段 ${f} 缺少"模型 → 页面快照"的同步语句`)
  }
})

test('装载期方向：读持久位后是"持久位 → 模型"，不是"模型 → 持久位"（防回归）', () => {
  // 装载点：`this.readerSetting = loaded as readerCore.ReaderSetting;` 之后必须把值灌进模型
  const loadIdx = PAGE_SRC.indexOf('this.readerSetting = loaded as readerCore.ReaderSetting;')
  assert.ok(loadIdx > 0, '找不到读持久位的整体赋值点')
  const after = PAGE_SRC.slice(loadIdx, loadIdx + 600)
  assert.match(after, /this\.settingState\.fontSize = this\.readerSetting\.fontSize/,
    '装载期必须把持久位里的值同步进模型；若反向覆盖，用户保存的字号每次进书都会丢')
  assert.equal(/this\.readerSetting\.fontSize = this\.settingState\.fontSize;[^]*?loaded as readerCore/.test(after), false,
    '装载期不允许反向覆盖快照')
})

