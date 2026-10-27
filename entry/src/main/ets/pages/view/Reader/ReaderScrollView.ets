/**
 * 上下滚动阅读视图（2026-10-20 新增：阅读方式第三档）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么需要自绘这一层
 * ══════════════════════════════════════════════════════════════════════════
 * ReaderKit 的 `ReadPageComponent` 只有两档翻页方式 —— `flipMode`
 * `'0'`=仿真 / `'1'`=横滑（SDK `@hms.core.readerservice.readerComponent.d.ets:169`），
 * `ReaderSetting` 全部 13 个字段里**没有任何**滚动/手势开关，翻页手势整块封装在原生
 * 组件内部，ArkTS 侧既关不掉也接管不了 ⇒ 「上下滑动」不可能由 ReaderKit 提供。
 *
 * 但 ReaderKit **只垄断了排版与栅格化渲染，没有垄断正文**：
 * `bookParser.BookParserHandler.getSpineItemContent(spine)` 能拿到整章原文
 * （TTS 朗读走的就是这条路）。所以这一层用 ArkUI 自己的 `List` 把段落铺出来，
 * 手指上下滑 = 连续滚动，与仿真/横滑并存。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 与「沉浸听读」的关系（复用，不是另起一套）
 * ══════════════════════════════════════════════════════════════════════════
 * 段落模型、字体/字号/行距/字色、段首缩进、句内高亮（`Span` + `textBackgroundStyle`）
 * 全部与 `ReaderPage3.ImmersiveListenLayer()` 同源同参数 —— 差别只有一处：
 * 沉浸层是「整章切成一页一页」，本层是「一段一段连续往下排」。
 * 段间距也不加（引擎的 `ReaderSetting` 根本没有段间距字段），保证两种方式看起来是同一版式。
 *
 * ⚠️ 因此本组件**不碰** TTS 状态机、不碰 ReaderKit 控制器：
 *    · 朗读位置由父页（ReaderPage3）算好，通过 `hlSpine/hlNode/hlFrom/hlTo` 传进来；
 *    · 进度（当前可视首段）通过 `onPos` 回调**上报**给父页，由父页写进全工程唯一的
 *      `(spine, 块节点, 字符)` 坐标 —— 书签/TTS 跟随/双端同步/目录跳转全都照旧。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 列表与虚拟化
 * ══════════════════════════════════════════════════════════════════════════
 * 一章可能有几百上千段，`ForEach` 会一次性建出全部 `Text` ⇒ 必须 `LazyForEach`。
 * 章节按需拼接：
 *   · 滚到底（`onReachEnd`）⇒ 追加下一章；
 *   · 滚到顶（首行 ≤ 2）⇒ 向前补一章，补完把「原来那一行」滚回顶部（`lastStart + 新增行数`），
 *     否则插入到前面的内容会把视口顶到别处；
 *   · 首屏窗口 = 前一章 + 当前章 + 下一章（向上向下都顺滑）。
 *
 * ⚠️ 数据源用本文件内的 `ScrollDataSource`（不走工程的 `BasicDataSource`）：
 * 后者的 `appendData` 是「一条一次通知」，追加一章 300 段就是 300 次队列刷新。
 * 这里用 `onDatasetChange([{type: ADD, index, count}])` **一次批量通知**。
 */

import { bookParser } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { buildChapterNodes } from '../../../tts/ChapterNodes';
import { Haptics } from '../../../common/utils/Haptics';
import { buildEngineLines, EngineLine, LineStyle, TITLE_FONT_SCALE, TITLE_FONT_WEIGHT, LETTER_SPACING_FP } from './EngineLines';

const TAG: string = 'ScrollReader';
const DOMAIN: number = 0x0000;

