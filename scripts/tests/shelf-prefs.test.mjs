// ─────────────────────────────────────────────────────────────────────────────
// P5 纯函数单测 ③：common/utils/ShelfPrefs.ets —— 宫格列数（effectiveColumns / autoColumns）
//
// 被测源码：entry/src/main/ets/common/utils/ShelfPrefs.ets（398 行）
// 运行：    node scripts/tests/shelf-prefs.test.mjs
// ⚠️ 任务书写的路径是 `common/shelf/ShelfPrefs.ets`，**实际文件在 `common/utils/ShelfPrefs.ets`**
//    （全工程只有这一份，见 `ShelfCollection.ets:1 import … from '../utils/ShelfPrefs'`）。
//
// ── 方式：源码文本提取 + 类型剥离 + 沙箱执行真源码 ────────────────────────────
// 理由：列数口径是「手机永远 3 列」的硬约束（源码 :119-133 有一段演进史注释），
// 复刻成第二份代码后，真源被改动测试不会红。这里直接执行真类体。
//
// `ShelfPrefs` 不是纯函数类：它 import 了 `PreferencesUtil`（真持久化）与 `CommonConstants`，
// 还在 `setUserColumns` 里写 `AppStorage`。处理办法是**注入替身**（不改源码）：
//   · `PreferencesUtil.getSync/putSync` → 内存 Map（并记录每次调用的 key/preferenceName）；
//   · `AppStorage.setOrCreate` → 内存 Map（作为 vm 沙箱全局）；
//   · `CommonConstants.PREFERENCES_BOOK_DATA_KEY` → 固定串 'book_data'。
// 被测的两个方法（`autoColumns` :148-160 / `effectiveColumns` :197-202）本身零 IO，
// 所以断言是确定性的；`getUserColumns` :163-175 的夹取逻辑靠替身也能覆盖。
//
// ── 漂移防护 ─────────────────────────────────────────────────────────────────
//   L1 真源码执行；L2 sentinel 钉住断点分支与夹取表达式；L3 import 绑定严格注入
//   （源码新增依赖 ⇒ 本测试立刻抛「未注入绑定」）。
//   L4 本文件额外断言**私有键名的字面值**（`shelf_grid_columns` / `shelfGridColumns`）——
//      这两个串是跨文件契约（6 个界面用 `@StorageProp(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE)`），
//      改名会静默丢用户设置，必须有断言拦。
// ─────────────────────────────────────────────────────────────────────────────
import { loadEtsModule, createRunner } from './_ets-harness.mjs'

const SRC = 'entry/src/main/ets/common/utils/ShelfPrefs.ets'

// ── 替身（注入给源码的 import / 全局）──────────────────────────────────────
const prefStore = new Map()
const getLog = []
const putLog = []
const PreferencesUtil = {
  getSync(key, defValue, preferenceName) {
    getLog.push({ key, defValue, preferenceName })
    return prefStore.has(key) ? prefStore.get(key) : defValue
  },
  putSync(key, value, preferenceName) {
    putLog.push({ key, value, preferenceName })
    prefStore.set(key, value)
  },
}
const CommonConstants = { PREFERENCES_BOOK_DATA_KEY: 'book_data' }
const appStorageStore = new Map()
const AppStorage = {
  setOrCreate(key, value) {
    appStorageStore.set(key, value)
  },
}

const mod = loadEtsModule(SRC, {
  bindings: { PreferencesUtil, CommonConstants },
  globals: { AppStorage },
})
const ShelfPrefs = mod.exports.default
const t = createRunner('ShelfPrefs 宫格列数（断点档 / 手动档）', { source: mod.source })

function reset() {
  prefStore.clear()
  getLog.length = 0
  putLog.length = 0
  appStorageStore.clear()
}

// ═══ 0. 漂移哨兵 + 跨文件契约常量 ════════════════════════════════════════════
t.group('0. 漂移哨兵 / 契约常量')
t.check('默认导出就是 ShelfPrefs 类（有 autoColumns/effectiveColumns）',
  typeof ShelfPrefs.autoColumns === 'function' && typeof ShelfPrefs.effectiveColumns === 'function',
  '证据：ShelfPrefs.ets:148/:197；:58 `export default class ShelfPrefs`')
