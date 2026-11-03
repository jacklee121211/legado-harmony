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
const GROUP_TREE_BUILD_BUDGET = 9;
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
    allow: () => false,
    budget: 71,
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
    note: '2026-11-03（Ⅱ-3）：5 处读取点已随旧分支删除 ⇒ 预算 5→0；GroupFlags.ets 本身保留一个版本（已标 deprecated）'
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
      || rel === 'common/group/GroupMutation.ets',
    budget: 5,
    note: '2026-11-03（Ⅲ-2 审计）：实测 5 处全在 FolderInfoDialog（合并/解散的移书与回滚）—— 书籍域还没有 BooksMutation，先 ratchet 锁住不许增长',
  },
  {
    id: 'boundary-dao-write',
    label: '边界 lane 直写事实（导入/传书/分享/碰一碰）',
    pattern: /\b(booksDao|bookGroupsDao|bookmarksDao)\.(insert|partialUpdate|update|updateBookGroup|add|remove|delete)\s*\(/,
    scope: /(FileHandler|WifiBookServer|BookShareBridge|UnsupportedDoc)\.ets$/,
    allow: () => false,
    budget: 2,
    note: '2026-11-03（Ⅳ-1）：FileHandler 已改走适配器；剩 WifiBookServer 的 bookmarksDao.add/remove 2 处（书签还没有适配器，属下一批）',
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