// ══════════════════════════════════════════════════════════════════════════════
// 版式对齐引擎（2026-10-20 第二版：修"滚动模式字比仿真/横滑更黑"）
// ══════════════════════════════════════════════════════════════════════════════
/**
 * 真机日志取证（`docs/日志.md` 里引擎自己的 `pushConfigTask config=`）：
 * ```
 * {"paragraphSpacing":0.95,"fontSize":32,"lineHeight":1.9,"fontWeight":400,
 *  "fontName":"鸿蒙黑体","fontPath":"/system/fonts/HarmonyOS_Sans_SC.ttf",
 *  "fontFamily":"2","textAlign":2,"fontColor":"#000000","themeColor":"#F2F2F4", …}
 * ```
 * 我们传的 `fontWeight / fontName / fontColor` 与引擎**逐项相同**，所以"更黑"不是
 * 参数传错，而是引擎内部还有两项公开 `ReaderSetting`（13 个字段）里**根本没有**的版式参数：
 *
 *  · `paragraphSpacing: 0.95` —— **段落间距**。分页模式的段与段之间有近一行的空隙；
 *    滚动层第一版把 padding 设成 0（当时的理由写的是"引擎没有段间距字段"，
 *    那只对**公开 API** 成立，对引擎**内部 config** 不成立）⇒ 段落全顶在一起，
 *    整块文字比引擎密得多，肉眼就是"更黑、更挤"。
 *  · `textAlign: 2` —— **两端对齐**。左对齐时每段右边缘参差，段落边界更难分辨，
 *    进一步加重"糊成一片"的观感。
 *
 * ⇒ 本版两项都补上。间距用 em（= 字号倍数）表达，随字号自动缩放；
 *   取值按引擎的 0.95 折算：`paragraphSpacing` 是相对**行高**的倍数，
 *   而我们的行高已经是 1.9 倍字号，故等效 em = 0.95 × 0.5 ≈ 0.48，取 **0.45**。
 *
 * 🔧 唯一可调项：真机若仍觉得比引擎紧就把 `SCROLL_PARA_GAP_EM` 调大，
 *    觉得太松就调小；设成 `0` 即完全关掉段间距（回到第一版的行为）。
 *
 * ⚠️ 2026-10-26：本常量已 **export**。理由：「无动画」档（`ReaderPageNoAnim`）
 *    与上下滚动是"一母同胞"，必须用**同一个段间距系数**，否则两档互切时
 *    段落疏密会变。导出后两处引用同一个值，改一次两边同时生效。
 */
export const SCROLL_PARA_GAP_EM: number = 0.95;
/**
 * 字重微调（0 = 原样使用 `readerSetting.fontWeight`）。
 *
 * 留这个开关的原因：即使段落间距/对齐都对齐了，**原生文本与引擎栅格化纹理**在
 * 同一名义字重下的观感仍可能有细微差别（引擎把整页排成纹理再贴出来，ArkUI 是
 * 直接画字形，后者通常更锐利、看起来略重）。真机若仍觉得偏黑，把它设成 `-100`
 * （400 → 300 = Light）即可；设成 `100` 则更重。**不要**用它去补段落间距的差 ——
 * 那是两件事，先把 `SCROLL_PARA_GAP_EM` 调好再动这里。
 */
/**
 * 字重补偿（**由父页按当前字体决定**后传进来，不再写死在这里）。
 *
 * ── 2026-10-23 真机定案 ────────────────────────────────────────────────────
 * `HarmonyOS Sans SC` 是**可变字体（Variable Font）**：
 *   · 引擎（ReaderKit）加载该 ttf 时**不指定 wght 轴** ⇒ 用文件**默认实例**；
 *   · ArkUI 收到 `fontWeight(400)` 会**显式取 wght=400 实例**。
 * 两者差一档 ⇒ 真机把补偿设成 `-100`（400→300）后，**与仿真/横滑完全一致**。
 *
 * ⚠️ 但这个补偿**只对系统中文黑体成立**，不能全局写死：
 *   自定义字体（书宋-简 `ShuS-SC.ttf`、用户导入的字体）大多是**单一字重**，
 *   减一档要么被 ArkUI 忽略、要么触发合成变细 ⇒ 反而弄坏自定义字体。
 * ⇒ 父页只在对 `HarmonyOS Sans SC` 时传 `-100`，其余字体传 `0`（保持引擎原值）。
 */
const SCROLL_FONT_WEIGHT_STEP: number = 100;

/** 段落间距（fp）= 字号 × em */
function scrollParaGapFp(fontSize: number): number {
  return fontSize * SCROLL_PARA_GAP_EM;
}

/**
 * 实际字重 = 引擎值 + 父页给的补偿，夹到 ArkUI 合法区间 [100, 900]，
 * 并对齐到 100 的整数倍（ArkUI 对非 100 整数倍的数值会静默忽略）。
 *
 * ⚠️ 2026-10-26：**export** 给「无动画」层（`ReaderPageNoAnim`）复用 ——
 *    两档必须算出同一个字重，否则互切时字会突然变粗/变细。
 */
export function scrollFontWeight(base: number, offset: number): number {
  const v: number = base + offset;
  const clamped: number = v < SCROLL_FONT_WEIGHT_STEP ? SCROLL_FONT_WEIGHT_STEP
    : (v > 900 ? 900 : v);
  return Math.round(clamped / SCROLL_FONT_WEIGHT_STEP) * SCROLL_FONT_WEIGHT_STEP;
}



/**
 * 列表里的一行 = **引擎排好的一行**（2026-10-27 换血）。
 *
 * ⚠️ 原来是"一个块节点（段）"，靠 ArkUI 自己换行；现在与「无动画」档共用
 *    `EngineLines.buildEngineLines()` 的同一份行数据 ⇒ **两档互切逐字一致**。
 *    `node` 仍是 ReaderKit 坐标系的块节点号（= `EngineLine.paraIndex`），
 *    所以书签/进度/朗读的坐标语义不变。
 */
