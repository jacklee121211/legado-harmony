#!/usr/bin/env node
/**
 * scripts/check-single-path.mjs —— **单一通路闸门**（2026-11-03 A4 新增）
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 * 真源 §17「单一通路」：同一语义只允许**一处实现**（写入口 / 树真源 / 计数 / 弹窗出口）。
 * 但纪律靠人记就会漂：本工程历史上出现过 22 处各自 `GroupTree.build` 建树、8 处绕过
 * `GroupMutation` 直写分组、3 份重复的 SQL 转义。弹窗那条已经有
 * `check-dialog-usage.mjs` 守着；本脚本补另外三类。
 *
 * ── 判据（两层）──────────────────────────────────────────────────────────────
 * ① **HARD（必须为 0）**
 *    · `BooksDao.queryBookByGroup(` —— 旧名，2026-11-03 A3 已改名 `moveBooksToGroup`
 *      （它是**写**操作，旧名诱导人当查询用）；
 *    · `DbUtil.executeSql(` 出现在 `database/` 之外 —— SQL 只允许存在于数据层
 *      （A1 已把 `BookRename` 那几处收进来；`DbUtil.ets` 自身是实现，不算）。
 *
 * ② **RATCHET（只许降，不许升）**
 *    · `GroupTree.build(` —— 自建树次数，当前预算 12；
 *    · `bookGroupUtil(s).<写方法>(` —— 绕过 `GroupMutation` 的写直连，当前预算 1。
 *
 * ── 关于这两个预算值 ────────────────────────────────────────────────────────
 * 沿革（每次下调必须在这里写清原因，否则等于自己骗自己）：
 *   · 2026-11-03 A2 收口前：写直连 **8 处**（4 删 + 1 批删 + 1 批解散 + 2 封面）；
 *   · 2026-11-03 A2b 再收口：新建分组 1 处 + 分组改名 1 处 ⇒ 合计 **10 处已收口**；
 *   · 2026-11-03 建闸门时实测：写直连 **1**（只剩白名单那处）⇒ 预算先设 1；
 *   · 2026-11-03 同日收紧：白名单内的不计入 ⇒ 实测 **0** ⇒ 预算降到 **0**
 *     （白名单仍保留：它允许"双轨回退分支"存在而不被判违规）。
 *   · `GroupTree.build`：建闸门时实测 **12**；把 `BookSelectGroupDialog` 里 4 处重复建树
 *     收敛为 1 处 `treeNow()`（带指纹缓存）后实测 **9** ⇒ 预算从 12 降到 **9**（只许降）。
 *     剩余 9 = `GroupStore` 2（真源自身）+ `bookGroupUtils` 2（解散/回滚）+ 页面/组件 5。
 *     目标是把页面/组件那 5 处逐步降到 0（多为"按类型过滤的视图树"，需逐个确认能否改用 GroupStore）。
 *   · `GroupTree.build` 当前 9 处：`GroupStore` 2 + `bookGroupUtils` 2 + 弹窗 1 + 书架 4 处待查。
 *
 * ── 明确"允许"的写，不在这里判违规 ──────────────────────────────────────────
 * `booksUtils` 里的 `updateAddBookIds` / `updateMoveBookIdsByGroupId` 写的是
 * **历史冗余列 `book_groups.bookIds`**（B④ 决议：保留写入、只保证无人依赖）。
 * 它不是"结构写入口旁路"，故本闸门不统计；若将来决定删列，再把它加入 HARD=0。
 *
 * 用法：
 *   node scripts/check-single-path.mjs            # 检查，违规 → 非零退出
 *   node scripts/check-single-path.mjs --json     # 机器可读
 */

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const ROOT = process.cwd();
const SRC_DIR = join(ROOT, 'entry', 'src', 'main', 'ets');

/** 只许降的预算（每下调一次都要在文件头写沿革） */
const GROUP_TREE_BUILD_BUDGET = 2;
const WRITE_BYPASS_BUDGET = 0;

