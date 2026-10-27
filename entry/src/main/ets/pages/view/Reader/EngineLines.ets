/**
 * 「引擎排行」—— 无动画与上下滚动两档的**唯一行数据源**。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么需要这个模块（2026-10-27 定案）
 * ══════════════════════════════════════════════════════════════════════════
 * 改造前两档的「行」各算各的：
 *   · 上下档：`Text(段)` 让 ArkUI 自己换行 —— 行是**真实**的；
 *   · 无动画：`ReaderPager.paginateNodes(cpl, maxLines)` 用
 *       `cpl = floor(宽/字号)`、`maxLines = floor(高/行高)`、`行数 = ceil(段长/cpl)`
 *     纯算术估算，而真实排版里每行字数并不固定（标点避头尾、中英混排、字距）。
 *   ⇒ 估算一页 156 字，实际排出 14 行 ⇒ **底部溢出**；
 *     估算 210 字，实际只用 9 行 ⇒ **下半屏空白**。
 *
 * ⇒ 现在统一用 **`@ohos.graphics.text`**（与 ArkUI `Text` 同一个底层引擎）真排一遍，
 *   拿 `getLineMetrics()` 的行区间作为**唯一权威**：
 *     · 无动画：按行高累加 → 精确切页（不溢出、不留白）；
 *     · 上下档：直接按行渲染。
 *   两档吃同一份 `EngineLine[]` ⇒ 互切版式**逐字一致**。
 *
 * ⚠️ 不追求与 ReaderKit（Chromium 内核）的仿真/横滑一致 ——
 *   日志实证 ReaderKit 用 `chromium` + 横向长卷裁切（`totalWidth:22685`），
 *   与 Skia 流式排版是两个引擎，差 ±1 字是物理极限（见 AGENTS.md）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 已踩过的坑（勿重犯）
 * ══════════════════════════════════════════════════════════════════════════
 * · `TextStyle` **没有** `lineHeight` 字段 ⇒ 行高只能走 `StrutStyle.height`
 *   （`@ohos.graphics.text.d.ts`），且该字段是**倍数**（行高 ÷ 字号），不是绝对值。
 * · `text.FontWeight` 枚举成员是 `W100..W900`，**没有** `REGULAR`/`NORMAL`。
 * · `TextStyle.fontFamilies` 要 **`string[]`**：父页传来的 `fontFamily` 是
 *   ArkUI 风格的回退链（`"HarmonyOS Sans SC, 鸿蒙黑体"`），整串塞进去会回落默认字体
 *   ⇒ 字宽不同 ⇒ 断行全错。
 * · 自定义字体必须 `FontCollection.loadFontSync(name, "file://"+path)` 注册进**引擎**，
 *   ArkUI 侧的字体注册与它是两套（`@ohos.graphics.text.d.ts:1335-1349` 原文）。
 * · 段首缩进用**全角空格前缀**实现，不要用"减宽度排版"：
 *   减宽度会改变换行计算（整段少 2 字），实测断点全错。
 */

import { text } from '@kit.ArkGraphics2D';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'EngineLines';
const DOMAIN: number = 0x0000;

/** 段首缩进字符：2 个全角空格 = 2 个字位（与 `ReaderPager.INDENT_SLOTS` 同义） */
const INDENT_CHARS: string = '\u3000\u3000';

/**
 * 章标题字号倍数（相对正文）。
 * ⚠️ **排版与渲染必须用同一个值**：EngineLines 按它算行高，渲染端按它设 `.fontSize`，
 *    不一致会导致标题行实际高度与分页假设不符 ⇒ 溢出。
 * 像素实测（ReaderKit 同一章首）：标题暗像素高 60px / 正文单行 50~55px、字宽比 ≈1.35。
 */
export const TITLE_FONT_SCALE: number = 1.33;
/** 章标题字重（ReaderKit 的标题明显更粗） */
export const TITLE_FONT_WEIGHT: number = 600;