export class ScrollRow {
  /** 正文号（= ReaderKit 的 spine） */
  spine: number;
  /** 块节点号（= `EngineLine.paraIndex`；-1 保留给章节标题行） */
  node: number;
  /** 渲染文本（**段首行含 2 个全角空格的缩进前缀**，与引擎排版完全一致） */
  text: string;
  /** LazyForEach 的稳定键 */
  key: string;
  /** 段内起始字符（不含缩进前缀）—— 高亮定位用 */
  charFrom: number = 0;
  /** 段内结束字符（不含缩进前缀） */
  charTo: number = 0;
  /** 缩进前缀字符数（段首行 = 2，其余 = 0） */
  prefixLen: number = 0;
  /** 是否段首行（渲染时顶部加段间距） */
  isParaStart: boolean = false;
  /** 是否章标题行（渲染时大字号 + 加粗） */
  isTitle: boolean = false;

  constructor(spine: number, node: number, text: string, charFrom: number, charTo: number,
    prefixLen: number, isParaStart: boolean, isTitle: boolean = false) {
    this.spine = spine;
    this.node = node;
    this.text = text;
    this.charFrom = charFrom;
    this.charTo = charTo;
    this.prefixLen = prefixLen;
    this.isParaStart = isParaStart;
    this.isTitle = isTitle;
    // ⚠️ 键必须区分**同一段的多行**：只拼 node 会让同段第 2 行起全部撞键
    this.key = `p-${spine}-${node}-${charFrom}`;
  }
}

/**
 * 极简数据源：只为「整章批量追加/前插」服务。
 * 批量 `ADD` 通知的语义见官方《LazyForEach：数据懒加载》：
 * 「进行批量的数据处理后，调用 `onDatasetChange` 接口通知组件按照 dataOperations 刷新组件」。
 */
class ScrollDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private rows: ScrollRow[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): ScrollRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  /** 全量替换（换书 / 换窗口） */
  reset(rows: ScrollRow[]): void {
    this.rows = rows;
    this.listeners.forEach((l: DataChangeListener): void => {
      l.onDatasetChange([{ type: DataOperationType.RELOAD }]);
    });
  }

  /** 尾部追加一章 */
  append(rows: ScrollRow[]): void {
    if (rows.length === 0) {
      return;
    }
    const at: number = this.rows.length;
    for (const r of rows) {
      this.rows.push(r);
    }
    this.listeners.forEach((l: DataChangeListener): void => {
      l.onDatasetChange([{ type: DataOperationType.ADD, index: at, count: rows.length }]);
    });
  }

  /** 头部前插一章 */
  prepend(rows: ScrollRow[]): void {
    if (rows.length === 0) {
      return;
    }
    const next: ScrollRow[] = [];
    for (const r of rows) {
      next.push(r);
    }
    for (const r of this.rows) {
      next.push(r);
    }
    this.rows = next;
    this.listeners.forEach((l: DataChangeListener): void => {
      l.onDatasetChange([{ type: DataOperationType.ADD, index: 0, count: rows.length }]);
    });
  }
}

/**
 * 上下滚动阅读视图。
 *
 * ⚠️ 所有 `@Prop` 都是**父页状态**的投影：父页改状态 ⇒ 这里自动刷新，
 *    本组件内部只持有「已加载了哪几章」「可视区是哪几行」这类自洽状态。
 */
@Component
export struct ReaderScrollView {
  // ── 排版参数（与 ReaderKit / 沉浸听读层同源）──────────────────────────────
  @Prop fontName: string = '鸿蒙黑体';
  /** 自定义字体文件路径（沙箱绝对路径；'' = 系统字体）—— 引擎排行要用 */
  @Prop fontPath: string = '';
  @Prop fontSize: number = 18;
  @Prop fontWeight: number = 400;
  @Prop fontColor: string = '#000000';
  /** 行高（fp）：= readerSetting.lineHeight × fontSize × effectiveLineMul() */
  @Prop lineHeightFp: number = 34;
  /** 段首缩进（fp）：= fontSize × 2（与引擎/沉浸层一致的 2 字位） */
  @Prop indentFp: number = 36;
  /** 背景纯色（= readerSetting.themeColor） */
  @Prop bgColor: string = '#FFFFFF';
  /** 背景图 URI（'' = 纯色；沙箱路径已在父页转成 file:// URI） */
  @Prop bgUri: string = '';
  /** 文本区左边距（vp）—— 左右各一份 ⇒ 中间正好是文本宽度 */
  @Prop sideInsetVp: number = 20;
  /** 顶部避让（vp）：状态栏 / 顶栏 */
  @Prop topInsetVp: number = 0;
  /** 底部避让（vp）：底部页签条 */
  @Prop bottomInsetVp: number = 0;