/**
 * 刷新信号的**写点**预算（2026-11-03 B1）：
 * 这三个全局键是书架域最大的"多路喊刷新"来源 —— 任一页面都可能自增它们，
 * 于是"改了 A 忘了 B"（U2b / B⑥ 的土壤）。
 *
 * 沿革：
 *   · 建闸门时（B1 之前）实测 **56** 处写点；
 *   · B1a 引入 `common/shelf/ShelfRefresh.ets` 门面后，56 → **0**（门面内部用变量 key 写法，
 *     不匹配本闸门的字面量规则）⇒ 预算降到 **0**。
 *   · **允许的例外**：`storage/bookListData.ets` 里把三个键**初始化为 0**
 *     （`AppStorage.setOrCreate(KEY, 0)`）—— 那是启动初始化，不是"喊刷新"，
 *     换算成门面会变成"加一到 1"，属行为变更，故明确允许并在下面登记。
 */
const REFRESH_SIGNAL_BUDGET = 0;
const REFRESH_SIGNALS = ['BOOK_IS_BOOK_REFRESHING', 'BOOK_IS_BOOK_GROUPS_REFRESHING', 'isBookRefreshing'];

/** 刷新信号写点的允许清单：只允许"初始化"语义，且只能在启动路径 */
const REFRESH_WRITE_ALLOW = [
  { file: 'storage/bookListData.ets', why: '启动时把三个全局键初始化为 0（不是喊刷新）' },
];

/**
 * **存量账**（2026-11-03，与用户讨论后新增）。
 *
 * 背景：上一轮闸门只守住了"门面写直连"这一类，于是出现了盲区 —— 例如
 * `BookGroupsDao.insert/updatePartialGroup` 在弹窗里**直接写库**、置顶 `isTopGroup` 没有入口方法、
 * `new CustomDialogController` 仍 77 处、分组域还有 8 处 `setTimeout` 延时刷。
 * 这些都不是"新问题"，是**从来没被机器数过**。
 *
 * 处理方式沿用 ratchet：**先把存量钉住（budget = 实测值），再逐批降**。
 * budget = null 表示"本次只统计、不判违规"（第一轮跑出来的数字用于定价）。
 */
/**
 * 2026-11-03（Ⅱ-4）：**纯 UI 计时**白名单（不触发数据刷新）。
 * 与"写完等 500ms 再刷新"是两回事，混在一起会让闸门数字失去意义。
 */
