/**
 * 朗读过滤规则（2026-10-10 新增，能力对齐参考项目）。
 *
 * ## 核心机制：**等长空格掩码**，不是删除
 * 参考项目 `voiceReadFilterApply.ts` 的做法（其作者经实战验证）：
 * 命中片段**逐字符替换为空格（换行保留）**，因此
 *   · 字符数完全不变 ⇒ **高亮偏移 / 行列号 / 词级时间戳全部不受影响**；
 *   · 掩码后若整段不再"可读"，由 `hasSpeakableText` 自动跳过
 *     （实测：`EdgeTtsClient.ets:95-101` 先剥空白再要求 CJK/假名/字母数字）。
 * 这就是我们**敢直接改 `chunk.text`** 而不动高亮链路的原因。
 *
 * ## 规则写法（面板里一行一条，便于手机上编辑）
 *   `正则`        → 按正则匹配（默认）
 *   `~文本`       → 按**字面量**匹配（不想处理正则转义时用）
 *   `#任意内容`   → 注释/停用该行
 * 依次套用（自上而下），与传统"按 order 排序"等价但更直观。
 *
 * ## 与参考项目的差异（合规）
 * 掩码语义是**行为/事实**，可对齐；但**默认规则集是我们自己写的**
 * （见 {@link DEFAULT_SPEAK_FILTER_TEXT}），不复制它的 pattern 常量。
 */
export interface SpeakFilterRuleLocal {
  pattern: string;
  isRegex: boolean;
}

/** 默认规则（自写）：括号注释、常见章末噪音、分隔线 */
export const DEFAULT_SPEAK_FILTER_TEXT: string =
  '# 一行一条；默认按正则；~ 开头表示按字面量；# 开头是注释\n' +
  '[(（〔﹝][^)）〕﹞]{0,60}[)）〕﹞]\n' +
  '[\\[［【〖][^\\]］】〗]{0,60}[\\]］】〗]\n' +
  '未完待续|本章完|全书完|全文完|求(推荐|收藏|月票)|字数[:：]?[0-9]+\n' +
  '[-=*—–_~·•]{3,}';

/** 解析：一行一条；`~` 字面量；`#` 停用 */
export function parseSpeakFilterText(text: string): SpeakFilterRuleLocal[] {
  const out: SpeakFilterRuleLocal[] = [];
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const t: string = lines[i].trim();
    if (t.length === 0 || t.startsWith('#')) {
      continue;
    }
    if (t.startsWith('~')) {
      const p: string = t.substring(1).trim();
      if (p.length > 0) {
        out.push({ pattern: p, isRegex: false });
      }
      continue;
    }
    out.push({ pattern: t, isRegex: true });
  }
  return out;
}

/** 命中片段 → 等长空格（换行保留） */
export function maskSpan(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    out += (c === '\n' || c === '\r') ? c : ' ';
  }
  return out;
}

/** 统计"被掩码掉的可读字符数"（写日志用，给真机取证） */
export function countMaskedChars(before: string, after: string): number {
  let n: number = 0;
  const len: number = Math.min(before.length, after.length);
  for (let i = 0; i < len; i++) {
    const b: string = before.charAt(i);
    if (after.charAt(i) === ' ' && b !== ' ' && b !== '\t') {
      n++;
    }
  }
  return n;
}

/** 编译正则：flags 逐级回退（`s`/`u` 在不同运行时支持度不同） */
function compileFilterRegex(pattern: string): RegExp | null {
  const flags: string[] = ['gms', 'gm', 'g'];
  for (let i = 0; i < flags.length; i++) {
    try {
      return new RegExp(pattern, flags[i]);
    } catch (e) {
      // 换下一组 flags
    }
  }
  return null;
}

/** 正则掩码：手动 exec 循环（**不用 replace 回调**，ArkTS 回调签名易踩坑；顺带防零宽死循环） */
function maskRegex(text: string, re: RegExp): string {
  let out: string = '';
  let last: number = 0;
  let guard: number = 0;
  let m: RegExpExecArray | null = re.exec(text);
  while (m !== null && guard < 20000) {
    guard++;
    const idx: number = m.index;
    const matched: string = m[0];
    if (matched.length === 0) {
      re.lastIndex = idx + 1; // 零宽匹配：强制前进，避免死循环
      m = re.exec(text);
      continue;
    }
    if (idx < last) { // 重叠（前一条规则已掩码）：跳过
      m = re.exec(text);
      continue;
    }
    out += text.substring(last, idx) + maskSpan(matched);
    last = idx + matched.length;
    m = re.exec(text);
  }
  out += text.substring(last);
  return out;
}

/** 字面量掩码（indexOf 循环，避免正则转义问题） */
function maskLiteral(text: string, pattern: string): string {
  if (pattern.length === 0) {
    return text;
  }
  let out: string = '';
  let i: number = 0;
  while (i < text.length) {
    const j: number = text.indexOf(pattern, i);
    if (j < 0) {
      out += text.substring(i);
      break;
    }
    out += text.substring(i, j) + maskSpan(pattern);
    i = j + pattern.length;
  }
  return out;
}

/**
 * 套用全部规则。
 * @param rules 已解析的规则（自上而下依次套用）
 * @returns 掩码后的文本；**长度与原文本一致**（换行保留）
 */
export function applySpeakFilter(text: string, rules: SpeakFilterRuleLocal[]): string {
  if (text.length === 0 || rules.length === 0) {
    return text;
  }
  let out: string = text;
  for (let i = 0; i < rules.length; i++) {
    const r: SpeakFilterRuleLocal = rules[i];
    if (r.pattern.length === 0) {
      continue;
    }
    try {
      if (r.isRegex) {
        const re: RegExp | null = compileFilterRegex(r.pattern);
        if (re === null) {
          continue; // 正则不合法 ⇒ 跳过该条（绝不因为一条坏规则中断朗读）
        }
        out = maskRegex(out, re);
      } else {
        out = maskLiteral(out, r.pattern);
      }
    } catch (e) {
      continue;
    }
  }
  return out;
}