  // ── 初始位置：`initSerial` 变化 = 重新载入窗口（进书 / 从分页切过来）──────
  @Prop initSpine: number = 0;
  @Prop initNode: number = 0;
  /** 初始化时的段内字符偏移（切档交接；与 initNode 配套，见 indexOfNode 注释） */
  @Prop initChar: number = 0;
  @Prop @Watch('onInitSerialChange') initSerial: number = 0;

  // ── 定位请求（TTS 跟随 / 目录 / 书签 / 沉浸层交接）───────────────────────
  @Prop seekSpine: number = 0;
  @Prop seekNode: number = 0;
  /** 段内字符偏移（与 seekNode 组成精确锚点；2026-10-27 增，与无动画档同签名） */
  @Prop seekChar: number = 0;
  @Prop @Watch('onSeekSerialChange') seekSerial: number = 0;

  // ── 翻一屏请求（音量键翻页）──────────────────────────────────────────────
  @Prop pageDir: number = 1;
  @Prop @Watch('onPageReqChange') pageReq: number = 0;

  // ── 朗读高亮（父页从 TtsEngine 算好再传，本层不碰引擎）──────────────────
  @Prop hlSpine: number = -1;
  @Prop hlNode: number = -1;
  @Prop hlFrom: number = -1;
  @Prop hlTo: number = -1;
  @Prop hlSerial: number = 0;

  /**
   * 字体就绪代数（2026-10-20 新增，修「滚动模式自定义字体失效 / 比其它模式更黑」）。
   *
   * 背景：ArkUI 的自定义字体由 `ReaderFontLib.ensureRegistered` **异步注册**
   * （`Font.registerFont` 返回 void、无完成回调），注册完成前 `.fontFamily(name)`
   * 解析不到该族名 ⇒ 回落系统默认字形。而 `Text` 的 `fontFamily` 参数一旦定下来
   * 就不会自己重排 ⇒ 字体永久停在默认字形。
   * ⇒ 父页在注册完成后自增这个代数，本层把它拼进 `LazyForEach` 的行键，
   *   可见行因此被重建一次，新字形才真正落到屏幕上。
   */
  @Prop fontSerial: number = 0;

  /**
   * 字重补偿（父页按当前字体算好传入）：系统中文黑体传 `-100`，其余传 `0`。
   * 完整理由见文件头 `SCROLL_FONT_WEIGHT_STEP` 注释（可变字体默认实例 vs wght 实例）。
   */
  @Prop weightOffset: number = 0;

  // ── 回调（构造时绑定，之后不变）──────────────────────────────────────────
  /** 取解析器（父页的 BookHandler；用闭包读，避免构造时还是 null） */
  handlerProvider: () => bookParser.BookParserHandler | null = () => null;
  /** 正文总章数（spine 数） */
  spineCountProvider: () => number = () => 0;
  /** 可视区首段/末段变化 ⇒ 父页写进度（节流由父页做）；含字符偏移供「从本页开始读」精确定位 */
  onPos: (spine: number, node: number, endNode: number, startChar: number, endChar: number) => void =
    (spine: number, node: number, endNode: number, startChar: number, endChar: number) => {};
  /** 轻点正文 ⇒ 父页拉起菜单 */
  onTap: () => void = () => {};
  /** 首屏文本已上屏 ⇒ 父页撤掉「正在排版…」占位 */
  onReady: () => void = () => {};

  // ── 内部状态 ─────────────────────────────────────────────────────────────
  private scroller: Scroller = new Scroller();
  private ds: ScrollDataSource = new ScrollDataSource();
  /** 已加载的章号区间（闭区间；-1 = 还没加载） */
  private loadedFirst: number = -1;
  private loadedLast: number = -1;
  /** 载入中标记（防重入：滚动回调会连续触发） */
  private loadingTop: boolean = false;
  private loadingBottom: boolean = false;
  /** spine → 该章首行在**全局**数据里的下标 */
  private chapStart: Map<number, number> = new Map<number, number>();
  /** spine → 该章「块节点号 → 章内行号」（-1 = 该节点不渲染，例如空行） */
  private chapRow: Map<number, number[]> = new Map<number, number[]>();
  /** 最近一次可视区行下标 */
  private lastStart: number = 0;
  private lastEnd: number = 0;
  /**
   * 首屏还没就绪时到来的定位请求（-1 = 无）。
   *
   * ⚠️ 为什么必须暂存而不是丢弃：进书时听书已经在播（桌面快捷方式「快速听书」）或
   *    TTS 自动跟随，都会在 `aboutToAppear` 的异步载入**还没完成**时就发 `seekSerial`。
   *    那时 `ready === false`、`chapStart` 还是空的 ⇒ 直接算下标会得到 -1 而静默丢请求，
   *    表现为"进书后页面停在开头、不跟朗读处"。暂存后在 `rebuildWindow` 末尾补做一次。
   */
  private pendingSeekSpine: number = -1;
  private pendingSeekNode: number = 0;

