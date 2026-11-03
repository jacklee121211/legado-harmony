// ─────────────────────────────────────────────────────────────────────────────
// P5 纯函数单测 ④：common/shelf/ShelfCollection.ets（resolve / batchEntryGroup）
//
// 被测源码：entry/src/main/ets/common/shelf/ShelfCollection.ets（66 行）
// 运行：    node scripts/tests/shelf-collection.test.mjs
//
// ── 方式：源码文本提取 + 类型剥离 + 沙箱执行真源码 ────────────────────────────
// 理由：`ShelfCollection.resolve()` 是 2026-11-03 收敛的「书架集合语义唯一实现」
// （收敛前三处各写一遍，见源码 :11-16）。它同时被 `BookContent.ets:163/296` 与
// `BookManagePage.ets:190` 调用 ⇒ 一旦被改，复刻式测试不会红，所以这里跑真源码。
//
// `ShelfCollection` 的依赖只有一条：`import ShelfPrefs, { SortKey, SortDir } from '../utils/ShelfPrefs'`
// （ShelfCollection.ets:1）。为了测「排序是否真的跟随 ShelfPrefs」而不是被测死的常量，
// 本文件**先**用替身加载真的 `ShelfPrefs.ets`（PreferencesUtil/AppStorage 用内存替身，
// 理由同 shelf-prefs.test.mjs 文件头），再把**真类 + 真枚举**注入给 ShelfCollection。
// ⇒ 这条链上从 `ShelfPrefs.getSortKey()` 到 `ShelfCollection.sortKey` 全部是生产代码。
//
// ── 漂移防护 ─────────────────────────────────────────────────────────────────
//   L1 真源码执行；L2 sentinel 钉住三条关键分支：`isBookSet = bookTypeNumber !== 1`、
//      最近态的 4 行写死（bookGroup=2 / RECENT_READ / DESC）、`batchEntryGroup` 的三元；
//   L3 `loadEtsModule` 严格注入（依赖集合变化立刻抛错）+ 本文件断言 import 形状；
//   L4 断言 `SortKey` / `SortDir` 的**数值**（它们被持久化进 Preferences，
//      改数字 = 老用户排序整体错乱，必须有断言拦）。
// ─────────────────────────────────────────────────────────────────────────────
import { loadEtsModule, createRunner } from './_ets-harness.mjs'

const PREFS_SRC = 'entry/src/main/ets/common/utils/ShelfPrefs.ets'
const SRC = 'entry/src/main/ets/common/shelf/ShelfCollection.ets'

// ── 真 ShelfPrefs + 替身持久化（仅内存）────────────────────────────────────
const prefStore = new Map()
const PreferencesUtil = {
  getSync(key, defValue) {
    return prefStore.has(key) ? prefStore.get(key) : defValue
  },
  putSync(key, value) {
    prefStore.set(key, value)
  },
}
const prefsMod = loadEtsModule(PREFS_SRC, {
  bindings: { PreferencesUtil, CommonConstants: { PREFERENCES_BOOK_DATA_KEY: 'book_data' } },
  globals: { AppStorage: { setOrCreate() {} } },
})
const ShelfPrefs = prefsMod.exports.default
const { SortKey, SortDir } = prefsMod.exports

// ── 被测模块 ────────────────────────────────────────────────────────────────
const mod = loadEtsModule(SRC, { bindings: { ShelfPrefs, SortKey, SortDir } })
const { ShelfCollection } = mod.exports
const t = createRunner('ShelfCollection.resolve / batchEntryGroup', { source: mod.source })

function resetPrefs() {
  prefStore.clear()
}

// ═══ 0. 漂移哨兵 / 枚举数值 ═════════════════════════════════════════════════
t.group('0. 漂移哨兵 / 枚举数值')
t.check('依赖形状未漂移（默认 ShelfPrefs + 具名 SortKey/SortDir，共 1 条 import）',
  mod.imports.length === 1 &&
  mod.imports[0].module === '../utils/ShelfPrefs' &&
  mod.imports[0].defaultName === 'ShelfPrefs' &&
  mod.imports[0].named.map((n) => n.imported).sort().join(',') === 'SortDir,SortKey',
  '证据：ShelfCollection.ets:1')
t.check('默认导出与具名导出是同一个类', mod.exports.default === ShelfCollection, '证据：ShelfCollection.ets:66')
t.sentinel('resolve 的分组判定仍是 `bookTypeNumber !== 1`', /out\.isBookSet = bookTypeNumber !== 1$/m,
  '守 ShelfCollection.ets:48 —— 唯一一处「分组集合 vs 单层书集合」判定')
t.sentinel('「最近」仍硬锁 bookGroup = 2', /out\.bookGroup = 2$/m,
  '守 ShelfCollection.ets:43 —— 最近 = 全部书（BooksDao.buildWhereClause 里 2 = 不加分组条件）')
t.sentinel('「最近」仍硬锁最近阅读降序', /out\.sortKey = SortKey\.RECENT_READ[\s\S]*?out\.sortDir = SortDir\.DESC/,
  '守 ShelfCollection.ets:44-45 —— 最近态的排序不受 ShelfPrefs 影响')
