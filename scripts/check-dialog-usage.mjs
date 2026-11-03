#!/usr/bin/env node
/**
 * scripts/check-dialog-usage.mjs —— **弹窗收口完备性闸门**（2026-11-02 第 25 轮新增）
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 * 真源文档 §3 规定：弹窗生命周期只能有**一个出口** `DialogHost`
 * （`common/dialog/DialogHost.ets`：一次性实例 / 父先真关 / 子退重建父）。
 * 但"人肉把 60+ 处改完"这件事**无法自证完备** —— 改漏一处，下次照样出现
 * "父弹窗留着旧快照、子退父进拿到过期数据"（用户实测过的那类问题）。
 * 所以用一个**机械脚本**把契约变成可执行断言：跑它就能回答"还有几处没走宿主"。
 *
 * ── 判据（三层）─────────────────────────────────────────────────────────────
 * ① **HARD · 裸开**：除 `DialogHost` 自身与显式白名单外，源码里**不允许**出现
 *    `.open()` 调用（就是"自己把弹窗打开"）。这条一旦为 0 ⇒ 所有弹窗打开都经过宿主。
 * ② **HARD · 旧 API**：`AlertDialog.show(` / `promptAction.showDialog(` 必须为 0。
 * ③ **RATCHET · 存量控制器**：`new CustomDialogController(` 的**总数**不得超过
 *    BUDGET。`DialogHost` 的 API 收的是 controller 实例，所以这个数不会自然到 0；
 *    它只用来防"新增弹窗时又各自 new 一堆"。**只许降，不许升**。
 *
 * 用法：
 *   node scripts/check-dialog-usage.mjs            # 检查，违规 → 非零退出
 *   node scripts/check-dialog-usage.mjs --report   # 只打印全量清单（不判失败）
 *   node scripts/check-dialog-usage.mjs --json     # 机器可读（给文档/CI 用）
 *
 * 范围：**只扫真实源码** `entry/src/main/ets/**\/*.ets`（排除 build/、oh_modules/、
 *       任何转译产物），因此它测的是"人写的代码"，不会被编译缓存骗过。
 */

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const ROOT = process.cwd();
const SRC_DIR = join(ROOT, 'entry', 'src', 'main', 'ets');

/** 允许出现裸 `.open()` 的文件（相对 SRC_DIR，正斜杠） */
const ALLOW_BARE_OPEN = [
  // 宿主自己：它就是唯一合法调用 controller.open() 的地方
  'common/dialog/DialogHost.ets',
  // 下面两个是**同名但不是弹窗**的成员方法 `this.open()`（历史命名），不属弹窗范畴
  'pages/view/OuterHomeCard.ets',
  'pages/view/Reader/PdfViewerPage.ets',
];

/**
 * 允许出现旧弹窗 API 的文件（目标：这个数组最终为空）
 *
 * 2026-11-02 已清空 ✅ —— 3 处全局 `AlertDialog.show`（ReaderPage3 ×2、UnsupportedDoc ×1）
 * 全部改成 **UIContext 作用域**的 `getUIContext().showAlertDialog()` / `ui.showAlertDialog()`
 * （SDK 证据：`api/@ohos.arkui.UIContext.d.ts:4715` `showAlertDialog(options): void`，外观参数一致）。
 *
 * ── 边界说明（为什么"系统弹窗"不算绕过 DialogHost）──────────────────────────
 * `DialogHost` 管的是 **`CustomDialogController` 的生命周期**（一次性实例/父先真关/子退重建父）。
 * 系统弹窗（alert）没有 controller 可托管，靠 UIContext 作用域即可保证"在哪个窗口上弹"。
 * ⇒ 硬性要求只有一条：**禁止再出现全局 `AlertDialog.show` / `promptAction.showDialog`**（已废弃）。
 */
const ALLOW_LEGACY_API = [];

/**
 * `new CustomDialogController` 的总预算（只许降不许升）。
 * 2026-11-02 全项目收口完成时的实测值 = 70。
 * ⚠️ 这个数**不会**变成 0：`DialogHost.open/openIf` 的入参就是 controller 实例
 *   （`common/dialog/DialogHost.ets`），构造动作必须留在调用方。它只用于防"新增弹窗又各自 new 一堆"。
 */