  @State ready: boolean = false;
  /** 首屏定位下标（只在 List **创建**时生效） */
  @State initialIndex: number = 0;
  /** 加载失败提示（非空则显示） */
  @State errText: string = '';

  aboutToAppear(): void {
    this.rebuildWindow(this.initSpine, this.initNode, true);
  }

  aboutToDisappear(): void {
    this.ds.reset([]);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 章节加载
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 读一章 → 行数组。
   *
   * 用的是 `buildChapterNodes()`（**不是** TtsEngine.previewNodeTexts）：后者只有
   * 一个槽位的缓存，连续读三章会互相挤掉；这里直接按同一套规则建节点，
   * 保证 `node` 与 ReaderKit 的块节点号严格同源（书签/进度/朗读全靠这个一致性）。
   *
   * 空行节点**占号但不渲染** —— 与 ReaderKit 的行为一致（空块不显示），
   * 同时保证节点号不因跳过而错位。
   */
  private async loadChapter(spine: number): Promise<ScrollRow[]> {
    const handler: bookParser.BookParserHandler | null = this.handlerProvider();
    if (handler === null || spine < 0) {
      return [];
    }
    try {
      const content: string = await handler.getSpineItemContent(spine);
      // ⚠️ txt 没有标签，标题靠目录名反推（与无动画档同一策略）
      const cn = buildChapterNodes(content, this.chapterTitleOf(handler, spine));
      const nodes: string[] = cn.nodes;
      // ⚠️ **引擎排行**：与「无动画」档共用 `EngineLines`（同一份行数据）⇒ 两档互切逐字一致。
      //    原来这里是把"段"直接当行交给 ArkUI 自己换行，与无动画档的切页结果对不上。
      const style: LineStyle = this.buildLineStyle();
      const lines: EngineLine[] = buildEngineLines(nodes, style, cn.isTitle);
      const rows: ScrollRow[] = [];
      // 块节点号 → 该节点首行在 `rows` 里的下标（定位/上报仍按节点号）
      const map: number[] = [];
      for (let i = 0; i < nodes.length; i++) {
        map.push(-1);
      }
      for (let k = 0; k < lines.length; k++) {
        const ln: EngineLine = lines[k];
        if (ln.paraIndex >= 0 && ln.paraIndex < map.length && map[ln.paraIndex] < 0) {
          map[ln.paraIndex] = rows.length;
        }
        rows.push(new ScrollRow(spine, ln.paraIndex, ln.text, ln.charFrom, ln.charTo,
          ln.prefixLen, ln.isParaStart, ln.isTitle));
      }
      this.chapRow.set(spine, map);
      hilog.info(DOMAIN, TAG, 'loadChapter(engine) spine=%{public}d nodes=%{public}d lines=%{public}d',
        spine, nodes.length, rows.length);
      return rows;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loadChapter %{public}d failed: %{public}s',
        spine, e instanceof Error ? e.message : String(e));
      return [];
    }
  }

  /** fp → px（字号/行高/缩进都是 fp） */
  private fp2px(v: number): number {
    return this.getUIContext().fp2px(v);
  }

  /** vp → px（文本区宽高实测是 vp） */
  private vp2px(v: number): number {
    return this.getUIContext().vp2px(v);
  }

  /**
   * 取「本章在目录里的名字」—— 用于识别 **TXT 的章标题段**。
   * 与 `ReaderPageNoAnim.chapterTitleOf()` 同一策略：txt 返回纯文本、无标签，
   * 只能借 ReaderKit 已经识别好的目录名反查章首段。
   */
  private chapterTitleOf(handler: bookParser.BookParserHandler, spine: number): string {
    try {
      const list: bookParser.CatalogItem[] = handler.getCatalogList();
      if (list === null || list === undefined || spine < 0 || spine >= list.length) {
        return '';
      }
      const name: string = list[spine].catalogName;
      return name !== undefined && name !== null ? name : '';
    } catch (e) {
      return '';
    }
  }

  /** 组出引擎排行参数（**全 px**；与 `ReaderPageNoAnim.buildLineStyle()` 同口径） */
  private buildLineStyle(): LineStyle {
    const s: LineStyle = new LineStyle();
    s.fontSizePx = this.fp2px(this.fontSize);
    s.lineHeightPx = this.fp2px(this.lineHeightFp);
    s.indentSlots = 2;
    s.gapPx = this.fp2px(scrollParaGapFp(this.fontSize));
    s.letterSpacingPx = this.fp2px(LETTER_SPACING_FP);
    // 流式不需要切页：宽度 = 屏幕宽(px) − 左右 inset(px)，与渲染宽度一致即可保证断行准确
    const screenPx: number = display.getDefaultDisplaySync().width;
    s.widthPx = Math.max(1, screenPx - 2 * this.vp2px(this.sideInsetVp));
    s.pageHeightPx = 1e9; // 流式不用切页，给个大值避免误用
    s.fontFamily = this.fontName;
    s.fontWeight = scrollFontWeight(this.fontWeight, this.weightOffset);
    s.fontPath = this.fontPath;
    return s;
  }