/**
 * **正文字距（fp）** —— 让每行字数与 ReaderKit 一致的关键。
 *
 * ⚠️⚠️ 为什么必须加（2026-10-27 双截图逐像素实测定案）
 * ─────────────────────────────────────────────────────────────
 * 同一章、同一字号，实测两边「字高完全相同（74px）」但「每行字数不同」：
 *   · ReaderKit：949px ÷ 11 字 = **86.2px/字**
 *   · 我们    ：965px ÷ 12 字 = **80.4px/字**
 * 字号一样（24fp → 81px）却能差 5.8px/字 ⇒ **ReaderKit 在正文上加了额外字距**。
 *
 * 后果不是"好不好看"，而是**页边界系统性错位**：我们每行多塞 1 个字，
 * 一页 14 行就多 14 个字，几页之后整页偏移 ⇒ 切档跳页、听书位错。
 *
 * ⚠️ 引擎（`text.TextStyle.letterSpacing`，单位 **px**，`@since 12`）与
 *    渲染（`Text.letterSpacing`，单位 **fp**）**必须用同一个值**换算，
 *    否则"引擎按 A 断行、ArkUI 按 B 渲染" ⇒ 溢出或换行位置错。
 */
export const LETTER_SPACING_FP: number = 1.7;

/** 一行（排版的唯一权威单位） */
export class EngineLine {
  /**
   * 该行要渲染的文本。
   * ⚠️ **段首行保留缩进前缀**（`\u3000\u3000`）：引擎是按"含前缀"排版的，
   *    渲染时也必须显示同样的字符，否则 ArkUI 会少 2 个字位的宽度 ⇒ 多显示字/换行。
   */
  text: string = '';
  /** 该行文本里属于缩进前缀的字符数（首行 = 2，其余 = 0），算高亮行内位置时要用 */
  prefixLen: number = 0;
  /** 属于第几段（= `nodes` 下标） */
  paraIndex: number = 0;
  /** 是否段首行（渲染时顶部要多留 `padTopPx`） */
  isParaStart: boolean = false;
  /** 段内起始字符下标（含，**不含缩进前缀**） */
  charFrom: number = 0;
  /** 段内结束字符下标（不含，**不含缩进前缀**） */
  charTo: number = 0;
  /** 该行**顶部**额外间距（px）—— 仅段首行 = `gapPx`，其余 = 0 */
  padTopPx: number = 0;
  /**
   * 该行的**真实行高**（px）—— 来自引擎 `LineMetrics.height`。
   *
   * ⚠️⚠️ 分页必须用它，**不能**用配置里的 `lineHeightPx`（2026-10-27 真机定案）：
   *   字号放大到 32 时，渲染出来的行框比 `lineHeightFp` 换算值更高
   *   （字体 ascent/descent、StrutStyle 与 ArkUI 的实际行高有微小差异）
   *   ⇒ 按配置值累加会多塞进一行 ⇒ **最后一行溢出到 dock 下面**。
   *   用引擎实测的高度累加，页高才算得准。
   */
  heightPx: number = 0;
  /** 是否**章标题行**（渲染时用大字号 + 加粗；见 `LineStyle.titleFontScale`） */
  isTitle: boolean = false;
}

/** 排行用的排版参数（全部 px） */
export class LineStyle {
  /** 字号（px）—— ⚠️ 必须 `fp2px` 得来，不能 `vp2px` */
  fontSizePx: number = 54;
  /** 行高（px）—— ⚠️ 必须 `fp2px` 得来 */
  lineHeightPx: number = 108;
  /** 段首缩进字数（2） */
  indentSlots: number = 2;
  /** 段间距（px）—— 只在段首行计入 `padTopPx` */
  gapPx: number = 0;
  /** 文本区宽度（px） */
  widthPx: number = 1000;
  /** 可用页高（px）—— 只给 `paginateLines` 用，不参与排版 */
  pageHeightPx: number = 2000;
  /** 字体回退链（逗号分隔，与 ArkUI `fontFamily` 同格式） */
  fontFamily: string = '';
  /** 字重（100..900） */
  fontWeight: number = 400;
  /** 自定义字体文件路径（沙箱绝对路径；空 = 系统字体） */
  fontPath: string = '';
  /**
   * 章标题字号倍数（相对正文字号）。
   * ⚠️ ReaderKit 把 <h1>~<h6> 渲染成大标题；像素实测标题暗像素高约 60px、
   *   正文单行约 50~55px、字宽比约 1.35 ⇒ 先取 1.3，**需要真机对比微调**。
   */
  titleFontScale: number = TITLE_FONT_SCALE;
  /** 正文/标题字距（**px**）—— 见 LETTER_SPACING_FP 注释 */
  letterSpacingPx: number = 0;
  /** 章标题字重（ReaderKit 的标题明显更粗，取 600） */
  titleWeight: number = TITLE_FONT_WEIGHT;
}