t.sentinel('非最近态排序仍取 ShelfPrefs', /out\.sortKey = ShelfPrefs\.getSortKey\(\)[\s\S]*?out\.sortDir = ShelfPrefs\.getSortDir\(\)/,
  '守 ShelfCollection.ets:50-51')
t.sentinel('batchEntryGroup 仍是 `onRecentChip ? 2 : bookTypeNumber`',
  /return onRecentChip \? 2 : bookTypeNumber$/m, '守 ShelfCollection.ets:62')
// 枚举数值被持久化（ShelfPrefs.ets:276/:301 putSync 直接存数字）⇒ 改数字=老用户排序错乱
t.eq('SortKey 数值不变（PINYIN…FILE_SIZE = 0…4）',
  [SortKey.PINYIN, SortKey.IMPORT_TIME, SortKey.RECENT_READ, SortKey.FORMAT, SortKey.FILE_SIZE],
  [0, 1, 2, 3, 4], '证据：ShelfPrefs.ets:39-50；持久化见 :271-279')
t.eq('SortDir 数值不变（ASC=0 / DESC=1）', [SortDir.ASC, SortDir.DESC], [0, 1], '证据：ShelfPrefs.ets:53-56')

// ═══ 1. 裸实例默认值 ════════════════════════════════════════════════════════
t.group('1. 字段默认值（new ShelfCollection()）')
const bare = new ShelfCollection()
t.eq('isBookSet 默认 true（单层书集合）', bare.isBookSet, true, '证据：ShelfCollection.ets:25')
t.eq('isRecent 默认 false', bare.isRecent, false, '证据：ShelfCollection.ets:27')
t.eq('bookGroup 默认 2（= 全部书，不分组）', bare.bookGroup, 2, '证据：ShelfCollection.ets:29')
t.eq('sortKey 默认 RECENT_READ', bare.sortKey, SortKey.RECENT_READ, '证据：ShelfCollection.ets:30')
t.eq('sortDir 默认 DESC', bare.sortDir, SortDir.DESC, '证据：ShelfCollection.ets:31')

// ═══ 2. 最近态（onRecentChip = true）════════════════════════════════════════
t.group('2. 最近态：全部书 + 排序硬锁')
resetPrefs()
const recent = ShelfCollection.resolve(true, 2)
t.eq('isRecent = true', recent.isRecent, true, '证据：ShelfCollection.ets:39')
t.eq('isBookSet = true', recent.isBookSet, true, '证据：ShelfCollection.ets:42')
t.eq('bookGroup = 2（全部书）', recent.bookGroup, 2, '证据：ShelfCollection.ets:43')
t.eq('sortKey = RECENT_READ', recent.sortKey, SortKey.RECENT_READ, '证据：ShelfCollection.ets:44')
t.eq('sortDir = DESC', recent.sortDir, SortDir.DESC, '证据：ShelfCollection.ets:45')
t.eq('最近态**忽略** bookTypeNumber=1（仍按单层书集合）',
  ShelfCollection.resolve(true, 1).isBookSet, true,
  '证据：ShelfCollection.ets:40-46（recent 分支提前 return，不走 :48）')
t.eq('最近态忽略 bookTypeNumber=7 ⇒ bookGroup 仍是 2', ShelfCollection.resolve(true, 7).bookGroup, 2,
  '证据：ShelfCollection.ets:43')
// 把持久化排序改成「首字母↑」，看最近态是否被污染
prefStore.set(ShelfPrefs.K_SORT_KEY, SortKey.PINYIN)
prefStore.set(ShelfPrefs.K_SORT_DIR, SortDir.ASC)
const recent2 = ShelfCollection.resolve(true, 2)
t.eq('持久化排序改成 首字母↑ 后，最近态仍是 RECENT_READ/DESC',
  [recent2.sortKey, recent2.sortDir], [SortKey.RECENT_READ, SortDir.DESC],
  '证据：ShelfCollection.ets:44-45（硬锁，不读 ShelfPrefs）+ :41 注释')

// ═══ 3. 非最近态 × 档位（1=分组 2=全部 3=未分组 4=本地 ≥5 自定义分组）════════
t.group('3. 非最近态：档位 → (isBookSet, bookGroup)')
resetPrefs()
const cases = [
  [1, false, '分组页 ⇒ 分组集合（需要子树）'],
  [2, true, '全部 ⇒ 单层书集合'],
  [3, true, '未分组 ⇒ 单层书集合'],
  [4, true, '本地 ⇒ 单层书集合'],
  [5, true, '自定义分组（≥5）⇒ 单层书集合'],
  [7, true, '自定义分组 id=7 透传'],
]
for (const [btn, expectIsBookSet, why] of cases) {
  const r = ShelfCollection.resolve(false, btn)
  t.eq(`resolve(false, ${btn})：isBookSet = ${expectIsBookSet}（${why}）`, r.isBookSet, expectIsBookSet,
    '证据：ShelfCollection.ets:48 `out.isBookSet = bookTypeNumber !== 1`')
  t.eq(`resolve(false, ${btn})：bookGroup = ${btn}（档位直传）`, r.bookGroup, btn,
    '证据：ShelfCollection.ets:49 `out.bookGroup = bookTypeNumber`')
  t.eq(`resolve(false, ${btn})：isRecent = false`, r.isRecent, false, '证据：ShelfCollection.ets:39 `out.isRecent = onRecentChip`')
}
// ⚠️ 语义可疑点（已报告）：resolve 对档位**不做合法性校验**，0/负数会原样进 SQL。
//    `BooksDao.buildWhereClause()` 对 bookGroup=0 会拼出 `bookGroup = 0`（BooksDao.ets:301-308）。
t.eq('已知缺陷：resolve(false, 0) ⇒ bookGroup = 0（无校验，直传 SQL）',
  ShelfCollection.resolve(false, 0).bookGroup, 0,
  '证据：ShelfCollection.ets:48-49；下游 BooksDao.ets:301-308 会把 0 当普通分组 id —— 已报告')
