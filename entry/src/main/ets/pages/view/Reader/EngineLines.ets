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
    fontWeight: weightToEnum(style.fontWeight)
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

/**
 * **候选入口**：把整章的段落数组排成行数组。
 *
 * @param nodes 段落数组（`buildChapterNodes` 的输出；空串段会被跳过但保留段号）
 * @param style 排版参数（全 px）
 */
export function buildEngineLines(nodes: string[], style: LineStyle): EngineLine[] {
  const out: EngineLine[] = [];
  const indent: string = style.indentSlots > 0 ? INDENT_CHARS : '';
  const indentLen: number = indent.length;

  for (let i = 0; i < nodes.length; i++) {
    const raw: string = nodes[i];
    if (raw.trim().length === 0) {
      continue;
    }
    // 段首缩进用**真实字符前缀**（不用减宽度排版，那会改变断行）
    const src: string = indent + raw;
    let metrics: text.LineMetrics[] = [];
    try {
      metrics = layoutLines(src, style);
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
      l.padTopPx = style.gapPx;
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
      line.padTopPx = k === 0 ? style.gapPx : 0;
      // ⚠️ 真实行高（引擎实测），分页按它累加才不会溢出；兜底用配置值
      line.heightPx = m.height > 0 ? m.height : style.lineHeightPx;
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