/** 一页 = 行索引区间 `[from, to)` */
export class PageSlice {
  from: number = 0;
  to: number = 0;
}

/** 已注册过引擎字体的「族名|路径」（`loadFontSync` 有 IO 代价，必须去重） */
const registeredFonts: Set<string> = new Set<string>();

/**
 * 把 ArkUI 风格的回退链拆成引擎要的 `string[]`。
 * `"HarmonyOS Sans SC, 鸿蒙黑体, HarmonyOS Sans"` → `['HarmonyOS Sans SC','鸿蒙黑体','HarmonyOS Sans']`
 */
function splitFamilies(family: string): string[] {
  const out: string[] = [];
  if (family.length === 0) {
    return out;
  }
  const parts: string[] = family.split(',');
  for (let i = 0; i < parts.length; i++) {
    const s: string = parts[i].trim();
    if (s.length > 0 && out.indexOf(s) < 0) {
      out.push(s);
    }
  }
  return out;
}

/** 数字字重 → 引擎枚举（`W100..W900`） */
function weightToEnum(w: number): text.FontWeight {
  const n: number = Math.max(100, Math.min(900, Math.round(w / 100) * 100));
  switch (n) {
    case 100: return text.FontWeight.W100;
    case 200: return text.FontWeight.W200;
    case 300: return text.FontWeight.W300;
    case 500: return text.FontWeight.W500;
    case 600: return text.FontWeight.W600;
    case 700: return text.FontWeight.W700;
    case 800: return text.FontWeight.W800;
    case 900: return text.FontWeight.W900;
    default: return text.FontWeight.W400;
  }
}

/**
 * 把自定义字体注册进**引擎的** `FontCollection`。
 * ⚠️ 与 ArkUI 侧的字体注册互不相通；不注册的话引擎用默认字体 ⇒ 字宽不同 ⇒ 断行全错。
 */
function ensureEngineFont(family: string, path: string): void {
  if (family.length === 0 || path.length === 0) {
    return;
  }
  const key: string = `${family}|${path}`;
  if (registeredFonts.has(key)) {
    return;
  }
  try {
    const fc: text.FontCollection = text.FontCollection.getGlobalInstance();
    const uri: string = path.startsWith('file://') ? path : `file://${path}`;
    fc.loadFontSync(family, uri);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'loadFontSync failed: %{public}s',
      e instanceof Error ? e.message : JSON.stringify(e));
  }
  registeredFonts.add(key);
}