const UI_TIMING_ALLOW = [
  { file: 'pages/view/bookShelf/BookFolder.ets', match: /this\.enterTimers\.push\(setTimeout/ },
  { file: 'pages/view/bookShelf/components/BookContentRefresh.ets', match: /^setTimeout\(\(\) => \{$/ },
];
function isUiTiming(rel, text) {
  return UI_TIMING_ALLOW.some((a) => a.file === rel && a.match.test(text));
}

const INVENTORY = [
  {
    id: 'dao-write-in-ui',
    label: 'DAO 直写分组（绕过 GroupMutation）',
    pattern: /BookGroupsDao\.(insert|update|updatePartialGroup|deleteBook|isUpdateGroupTop|onlyGroupUpdateName)\s*\(/,
    allow: (rel) => rel.startsWith('database/')
      || rel === 'common/group/GroupMutation.ets'
      || rel === 'common/utils/bookGroupUtils.ets',
    budget: 0,
    note: 'UI 层不得直接写分组表（实测 6 处：insert 2 + updatePartialGroup 4）；只允许写入口与数据层内部',
  },
  {
    id: 'set-top-direct',
    label: '置顶直连（还没有入口方法）',
    pattern: /bookGroupUtil(s)?\.isTopGroup\s*\(/,
    // ⚠️ 写入口自身（`GroupMutation.setTop` 的实现）不算"绕过入口"——与 dao-write-in-ui 同因
    allow: (rel) => rel === 'common/utils/bookGroupUtils.ets' || rel === 'common/group/GroupMutation.ets',
    budget: 0,
    note: '2026-11-03（Ⅱ-1）：已新增 GroupMutation.setTop，两处调用点收口 ⇒ 预算 2→0',
  },
  {
    id: 'new-dialog-controller',
    label: 'new CustomDialogController（组件自持 controller）',
    pattern: /new CustomDialogController\s*\(/,
    allow: (rel) => rel.startsWith('common/reader/'),
    budget: 63,
    note: 'DialogHost 铁律 4：调用点不许自持 controller（打开已收口，持有未收口；实测 71 处）',
  },
  {
    id: 'group-setTimeout',
    label: '分组域 setTimeout 延时刷',
    pattern: /setTimeout\s*\(/,
    scope: /(FolderInfoDialog|BookSelectGroupDialog|coverInfoDialog|BookFolder|BookContentRefresh|groupTypePanel|GroupType)\.ets$/,
    // 2026-11-03（Ⅱ-4）：8 处"写完 500ms 再刷新"已全部改成 await 后立即刷 ⇒ 预算 10→0。
    //   剩下 2 处是**纯 UI 计时**（不是数据刷新），单独记在 `ui-timing-setTimeout`：
    //     · BookFolder 卡片入场错峰（enteredFlags 置真）
    //     · BookContentRefresh 下拉刷新转圈的最短展示时长
    allow: (rel, text) => isUiTiming(rel, text),
    budget: 0,
    note: '2026-11-03（Ⅱ-4）：延时刷已归零；UI 计时另立 `ui-timing-setTimeout`',
  },
  {
    id: 'ui-timing-setTimeout',
    label: 'UI 计时的 setTimeout（允许，但只许这 2 处）',
    pattern: /setTimeout\s*\(/,
    scope: /(BookFolder|BookContentRefresh)\.ets$/,
    allow: (rel, text) => !isUiTiming(rel, text),
    budget: 2,
    note: '入场动画错峰 + 下拉刷新最短转圈时长；它们不触发数据刷新，若换成"写完再刷"请改回 group-setTimeout 账号',
  },
  {
    id: 'group-flags-old-branch',
    label: '双轨旧分支读取点（GroupFlags.USE_*）',
    pattern: /GroupFlags\.USE_\w+/,
    allow: (rel) => rel === 'common/group/GroupFlags.ets',
    budget: 0,
    note: '2026-11-03（Ⅱ-3）：5 处读取点已随旧分支删除 ⇒ 预算 5→0；2026-11-03（P12/A8）GroupFlags.ets 已整份删除'
  },
  {
    id: 'collection-semantics-fork',
    label: '集合语义分叉（最近/全部 口径写死在各处）',
    pattern: /(onRecentChip\s*\?\s*2\b)|(bookGroup:\s*2\b)/,
    // 唯一允许：集合语义真源自身
    allow: (rel) => rel === 'common/shelf/ShelfCollection.ets',
    budget: 0,
    note: '2026-11-03（Ⅲ-1）：统一走 ShelfCollection.resolve()；闸门防"又有人在一处写死 bookGroup: 2"',
  },
  {
    id: 'books-dao-write-in-ui',
    label: 'UI 层直写 bookGroup（书籍域的"写入口"缺口）',
    pattern: /booksDao\.updateBookGroup\s*\(/,
    // 数据层与工具层是合法落点；`GroupMutation` 是分组写入口本身（移书是它的职责）
    allow: (rel) => rel.startsWith('database/')
      || rel === 'common/utils/booksUtils.ets'
      || rel === 'common/utils/bookGroupUtils.ets'
      || rel === 'common/group/GroupMutation.ets'
      || rel === 'common/books/BooksMutation.ets',
    budget: 0,
    note: '2026-11-03（Ⅲ-2 审计 → P3/A1 收口）：5 处已全部走 common/books/BooksMutation.ets（moveOne/moveMany/update/restoreGroups）',
  },
  // 2026-11-03（P3/B4）：书籍域**旧写通道**的定性闸门。
  //   定性：ooksUtils = 书籍域**适配器**（写入细节唯一实现），ookGroupUtils = **遗留分组工具**
  //   （分组写已归 GroupMutation，它现在只剩"读 + 被 GroupMutation 调用"）。
  //   允许的调用方：数据层、两个工具自身、新的 common/books/BooksMutation、
  //   以及**边界适配器**（导入/传书/分享：FileHandler / WifiBookServer / BookShareBridge）。
  //   UI 层对新代码**不允许**再直接调它；存量以预算锁定，只降不升（下一批如 P6/P13 再压）。
  {
    id: 'legacy-book-write',
    label: 'UI 直接调旧书籍工具写（绕过 BooksMutation）',
    pattern: /booksUtils?\.(updateBooks|updateAddBookIds|addBooks|delBooksById|partialUpdate|update)\s*\(/,
    allow: (rel) => rel.startsWith('database/')
      || rel === 'common/utils/booksUtils.ets'
      || rel === 'common/utils/bookGroupUtils.ets'
      || rel === 'common/books/BooksMutation.ets'
      || rel === 'common/utils/FileHandler.ets'
      || rel === 'common/utils/WifiBookServer.ets'
      || rel === 'common/share/BookShareBridge.ets',
    budget: 0,
    note: '2026-11-03（B4 收尾）：13 处 UI 写调用已全部迁到 BooksMutation（add/remove/moveTo），预算 13→0',
  },  // 2026-11-03（P6/B2）：计数文案的唯一实现闸门。
  //   「共N本 · M个分组」「已选N本 · M个分组」这类字符串曾经有 4 份各自拼（其中 coverInfoDialog 那份
  //   还把数量写死成 0）。现在统一从 `common/shelf/CountLabel.ets` 出，禁止再自己拼。
  {
    id: 'count-label-fork',
    label: '计数文案自己拼（绕过 CountLabel）',
    pattern: /(共\\\$\{[^}]*\}本 · \\\$\{[^}]*\}个分组|已选\\\$\{[^}]*\}本 · )/,
    allow: (rel) => rel === 'common/shelf/CountLabel.ets',
    budget: 0,
    note: '2026-11-03（P6/B2）：分组卡片/批量顶部/详情小字统一走 CountLabel.groupCard/selected/books',
  },  // 2026-11-03（双轨收口）：**旧计数器订阅方**存量账。
  //   两个计数器（`BOOK_IS_BOOK_GROUPS_REFRESHING` / `BOOK_IS_BOOK_REFRESHING`）仍是当前渲染广播的
  //   主通道：25 处 `@StorageProp/@StorageLink`、16 个文件。事件轨（`GroupEvents.subscribe`）今天只有
  //   `BookManagePage` 一个订阅者，且没有任何地方用 payload 的精确 id 做选择性刷新。
  //   ⇒ 先把"事件出口"接成唯一（上面那条），订阅方迁移留到有真机可验时再逐文件做；
  //   本阈值只许降，防止双轨继续扩大。
  {
    id: 'legacy-refresh-consumers',
    label: '旧计数器订阅方（@StorageProp/@StorageLink 两个刷新键）',
    pattern: /@Storage(Prop|Link)\(['"](BOOK_IS_BOOK_GROUPS_REFRESHING|BOOK_IS_BOOK_REFRESHING)['"]\)/,
    budget: 8,
    note: '2026-11-03（双轨收口·二）：25 → 8。删掉的 17 处全是「只声明不读」的死订阅；剩下 8 处都带 @Watch 回调（真行为），需逐文件迁移并真机验刷新',
  },
  // 2026-11-03（双轨收口）：**事件出口唯一性**闸门。
  //   双轨的根因是"计数器广播"和"领域事件"各自为政：只有 GroupMutation 发事件，
  //   UI 里直接 bump 计数器的路径不会通知事件订阅方 ⇒ 新订阅者静默漏刷新。
  //   现在 `ShelfRefresh` 在 bump 的同时补发（微任务合并），所以：
  //     · `GroupEvents.emit` 只许出现在 GroupEvents（实现）/ GroupMutation（精确 payload）/ ShelfRefresh（补发）三处；
  //     · `emitFromBump` 只许 ShelfRefresh 调。
  {
    id: 'group-event-exit',
    label: '事件广播绕过唯一出口（GroupEvents 只许三个出口文件）',
    pattern: /GroupEvents\.(emit|emitFromBump)\s*\(/,
    allow: (rel) => rel === 'common/group/GroupEvents.ets'
      || rel === 'common/group/GroupMutation.ets'
      || rel === 'common/shelf/ShelfRefresh.ets',
    budget: 0,
    note: '2026-11-03（双轨收口）：计数器与事件由 ShelfRefresh 同一出口发出（微任务合并，已有精确事件则不补发）',
  },
  // 2026-11-03（双轨收口）：分组卡片 ForEach 键的**唯一实现**闸门。
  //   `GroupCardKey.groupCardKeyOf` 是唯一实现；历史上有 4 份副本，其中 `BookFolderManages` 那份
  //   缺 `parentId` / `isSystem` ⇒「移动分组后管理页卡片不重建」（键里少字段 = 不重绘）。
  {
    id: 'group-card-key-fork',
    label: '分组卡片键自己拼（绕过 GroupCardKey）',
    pattern: /\bfunction\s+groupCardKey\s*\(/,
    allow: (rel) => rel === 'common/group/GroupCardKey.ets',
    budget: 0,
    note: '2026-11-03（双轨收口）：第 4 份副本（BookFolderManages）已删，统一 groupCardKeyOf()',
  },
  // 2026-11-03（双轨收口）：计数**取数**（不是文案）的闸门。
  //   「共N本」必须按事实 `books.bookGroup` 现算（`bookGroupUtils.directBookCount` / `fillRealBookIds`），
  //   不许再读冗余列 `book_groups.bookIds.length`（它只在移动分组时追加、导入/删除都不同步 ⇒ 恒「共0本」）。
  //   存量允许：bookGroupUtils 内部（填充/子树求和）、GroupCardKey（键需要计数）、
  //   已在 `fillRealBookIds` 之后的显示路径（BookFolder / BookContentRefresh / BookFolderManages）、
  //   以及两个弹窗的**首帧占位**（随即被 directBookCount 覆盖）。预算只许降。
  {
    id: 'bookids-count-read',
    label: '用冗余列 bookIds.length 当"共N本"',
    pattern: /bookIds\?\.length/,
    allow: (rel) => rel === 'common/utils/bookGroupUtils.ets'
      || rel === 'common/group/GroupCardKey.ets'
      || rel.startsWith('database/')
      || rel.endsWith('/BookFolder.ets')
      || rel.endsWith('/BookContentRefresh.ets')
      || rel.endsWith('/BookFolderManages.ets'),
    budget: 2,
    note: '2026-11-03（双轨收口）：只剩两个弹窗的首帧占位（coverInfoDialog / FolderInfoDialog），实际显示走 directBookCount',
  },  {
    id: 'boundary-dao-write',
    label: '边界 lane 直写事实（导入/传书/分享/碰一碰）',
    pattern: /\b(booksDao|bookGroupsDao|bookmarksDao)\.(insert|partialUpdate|update|updateBookGroup|add|remove|delete)\s*\(/,
    scope: /(FileHandler|WifiBookServer|BookShareBridge|UnsupportedDoc)\.ets$/,
    allow: (rel) => rel.startsWith('common/reader/'),
    budget: 0,
    note: '2026-11-03（Ⅴ-2）：书签写点已全部收进 BookmarkPorts ⇒ 边界 lane 归零（Ⅳ-1 的 2 处随 Ⅴ-2 一并消失）',
  },
  {
    id: 'reader-fact-write',
    label: '阅读器直写 books 事实（绕过 ReaderPorts）',
    pattern: /\bBooksDao\.(stampReadProgress|markFinished|update|updateBookGroup|insert|delete)\s*\(/,
    // 2026-11-03（P1/R2）：scope 由「4 个文件」扩到 Reader 目录全量 + common/reader 通路 ——
    //   收掉 PdfReaderPage 那种「新加个阅读页就绕过闸门」的口子。
    scope: /((^|\/)pages\/view\/Reader\/[^/]+\.ets$)|((^|\/)common\/reader\/[^/]+\.ets$)/,
    allow: (rel) => rel.startsWith('common/reader/'),
    budget: 0,
    note: '2026-11-03（Ⅴ-1）：阅读器只允许"进书取快照 / 退书结算"两个窄口（common/reader/ReaderPorts.ets）',
  },
  {
    id: 'bookmark-dao-write',
    label: '书签直写（绕过 BookmarkPorts）',
    pattern: /\b(bookmarksDao|BookmarksDao)\.(add|remove|removeAt|deleteByBookName|renameBookSqls|initBookmarksTable)\s*\(/,
    // 建表引导在数据层内部（database/index.ets）是合法的，不反向依赖 common/
    allow: (rel) => rel === 'common/reader/BookmarkPorts.ets' || rel.startsWith('database/'),
    budget: 0,
    note: '2026-11-03（Ⅴ-2）：6 文件 13 处已收进 BookmarkPorts；建表引导留在 database/ 内部避免循环依赖'
  },
  {
    id: 'hidden-state-owner',
    label: '隐藏集合写入点（第二份状态的回归闸门）',
    pattern: /GroupStore\.setHiddenIds\s*\(/,
    // 唯一允许的写法：真源自身（apply 内部）与遗留兼容壳（BooksDao.setHiddenGroupIds）
    allow: (rel) => rel === 'common/group/GroupStore.ets' || rel === 'database/dao/BooksDao.ets',
    budget: 0,
    note: '2026-11-03（Ⅱ-2）：HiddenGroups 已删除，真源唯一所有者是 GroupStore；遗留壳只许 1 处，删掉后降 0',
  },
];

/** 写直连白名单：双轨回退分支（不可达但刻意保留） */
const WRITE_BYPASS_ALLOW = [
  { file: 'pages/view/bookShelf/components/dialog/FolderInfoDialog.ets', method: 'updateGroupShow' },
];

const WRITE_METHODS = [
  'delGroupById', 'dissolveGroup', 'dissolveGroups',
  'updateGroupShow', 'updatePartialGroup', 'addGroup', 'onlyGroupUpdateName',
];

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'build' || name === 'oh_modules' || name === 'node_modules') continue;
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) walk(p, out);
    else if (name.endsWith('.ets')) out.push(p);
  }
  return out;
}

const files = walk(SRC_DIR);
const hits = {
  groupTreeBuild: [],
  writeBypass: [],
  legacyQueryName: [],
  uiSql: [],
  refreshWrites: [],
};
const allowedBypass = [];
const allowedRefresh = [];
/** 存量账命中：ruleId → [{file,line,text}] */
const inventoryHits = new Map();
for (const r of INVENTORY) inventoryHits.set(r.id, []);

for (const abs of files) {
  const rel = relative(SRC_DIR, abs).split(sep).join('/');
  const lines = readFileSync(abs, 'utf8').split(/\r?\n/);
  lines.forEach((line, i) => {
    const t = line.trim();
    if (!t || /^(\/\/|\*|\/\*)/.test(t)) return;   // 注释不算
    const lineNo = i + 1;

    if (/GroupTree\.build\(/.test(t)) hits.groupTreeBuild.push({ file: rel, line: lineNo, text: t });

    const m = t.match(/bookGroupUtil(s)?\.(\w+)\(/);
    // ⚠️ `GroupMutation.ets` 就是**唯一写入口本身**，它委托 bookGroupUtils 是设计的核心，
    //    不能算"绕过入口"（否则闸门会把实现自己判成违规）。
    const isEntryItself = rel === 'common/group/GroupMutation.ets';
    if (m && WRITE_METHODS.includes(m[2]) && !isEntryItself) {
      const isAllowed = WRITE_BYPASS_ALLOW.some((a) => a.file === rel && a.method === m[2]);
      if (isAllowed) allowedBypass.push({ file: rel, line: lineNo, method: m[2] });
      else hits.writeBypass.push({ file: rel, line: lineNo, text: t, method: m[2] });
    }

    if (/BooksDao\.queryBookByGroup\s*\(/.test(t)) hits.legacyQueryName.push({ file: rel, line: lineNo, text: t });

    // SQL 只许在数据层：database/ 目录内 + DbUtil 自身（它是唯一执行器）
    const inDataLayer = rel.startsWith('database/') || rel.endsWith('common/utils/DbUtil.ets');
    if (/DbUtil\.executeSql\s*\(/.test(t) && !inDataLayer) {
      hits.uiSql.push({ file: rel, line: lineNo, text: t });
    }

    // 刷新信号写点（自增 / AppStorage 写）
    for (const sig of REFRESH_SIGNALS) {
      const re = new RegExp('(?:' + sig + '\\s*(?:\\+\\+|\\+=))|(?:AppStorage\\.setOrCreate\\(\\s*[\'"]' + sig + '[\'"])');
      if (re.test(t)) {
        const allowIt = REFRESH_WRITE_ALLOW.some((a) => a.file === rel);
        if (!allowIt) hits.refreshWrites.push({ file: rel, line: lineNo, sig, text: t });
        else allowedRefresh.push({ file: rel, line: lineNo, sig });
      }
    }

    // 存量账（ratchet 候选）：先如实统计，再定价
    for (const r of INVENTORY) {
      if (r.scope && !r.scope.test(rel)) continue;
      if (!r.pattern.test(t)) continue;
      if (r.allow && r.allow(rel, t)) continue;
      inventoryHits.get(r.id).push({ file: rel, line: lineNo, text: t });
    }
  });
}

const violations = [];
for (const h of hits.legacyQueryName) {
  violations.push({ kind: 'hard-legacy-name', ...h, msg: '旧名 BooksDao.queryBookByGroup（写操作）已改名为 moveBooksToGroup' });
}
for (const h of hits.uiSql) {
  violations.push({ kind: 'hard-ui-sql', ...h, msg: 'SQL 只允许存在于数据层（database/）' });
}
if (hits.groupTreeBuild.length > GROUP_TREE_BUILD_BUDGET) {
  violations.push({
    kind: 'ratchet-group-tree', file: '(全仓)', line: 0,
    msg: `GroupTree.build = ${hits.groupTreeBuild.length} > 预算 ${GROUP_TREE_BUILD_BUDGET}（只许降）`,
  });
}
if (hits.writeBypass.length > WRITE_BYPASS_BUDGET) {
  violations.push({
    kind: 'ratchet-write-bypass', file: '(全仓)', line: 0,
    msg: `bookGroupUtils 写直连 = ${hits.writeBypass.length} > 预算 ${WRITE_BYPASS_BUDGET}（只许降）`,
  });
}
if (hits.refreshWrites.length > REFRESH_SIGNAL_BUDGET) {
  violations.push({
    kind: 'ratchet-refresh-signal', file: '(全仓)', line: 0,
    msg: `刷新信号写点 = ${hits.refreshWrites.length} > 预算 ${REFRESH_SIGNAL_BUDGET}（只许降；B1 目标是收敛到 GroupEvents 单一路）`,
  });
}
for (const r of INVENTORY) {
  const list = inventoryHits.get(r.id);
  if (r.budget !== null && list.length > r.budget) {
    violations.push({
      kind: 'ratchet-' + r.id, file: '(全仓)', line: 0,
      msg: `${r.label} = ${list.length} > 预算 ${r.budget}（只许降）`,
    });
  }
}

const summary = {
  scannedFiles: files.length,
  groupTreeBuild: hits.groupTreeBuild.length,
  groupTreeBuildBudget: GROUP_TREE_BUILD_BUDGET,
  writeBypass: hits.writeBypass.length,
  writeBypassBudget: WRITE_BYPASS_BUDGET,
  writeBypassAllowed: allowedBypass.length,
  legacyQueryName: hits.legacyQueryName.length,
  uiSql: hits.uiSql.length,
  refreshWrites: hits.refreshWrites.length,
  refreshSignalBudget: REFRESH_SIGNAL_BUDGET,
  inventory: INVENTORY.map((r) => ({
    id: r.id, label: r.label, count: inventoryHits.get(r.id).length, budget: r.budget,
  })),
  violations,
};

if (process.argv.includes('--json')) {
  console.log(JSON.stringify(summary, null, 2));
  process.exit(violations.length ? 1 : 0);
}

console.log('=== 单一通路闸门 (scripts/check-single-path.mjs) ===');
console.log(`扫描真实源码: ${summary.scannedFiles} 个 .ets`);
console.log(`GroupTree.build       : ${summary.groupTreeBuild} / 预算 ${summary.groupTreeBuildBudget}（只许降）`);
console.log(`分组写直连(绕过入口)   : ${summary.writeBypass} / 预算 ${summary.writeBypassBudget}（只许降；白名单 ${summary.writeBypassAllowed} 处）`);
console.log(`旧名 queryBookByGroup  : ${summary.legacyQueryName}（必须 0）`);
console.log(`UI 层 SQL              : ${summary.uiSql}（必须 0）`);
console.log(`刷新信号写点           : ${summary.refreshWrites} / 预算 ${summary.refreshSignalBudget}（只许降）`);
console.log('');

if (hits.groupTreeBuild.length) {
  console.log('--- GroupTree.build 明细（自建树）---');
  const byFile = {};
  for (const h of hits.groupTreeBuild) byFile[h.file] = (byFile[h.file] ?? 0) + 1;
  for (const [f, n] of Object.entries(byFile).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(n).padStart(2)}  ${f}`);
  }
  console.log('');
}
for (const a of allowedBypass) {
  console.log(`  [白名单] ${a.file}:${a.line}  ${a.method}(…)  —— 双轨回退分支，开关 true 时不可达`);
}

console.log('');
console.log('--- 存量账（ratchet 候选：只许降）---');
for (const r of INVENTORY) {
  const list = inventoryHits.get(r.id);
  const budgetText = r.budget === null ? '未定价（只统计）' : `预算 ${r.budget}`;
  console.log(`  ${String(list.length).padStart(3)}  ${r.label}   [${budgetText}]`);
  for (const h of list.slice(0, 8)) {
    console.log(`        ${h.file}:${h.line}  ${h.text.slice(0, 72)}`);
  }
  if (list.length > 8) console.log(`        … 其余 ${list.length - 8} 处见 --json`);
  if (r.note) console.log(`        ↳ ${r.note}`);
}

if (violations.length === 0) {
  console.log('✅ 通过：没有绕过单一通路的写法，预算未被突破。');
  process.exit(0);
}
console.log(`❌ 违规 ${violations.length} 处：`);
for (const v of violations) {
  console.log(`  [${v.kind}] ${v.file}:${v.line}  ${v.msg ?? ''}`);
  if (v.text) console.log(`      ${v.text}`);
}
process.exit(1);




