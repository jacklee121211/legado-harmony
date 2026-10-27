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
/** 标题标记（插在 </h1>~</h6> 产生的块边界**之前**，切分后该段以此标记结尾）
 *  ⚠️ 2026-10-27：ReaderKit 会把 <h1>~<h6> 渲染成**大字号+加粗**的章标题，
 *  而我们原来把所有标签都剥成普通正文 ⇒ 行数不同 ⇒ 页边界不同 ⇒ 进度错位。
 *  这里保留标题语义，供 EngineLines 用标题样式排版。 */
const TITLE_MARK = '\u0002';

/** 章节块节点模型 */
export interface ChapterNodes {
  /** ReaderKit 块节点文本；下标即 (domPos 的 X - 1) */
  nodes: string[];
  /** 节点起始在明文中的偏移（locateText 的兜底搜索空间） */
  nodeStart: number[];
  /** nodes 以 '\n' 连接后的明文 */
  plain: string;
  /**
   * 每段是否「章标题」（与 `nodes` 等长）。
   *
   * ⚠️ 2026-10-27 新增：ReaderKit 把 `<h1>`~`<h6>` 渲染成**大字号 + 加粗**的章标题，
   *    而本模块原来把所有标签都剥成普通正文 ⇒ 同一段落一行大字号 vs 一行正文字号
   *    ⇒ **行数不同 ⇒ 页边界不同 ⇒ 两种阅读方式的进度对不上**（真机实测：同一章
   *    仿真档停在章首、无动画档已到章中，差好几页）。
   *    ⇒ 现在保留标题语义，`EngineLines` 据此对标题段套用标题样式。
   */
  isTitle: boolean[];
}

export function buildChapterNodes(content: string, chapterTitle?: string): ChapterNodes {
  const isHtml: boolean = content.indexOf('<') >= 0;
  const split: NodeSplit = isHtml ? splitHtmlNodes(content) : splitTxtNodes(content);
  const nodes: string[] = split.nodes;
  const nodeStart: number[] = [];
  let abs = 0;
  for (let i = 0; i < nodes.length; i++) {
    nodeStart.push(abs);
    abs += nodes[i].length + 1; // +1 = 连接用的 '\n'
  }
  // ⚠️ TXT 没有标签，`isTitle` 全是 false ⇒ 章标题会和正文一样大。
  //   真机日志实证：`getSpineItemContent()` 对 txt 返回**纯文本**（`hasTag=NO`），
  //   首行就是「第十章 澹台仙子」。ReaderKit 的标题样式是它内部按文本正则识别的。
  //   ⇒ 我们**不猜它的正则**，直接用它的目录（`getCatalogList()` 已经识别出章节名）
  //     反推：章首第一段若与该章目录名匹配，就认定为标题。
  //   这样与 ReaderKit 的判断依据同源，命中率高且不会误判正文。
  if (chapterTitle !== undefined && chapterTitle.length > 0 && nodes.length > 0) {
    if (matchChapterTitle(nodes[0], chapterTitle)) {
      split.isTitle[0] = true;
    }
  }
  const model: ChapterNodes = {
    nodes: nodes,
    nodeStart: nodeStart,
    plain: nodes.join('\n'),
    isTitle: split.isTitle
  };
  return model;
}

/**
 * 章首段是否就是章标题。
 *
 * 允许三种形态（目录名与正文标题常有细微差异）：
 *   · 完全相等
 *   · 正文以目录名开头（正文带额外前后缀）
 *   · 目录名以正文开头（正文截断了）
 * 都先 trim + 压缩空白，避免全角空格/多空格导致假阴性。
 */
function matchChapterTitle(node: string, title: string): boolean {
  const a: string = node.replace(/\s+/g, ' ').trim();
  const b: string = title.replace(/\s+/g, ' ').trim();
  if (a.length === 0 || b.length === 0) {
    return false;
  }
  // 太短的"标题"不可信（避免把"一"这种正文误判成标题）
  if (a.length < 2 || b.length < 2) {
    return false;
  }
  return a === b || a.startsWith(b) || b.startsWith(a);
}

/** 内部：切分结果（段文本 + 是否标题） */
interface NodeSplit {
  nodes: string[];
  isTitle: boolean[];
}

/**
 * TXT：按物理行切节点，保留空行（空行占号但不朗读）。
 * 仅去掉文件末尾换行产生的尾部空节点——阅读器不会为文档末尾的换行生成可见块。
 */
function splitTxtNodes(content: string): NodeSplit {
  const t = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const raw = t.split('\n');
  let end = raw.length;
  while (end > 1 && raw[end - 1].trim().length === 0) {
    end--;
  }
  const out: string[] = [];
  const isTitle: boolean[] = [];
  for (let i = 0; i < end; i++) {
    out.push(raw[i]);
    // TXT 没有标签，无法判断标题（纯文本里没有语义）
    isTitle.push(false);
  }
  const r: NodeSplit = { nodes: out, isTitle: isTitle };
  return r;
}

/**
 * HTML：块级元素结束标签处切分。首尾因标签产生的空片段丢弃，
 * 中间的空片段保留（对应空块节点，与 ReaderKit 的占号行为一致）。
 */
function splitHtmlNodes(content: string): NodeSplit {
  let t = content.replace(/<(script|style)[\s\S]*?<\/\1\s*>/gi, '');
  // ⚠️ 标题结束标签**必须先处理**：插 `TITLE_MARK` 再复用块边界，
  //    这样切分后"标题段"的文本会以 TITLE_MARK 结尾，可据此标记（且不污染正文）。
  //    ⚠️ 顺序不能反：普通块正则里若仍含 `h[1-6]`，会把刚插入的标记当标签一起剥掉。
  t = t.replace(/<\/h[1-6]\s*>/gi, TITLE_MARK + BLOCK_SENTINEL);
  t = t.replace(/<\/(p|div|li|tr|section|article|blockquote)\s*>/gi, BLOCK_SENTINEL);
  // <br> 是块内换行，不产生新节点
  t = t.replace(/<br\s*\/?\s*>/gi, ' ');
  t = t.replace(/<[^>]+>/g, '');
  t = decodeHtmlEntities(t);
  const parts = t.split(BLOCK_SENTINEL);
  const out: string[] = [];
  const isTitle: boolean[] = [];
  for (let i = 0; i < parts.length; i++) {
    let s: string = parts[i].replace(/\s+/g, ' ').trim();
    let title: boolean = false;
    if (s.endsWith(TITLE_MARK)) {
      title = true;
      s = s.substring(0, s.length - TITLE_MARK.length).trim();
    }
    out.push(s);
    isTitle.push(title);
  }
  // 首尾空段丢弃（`isTitle` 必须同步丢，否则与 `nodes` 错位）
  while (out.length > 0 && out[out.length - 1].length === 0) {
    out.pop();
    isTitle.pop();
  }
  while (out.length > 0 && out[0].length === 0) {
    out.shift();
    isTitle.shift();
  }
  const r: NodeSplit = { nodes: out, isTitle: isTitle };
  return r;
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