t.sentinel('autoColumns 的 md 分支仍存在', /if \(bp === 'md'\) \{/, '守 ShelfPrefs.ets:149-151（自动档 md=4）')
t.sentinel('autoColumns 的 xl 分支仍存在', /if \(bp === 'xl'\) \{/, '守 ShelfPrefs.ets:155-157（自动档 xl=6）')
t.sentinel('autoColumns 兜底仍是 3', /return 3;/, '守 ShelfPrefs.ets:159（手机基线 3 列，绝不回归）')
t.sentinel('effectiveColumns 仍是「手动优先，否则断点」', /if \(userCols > 0\) \{[\s\S]*?return ShelfPrefs\.autoColumns\(bp\)/,
  '守 ShelfPrefs.ets:197-202（唯一取值入口）')
t.sentinel('读取侧夹取仍在（MIN/MAX）', /n < ShelfPrefs\.COLUMNS_MIN \? ShelfPrefs\.COLUMNS_MIN/,
  '守 ShelfPrefs.ets:170-171')
t.eq('回退总开关 ENABLED 仍为 true', ShelfPrefs.ENABLED, true, '证据：ShelfPrefs.ets:62（注释 :20-22 一键回退点）')
t.eq('COLUMNS_MIN = 2', ShelfPrefs.COLUMNS_MIN, 2, '证据：ShelfPrefs.ets:139')
t.eq('COLUMNS_MAX = 8', ShelfPrefs.COLUMNS_MAX, 8, '证据：ShelfPrefs.ets:141')
t.eq('持久化键名未改名 shelf_grid_columns', ShelfPrefs.K_GRID_COLUMNS, 'shelf_grid_columns',
  '证据：ShelfPrefs.ets:78；改这里=老用户设置静默丢失')
t.eq('AppStorage 键名未改名 shelfGridColumns', ShelfPrefs.KEY_GRID_COLUMNS_STORAGE, 'shelfGridColumns',
  '证据：ShelfPrefs.ets:205；跨文件契约：BookContent.ets:479 / BookFolder.ets:43 / MySetPage.ets:235 等 6 处 @StorageProp/@StorageLink')

// ═══ 1. autoColumns：断点档 sm/md/lg/xl ══════════════════════════════════════
t.group('1. autoColumns（自动档：跟随断点）')
t.eq('sm → 3（手机基线，与旧写死值相同）', ShelfPrefs.autoColumns('sm'), 3, '证据：ShelfPrefs.ets:158-159')
t.eq('xs → 3（无专属档）', ShelfPrefs.autoColumns('xs'), 3, '证据：ShelfPrefs.ets:158-159')
t.eq('md → 4', ShelfPrefs.autoColumns('md'), 4, '证据：ShelfPrefs.ets:149-151')
t.eq('lg → 5', ShelfPrefs.autoColumns('lg'), 5, '证据：ShelfPrefs.ets:152-154')
t.eq('xl → 6', ShelfPrefs.autoColumns('xl'), 6, '证据：ShelfPrefs.ets:155-157')
t.eq("空串（冷启动键未写入）→ 3", ShelfPrefs.autoColumns(''), 3, '证据：ShelfPrefs.ets:132-133 注释 + :158-159')
t.eq('未知值 → 3', ShelfPrefs.autoColumns('xxl'), 3, '证据：ShelfPrefs.ets:158-159')
t.eq('undefined → 3（不抛错）', ShelfPrefs.autoColumns(undefined), 3, '证据：ShelfPrefs.ets:149 起三个 `===` 全 false')
t.eq('大小写敏感：MD → 3（不是 4）', ShelfPrefs.autoColumns('MD'), 3, '证据：ShelfPrefs.ets:149 `bp === \'md\'` 严格比较')
t.eq('不 trim：` md` → 3', ShelfPrefs.autoColumns(' md'), 3, '证据：ShelfPrefs.ets:149（无 trim 调用）')

// ═══ 2. effectiveColumns：自动档 ═════════════════════════════════════════════
t.group('2. effectiveColumns（自动档：userCols = 0）')
t.eq('(0, sm) → 3', ShelfPrefs.effectiveColumns(0, 'sm'), 3, '证据：ShelfPrefs.ets:198-201')
t.eq('(0, md) → 4', ShelfPrefs.effectiveColumns(0, 'md'), 4, '证据：ShelfPrefs.ets:198-201')
t.eq('(0, lg) → 5', ShelfPrefs.effectiveColumns(0, 'lg'), 5, '证据：ShelfPrefs.ets:198-201')
t.eq('(0, xl) → 6', ShelfPrefs.effectiveColumns(0, 'xl'), 6, '证据：ShelfPrefs.ets:198-201')
t.eq('(0, 空串) → 3', ShelfPrefs.effectiveColumns(0, ''), 3, '证据：ShelfPrefs.ets:201 → :158-159')
t.eq('自动档恒等于 autoColumns（单一取值入口）',
  ['xs', 'sm', 'md', 'lg', 'xl', '', 'xxl'].every((bp) => ShelfPrefs.effectiveColumns(0, bp) === ShelfPrefs.autoColumns(bp)),
  true, '证据：ShelfPrefs.ets:201 `return ShelfPrefs.autoColumns(bp)`')

// ═══ 3. effectiveColumns：手动档 ═════════════════════════════════════════════
t.group('3. effectiveColumns（手动档：userCols > 0）')
t.eq('(2, sm) → 2（手动值压过断点）', ShelfPrefs.effectiveColumns(2, 'sm'), 2, '证据：ShelfPrefs.ets:198-200')
t.eq('(3, xl) → 3（xl 也不会变 6）', ShelfPrefs.effectiveColumns(3, 'xl'), 3, '证据：ShelfPrefs.ets:198-200 提前 return')
t.eq('(8, sm) → 8（取上限）', ShelfPrefs.effectiveColumns(8, 'sm'), 8, '证据：ShelfPrefs.ets:198-200')
t.eq('(-1, md) → 4（负数=自动）', ShelfPrefs.effectiveColumns(-1, 'md'), 4, '证据：ShelfPrefs.ets:198 `userCols > 0`')
// ⚠️ 语义可疑点（已报告，未改源码）：本函数**不夹取** COLUMNS_MIN/MAX，
//    夹取只发生在 `getUserColumns()`（:170-171）。若调用方传入未夹取的值就会原样落进 lanes()。
t.eq('已知缺陷：(1, lg) → 1（不夹 COLUMNS_MIN=2）', ShelfPrefs.effectiveColumns(1, 'lg'), 1,
  '证据：ShelfPrefs.ets:198-200 只判 >0，无下限夹取；夹取在 :170-171 —— 已报告')
t.eq('已知缺陷：(99, sm) → 99（不夹 COLUMNS_MAX=8）', ShelfPrefs.effectiveColumns(99, 'sm'), 99,
  '证据：ShelfPrefs.ets:198-200 无上限夹取 —— 已报告')

// ═══ 4. getUserColumns：读取侧夹取 ═══════════════════════════════════════════
t.group('4. getUserColumns（读持久化 + 夹取）')
reset()
t.eq('从未写过 ⇒ 0（自动）', ShelfPrefs.getUserColumns(), 0, '证据：ShelfPrefs.ets:168 `getSync(…, 0, …)`')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, 5)
t.eq('存 5 ⇒ 5', ShelfPrefs.getUserColumns(), 5, '证据：ShelfPrefs.ets:169-171')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, 1)
t.eq('存 1 ⇒ 夹到 MIN=2', ShelfPrefs.getUserColumns(), 2, '证据：ShelfPrefs.ets:170')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, 99)
t.eq('存 99 ⇒ 夹到 MAX=8', ShelfPrefs.getUserColumns(), 8, '证据：ShelfPrefs.ets:171')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, 0)
t.eq('存 0 ⇒ 0（自动）', ShelfPrefs.getUserColumns(), 0, '证据：ShelfPrefs.ets:170 `n <= 0 ? 0`')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, -3)
t.eq('存 -3 ⇒ 0（负数=自动）', ShelfPrefs.getUserColumns(), 0, '证据：ShelfPrefs.ets:170')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, 3.6)
t.eq('存 3.6 ⇒ 4（Math.round）', ShelfPrefs.getUserColumns(), 4, '证据：ShelfPrefs.ets:169 `Math.round(v)`')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, 2.4)
t.eq('存 2.4 ⇒ 2（Math.round）', ShelfPrefs.getUserColumns(), 2, '证据：ShelfPrefs.ets:169')
reset(); prefStore.set(ShelfPrefs.K_GRID_COLUMNS, 'abc')
t.eq('存非 number（脏数据）⇒ 0', ShelfPrefs.getUserColumns(), 0, '证据：ShelfPrefs.ets:169 `typeof v === \'number\' ? … : 0`')
t.check('读列数时始终带同一个偏好库名（同库同 flush 口径）',
  getLog.length > 0 && getLog.every((c) => c.preferenceName === CommonConstants.PREFERENCES_BOOK_DATA_KEY),
  '证据：ShelfPrefs.ets:81 `PREF_NAME = CommonConstants.PREFERENCES_BOOK_DATA_KEY` + :168')