t.eq('已知缺陷：resolve(false, -3) ⇒ bookGroup = -3（无校验）',
  ShelfCollection.resolve(false, -3).bookGroup, -3, '证据：ShelfCollection.ets:48-49 —— 已报告')

// ═══ 4. 排序跟随 ShelfPrefs（非最近态）══════════════════════════════════════
t.group('4. 非最近态：排序跟随 ShelfPrefs')
resetPrefs()
const def = ShelfCollection.resolve(false, 2)
t.eq('空库默认排序 = 导入时间 ↓（ShelfPrefs 默认值）',
  [def.sortKey, def.sortDir], [SortKey.IMPORT_TIME, SortDir.DESC],
  '证据：ShelfPrefs.ets:262-265（默认 IMPORT_TIME）+ :287-290（默认 DESC）；ShelfCollection.ets:50-51')
prefStore.set(ShelfPrefs.K_SORT_KEY, SortKey.PINYIN)
prefStore.set(ShelfPrefs.K_SORT_DIR, SortDir.ASC)
const custom = ShelfCollection.resolve(false, 3)
t.eq('持久化改成 首字母↑ ⇒ resolve 反映为 PINYIN/ASC',
  [custom.sortKey, custom.sortDir], [SortKey.PINYIN, SortDir.ASC],
  '证据：ShelfCollection.ets:50-51 `ShelfPrefs.getSortKey()/getSortDir()`')
prefStore.set(ShelfPrefs.K_SORT_KEY, 99)          // 脏值
prefStore.set(ShelfPrefs.K_SORT_DIR, 7)           // 脏值
const dirty = ShelfCollection.resolve(false, 2)
t.eq('持久化是脏值 ⇒ 回落到 IMPORT_TIME/DESC（不抛错）',
  [dirty.sortKey, dirty.sortDir], [SortKey.IMPORT_TIME, SortDir.DESC],
  '证据：ShelfPrefs.ets:265 `n >= 0 && n <= FILE_SIZE ? … : IMPORT_TIME`；:290 `n === ASC ? ASC : DESC`')

// ═══ 5. batchEntryGroup（批量页进入档位）════════════════════════════════════
t.group('5. batchEntryGroup：最近归一成全部')
t.eq('(true, 1) ⇒ 2（最近 + 分组 也归全部）', ShelfCollection.batchEntryGroup(true, 1), 2,
  '证据：ShelfCollection.ets:61-63')
t.eq('(true, 2) ⇒ 2', ShelfCollection.batchEntryGroup(true, 2), 2, '证据：ShelfCollection.ets:62')
t.eq('(true, 7) ⇒ 2（最近态一律归全部）', ShelfCollection.batchEntryGroup(true, 7), 2, '证据：ShelfCollection.ets:62')
t.eq('(false, 1) ⇒ 1（非最近原样）', ShelfCollection.batchEntryGroup(false, 1), 1, '证据：ShelfCollection.ets:62')
t.eq('(false, 3) ⇒ 3', ShelfCollection.batchEntryGroup(false, 3), 3, '证据：ShelfCollection.ets:62')
t.eq('(false, 7) ⇒ 7', ShelfCollection.batchEntryGroup(false, 7), 7, '证据：ShelfCollection.ets:62')
prefStore.set(ShelfPrefs.K_SORT_KEY, SortKey.FILE_SIZE)
t.eq('batchEntryGroup 不读 ShelfPrefs（纯归一）', ShelfCollection.batchEntryGroup(false, 4), 4,
  '证据：ShelfCollection.ets:61-63（方法体只有一条三元，无 IO）')

// ═══ 6. 实例隔离（每次 resolve 都是新对象）══════════════════════════════════
t.group('6. 实例隔离')
t.check('两次 resolve 返回不同实例', ShelfCollection.resolve(true, 2) !== ShelfCollection.resolve(true, 2),
  '证据：ShelfCollection.ets:38 `const out = new ShelfCollection()`')
const mutated = ShelfCollection.resolve(false, 2)
mutated.bookGroup = 9
t.eq('改旧实例不影响新实例（无共享可变状态）', ShelfCollection.resolve(false, 2).bookGroup, 2,
  '证据：ShelfCollection.ets:38 + :49')

t.done()