/**
 * `new CustomDialogController` 的总预算（只许降不许升）。
 *
 * 沿革（每次变动都必须在这里写清原因，否则等于自己骗自己）：
 *   · 2026-11-02 收口完成时实测 = 70；
 *   · 2026-11-02 第 26 轮 **70 → 71**：E1 修复给「分组管理 → 长按 → 删除」补二次确认，
 *     新增一个 `TitleContentDialog` 的 controller（`BookSelectGroupDialog.askDeleteGroup`）。
 *     这是**加防护**而非加弹窗面：原动作窗保留，只是删除动作多一道确认。
 *
 * ⚠️ 这个数**不会**变成 0：`DialogHost.open/openIf` 的入参就是 controller 实例
 *   （`common/dialog/DialogHost.ets`），构造动作必须留在调用方。它只用于防"新增弹窗又各自 new 一堆"。
 */
const CTRL_BUDGET = 63;

/**
 * RATCHET · **自持 controller 字段**（2026-11-04 P4b 批 C-1 新增，只许降）。
 *
 * 与 `CTRL_BUDGET` 的区别：那个数的是 `new CustomDialogController(` 的**总次数**（含方法内临时创建）；
 * 宿主化之后每个调用点仍然要 new 一次，所以它**不会降**。本项数的是 struct 里
 * 「`xxx: CustomDialogController` 字段」的**存量** —— 这才是"自持"的真指标。
 *
 * 沿革：2026-11-04 首次实测 = **39** → 批 C-1 宿主化 `MyThemeConfigComp` 三个弹窗后 = **36** →
 *   批 C-2 宿主化 `MyCenter` 两个后 = **34** → 批 C-3 宿主化 `MySetPage`(2) + `GroupType`(2) +
 *   `BookContentRefresh`(2) 后 = **39**（新口径下）。
 *
 * ⚠️ 2026-11-04 同日**修正过一次统计口径**：上面的"39/36/34"是用旧判据数的，而旧判据
 *   `if (line.includes('(')) return` 把「`xxx: CustomDialogController = new CustomDialogController({`」
 *   这种**初始化器字段**全漏掉了（例如 `IndexShelf.shelfSearchDialog`、`BookFolder.groupInfoDialog`、
 *   `BookContentRefresh.addGroupDialog`…）。改用"只有含 '(' 且**不是** `= new CustomDialogController(` 才排除"之后，
 *   **真实基线 = 61**，批 C-1~C-3 共宿主化 11 个 ⇒ 现在 = **50**，预算按 50 钉住。
 * 每降一批必须同步改这个数，并把原因写在这里（否则等于自己骗自己）。
 */
const SELF_HELD_BUDGET = 50;
const SELF_HELD_RE = /^\s*(?:(?:private|public|protected|readonly|static)\s+)*[A-Za-z_$][\w$]*\s*:\s*CustomDialogController\b/;

const args = process.argv.slice(2);
const REPORT_ONLY = args.includes('--report');
const AS_JSON = args.includes('--json');

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
const rows = [];

