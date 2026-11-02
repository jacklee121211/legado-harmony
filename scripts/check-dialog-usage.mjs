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

/** 允许出现旧弹窗 API 的文件（目标：这个数组最终为空） */
const ALLOW_LEGACY_API = [
  // 第 25 轮摸底：UnsupportedDoc 的 AlertDialog.show、ReaderPage3 的 2 处 AlertDialog.show
  // 会在「阅读器域」批次统一迁走，迁完就把这几条删掉（闸门会因此变严）
  'common/utils/UnsupportedDoc.ets',
  'pages/view/Reader/ReaderPage3.ets',
];

/** `new CustomDialogController` 的总预算（只许降不许升） */
const CTRL_BUDGET = 79;

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
const violations = [];
for (const r of rows) {
  if (r.bareOpen.length && !ALLOW_BARE_OPEN.includes(r.file)) {
    for (const o of r.bareOpen) violations.push({ kind: 'bare-open', file: r.file, ...o });
  }
  if (r.legacyApi.length && !ALLOW_LEGACY_API.includes(r.file)) {
    for (const o of r.legacyApi) violations.push({ kind: 'legacy-api', file: r.file, ...o });
  }
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