  /** 重建窗口：以 `spine` 为中心装 [spine-1 .. spine+1]，并定位到 `node` */
  private async rebuildWindow(spine: number, node: number, first: boolean): Promise<void> {
    const total: number = this.spineCountProvider();
    const target: number = Math.max(0, total > 0 ? Math.min(spine, total - 1) : spine);
    const from: number = Math.max(0, target - 1);
    const to: number = Math.min(total > 0 ? total - 1 : target, target + 1);
    hilog.info(DOMAIN, TAG, 'rebuildWindow spine=%{public}d node=%{public}d window=%{public}d..%{public}d',
      target, node, from, to);

    this.chapStart.clear();
    this.chapRow.clear();
    const rows: ScrollRow[] = [];
    for (let s = from; s <= to; s++) {
      const part: ScrollRow[] = await this.loadChapter(s);
      if (part.length === 0) {
        continue;
      }
      this.chapStart.set(s, rows.length);
      for (const r of part) {
        rows.push(r);
      }
    }
    this.loadedFirst = from;
    this.loadedLast = to;
    this.errText = rows.length === 0 ? '这一章没有可显示的正文' : '';

    const idx: number = this.indexOfNode(target, node);
    const at: number = idx >= 0 ? idx : 0;
    if (first) {
      // 首屏：交给 List 的 initialIndex（只在创建时生效），再置 ready 触发创建
      this.initialIndex = at;
      this.lastStart = at;
      this.lastEnd = at;
      this.ds.reset(rows);
      this.ready = true;
      this.onReady();
      this.reportAt(at, at);
      // 首屏期间被暂存的定位请求：现在窗口有了，补做一次
      if (this.pendingSeekSpine >= 0) {
        const ps: number = this.pendingSeekSpine;
        const pn: number = this.pendingSeekNode;
        this.pendingSeekSpine = -1;
        const i2: number = this.indexOfNode(ps, pn);
        if (i2 >= 0) {
          this.scrollToIndex(i2);
          this.lastStart = i2;
          this.reportAt(i2, i2);
        }
      }
    } else {
      this.ds.reset(rows);
      this.scrollToIndex(at);
      this.lastStart = at;
      this.lastEnd = at;
      this.reportAt(at, at);
    }
  }

  /** 尾部追加下一章（滚到底触发） */
  private async appendNext(): Promise<void> {
    if (this.loadingBottom || this.loadingTop) {
      return;
    }
    const total: number = this.spineCountProvider();
    const next: number = this.loadedLast + 1;
    if (total > 0 && next >= total) {
      return;
    }
    this.loadingBottom = true;
    const rows: ScrollRow[] = await this.loadChapter(next);
    this.loadingBottom = false;
    this.loadedLast = next;
    if (rows.length === 0) {
      return;
    }
    this.chapStart.set(next, this.ds.totalCount());
    this.ds.append(rows);
    hilog.info(DOMAIN, TAG, 'appendNext spine=%{public}d rows=%{public}d total=%{public}d',
      next, rows.length, this.ds.totalCount());
  }

