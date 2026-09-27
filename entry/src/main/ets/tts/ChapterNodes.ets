/**
 * 章节原文 → ReaderKit 块节点模型（全链路唯一坐标系）。
 *
 * 为什么需要这一层（来自真机日志的结论，不是猜测）：
 *   on('pageShow') 返回的 startDomPos / endDomPos 形如
 *     "19=0#43;@;0"   →   <块节点序号(1 起)>=0#<节点内字符下标>
 *   证据 1：相邻页首尾严丝合缝（页尾 31=0#57 → 下页首 31=0#58），说明 Y 是"含末字符"的
 *          节点内字符下标，因此页内容的字符级映射是可精确获得的。
 *   证据 2：日志里出现过 39 → 41 的断号（39=0#58 的下一页直接是 41=0#0），
 *          说明 ReaderKit 的节点序号里存在"空节点"（不渲染但占号）。
 *
 * 而 TTS 侧原先用 `plain.split(/\n+/)` 建段落号，空行被折叠、不计数。
 * 只要章节里存在空行，从第一个空行之后，TTS 段落号与 ReaderKit 节点号就整体错位，
 * 于是 startPlay 拿到的 domPos 指向错误段落 —— 这就是"定位只能理论定位"的第一性原因。
 *
 * 本模块只做一件事：生成与 ReaderKit 块节点 1:1 的节点数组，
 * 让 TTS 的 nodeIndex 直接就是 ReaderKit 的 (X - 1)，无需任何换算。
 *
 * - TXT：每个物理行（含空行）一个节点；
 * - HTML：每个块级元素结束标签切一刀，得到与 DOM 块子节点顺序一致的节点序列。
 *
 * HTML 路径为最佳努力（ReaderKit 内部会折叠空白、处理实体），
 * TXT 路径可与 ReaderKit 严格一致；两者都会由 ReaderPage3 用 pageShow 观测到的
 * 最大节点号做一次一致性自检（见 TtsEngine.parityHint）。
 */

const BLOCK_SENTINEL = '\u0001';

/** 章节块节点模型 */
export interface ChapterNodes {
  /** ReaderKit 块节点文本；下标即 (domPos 的 X - 1) */
  nodes: string[];
  /** 节点起始在明文中的偏移（locateText 的兜底搜索空间） */
  nodeStart: number[];
  /** nodes 以 '\n' 连接后的明文 */
  plain: string;
}

export function buildChapterNodes(content: string): ChapterNodes {
  const nodes: string[] = content.indexOf('<') < 0
    ? splitTxtNodes(content)
    : splitHtmlNodes(content);
  const nodeStart: number[] = [];
  let abs = 0;
  for (let i = 0; i < nodes.length; i++) {
    nodeStart.push(abs);
    abs += nodes[i].length + 1; // +1 = 连接用的 '\n'
  }
  const model: ChapterNodes = {
    nodes: nodes,
    nodeStart: nodeStart,
    plain: nodes.join('\n')
  };
  return model;
}

/**
 * TXT：按物理行切节点，保留空行（空行占号但不朗读）。
 * 仅去掉文件末尾换行产生的尾部空节点——阅读器不会为文档末尾的换行生成可见块。
 */
function splitTxtNodes(content: string): string[] {
  const t = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const raw = t.split('\n');
  let end = raw.length;
  while (end > 1 && raw[end - 1].trim().length === 0) {
    end--;
  }
  const out: string[] = [];
  for (let i = 0; i < end; i++) {
    out.push(raw[i]);
  }
  return out;
}

/**
 * HTML：块级元素结束标签处切分。首尾因标签产生的空片段丢弃，
 * 中间的空片段保留（对应空块节点，与 ReaderKit 的占号行为一致）。
 */
function splitHtmlNodes(content: string): string[] {
  let t = content.replace(/<(script|style)[\s\S]*?<\/\1\s*>/gi, '');
  t = t.replace(/<\/(p|div|h[1-6]|li|tr|section|article|blockquote)\s*>/gi, BLOCK_SENTINEL);
  // <br> 是块内换行，不产生新节点
  t = t.replace(/<br\s*\/?\s*>/gi, ' ');
  t = t.replace(/<[^>]+>/g, '');
  t = decodeHtmlEntities(t);
  const parts = t.split(BLOCK_SENTINEL);
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    out.push(parts[i].replace(/\s+/g, ' ').trim());
  }
  while (out.length > 0 && out[out.length - 1].length === 0) {
    out.pop();
  }
  while (out.length > 0 && out[0].length === 0) {
    out.shift();
  }
  return out;
}

/** 明文（不带标签的纯文本内容）→ 单节点。用于兜底/兼容调用。 */
export function htmlToPlainText(content: string): string {
  return buildChapterNodes(content).plain;
}

export function decodeHtmlEntities(s: string): string {
  let out = s.replace(/&#x([0-9a-fA-F]+);/g, (_m: string, p1: string): string => {
    return String.fromCodePoint(parseInt(p1, 16));
  });
  out = out.replace(/&#(\d+);/g, (_m: string, p1: string): string => {
    return String.fromCodePoint(parseInt(p1, 10));
  });
  out = out.replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&ldquo;/g, '\u201C')
    .replace(/&rdquo;/g, '\u201D')
    .replace(/&lsquo;/g, '\u2018')
    .replace(/&rsquo;/g, '\u2019')
    .replace(/&hellip;/g, '\u2026')
    .replace(/&mdash;/g, '\u2014')
    .replace(/&ensp;/g, ' ')
    .replace(/&emsp;/g, ' ');
  return out;
}