for (const abs of files) {
  const rel = relative(SRC_DIR, abs).split(sep).join('/');
  const text = readFileSync(abs, 'utf8');
  const lines = text.split(/\r?\n/);
  const hit = { file: rel, bareOpen: [], legacyApi: [], newCtrl: [] };
  lines.forEach((line, i) => {
    // 注释行不算（避免把"文档里写的 xxx.open()"当成违规）
    const isComment = /^\s*(\/\/|\*|\/\*)/.test(line);
    if (isComment) return;
    if (/\.open\(\)/.test(line)) hit.bareOpen.push({ line: i + 1, text: line.trim() });
    if (/AlertDialog\.show\(|promptAction\.showDialog\(/.test(line)) {
      hit.legacyApi.push({ line: i + 1, text: line.trim() });
    }
    if (/new CustomDialogController\(/.test(line)) hit.newCtrl.push({ line: i + 1 });
  });
  if (hit.bareOpen.length || hit.legacyApi.length || hit.newCtrl.length) rows.push(hit);
}

const totalNew = rows.reduce((n, r) => n + r.newCtrl.length, 0);

// ── 自持 controller 字段（排除唯一宿主 DialogHost 自身的实现文件）──
const selfHeld = [];
for (const abs of files) {
  const rel = relative(SRC_DIR, abs).split(sep).join('/');
  if (rel.startsWith('common/dialog/')) continue;
  const lines = readFileSync(abs, 'utf8').split(/\r?\n/);
  lines.forEach((line, i) => {
    if (/^\s*(\/\/|\*|\/\*)/.test(line)) return;
    // 形参 / 局部调用不是字段声明；但 xxx: CustomDialogController = new CustomDialogController( 这种初始化器字段必须算进来（2026-11-04 修正：原先把它们漏掉了）
    if (line.includes('(') && !/=\s*new\s+CustomDialogController\s*\(/.test(line)) return;
    if (SELF_HELD_RE.test(line)) selfHeld.push({ file: rel, line: i + 1, text: line.trim() });
  });
}
const totalSelfHeld = selfHeld.length;
const violations = [];
for (const r of rows) {
  if (r.bareOpen.length && !ALLOW_BARE_OPEN.includes(r.file)) {
    for (const o of r.bareOpen) violations.push({ kind: 'bare-open', file: r.file, ...o });
  }
  if (r.legacyApi.length && !ALLOW_LEGACY_API.includes(r.file)) {
    for (const o of r.legacyApi) violations.push({ kind: 'legacy-api', file: r.file, ...o });
  }
}
if (totalSelfHeld > SELF_HELD_BUDGET) {
  violations.push({
    kind: 'self-held-budget',
    file: '(全仓)',
    line: 0,
    text: `自持 CustomDialogController 字段 = ${totalSelfHeld} > BUDGET ${SELF_HELD_BUDGET}`,
  });
}
if (totalNew > CTRL_BUDGET) {
  violations.push({
    kind: 'ctrl-budget',
    file: '(全仓)',
    line: 0,
    text: `new CustomDialogController = ${totalNew} > BUDGET ${CTRL_BUDGET}`,
  });
}

const summary = {
  scannedFiles: files.length,
  filesWithDialogs: rows.length,
  newCustomDialogController: totalNew,
  ctrlBudget: CTRL_BUDGET,
  selfHeldControllers: totalSelfHeld,
  selfHeldBudget: SELF_HELD_BUDGET,
  bareOpenAllowed: rows.reduce((n, r) => n + (ALLOW_BARE_OPEN.includes(r.file) ? r.bareOpen.length : 0), 0),
  violations,
};

if (AS_JSON) {
  console.log(JSON.stringify(summary, null, 2));
  process.exit(violations.length && !REPORT_ONLY ? 1 : 0);
}

console.log('=== 弹窗收口闸门 (scripts/check-dialog-usage.mjs) ===');
console.log(`扫描真实源码: ${summary.scannedFiles} 个 .ets；含弹窗用法的文件: ${summary.filesWithDialogs} 个`);
console.log(`new CustomDialogController 总数: ${totalNew} / 预算 ${CTRL_BUDGET}（只许降）`);
console.log(`自持 controller 字段: ${totalSelfHeld} / 预算 ${SELF_HELD_BUDGET}（只许降）`);
console.log('');

if (rows.length) {
  console.log('--- 按文件的弹窗用法 ---');
  console.log('  bareOpen  legacyApi  newCtrl  文件');
  for (const r of rows.sort((a, b) => b.bareOpen.length - a.bareOpen.length || b.newCtrl.length - a.newCtrl.length)) {
    const mark = (r.bareOpen.length && !ALLOW_BARE_OPEN.includes(r.file)) ? '!' : ' ';
    console.log(
      `${mark} ${String(r.bareOpen.length).padStart(6)}  ${String(r.legacyApi.length).padStart(9)}  ` +
      `${String(r.newCtrl.length).padStart(7)}  ${r.file}`
    );
  }
  console.log('');
}

if (violations.length === 0) {
  console.log('✅ 通过：没有"绕过 DialogHost 自己开弹窗"的代码，也没有旧弹窗 API。');
  process.exit(0);
}

console.log(`❌ 未收口 ${violations.length} 处：`);
for (const v of violations) {
  console.log(`  [${v.kind}] ${v.file}:${v.line}  ${v.text}`);
}
console.log('');
console.log('修改方式：把 `<controller>?.open()` / `<controller>.open()` 换成');
console.log('  DialogHost.openIf(<controller>)        // 可空版本，等价于旧 xxx?.open()');
console.log('  DialogHost.open(<controller>)          // 非空版本');
console.log('旧 API（AlertDialog.show / promptAction.showDialog）改成对应 @CustomDialog + DialogHost。');
process.exit(REPORT_ONLY ? 0 : 1);