  /**
   * 头部前插上一章（滚到顶触发）。
   *
   * ⚠️ 前插后**必须把原来那一行滚回顶部**：否则新内容把视口顶到别处，
   *    用户会看到「上滑一下整段文字跳走」。锚点用 `lastStart + 新增行数`，
   *    这是精确的（前插只增加下标偏移，不改顺序）。
   */
  private async prependPrev(): Promise<void> {
    if (this.loadingTop || this.loadingBottom) {
      return;
    }
    const prev: number = this.loadedFirst - 1;
    if (prev < 0) {
      return;
    }
    this.loadingTop = true;
    const anchor: number = this.lastStart;
    const rows: ScrollRow[] = await this.loadChapter(prev);
    this.loadingTop = false;
    this.loadedFirst = prev;
    if (rows.length === 0) {
      return;
    }
    // 已有的章首下标整体后移
    const shift: number = rows.length;
    const keys: number[] = [];
    this.chapStart.forEach((_v: number, k: number): void => {
      keys.push(k);
    });
    for (const k of keys) {
      const v: number | undefined = this.chapStart.get(k);
      if (v !== undefined) {
        this.chapStart.set(k, v + shift);
      }
    }
    this.chapStart.set(prev, 0);
    this.ds.prepend(rows);
    hilog.info(DOMAIN, TAG, 'prependPrev spine=%{public}d rows=%{public}d anchor=%{public}d',
      prev, rows.length, anchor);
    this.scrollToIndex(anchor + shift);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 下标换算 / 滚动定位
  // ══════════════════════════════════════════════════════════════════════════

  /** (spine, 块节点号) → 全局行下标（-1 = 不在已加载窗口内） */
  private indexOfNode(spine: number, node: number): number {
    const base: number | undefined = this.chapStart.get(spine);
    const map: number[] | undefined = this.chapRow.get(spine);
    if (base === undefined || map === undefined) {
      return -1;
    }
    if (node <= 0 || node >= map.length) {
      return base;
    }
    const local: number = map[node];
    if (local < 0) {
      // 空行/未渲染节点 ⇒ 退到该章首行（宁可粗略也不跳空）
      return base;
    }
    return base + local;
  }

  private scrollToIndex(index: number): void {
    if (index < 0) {
      return;
    }
    // 下一帧再滚：数据源刚变过，List 还没按新数据完成布局
    setTimeout((): void => {
      try {
        this.scroller.scrollToIndex(index, false, ScrollAlign.START);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'scrollToIndex %{public}d failed', index);
      }
    }, 0);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 可视区上报
  // ══════════════════════════════════════════════════════════════════════════

  private onScrollIndexChange(start: number, end: number): void {
    this.lastStart = start;
    this.lastEnd = end;
    this.reportAt(start, end);
    // 到底 ⇒ 拼下一章；到顶 ⇒ 补上一章（阈值留几行，避免"滚到头才加载"的空白）
    if (end >= this.ds.totalCount() - 3) {
      this.appendNext();
    }
    if (start <= 2 && this.loadedFirst > 0) {
      this.prependPrev();
    }
  }

  private reportPos(): void {
    this.reportAt(this.lastStart, this.lastEnd);
  }

  private reportAt(start: number, end: number): void {
    const total: number = this.ds.totalCount();
    if (start < 0 || start >= total) {
      return;
    }
    const a: ScrollRow = this.ds.getData(start);
    const e: number = Math.max(start, Math.min(end, total - 1));
    const b: ScrollRow = this.ds.getData(e);
    this.onPos(a.spine, a.node, b.spine === a.spine ? b.node : a.node, a.charFrom, b.charTo);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 父页驱动的变更
  // ══════════════════════════════════════════════════════════════════════════

  onInitSerialChange(): void {
    this.ready = false;
    this.rebuildWindow(this.initSpine, this.initNode, true);
  }

  onSeekSerialChange(): void {
    const spine: number = this.seekSpine;
    const node: number = this.seekNode;
    // 首屏还没载入完 ⇒ 暂存，等 `rebuildWindow` 末尾补做（见 pendingSeek* 注释）
    if (!this.ready) {
      this.pendingSeekSpine = spine;
      this.pendingSeekNode = node;
      return;
    }
    if (spine < this.loadedFirst || spine > this.loadedLast) {
      this.rebuildWindow(spine, node, false);
      return;
    }
    const idx: number = this.indexOfNode(spine, node);
    if (idx >= 0) {
      this.scrollToIndex(idx);
      this.lastStart = idx;
      this.reportAt(idx, idx);
    }
  }

  /** 翻一屏（音量键）：按当前可视行数滚动 */
  onPageReqChange(): void {
    const span: number = Math.max(1, this.lastEnd - this.lastStart);
    const dir: number = this.pageDir >= 0 ? 1 : -1;
    const from: number = dir > 0 ? this.lastEnd : this.lastStart;
    const total: number = this.ds.totalCount();
    const target: number = Math.max(0, Math.min(total - 1, from + dir * span));
    try {
      this.scroller.scrollToIndex(target, true, ScrollAlign.START);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'page scroll failed');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 行键：**高亮那一行**把句序号拼进键里，逼 LazyForEach 重建它 —— 否则 ArkUI
   * 会复用旧组件、高亮不移动。这是沉浸听读层已经验证过的写法（同款注释见
   * `ReaderPage3.ImmersiveListenLayer()`）。
   *
   * 2026-10-20：所有行键再拼上 `fontSerial` —— 字体异步注册完成后代数 +1，
   * 可见行整体重建一次，`.fontFamily(name)` 才能用上刚注册好的族名
   * （否则原生 Text 参数不变就不重排，字体永久停在系统默认字形）。
   * 只在换字体/开书注册完成时发生一次，无性能顾虑。
   */
  /** 该行是否落在朗读高亮区间内（区间交集；换血后行是段内的一段，必须比 `charTo`） */
  private isHlRow(row: ScrollRow): boolean {
    if (this.hlFrom < 0 || row.spine !== this.hlSpine || row.node !== this.hlNode) {
      return false;
    }
    return Math.max(row.charFrom, this.hlFrom) < Math.min(row.charTo, this.hlTo);
  }

  /** 行内高亮起点（`+ prefixLen`：段首行含 2 个全角空格缩进前缀） */
  private hlRelFrom(row: ScrollRow): number {
    const v: number = this.hlFrom - row.charFrom + row.prefixLen;
    return Math.max(0, Math.min(v, row.text.length));
  }

  /** 行内高亮终点 */
  private hlRelTo(row: ScrollRow): number {
    const v: number = this.hlTo - row.charFrom + row.prefixLen;
    const from: number = this.hlRelFrom(row);
    return Math.max(from, Math.min(v, row.text.length));
  }

  /** 段首行的顶部间距（vp）—— 与 `EngineLines.gapPx` 同口径 */
  private rowPadVp(row: ScrollRow): number {
    return row.isParaStart ? scrollParaGapFp(this.fontSize) : 0;
  }

  private rowKey(row: ScrollRow): string {
    const base: string = `${row.key}-f${this.fontSerial}`;
    if (this.isHlRow(row)) {
      return `${base}-h${this.hlSerial}`;
    }
    return base;
  }

  /** 标题行字号（fp）= 正文字号 × TITLE_FONT_SCALE（与 EngineLines 算行高同一个值） */
  private titleFontSizeFp(): number {
    return this.fontSize * TITLE_FONT_SCALE;
  }

  /** 标题行行高（fp）= 正文行高 × TITLE_FONT_SCALE（同比放大，否则与下行重叠） */
  private titleLineHeightFp(): number {
    return this.lineHeightFp * TITLE_FONT_SCALE;
  }

  @Builder
  RowView(row: ScrollRow) {
    if (row.isTitle) {
      // ── 章标题：大字号 + 加粗、顶格（对齐 ReaderKit 的 h1 观感与行数）────────
      Text(row.text)
        .fontSize(this.titleFontSizeFp())
        .fontWeight(TITLE_FONT_WEIGHT)
        .fontFamily(this.fontName)
        .fontColor(this.fontColor)
        .lineHeight(this.titleLineHeightFp())
        .textAlign(TextAlign.Start)
        .width('100%')
        .padding({ top: this.rowPadVp(row) })
    } else if (this.isHlRow(row)) {
      Text() {
        Span(row.text.substring(0, this.hlRelFrom(row)))
        Span(row.text.substring(this.hlRelFrom(row), this.hlRelTo(row)))
          .textBackgroundStyle({ color: 'rgba(0, 125, 255, 0.20)', radius: 4 })
        Span(row.text.substring(this.hlRelTo(row)))
      }
      .fontSize(this.fontSize)
      .fontWeight(scrollFontWeight(this.fontWeight, this.weightOffset))
      .fontFamily(this.fontName)
      .fontColor(this.fontColor)
      .lineHeight(this.lineHeightFp)
          .letterSpacing(LETTER_SPACING_FP)
      // ⚠️ **不要 textIndent**：缩进已经由引擎排进行文本的前缀里，
      //    再缩一次会让首行少 2 个字位 ⇒ 与无动画档版式对不上。
      .textAlign(TextAlign.JUSTIFY)
      .width('100%')
      .padding({ top: this.rowPadVp(row) })
    } else {
      Text(row.text)
        .fontSize(this.fontSize)
        .fontWeight(scrollFontWeight(this.fontWeight, this.weightOffset))
        .fontFamily(this.fontName)
        .fontColor(this.fontColor)
        .lineHeight(this.lineHeightFp)
          .letterSpacing(LETTER_SPACING_FP)
        .textAlign(TextAlign.JUSTIFY)
        .width('100%')
        .padding({ top: this.rowPadVp(row) })
    }
  }

  build() {
    Stack() {
      // 背景：纯色打底 + 可选背景图（材质图 / 自定义图）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.bgColor)
      if (this.bgUri.length > 0) {
        Image(this.bgUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
      }

      if (this.errText.length > 0) {
        Column() {
          Text(this.errText)
            .fontSize(14)
            .fontColor(this.fontColor)
            .opacity(0.7)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.ready) {
        List({ scroller: this.scroller, initialIndex: this.initialIndex }) {
          LazyForEach(this.ds, (row: ScrollRow): void => {
            ListItem() {
              this.RowView(row)
            }
          }, (row: ScrollRow): string => this.rowKey(row))
        }
        .width('100%')
        .height('100%')
        // 文本区左右留白：左右各一份 ⇒ 中间正好是 ReaderKit 的文本宽度
        .padding({
          left: this.sideInsetVp,
          right: this.sideInsetVp,
          top: this.topInsetVp,
          bottom: this.bottomInsetVp
        })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
        .onScrollIndex((start: number, end: number): void => {
          this.onScrollIndexChange(start, end);
        })
        .onReachEnd((): void => {
          this.appendNext();
        })
        .onScrollStop((): void => {
          this.reportPos();
        })
      } else {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.fontColor)
          Text('正在载入正文…')
            .fontSize(13)
            .fontColor(this.fontColor)
            .opacity(0.7)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .onClick((): void => {
      Haptics.tap();
      this.onTap();
    })
  }
}