// ═══ 5. setUserColumns：写侧 + AppStorage 广播 ══════════════════════════════
t.group('5. setUserColumns（写持久化 + 同步 AppStorage）')
reset()
ShelfPrefs.setUserColumns(6)
t.eq('写 6 ⇒ 持久化 6', prefStore.get(ShelfPrefs.K_GRID_COLUMNS), 6, '证据：ShelfPrefs.ets:183-184')
t.eq('写 6 ⇒ AppStorage 同步 6（书架立即重排）', appStorageStore.get(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE), 6,
  '证据：ShelfPrefs.ets:185-187')
reset()
ShelfPrefs.setUserColumns(-5)
t.eq('写 -5 ⇒ 落 0（恢复自动）', prefStore.get(ShelfPrefs.K_GRID_COLUMNS), 0, '证据：ShelfPrefs.ets:183 `n <= 0 ? 0`')
reset()
ShelfPrefs.setUserColumns(4.6)
t.eq('写 4.6 ⇒ 落 5（Math.round）', prefStore.get(ShelfPrefs.K_GRID_COLUMNS), 5, '证据：ShelfPrefs.ets:183 `Math.round(n)`')
reset()
ShelfPrefs.setUserColumns(7)
t.check('写后读 + 取值端到端一致（set 7 ⇒ get 7 ⇒ effective 7）',
  ShelfPrefs.getUserColumns() === 7 && ShelfPrefs.effectiveColumns(ShelfPrefs.getUserColumns(), 'sm') === 7,
  '证据：ShelfPrefs.ets:178-190 + :163-175 + :197-202')