/** 用引擎排一段文本，返回每一行的度量 */
function layoutLines(src: string, style: LineStyle): text.LineMetrics[] {
  const fc: text.FontCollection = text.FontCollection.getGlobalInstance();
  const families: string[] = splitFamilies(style.fontFamily);
  if (style.fontPath.length > 0 && families.length > 0) {
    ensureEngineFont(families[0], style.fontPath);
  }
  const tStyle: text.TextStyle = {
    fontSize: style.fontSizePx,
    fontFamilies: families,
    fontWeight: weightToEnum(style.fontWeight),
    // ⚠️ 字距（**px**）。必须与渲染端 `Text.letterSpacing(fp)` 严格对应换算，
    //    否则引擎断行与 ArkUI 渲染不一致 ⇒ 溢出/换行错位。
    //    没有它就每行多塞 1 个字 ⇒ 页边界与 ReaderKit 系统性错位（见 LETTER_SPACING_FP 注释）。
    letterSpacing: Math.max(0, style.letterSpacingPx)
  };
  // ⚠️⚠️ 行高只能走 StrutStyle，而且**只给 `height` 不生效**（2026-10-27 真机定案）：
  //   实测 `getLineMetrics().height` 只返回字体自然高度（32px 字 → 95px），
  //   配置的 193.61px 完全被忽略 ⇒ 分页按 95 算会**多塞一倍的行** ⇒ 严重溢出。
  //   必须同时给：
  //     · `enabled: true`        —— 不启用 strut 就完全不生效
  //     · `heightOverride: true` —— 用 height 覆盖字体自然行高
  //     · `forceHeight: true`    —— 每一行都强制用这个高度（含首末行）
  const strut: text.StrutStyle = {
    fontFamilies: families,
    fontSize: style.fontSizePx,
    height: style.lineHeightPx / Math.max(0.1, style.fontSizePx),
    enabled: true,
    heightOverride: true,
    forceHeight: true
  };
  const pStyle: text.ParagraphStyle = {
    textStyle: tStyle,
    // ⚠️ 必须与静止层渲染的 `TextAlign.JUSTIFY` **一致**：
    //    对齐方式不改变断行点（JUSTIFY 是断行后调字距），但保持一致可避免任何歧义
    align: text.TextAlign.JUSTIFY,
    strutStyle: strut
  };
  const b: text.ParagraphBuilder = new text.ParagraphBuilder(pStyle, fc);
  b.pushStyle(tStyle);
  b.addText(src);
  const para: text.Paragraph = b.build();
  para.layoutSync(Math.max(1, style.widthPx));
  return para.getLineMetrics();
}

/** 由正文 style 派生**标题 style**（字号/行高同比放大、字重加粗、不缩进） */
function titleStyleOf(s: LineStyle): LineStyle {
  const t: LineStyle = new LineStyle();
  t.fontSizePx = s.fontSizePx * Math.max(1, s.titleFontScale);
  // ⚠️ 行高必须**同比放大**：只放大字号不放大行高会让标题与下一行文字重叠
  t.lineHeightPx = s.lineHeightPx * Math.max(1, s.titleFontScale);
  // ReaderKit 的章标题是**顶格**的（截图实证），不吃 2 字缩进
  t.indentSlots = 0;
  t.gapPx = s.gapPx;
  t.widthPx = s.widthPx;
  t.pageHeightPx = s.pageHeightPx;
  t.fontFamily = s.fontFamily;
  t.fontWeight = s.titleWeight;
  t.titleFontScale = s.titleFontScale;
  t.titleWeight = s.titleWeight;
  // ⚠️ 标题**不加**正文字距：实测标题宽度已与 ReaderKit 一致（776 vs 775px），
  //    再加字距会超出。标题观感由 `TITLE_FONT_SCALE` 单独控制。
  t.letterSpacingPx = 0;
  // 标题不是自定义字体路径的重点，沿用正文字体
  t.fontPath = s.fontPath;
  return t;
}

/**
 * **候选入口**：把整章的段落数组排成行数组。
 *
 * @param nodes   段落数组（`buildChapterNodes` 的输出；空串段会被跳过但保留段号）
 * @param style   排版参数（全 px）
 * @param isTitle 每段是否章标题（与 `nodes` 等长；缺省 = 全部非标题）。
 *                ⚠️ 标题段会用 `titleStyleOf(style)` 排（大字号 + 加粗、不缩进），
 *                这样行数与 ReaderKit 才接近，两种阅读方式的页边界才对得上。
 */
