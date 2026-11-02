#!/usr/bin/env node
/**
 * scripts/migrate-refresh-signals.mjs —— B1 的一次性机械迁移（**默认 dry-run**）
 *
 * 把散落的"刷新信号自增写点"改为 `ShelfRefresh.*()` 调用。**行为等价**：
 *   · `this.BOOK_IS_BOOK_GROUPS_REFRESHING++`  → `ShelfRefresh.groups()`
 *   · `this.BOOK_IS_BOOK_REFRESHING++`         → `ShelfRefresh.books()`
 *   · `this.isBookRefreshing++`               → `ShelfRefresh.books()`   （它是书键的 @StorageLink 别名）
 *   · `this.isGroupRefreshing++` / `this.groupRefreshing++` → `ShelfRefresh.groups()`
 *   · `this.bookRefreshing++` / `this.dataTick++`           → `ShelfRefresh.books()`
 *
 * 为什么写成脚本而不是逐个手改：56 处 × 12 文件属**批量机械改写**，按项目纪律必须
 * "脚本 + 先 dry-run 打印计划 + 复核 + 执行 + 立即 git diff 复核"（见预设【改文件只用编辑工具】）。
 *
 * 用法：
 *   node scripts/migrate-refresh-signals.mjs           # dry-run（只打印计划，不落盘）
 *   node scripts/migrate-refresh-signals.mjs --write   # 真正写入
 *
 * 注意：本脚本**只做这一件事**，迁移完即可删除（它不是长期闸门，闸门是 check-single-path.mjs）。
 */
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join, relative, sep, dirname } from 'node:path';

const ROOT = process.cwd();
const SRC = join(ROOT, 'entry', 'src', 'main', 'ets');
const WRITE = process.argv.includes('--write');

/** 键/别名 → 门面方法（顺序敏感：先匹配长名，避免 isBookRefreshing 被 BOOK_IS_BOOK 部分命中） */
const RULES = [
  { re: /\bthis\.BOOK_IS_BOOK_GROUPS_REFRESHING\+\+/g, to: 'ShelfRefresh.groups()', kind: 'groups' },
  { re: /\bthis\.BOOK_IS_BOOK_REFRESHING\+\+/g, to: 'ShelfRefresh.books()', kind: 'books' },
  { re: /\bthis\.bookRefreshing\+\+/g, to: 'ShelfRefresh.books()', kind: 'books' },
  { re: /\bthis\.dataTick\+\+/g, to: 'ShelfRefresh.books()', kind: 'books' },
  { re: /\bthis\.isBookRefreshing\+\+/g, to: 'ShelfRefresh.books()', kind: 'books' },
  { re: /\bthis\.isGroupRefreshing\+\+/g, to: 'ShelfRefresh.groups()', kind: 'groups' },
  { re: /\bthis\.groupRefreshing\+\+/g, to: 'ShelfRefresh.groups()', kind: 'groups' },
];

const SKIP_FILES = [
  // 门面自己（它就是唯一写点）
  'common/shelf/ShelfRefresh.ets',
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

/** 从目标文件到 ets 根计算 ShelfRefresh 的相对导入路径 */
function importPath(absFile) {
  const fromDir = dirname(absFile);
  let rel = relative(fromDir, join(SRC, 'common', 'shelf', 'ShelfRefresh')).split(sep).join('/');
  if (!rel.startsWith('.')) rel = './' + rel;
  return rel;
}

const files = walk(SRC);
const plan = [];

for (const abs of files) {
  const rel = relative(SRC, abs).split(sep).join('/');
  if (SKIP_FILES.includes(rel)) continue;
  let text = readFileSync(abs, 'utf8');
  const before = text;
  let count = 0;
  const kinds = new Set();

  for (const rule of RULES) {
    text = text.replace(rule.re, () => {
      count++;
      kinds.add(rule.kind);
      return rule.to;
    });
  }

  // 第二类：`const x = (AppStorage.get<number>(KEY) ?? 0) + 1; AppStorage.setOrCreate(KEY, x)`
  // 两行成对写法（非书架域的触发方：网关/启动/阅读器/PDF）。语义与门面"加一"完全一致，
  // 转换后保留同一个变量名，调用方后续的日志仍能打印新值。
  const pairRe = new RegExp(
    'const\\s+(\\w+)\\s*:\\s*number\\s*=\\s*\\(\\s*AppStorage\\.get<number>\\(\\s*([^)]+?)\\s*\\)\\s*\\?\\?\\s*0\\s*\\)\\s*\\+\\s*1;?\\s*\\r?\\n\\s*AppStorage\\.setOrCreate\\(\\s*([^,]+?),\\s*\\1\\s*\\)',
    'g'
  );
  text = text.replace(pairRe, (m, name, keyExpr, keyExpr2) => {
    const keyText = String(keyExpr2 || keyExpr);
    const fn = keyText.includes('GROUPS') ? 'groups' : 'books';
    count++;
    kinds.add(fn);
    return `const ${name}: number = ShelfRefresh.${fn}()`;
  });
  if (count === 0) continue;

  // 补 import（已有就不重复）
  if (!/from\s+['"][^'"]*common\/shelf\/ShelfRefresh['"]/.test(text)) {
    const p = importPath(abs);
    const line = `import { ShelfRefresh } from '${p}';\n`;
    // 插在最后一个 import 之后；没有 import 就插在文件头
    const lines = text.split('\n');
    let last = -1;
    for (let i = 0; i < lines.length; i++) {
      if (/^\s*import\s/.test(lines[i])) last = i;
    }
    if (last >= 0) lines.splice(last + 1, 0, line.trimEnd());
    else lines.unshift(line.trimEnd());
    text = lines.join('\n');
  }

  plan.push({ rel, abs, count, kinds: [...kinds].join('+'), changed: text !== before, text });
}

const total = plan.reduce((n, p) => n + p.count, 0);
console.log(`=== 迁移计划（${WRITE ? 'WRITE' : 'DRY-RUN'}）===`);
console.log(`命中文件 ${plan.length} 个，写点 ${total} 处\n`);
for (const p of plan.sort((a, b) => b.count - a.count)) {
  console.log(`  ${String(p.count).padStart(2)}  ${p.rel.padEnd(58)} ${p.kinds}`);
}

if (!WRITE) {
  console.log('\n（dry-run 结束；确认无误后加 --write 执行）');
  process.exit(0);
}
for (const p of plan) {
  writeFileSync(p.abs, p.text, 'utf8');
}
console.log(`\n已写入 ${plan.length} 个文件。请立即 \`git diff\` 复核，并跑 build + 闸门。`);