// ⚠️ 语义可疑点（已报告，未改源码）：**写侧不夹、读侧夹**是两套口径。
//    setUserColumns 只做 `n <= 0 ? 0 : Math.round(n)`（:183），不夹 COLUMNS_MIN/MAX；
//    夹取只发生在 getUserColumns（:170-171）。
//    ⇒ 若有人（非当前滑块 UI）写进 99：本会话 AppStorage 拿到 99 ⇒ BookContent 真的 lanes(99)；
//      重启后 EntryAbility.ets:583 用 getUserColumns() 回填 ⇒ 变成 8。同一设置跨重启不一致。
reset()
ShelfPrefs.setUserColumns(99)
t.eq('已知缺陷：写侧不夹取 ⇒ 落盘 99', prefStore.get(ShelfPrefs.K_GRID_COLUMNS), 99,
  '证据：ShelfPrefs.ets:183 `n <= 0 ? 0 : Math.round(n)`（无 MIN/MAX 夹取）—— 已报告')
t.eq('已知缺陷：同一设置本会话 AppStorage=99 ⇒ lanes(99)', appStorageStore.get(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE), 99,
  '证据：ShelfPrefs.ets:185-187 写未夹取值；消费端 BookContent.ets:733 `effectiveColumns(userGridColumns, …)`')
t.eq('已知缺陷：重启后读回 8（读侧夹）⇒ 同一设置跨重启不一致', ShelfPrefs.getUserColumns(), 8,
  '证据：ShelfPrefs.ets:170-171 读侧夹取；回填点 EntryAbility.ets:583 —— 已报告')

// ═══ 6. 端到端：空库时「唯一取值入口」= 自动档 ══════════════════════════════
t.group('6. 端到端（空库 = 自动档，不出现"一进书架列数乱跳"）')
reset()
t.eq('空库 × 四个断点 ⇒ 3/4/5/6',
  ['sm', 'md', 'lg', 'xl'].map((bp) => ShelfPrefs.effectiveColumns(ShelfPrefs.getUserColumns(), bp)),
  [3, 4, 5, 6], '证据：ShelfPrefs.ets:132-133（断点取不到回落 sm）')

t.done()