export function buildEngineLines(nodes: string[], style: LineStyle,
  isTitle?: boolean[]): EngineLine[] {
  const out: EngineLine[] = [];

  for (let i = 0; i < nodes.length; i++) {
    const raw: string = nodes[i];
    if (raw.trim().length === 0) {
      continue;
    }
    const titleSeg: boolean = isTitle !== undefined && i < isTitle.length && isTitle[i];
    // 标题段用标题 style（字号/行高放大、加粗、不缩进）；正文段用原 style
    const segStyle: LineStyle = titleSeg ? titleStyleOf(style) : style;
    const indent: string = segStyle.indentSlots > 0 ? INDENT_CHARS : '';
    const indentLen: number = indent.length;
    // 段首缩进用**真实字符前缀**（不用减宽度排版，那会改变断行）
    const src: string = indent + raw;
    let metrics: text.LineMetrics[] = [];
    try {
      metrics = layoutLines(src, segStyle);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'layout failed para=%{public}d: %{public}s',
        i, e instanceof Error ? e.message : JSON.stringify(e));
    }
    if (metrics.length === 0) {
      // 引擎异常兜底：整段当一行（宁可粗也不丢字）
      const l: EngineLine = new EngineLine();
      l.text = raw;
      l.paraIndex = i;
      l.isParaStart = true;
      l.charFrom = 0;
      l.charTo = raw.length;
      l.padTopPx = segStyle.gapPx;
      l.heightPx = segStyle.lineHeightPx;
      l.isTitle = titleSeg;
      out.push(l);
      continue;
    }
    for (let k = 0; k < metrics.length; k++) {
      const m: text.LineMetrics = metrics[k];
      const a: number = Math.max(0, Math.min(m.startIndex, src.length));
      const z: number = Math.max(a, Math.min(m.endIndex, src.length));
      if (z <= a) {
        continue;
      }
      const line: EngineLine = new EngineLine();
      // ⚠️ 必须**保留**缩进前缀：引擎按含前缀排版，渲染也要显示同样字符
      line.text = src.substring(a, z);
      line.prefixLen = k === 0 ? indentLen : 0;
      line.paraIndex = i;
      line.isParaStart = k === 0;
      // 段内区间**不含前缀**（父页的高亮坐标是按原文段内偏移给的）
      line.charFrom = Math.max(0, a - indentLen);
      line.charTo = Math.max(line.charFrom, z - indentLen);
      line.padTopPx = k === 0 ? segStyle.gapPx : 0;
      // ⚠️ 真实行高（引擎实测），分页按它累加才不会溢出；兜底用配置值
      line.heightPx = m.height > 0 ? m.height : segStyle.lineHeightPx;
      line.isTitle = titleSeg;
      out.push(line);
    }
  }
  return out;
}

/**
 * **精确切页**：按「每行**真实**高度 + 段首额外间距」累加，超过页高就换页。
 *
 * 与旧 `ReaderPager.paginateNodes` 的根本区别：不再用 `ceil(段长/cpl)` 估算行数，
 * 行数与每行高度都是引擎实测 ⇒ 一页能放多少行是**确定的**，不会溢出也不会留白。
 *
 * @param lines          `buildEngineLines` 的输出（每行带 `heightPx`）
 * @param pageHeightPx   可用页高（px）
 * @param lineHeightPx   兜底行高（`heightPx` 缺失时用）
 */
export function paginateLines(lines: EngineLine[], pageHeightPx: number, lineHeightPx: number): PageSlice[] {
  const pages: PageSlice[] = [];
  const pageH: number = Math.max(1, pageHeightPx);
  const fallbackH: number = Math.max(1, lineHeightPx);
  let from: number = 0;
  let used: number = 0;
  for (let i = 0; i < lines.length; i++) {
    const h: number = lines[i].heightPx > 0 ? lines[i].heightPx : fallbackH;
    const cost: number = h + Math.max(0, lines[i].padTopPx);
    // 页首行无条件放（否则段间距过大时会死循环）
    if (used + cost > pageH && i > from) {
      const p: PageSlice = new PageSlice();
      p.from = from;
      p.to = i;
      pages.push(p);
      from = i;
      used = 0;
    }
    used += cost;
  }
  if (from < lines.length) {
    const p: PageSlice = new PageSlice();
    p.from = from;
    p.to = lines.length;
    pages.push(p);
  }
  return pages;
}
