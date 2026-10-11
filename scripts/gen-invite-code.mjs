/**
 * 邀请码生成脚本（2026-10-12 纯白名单版）。
 *
 * 用法：
 *   node scripts/gen-invite-code.mjs 10000
 *
 * 输出：
 *   - 控制台打印前 10 个码预览
 *   - scripts/inviteCodes_10000.csv（Excel 可打开）
 *
 * 生成后：
 *   1. 把 CSV 导入 Excel，自己管理"给谁了"
 *   2. 把 scripts/inviteCodes_10000.csv 第 2 列复制进
 *      InviteCodeManager.ets 的 WHITELIST Set，替换占位数组
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PREFIX = 'LEGADO-';
const CODE_LEN = 10;
const BASE36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/**
 * 生成一个 10 位随机 base36 码（crypto 安全随机）。
 */
function genOne() {
  const bytes = crypto.randomBytes(CODE_LEN); // 10 字节 → 80 bit 熵
  let code = '';
  for (let i = 0; i < CODE_LEN; i++) {
    code += BASE36.charAt(bytes[i] % 36);
  }
  return code;
}

// ── main ──────────────────────────────────────────────────────────────────

const count = parseInt(process.argv[2] ?? '10000', 10);

if (isNaN(count) || count < 1) {
  console.error('用法：node scripts/gen-invite-code.mjs [数量]');
  process.exit(1);
}

const codes = new Set();
while (codes.size < count) {
  codes.add(genOne());
}

const list = Array.from(codes);
list.sort();

// 控制台预览前 10 个
console.log(`生成了 ${count} 个邀请码：`);
for (let i = 0; i < Math.min(10, count); i++) {
  console.log(`  ${PREFIX}${list[i]}`);
}
if (count > 10) {
  console.log(`  ...（共 ${count} 个）`);
}

// 写 CSV
const csvPath = path.join(__dirname, 'inviteCodes_' + count + '.csv');
const csvLines = ['序号,邀请码,已送出(是/否),给了谁,日期'];
for (let i = 0; i < list.length; i++) {
  csvLines.push(`${i + 1},${PREFIX}${list[i]},否,,`);
}
fs.writeFileSync(csvPath, csvLines.join('\n'), 'utf-8');
console.log(`\nCSV 已写入：${csvPath}`);
console.log('用 Excel 打开即可管理。');

// 写 ArkTS 白名单文件（方便直接粘贴）
const tsPath = path.join(__dirname, 'inviteCodes_' + count + '_whitelist.txt');
const tsLines = [];
for (let i = 0; i < list.length; i++) {
  tsLines.push(`    '${list[i]}',`);
}
fs.writeFileSync(tsPath, tsLines.join('\n'), 'utf-8');
console.log(`白名单代码块已写入：${tsPath}`);
console.log('复制全部内容，替换 InviteCodeManager.ets 中 new Set([...]) 部分即可。');