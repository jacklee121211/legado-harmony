/**
 * 无动画阅读视图（2026-10-26 新增：阅读方式第四档）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 它是什么 / 它不是什么
 * ══════════════════════════════════════════════════════════════════════════
 * **是**：「上下滚动」那张连续行流，按页容量切成固定页，手动翻页。
 * **不是**：ReaderKit 的第三种 `flipMode` —— 那不存在。
 *   SDK `@hms.core.readerservice.readerComponent.d.ets:169` 原文只有
 *   `flipMode: string;`（无枚举、无注释），`ReaderSetting` 全文 13 个字段
 *   （`:69-200`）无任何"动画开关/时长"字段；
 *   官方文档 documentId
 *   `…/修改阅读设置/修改翻页方式_字体大小及行间距/reader-setting-other` 原文
 *   「0代表仿真翻页，1代表横滑翻页」⇒ **只有两档，没有"无动画"**。
 *   所以只能自绘 —— 与 `READ_MODE_SCROLL`（上下滚动）完全同级的做法。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 「无动画」怎么保证真的没有动画
 * ══════════════════════════════════════════════════════════════════════════
 * 翻页 = **改一个整数 `pageIdx`**，让 ArkUI 重建这一页的节点。
 * 全文件**没有** `animateTo` / `transition` / 滚动容器 / 跟手位移 / 补间 ——
 * 所以不是"把动画时长调成 0"（那种做法仍受系统曲线与合成器影响），
 * 而是**物理上没有动画可播**。这正是用户要的语义：「完全不需要任何动画」。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 与「上下滚动」同源（用户 2026-10-26：「他和上下应该属于一母同胞」）
 * ══════════════════════════════════════════════════════════════════════════
 * · 段落模型：`buildChapterNodes()`（与 ReaderKit 块节点 1:1）—— 同 `ReaderScrollView`；
 * · 版式参数：字号/行高/缩进/字色/字重补偿/字体族名/背景 —— 由父页**同一批方法**
 *   （`scrollLineHeightFp()` / `scrollIndentFp()` / `scrollFontFamily()` /
 *   `scrollWeightOffset()` / `scrollTopInsetVp()` / `scrollBottomInsetVp()`）算好传入，
 *   与滚动层逐项相同 ⇒ 互切时版式不跳；
 * · 段间距：`gapEm` 与 `ReaderScrollView.SCROLL_PARA_GAP_EM` 同一个 **0.45**，
 *   且**同时参与分页计价**（`gapLines`）与**渲染**（`padding.top`）——
 *   两头一致才不会出现"切模式段落忽然变密"；
 * · 分页算法：`ReaderPager.paginateNodes()` —— 与沉浸听读层**同一份实现**。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 进度：复用全工程唯一坐标 `(spine, 块节点, 字符)`
 * ══════════════════════════════════════════════════════════════════════════
 * 翻到哪一页 ⇒ 用 `onPos(本页首段.spine, 本页首段.node, 本页末段.node)` 上报，
 * 父页 `onSelfDrawnPos()` 往下的那一串（目录号跟随 / 书签图标 / 读完判定 /
 * 进度落盘 / 双端同步 / 应用接续）与「上下」「分页」完全同一条链 ⇒ 上层零改动。
 *
 * ⚠️ 本组件**不碰** TTS 状态机、不碰 ReaderKit 控制器：
 *    朗读位置由父页算好，通过 `hlSpine/hlNode/hlFrom/hlTo` 传进来；
 *    句内高亮画在 `Text` 内部（`Span.textBackgroundStyle`），与滚动层同款画法。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 章节窗口
 * ══════════════════════════════════════════════════════════════════════════
 * 不做整本预分页（几百章会卡），而是**以当前章为中心装 [章-1 .. 章+1]**：
 *   · 翻到窗口末页还往后 ⇒ 载入下一章并前进一页；
 *   · 翻到窗口首页还往前 ⇒ 载入上一章并后退一页；
 *   · 每章的分页结果与节点文本都缓存在 `chapPages/chapTexts`，窗口内反复翻零重算。
 */

import { bookParser } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buildChapterNodes } from '../../../tts/ChapterNodes';
import { Haptics } from '../../../common/utils/Haptics';
import { paginateNodes, PaginateResult } from './ReaderPager';
import { buildEngineLines, paginateLines, EngineLine, LineStyle, PageSlice, TITLE_FONT_SCALE, TITLE_FONT_WEIGHT, LETTER_SPACING_FP } from './EngineLines';
// 字重补偿与滚动层**必须共用同一个函数**（否则两档互切时字会突然变粗/变细）
import { scrollFontWeight } from './ReaderScrollView';

const TAG: string = 'NoAnimReader';
const DOMAIN: number = 0x0000;

/**
 * 横滑判定的位移阈值（vp）。
 *
 * 「无动画」的横滑**不跟手**：手指移动时页面一动不动，抬手时若位移过这个阈值
 * 就直接换页（用户 2026-10-26 口径：「横滑也可以用，只是松手才翻页…属于天然适应」）。
 * 取 40vp：小于它当误触忽略，大于它才认。
 */
const SWIPE_TRIGGER_VP: number = 40;

/**
 * 一章的「行 + 分页」结果（`chapPages` 的值）。
 *
 * ⚠️ 2026-10-27 换血：原来是 `PaginateResult`（`pages[][][]` 是"段+字符区间"的算术估算），
 *    现在是**引擎排好的行**（`EngineLine[]`）按页高切成 `PageSlice[]`。
 *    理由见 `EngineLines.ets` 文件头：`cpl = floor(宽/字号)` 与实际断行不符 ⇒
 *    放大字号溢出、缩小字号留白。
 */
class ChapterLines {
  /** 整章的行（唯一权威，来自 `buildEngineLines`） */
  lines: EngineLine[] = [];
  /** 按页高切好的页区间 */
  pages: PageSlice[] = [];
  /** 块节点号 → 该节点起始页（-1 = 空块不渲染），保持旧 `indexOfNode` 语义 */
  pageOfNode: number[] = [];
}

/** 一页 = 一条扁平记录（跨章连续寻址用；`spine` 让上报坐标不依赖窗口起点） */
export class FlatPage {
  spine: number;
  /** 本页的行（引擎排好的，唯一权威） */
  lines: EngineLine[];
  /** 稳定键 */
  key: string;

  constructor(spine: number, lines: EngineLine[], key: string) {
    this.spine = spine;
    this.lines = lines;
    this.key = key;
  }
}

/**
 * 无动画阅读视图。
 *
 * ⚠️ 所有 `@Prop` 都是**父页状态**的投影：父页改状态 ⇒ 这里自动刷新。
 *    本组件内部只持有「窗口载入了哪几章」「当前第几页」这类自洽状态。
 */
@Component
export struct ReaderPageNoAnim {
  // ── 排版参数（与 ReaderKit / 上下滚动层 / 沉浸听读层同源）──────────────────
  @Prop @Watch('onFontSerialChange') fontName: string = '鸿蒙黑体';
  /** 自定义字体文件路径（沙箱绝对路径；'' = 系统字体）—— 引擎排行与渲染都要用 */
  @Prop @Watch('onFontSerialChange') fontPath: string = '';
  @Prop @Watch('onFontSerialChange') fontSize: number = 18;
  @Prop fontWeight: number = 400;
  @Prop fontColor: string = '#000000';
  /** 行高（fp）= readerSetting.lineHeight × fontSize × effectiveLineMul() */
  @Prop @Watch('onFontSerialChange') lineHeightFp: number = 34;
  /** 段首缩进（fp）= fontSize × 2 */
  @Prop @Watch('onFontSerialChange') indentFp: number = 36;
  /** 段间距系数（em）—— 必须与 `ReaderScrollView.SCROLL_PARA_GAP_EM` 一致（0.45） */
  @Prop @Watch('onFontSerialChange') gapEm: number = 0.45;
  /** 背景纯色（= readerSetting.themeColor） */
  @Prop bgColor: string = '#FFFFFF';
  /** 背景图 URI（'' = 纯色） */
  @Prop bgUri: string = '';
  /** 文本区左右内边距（vp）—— 左右各一份 ⇒ 中间正好是文本宽 */
  @Prop sideInsetVp: number = 20;
  /** 顶部避让（vp）：与分页模式正文首行严格对齐 */
  @Prop topInsetVp: number = 0;
  /** 底部避让（vp）：只让出手势条 */
  @Prop bottomInsetVp: number = 0;

  // ── 初始位置：`initSerial` 变化 = 重新载入窗口（进书 / 从别的模式切过来）──
  @Prop initSpine: number = 0;
  @Prop initNode: number = 0;
  /** 初始化时的段内字符偏移（切档交接；与 initNode 配套，见 indexOfNode 注释） */
  @Prop initChar: number = 0;
  @Prop @Watch('onInitSerialChange') initSerial: number = 0;

  // ── 定位请求（TTS 跟随 / 目录 / 书签 / 模式交接）─────────────────────────
  @Prop seekSpine: number = 0;
  @Prop seekNode: number = 0;
  /**
   * 定位用的**段内字符偏移**（与 seekNode 一起构成精确锚点）。
   * ⚠️ 2026-10-27 新增：只给段号时 indexOfNode 只能落到"该段**起始**的那一页"，
   *   而分页模式下页首常常是"上一页延续下来的半段" ⇒ 切档后无动画会落到**上一页**
   *   （用户感知："怎么搞到上一页的最后一段去了"）。带上字符偏移才能落到"包含该字的那一页"。
   */
  @Prop seekChar: number = 0;
  @Prop @Watch('onSeekSerialChange') seekSerial: number = 0;

  // ── 翻一页请求（音量键 / 智控键）──────────────────────────────────────────
  @Prop pageDir: number = 1;
  @Prop @Watch('onPageReqChange') pageReq: number = 0;

  // ── 朗读高亮（父页从 TtsEngine 算好再传）──────────────────────────────────
  @Prop hlSpine: number = -1;
  @Prop hlNode: number = -1;
  @Prop hlFrom: number = -1;
  @Prop hlTo: number = -1;
  @Prop hlSerial: number = 0;

  /** 字体就绪代数（字体异步注册完成后 +1 ⇒ 逼可见节点重建，见滚动层同名字段注释） */
  @Prop @Watch('onFontSerialChange') fontSerial: number = 0;

  /** 字重补偿（系统中文黑体传 -100，其余 0）—— 理由见 `ReaderScrollView` 文件头 */
  @Prop weightOffset: number = 0;

  /**
   * 是否允许本层的**横向手势**（2026-10-26 新增）。
   *
   * ⚠️ 必须在 dock 展开 / PDF 放大态时传 `false`。理由（工程已踩过的真机坑，
   *   见 `ReaderPage3` 下拉书签 `priorityGesture` 处 `:8846-8859` 的长注释）：
   *   本层用 `priorityGesture` 抢横向 pan，而 dock 里的**进度滑条也是横轴的**
   *   ⇒ 不关掉的话，向右拖滑条会被本层识别并独占，滑条一条 `onChange` 都收不到。
   *   关法与工程既有做法完全一致：`fingers: 9` 让单指/双指都触发不了。
   */
  @Prop gestureEnabled: boolean = true;

  // ── 回调（构造时绑定，之后不变）──────────────────────────────────────────
  /** 取解析器（父页的 BookHandler；用闭包读，避免构造时还是 null） */
  handlerProvider: () => bookParser.BookParserHandler | null = () => null;
  /** 正文总章数（spine 数） */
  spineCountProvider: () => number = () => 0;
  /** 当前位置变化（首段 spine / 首段 node / 末段 node）⇒ 父页写进度 */
  /**
   * 位置上报。startChar / ndChar = 页首行/页末行在该段内的**字符偏移**：
   * ⚠️ 2026-10-27 新增：原来只报段号，父页 pplySelfDrawnPos() 只能把 startChar 写 0。
   *   后果：当页首是"上一页延续下来的半段"时，"从本页开始读"会从该段**开头**读
   *   ⇒ 又跳回上一页最后一段（用户实测："怎么搞到上一页的最后一段开始读去了"）。
   */
  onPos: (spine: number, node: number, endNode: number, startChar: number, endChar: number) => void =
    (spine: number, node: number, endNode: number, startChar: number, endChar: number) => {};
  /**
   * 听书状态下的「从此处听书」：把被点那一行的段号回传给父页，由父页 TtsEngine.seekToChapter。
   * ⚠️ 只在 listenActive 为真时才会被触发（见 LineView 的点击条件），平时不影响翻页手势。
   */
  onPlayFrom: (spine: number, node: number) => void = () => {};
  /** 是否处于听书状态（true 时正文每行可点，弹出「从此处听书」气泡） */
  @Prop listenActive: boolean = false;
  /** 轻点中间三分之一 ⇒ 父页拉起菜单 */
  onTap: () => void = () => {};
  /** 右侧三分之一 ⇒ 下一页；左侧三分之一 ⇒ 上一页 */
  onTapNext: () => void = () => {};
  onTapPrev: () => void = () => {};
  /** 首屏已上屏 ⇒ 父页撤掉「正在排版…」占位 */
  onReady: () => void = () => {};

  // ── 内部状态 ─────────────────────────────────────────────────────────────
  /** 扁平页数组（跨章连续） */
  @State flat: FlatPage[] = [];
  /** 当前页下标（**唯一**驱动翻页的状态；改它 = 换页，无任何补间） */
  @State pageIdx: number = 0;
  @State ready: boolean = false
  /** 当前弹出「从此处听书」气泡的行键（'' = 没有气泡） */
  @State listenPopupKey: string = '';
  @State errText: string = '';

  /** 已载入的章区间（闭区间；-1 = 还没加载） */
  private loadedFirst: number = -1;
  private loadedLast: number = -1;
  /** spine → 该章的行与分页结果（窗口内缓存，反复翻页零重算） */
  private chapPages: Map<number, ChapterLines> = new Map<number, ChapterLines>();
  /** spine → 该章块节点文本（渲染时同步取，绝不在 build 里 await） */
  private chapTexts: Map<number, string[]> = new Map<number, string[]>();
  /** 载入中标记（防重入） */
  private loadingTop: boolean = false;
  private loadingBottom: boolean = false;
  /**
   * ⚠️ 2026-10-27：`cpl` / `maxLines` **不再是分页依据**（那是算术估算，会溢出/留白）。
   * 现在只保留为「几何签名」的一部分，用于判断"排版参数是否真的变了"。
   * 真正的行切分由 `EngineLines.buildEngineLines()`（引擎）给出。
   */
  private cpl: number = 20;
  private maxLines: number = 20;
  /** 实测文本区宽高（vp）；0 = 还不知道 */
  private areaW: number = 0;
  private areaH: number = 0;
  /** 首屏还没就绪时到来的定位请求（-1 = 无）—— 理由见滚动层同名注释 */
  private pendingSeekSpine: number = -1;
  private pendingSeekNode: number = 0;
  /** 待消费的字符偏移（indexOfNode 用；换页/换章后清零） */
  private pendingSeekChar: number = 0;

  aboutToAppear(): void {
    // 首次布局尺寸还未知，先用默认 `cpl/maxLines` 载一版（保证不是白屏）；
    // `onAreaChange` 拿到真实尺寸后会重排。
    this.rebuildWindow(this.initSpine, this.initNode, true);
  }

  aboutToDisappear(): void {
    this.chapPages.clear();
    this.chapTexts.clear();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 几何 / 分页
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 判断「排版几何是否变了」⇒ 决定要不要重排窗口。
   * @returns true = 变了（调用方据此重建窗口）
   *
   * ⚠️ 2026-10-27 换血：原来只比 `cpl` / `maxLines`（算术估算），
   *    ⇒ **只改段间距（`gapEm`）或只改缩进（`indentFp`）时这两个值都不变**，
   *      函数返回 false ⇒ 不重排 ⇒ 用户觉得"改了没生效"。
   *   现在用**完整签名**：字号/行高/缩进/段距/字体族/字重/文本区尺寸，任一变化都必须重排。
   *
   * `cpl` / `maxLines` 仍算出来（日志与粗略兜底用），但**不再是分页依据**。
   */
  private applyLayout(): boolean {
    if (this.areaW <= 0 || this.areaH <= 0) {
      return false;
    }
    const cpl: number = Math.max(4, Math.floor(this.areaW / Math.max(1, this.fontSize)));
    const maxLines: number = Math.max(1, Math.floor(this.areaH / Math.max(1, this.lineHeightFp)));
    const sig: string = `${this.areaW.toFixed(2)}|${this.areaH.toFixed(2)}`
      + `|${this.fontSize}|${this.lineHeightFp}|${this.indentFp}|${this.gapEm}`
      + `|${this.fontName}|${this.fontWeight}|${this.fontPath}`;
    if (sig === this.layoutSig && this.ready) {
      return false;
    }
    this.layoutSig = sig;
    this.cpl = cpl;
    this.maxLines = maxLines;
    return true;
  }

  /** 上一次生效的排版签名（见 `applyLayout`） */
  private layoutSig: string = '';

  /** 段间距折合行数（浮点）—— 与渲染端 `padding.top = fontSize × gapEm` 同源 */
  private gapLines(): number {
    return Math.max(1, this.fontSize) * this.gapEm / Math.max(1, this.lineHeightFp);
  }

  /**
   * 读一章 → 分页结果（同时缓存节点文本，供渲染同步取用）。
   *
   * 用 `buildChapterNodes()`（**不是** TtsEngine.previewNodeTexts）：后者只有一个
   * 槽位缓存，连续读三章会互相挤掉；这里按同一套规则建节点，保证 `node` 与
   * ReaderKit 的块节点号严格同源（书签/进度/朗读全靠这个一致性）。
   */
  private async loadChapter(spine: number): Promise<number> {
    const handler: bookParser.BookParserHandler | null = this.handlerProvider();
    if (handler === null || spine < 0) {
      return 0;
    }
    try {
      const content: string = await handler.getSpineItemContent(spine);
      // 说明：txt 没有标签，标题靠目录名反推 —— 把本章 catalogName 传进去，由 ChapterNodes 比对章首段。
      const cn = buildChapterNodes(content, this.chapterTitleOf(handler, spine));
      // （已用探针验证：getSpineItemContent 对 txt 返回纯文本，hasTag=NO）
      const nodes: string[] = cn.nodes;
      // ⚠️ **引擎排行**（唯一权威）：`cpl/maxLines` 的算术估算已废弃，见 `EngineLines.ets`
      const style: LineStyle = this.buildLineStyle();
      const t0: number = Date.now();
      const lines: EngineLine[] = buildEngineLines(nodes, style, cn.isTitle);
      const pageSlices: PageSlice[] = paginateLines(lines, style.pageHeightPx, style.lineHeightPx);
      // 块节点号 → 起始页（保持旧 `indexOfNode` 语义）
      const pageOfNode: number[] = [];
      for (let i = 0; i < nodes.length; i++) {
        pageOfNode.push(-1);
      }
      for (let p = 0; p < pageSlices.length; p++) {
        const sl: PageSlice = pageSlices[p];
        for (let k = sl.from; k < sl.to; k++) {
          const pi: number = lines[k].paraIndex;
          if (pi >= 0 && pi < pageOfNode.length && pageOfNode[pi] < 0) {
            pageOfNode[pi] = p;
          }
        }
      }
      const cl: ChapterLines = new ChapterLines();
      cl.lines = lines;
      cl.pages = pageSlices;
      cl.pageOfNode = pageOfNode;
      this.chapTexts.set(spine, nodes);
      this.chapPages.set(spine, cl);
      hilog.info(DOMAIN, TAG,
        'loadChapter(engine) spine=%{public}d nodes=%{public}d lines=%{public}d pages=%{public}d 宽%{public}s 页高%{public}s 耗时%{public}dms',
        spine, nodes.length, lines.length, pageSlices.length,
        style.widthPx.toFixed(0), style.pageHeightPx.toFixed(0), Date.now() - t0);
      return pageSlices.length;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loadChapter %{public}d failed: %{public}s',
        spine, e instanceof Error ? e.message : String(e));
      return 0;
    }
  }

  /** fp → px（字号/行高/缩进都是 fp，必须乘字体缩放） */
  private fp2px(v: number): number {
    return this.getUIContext().fp2px(v);
  }

  /** vp → px（文本区宽高实测是 vp） */
  private vp2px(v: number): number {
    return this.getUIContext().vp2px(v);
  }

  /**
   * 取「本章在目录里的名字」—— 用于识别 **TXT 的章标题段**。
   *
   * ⚠️ 为什么需要它：`getSpineItemContent()` 对 txt 返回的是**纯文本**
   *    （真机探针实证 `hasTag=NO`），首行就是「第十章 澹台仙子」，与正文毫无区别
   *    ⇒ 无法靠标签判断标题。而 ReaderKit 自己的目录（`getCatalogList()`）
   *    已经把章节名识别出来了 ⇒ 直接拿它反查"章首段是不是标题"，
   *    与 ReaderKit 的判断依据同源。
   *
   * ⚠️ `catalog[spine]` 不保证一一对应（某些 spine 无目录项）：越界或空名一律返回空串，
   *    此时不标记标题（退化为旧行为）—— 宁可没有标题样式，也不误判正文。
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

  /** 组出引擎排行参数（**全 px**） */
  private buildLineStyle(): LineStyle {
    const s: LineStyle = new LineStyle();
    s.fontSizePx = this.fp2px(this.fontSize);
    s.lineHeightPx = this.fp2px(this.lineHeightFp);
    s.indentSlots = 2;
    // 段间距 px：与渲染端 `padding.top = fontSize × gapEm` 同口径（都用 fp→px 的字号）
    s.gapPx = this.fp2px(this.fontSize) * this.gapEm;
    s.widthPx = this.vp2px(this.areaW);
    // ⚠️ 页高要扣掉上下 inset（`areaH` 已经由 `syncTextArea` 扣过了，这里直接用）
    s.pageHeightPx = this.vp2px(this.areaH);
    s.fontFamily = this.fontName;
    s.fontWeight = scrollFontWeight(this.fontWeight, this.weightOffset);
    s.fontPath = this.fontPath;
    // ⚠️ 字距：必须与渲染端 `.letterSpacing(LETTER_SPACING_FP)` 严格对应，
    //    否则"引擎按 A 断行、ArkUI 按 B 渲染" ⇒ 溢出或换行错位。
    //    没有它就每行多塞 1 个字 ⇒ 页边界与 ReaderKit 系统性错位。
    s.letterSpacingPx = this.fp2px(LETTER_SPACING_FP);
    return s;
  }

  /** 把 [from..to] 章拼进扁平页数组（按当前排版几何重建） */
  private async buildFlat(from: number, to: number): Promise<FlatPage[]> {
    this.chapPages.clear();
    this.chapTexts.clear();
    const out: FlatPage[] = [];
    for (let s = from; s <= to; s++) {
      const n: number = await this.loadChapter(s);
      if (n <= 0) {
        continue;
      }
      const cl: ChapterLines | undefined = this.chapPages.get(s);
      if (cl === undefined) {
        continue;
      }
      for (let p = 0; p < cl.pages.length; p++) {
        const sl: PageSlice = cl.pages[p];
        // 只切出本页的行（同一份 `EngineLine` 引用，不复制对象）
        out.push(new FlatPage(s, cl.lines.slice(sl.from, sl.to), `n-${s}-${p}`));
      }
    }
    return out;
  }

  /** 重建窗口：以 `spine` 为中心装 [spine-1 .. spine+1]，并定位到包含 `node` 的页 */
  private async rebuildWindow(spine: number, node: number, first: boolean): Promise<void> {
    // 首次进入：把切档交接来的字符偏移灌进 pending，indexOfNode 才能落到"包含它"的那一页
    if (first) {
      this.pendingSeekChar = Math.max(0, this.initChar);
    }
    const total: number = this.spineCountProvider();
    const target: number = Math.max(0, total > 0 ? Math.min(spine, total - 1) : spine);
    const from: number = Math.max(0, target - 1);
    const to: number = Math.min(total > 0 ? total - 1 : target, target + 1);
    hilog.info(DOMAIN, TAG, 'rebuildWindow spine=%{public}d node=%{public}d window=%{public}d..%{public}d',
      target, node, from, to);

    const flat: FlatPage[] = await this.buildFlat(from, to);
    this.loadedFirst = from;
    this.loadedLast = to;
    this.errText = flat.length === 0 ? '这一章没有可显示的正文' : '';

    const at: number = Math.max(0, this.indexOfNode(flat, target, node, this.pendingSeekChar));
    this.flat = flat;
    this.pageIdx = at;
    this.ready = flat.length > 0;
    if (this.ready) {
      this.reportAt(flat, at);
      if (first) {
        this.onReady();
      }
    }
    if (first && this.pendingSeekSpine >= 0) {
      const ps: number = this.pendingSeekSpine;
      const pn: number = this.pendingSeekNode;
      this.pendingSeekSpine = -1;
      const i2: number = this.indexOfNode(this.flat, ps, pn);
      if (i2 >= 0) {
        this.pageIdx = i2;
        this.reportAt(this.flat, i2);
      }
    }
  }

  /** (spine, 块节点号) → 扁平页下标（-1 = 不在窗口内；找不到就退到该章首页） */
  /**
   * (spine, 段号, 字符偏移) → 扁平页下标。
   *
   * ⚠️ 2026-10-27 新增 char 参数：只按段号找会落到「该段**起始**的那一页」，
   *    而分页模式下页首常常是「上一页延续下来的半段」⇒ 切档后无动画会退到上一页。
   *    带上字符偏移后，找的是「包含该字的那一页」，与用户看到的那一页一致。
   *    找不到（越界/空块）时退回原来的「段起始页」行为。
   */
  private indexOfNode(flat: FlatPage[], spine: number, node: number, char: number = 0): number {
    const cl: ChapterLines | undefined = this.chapPages.get(spine);
    if (cl === undefined || cl.pages.length === 0) {
      return -1;
    }
    let local: number = -1;
    // ① 优先：按 (段号 + 字符偏移) 找「真正包含这个字」的那一页
    if (char > 0) {
      for (let p = 0; p < cl.pages.length && local < 0; p++) {
        const sl: PageSlice = cl.pages[p];
        for (let k = sl.from; k < sl.to && k < cl.lines.length; k++) {
          const ln: EngineLine = cl.lines[k];
          if (ln.paraIndex === node && char >= ln.charFrom && char < ln.charTo) {
            local = p;
            break;
          }
        }
      }
    }
    // ② 回退：该节点起始页
    if (local < 0 && node >= 0 && node < cl.pageOfNode.length) {
      local = cl.pageOfNode[node];
    }
    if (local < 0) {
      // 该节点不渲染（空块）⇒ 往后找第一个渲染块（宁可粗略也不跳空）
      for (let i = Math.max(0, node); i < cl.pageOfNode.length; i++) {
        if (cl.pageOfNode[i] >= 0) {
          local = cl.pageOfNode[i];
          break;
        }
      }
    }
    if (local < 0) {
      local = 0;
    }
    // ③ 章首页在扁平数组里的起点
    for (let i = 0; i < flat.length; i++) {
      if (flat[i].spine === spine) {
        return Math.min(flat.length - 1, i + local);
      }
    }
    return -1;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 位置上报
  // ══════════════════════════════════════════════════════════════════════════

  /** 上报当前页的首段/末段（父页据此写全工程唯一坐标） */
  private reportAt(flat: FlatPage[], idx: number): void {
    if (idx < 0 || idx >= flat.length) {
      return;
    }
    const pg: FlatPage = flat[idx];
    if (pg.lines.length === 0) {
      return;
    }
    // 段号 = 该行的 `paraIndex`（引擎排行时已记录）
    // ⚠️ 2026-10-27：同时上报**字符偏移**，否则父页只能把 startChar 记成 0
    //    ⇒ 页首是"上一页延续下来的半段"时，"从本页开始读"会从该段开头读、跳回上一页。
    const first: EngineLine = pg.lines[0];
    const last: EngineLine = pg.lines[pg.lines.length - 1];
    const a: number = first.paraIndex;
    const b: number = last.paraIndex;
    this.onPos(pg.spine, a, b >= a ? b : a, first.charFrom, last.charTo);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 翻页（核心：只改整数，无任何补间）
  // ══════════════════════════════════════════════════════════════════════════

  /** 翻页：`dir > 0` 下一页 / `dir < 0` 上一页。**同步换页，无动画** */
  private turn(dir: number): void {
    if (this.flat.length === 0) {
      return;
    }
    const next: number = this.pageIdx + (dir >= 0 ? 1 : -1);
    if (next < 0) {
      // 已到窗口首章首页 ⇒ 尝试向前补一章（补到就后退一页）
      this.prependPrev(true);
      return;
    }
    if (next >= this.flat.length) {
      // 已到窗口末章末页 ⇒ 尝试向后补一章（补到就前进一页）
      this.appendNext(true);
      return;
    }
    this.pageIdx = next;
    this.reportAt(this.flat, next);
  }

  /** 尾接下一章；`thenTurn = true` 表示"翻到边界后继续翻"⇒ 接上后前进一步 */
  private async appendNext(thenTurn: boolean): Promise<void> {
    if (this.loadingBottom || this.loadingTop) {
      return;
    }
    const total: number = this.spineCountProvider();
    const next: number = this.loadedLast + 1;
    if (total > 0 && next >= total) {
      return;
    }
    this.loadingBottom = true;
    const n: number = await this.loadChapter(next);
    this.loadingBottom = false;
    this.loadedLast = next;
    const cl: ChapterLines | undefined = this.chapPages.get(next);
    if (n <= 0 || cl === undefined) {
      return;
    }
    const merged: FlatPage[] = this.flat.slice();
    for (let p = 0; p < cl.pages.length; p++) {
      const sl: PageSlice = cl.pages[p];
      merged.push(new FlatPage(next, cl.lines.slice(sl.from, sl.to), `n-${next}-${p}`));
    }
    this.flat = merged;
    hilog.info(DOMAIN, TAG, 'appendNext spine=%{public}d pages=%{public}d total=%{public}d',
      next, cl.pages.length, merged.length);
    if (thenTurn && this.pageIdx < this.flat.length - 1) {
      this.pageIdx = this.pageIdx + 1;
      this.reportAt(this.flat, this.pageIdx);
    }
  }

  /**
   * 前插上一章；`thenTurn = true` 表示继续回翻一页。
   *
   * ⚠️ 前插后**必须把当前页下标追平**（原下标 + 新增页数），否则会跳到别的章。
   */
  private async prependPrev(thenTurn: boolean): Promise<void> {
    if (this.loadingTop || this.loadingBottom) {
      return;
    }
    const prev: number = this.loadedFirst - 1;
    if (prev < 0) {
      return;
    }
    this.loadingTop = true;
    const n: number = await this.loadChapter(prev);
    this.loadingTop = false;
    this.loadedFirst = prev;
    const cl: ChapterLines | undefined = this.chapPages.get(prev);
    if (n <= 0 || cl === undefined) {
      return;
    }
    const shift: number = cl.pages.length;
    const merged: FlatPage[] = [];
    for (let p = 0; p < shift; p++) {
      const sl: PageSlice = cl.pages[p];
      merged.push(new FlatPage(prev, cl.lines.slice(sl.from, sl.to), `n-${prev}-${p}`));
    }
    for (const f of this.flat) {
      merged.push(f);
    }
    this.flat = merged;
    this.pageIdx = Math.min(merged.length - 1, this.pageIdx + shift);
    hilog.info(DOMAIN, TAG, 'prependPrev spine=%{public}d pages=%{public}d idx=%{public}d',
      prev, shift, this.pageIdx);
    if (thenTurn && this.pageIdx > 0) {
      this.pageIdx = this.pageIdx - 1;
      this.reportAt(this.flat, this.pageIdx);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 父页驱动的变更
  // ══════════════════════════════════════════════════════════════════════════

  onInitSerialChange(): void {
    // 延到渲染帧外（`@Watch` 运行在状态更新的渲染周期内，此间改 @State 非法）
    setTimeout((): void => {
      this.ready = false;
      this.rebuildWindow(this.initSpine, this.initNode, true);
    }, 0);
  }

  onSeekSerialChange(): void {
    const spine: number = this.seekSpine;
    const node: number = this.seekNode;
    // 字符偏移：与段号一起构成精确锚点（见 seekChar 字段注释）
    this.pendingSeekChar = Math.max(0, this.seekChar);
    if (!this.ready) {
      // 首屏还没载入完 ⇒ 暂存，等 rebuildWindow 末尾补做
      this.pendingSeekSpine = spine;
      this.pendingSeekNode = node;
      return;
    }
    if (spine < this.loadedFirst || spine > this.loadedLast) {
      setTimeout((): void => {
        this.rebuildWindow(spine, node, false);
      }, 0);
      return;
    }
    const idx: number = this.indexOfNode(this.flat, spine, node, this.pendingSeekChar);
    if (idx >= 0) {
      setTimeout((): void => {
        this.pageIdx = idx;
        this.reportAt(this.flat, idx);
      }, 0);
    }
  }

  /**
   * 翻一页（音量键/智控键 / 右左三分区点击）：语义与分页模式的 `flipPage()` 一致。
   *
   * ⚠️⚠️ 本方法是 `@Watch('onPageReqChange')` 的回调 —— **运行在状态更新的渲染周期内**，
   *    此间同步写 `@State pageIdx` 会触发 ArkUI 的
   *    「State variable has changed during render」（真机日志 `Documents\日志`
   *    17:13:52.005 原文实证 : `It's illegal to change @Component state while build …`），
   *    后果是整页被判错并拆掉（表现为"右滑/点击把书弄没了"）。
   *    ⇒ 一律推迟一个宏任务再翻。用户侧无感（下一帧即完成）。
   */
  onPageReqChange(): void {
    const dir: number = this.pageDir >= 0 ? 1 : -1;
    setTimeout((): void => {
      this.turn(dir);
    }, 0);
  }

  /**
   * 文本区尺寸变化 ⇒ 重算 `cpl/maxLines` 并**重建窗口**（页边界会变）。
   *
   * 只在真的变了才重建：`onAreaChange` 在首帧、字体变化、横竖屏旋转时都会触发，
   * 而重建要重读三章正文，属于重活。
   *
   * ⚠️ 方法名**不能**叫 `onAreaChange` —— 那是 ArkUI 组件基类 `CustomComponent`
   *    自带的属性（入参是 `(oldValue: Area, newValue: Area) => void`），同名会
   *    覆盖基类签名并报 `tsCheck 2416`（真机/编译都会拦）。
   *
   * ⚠️⚠️ `onAreaChange` 运行在**布局阶段**，此间写 `@State`（`ready` / `flat` / `pageIdx`）
   *    会被 ArkUI 判为「State variable has changed during render」（真机日志
   *    `Documents\日志` 17:13:52.005 实证同类错误直接拆页）。⇒ 真正的重建**推迟一帧**，
   *    这里只记下尺寸（普通字段，不改状态）。
   */
  /**
   * **字号 / 行高 / 字体变化 ⇒ 必须重新分页**（2026-10-27 真机定案）。
   *
   * ⚠️⚠️ 原来 `fontSerial` 是 `@Prop` 但**没有 `@Watch`**：
   *   用户在设置里改字号后，父页确实把 `fontSerial` 自增了，本组件也只是"重建"一次，
   *   但 **`applyLayout()` 不会被调用 ⇒ 不会重新分页** ⇒ 页面仍按**旧字号**算出的行数渲染
   *   （字号改小 → 只填半屏；字号改大 → 溢出到 dock 下面）。
   *   这正是用户反馈的「放大溢出 / 缩小下半屏空白」。
   *
   * ⇒ 现在监听 `fontSerial`，变化时按「当前页首行段号」为锚重排（不跳章、不跳页）。
   */
  private onFontSerialChange(): void {
    // ⚠️ `@Watch` 运行在状态更新的渲染周期内，此间改 @State / 重排都是非法的 ⇒ 推迟一帧
    setTimeout((): void => {
      if (!this.applyLayout()) {
        return;
      }
      const anchor: FlatPage | null = this.pageIdx >= 0 && this.pageIdx < this.flat.length
        ? this.flat[this.pageIdx] : null;
      const sp: number = anchor !== null ? anchor.spine : this.initSpine;
      const nd: number = anchor !== null && anchor.lines.length > 0
        ? anchor.lines[0].paraIndex : this.initNode;
      this.ready = false;
      this.rebuildWindow(sp, nd, true);
    }, 0);
  }

  private syncTextArea(newW: number, newH: number): void {
    if (newW <= 0 || newH <= 0) {
      return;
    }
    const changed: boolean = Math.abs(newW - this.areaW) > 1 || Math.abs(newH - this.areaH) > 1;
    this.areaW = newW;
    this.areaH = newH;
    if (!changed && this.ready) {
      return;
    }
    if (!this.applyLayout()) {
      return;
    }
    // 换尺寸 ⇒ 位置以"当前页首段"为锚重排，不跳章（放到渲染帧之外执行）
    const anchor: FlatPage | null = this.pageIdx >= 0 && this.pageIdx < this.flat.length
      ? this.flat[this.pageIdx] : null;
    const sp: number = anchor !== null ? anchor.spine : this.initSpine;
    // 锚点用当前页首行的段号（换血前是 `segs[0][0]`，现在行上直接带 `paraIndex`）
    const nd: number = anchor !== null && anchor.lines.length > 0
      ? anchor.lines[0].paraIndex : this.initNode;
    setTimeout((): void => {
      this.ready = false;
      this.rebuildWindow(sp, nd, true);
    }, 0);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 当前页里的某段是否就是朗读段。
   *
   * ⚠️ **必须同时比 spine**：窗口里装着 [本章-1..本章+1] 三章的页，
   *    块节点号在各章里都从 0 开始 ⇒ 只比 `seg[0]` 会把相邻章的同号段**误判成朗读段**
   *    （表现为"没在念的那一段也亮着"）。滚动层 `rowKey()` 也是同款双条件。
   */
  // ══════════════════════════════════════════════════════════════════════════
  // 行渲染（2026-10-27 换血：引擎排行 + 每行一个 Text）
  // ══════════════════════════════════════════════════════════════════════════
  // ⚠️ 为什么从「每段一个 Text」改成「每行一个 Text」：
  //   引擎（`@ohos.graphics.text`，与 ArkUI `Text` 同底层）已经把行切好了，
  //   若仍按段交给 ArkUI 自己换行，等于**又排一遍**，与引擎结果可能差 1 字
  //   ⇒ 溢出/留白回归。现在每行文本是引擎算定的，ArkUI 只负责画，不再参与断行。
  //   实测：一页 10~15 行、一章几百行，`ForEach` 完全扛得住（无动画页不滚动）。

  /** 该行是否落在当前高亮区间内（⚠️ 必须同时比 spine，理由见上方注释） */
  private isHlLine(line: EngineLine): boolean {
    if (this.hlFrom < 0 || line.paraIndex !== this.hlNode) {
      return false;
    }
    if (this.pageIdx < 0 || this.pageIdx >= this.flat.length) {
      return false;
    }
    if (this.flat[this.pageIdx].spine !== this.hlSpine) {
      return false;
    }
    return Math.max(line.charFrom, this.hlFrom) < Math.min(line.charTo, this.hlTo);
  }

  /** 行内高亮起点（`+ prefixLen`：段首行文本含 2 个全角空格缩进前缀） */
  private hlRelFrom(line: EngineLine): number {
    const v: number = this.hlFrom - line.charFrom + line.prefixLen;
    return Math.max(0, Math.min(v, line.text.length));
  }

  /** 行内高亮终点 */
  private hlRelTo(line: EngineLine): number {
    const v: number = this.hlTo - line.charFrom + line.prefixLen;
    const from: number = this.hlRelFrom(line);
    return Math.max(from, Math.min(v, line.text.length));
  }

  /**
   * 行渲染键：**高亮那一行**把句序号与字体代数拼进键里，逼 ArkUI 重建它 ——
   * 否则会复用旧组件、高亮不移动（与滚动层 `rowKey()` 同款做法）。
   */
  private lineKey(line: EngineLine): string {
    const base: string = `l-${line.paraIndex}-${line.charFrom}-${line.charTo}-f${this.fontSerial}`;
    return this.isHlLine(line) ? `${base}-h${this.hlSerial}` : base;
  }

  /** 段首行的顶部间距（vp）—— 与 `EngineLines.gapPx` 同口径（都是 `fontSize × gapEm`） */
  private linePadVp(line: EngineLine): number {
    return line.isParaStart ? this.fontSize * this.gapEm : 0;
  }

  /** 标题行字号（fp）= 正文字号 × `TITLE_FONT_SCALE`（与 `EngineLines` 算行高同一个值） */
  private titleFontSizeFp(): number {
    return this.fontSize * TITLE_FONT_SCALE;
  }

  /** 标题行行高（fp）= 正文行高 × `TITLE_FONT_SCALE`（必须同比放大，否则与下行重叠） */
  private titleLineHeightFp(): number {
    return this.lineHeightFp * TITLE_FONT_SCALE;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 听书状态下「点击任意一行 ⇒ 从此处听书」（2026-10-27）
  // ══════════════════════════════════════════════════════════════════════════
  // 只在本档（无动画）实现：四档听书现在统一走无动画（见 `ReaderPage3.enterListenMode`），
  // 所以这里加一次就等于全系统都有了。

  /** 当前页所属正文号（气泡回传坐标要用） */
  /** px → vp（气泡命中行要用 vp 累加，行高数据来自引擎是 px） */
  private px2vp(v: number): number {
    return this.getUIContext().px2vp(v);
  }

  /**
   * 长按正文 ⇒ 按落点的 **y 坐标**反算命中哪一行，再弹「从此处听书」气泡。
   *
   * ⚠️⚠️ 为什么由**触摸分区层**来收这个长按（而不是每行 Text 自己挂手势）：
   *    本组件的 Stack 从下到上是
   *      ① 背景 Column ② 正文 Column（每行一个 Text）③ 触摸分区 Row（左1/3/中1/3/右1/3）。
   *    ③ 在最上层且各分区都挂了 onClick ⇒ **触摸事件全被它接走**，
   *    ② 里 Text 上的任何手势都**收不到**（真机日志：长按完全没有 play-from-line）。
   *    ⇒ 只能把长按挂到 ③ 上，再用坐标自己算行号。
   *
   * 行高换算：逐行累加「真实行高 + 段首间距」，第一个"落点小于累计高度"的行即命中行。
   * 比 y / lineHeight 的除法稳（段间距会破坏等距）。
   */
  private onBodyLongPress(localY: number): void {
    if (!this.listenActive) {
      return;
    }
    const lines: EngineLine[] = this.curLines();
    if (lines.length === 0) {
      return;
    }
    // localY 是相对触摸分区 Row 的 vp；正文从 topInsetVp 之下才开始
    const y: number = localY - this.topInsetVp;
    let acc: number = 0;
    let hit: EngineLine = lines[lines.length - 1];
    for (let i = 0; i < lines.length; i++) {
      const hPx: number = lines[i].heightPx > 0 ? lines[i].heightPx : this.fp2px(this.lineHeightFp);
      const hVp: number = this.px2vp(hPx) + this.linePadVp(lines[i]);
      if (y < acc + hVp) {
        hit = lines[i];
        break;
      }
      acc += hVp;
    }
    Haptics.tap();
    this.listenPopupKey = this.lineKey(hit);
    hilog.info(DOMAIN, TAG,
      'listen: long-press y=%{public}s topInset=%{public}s acc=%{public}s → para=%{public}d',
      localY.toFixed(1), this.topInsetVp.toFixed(1), acc.toFixed(1), hit.paraIndex);
  }

  private spineOfPage(): number {
    if (this.pageIdx < 0 || this.pageIdx >= this.flat.length) {
      return 0;
    }
    return this.flat[this.pageIdx].spine;
  }

  /**
   * 点击正文某一行。
   *
   * ⚠️ 非听书状态**必须直接 return**（不 `Haptics`、不改状态）：
   *    无动画档的整行都铺满了屏幕，拦截点击会把父页的"点右 1/3 翻页"手势吃掉。
   */
  private tapLine(line: EngineLine): void {
    if (!this.listenActive) {
      return;
    }
    Haptics.tap();
    const k: string = this.lineKey(line);
    this.listenPopupKey = this.listenPopupKey === k ? '' : k;
  }

  /** 这一行是否要显示「从此处听书」气泡 */
  private popupShown(line: EngineLine): boolean {
    return this.listenActive && this.listenPopupKey.length > 0
      && this.listenPopupKey === this.lineKey(line);
  }

  /** 气泡配置（自定义 builder，整体可点） */
  private popupOpts(line: EngineLine): CustomPopupOptions {
    const opts: CustomPopupOptions = {
      builder: (): void => {
        this.ListenBubble(line)
      },
      placement: Placement.Top,
      // 无遮罩：点别处直接关掉，不打断阅读
      mask: false,
      // ⚠️ 去掉箭头：箭头会把气泡往上顶约 8vp，导致"看着挂在了上一段下面"（用户实截图）。
      enableArrow: false,
      // 再往下压一点，让气泡底边正好贴住**命中行**的顶边（用户要求：对齐那一段的分隔线）
      offset: { x: 0, y: 34 },
      onStateChange: (e: PopupStateChangeParam): void => {
        if (!e.isVisible && this.listenPopupKey === this.lineKey(line)) {
          this.listenPopupKey = '';
        }
      }
    };
    return opts;
  }

  /** 气泡本体：一颗圆角胶囊「▶ 从此处听书」，整颗可点 */
  @Builder
  ListenBubble(line: EngineLine) {
    Row() {
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(13)
        .fontColor(['#FFFFFF'])
      Text('从此处听书')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .margin({ left: 6 })
    }
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor('#1F2937')
    .borderRadius(18)
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.25)', offsetY: 2 })
    .onClick(() => {
      Haptics.tap();
      this.listenPopupKey = '';
      // 段首开始读：`charFrom` 是行在段内的起点，这里统一从 0 起（从整段开头听才对）
      this.onPlayFrom(this.spineOfPage(), line.paraIndex);
    })
  }

  @Builder
  LineView(line: EngineLine) {
    if (line.isTitle) {
      // ── 章标题：大字号 + 加粗、顶格（对齐 ReaderKit `<h1>` 的观感与行数）──────
      Text(line.text)
        .fontSize(this.titleFontSizeFp())
        .fontWeight(TITLE_FONT_WEIGHT)
        .fontFamily(this.fontName)
        .fontColor(this.fontColor)
        .lineHeight(this.titleLineHeightFp())
        .textAlign(TextAlign.Start)
        .width('100%')
        .padding({ top: this.linePadVp(line) })
        // 听书状态下整行可点 ⇒ 弹「从此处听书」气泡（详见 tapLine / ListenBubble 注释）
        // ⚠️ 用**长按**而不是点击：整行铺满屏幕，onClick 会被父页的"点右 1/3 翻页"/"点中央出菜单"先接走，
        //    气泡永远不出现（用户实测反馈）。长按与点击手势不冲突。
        .bindPopup(this.popupShown(line), this.popupOpts(line))
    } else if (this.isHlLine(line)) {
      Text() {
        Span(line.text.substring(0, this.hlRelFrom(line)))
        Span(line.text.substring(this.hlRelFrom(line), this.hlRelTo(line)))
          .textBackgroundStyle({ color: 'rgba(0, 125, 255, 0.20)', radius: 4 })
        Span(line.text.substring(this.hlRelTo(line)))
      }
      .fontSize(this.fontSize)
      .fontWeight(scrollFontWeight(this.fontWeight, this.weightOffset))
      .fontFamily(this.fontName)
      .fontColor(this.fontColor)
      .lineHeight(this.lineHeightFp)
          .letterSpacing(LETTER_SPACING_FP)
      .textAlign(TextAlign.Start)
      .width('100%')
      .padding({ top: this.linePadVp(line) })
      // 听书状态下长按整行 ⇒ 弹「从此处听书」气泡（长按避开点击手势冲突）
      .bindPopup(this.popupShown(line), this.popupOpts(line))
    } else {
      Text(line.text)
        .fontSize(this.fontSize)
        .fontWeight(scrollFontWeight(this.fontWeight, this.weightOffset))
        .fontFamily(this.fontName)
        .fontColor(this.fontColor)
        .lineHeight(this.lineHeightFp)
          .letterSpacing(LETTER_SPACING_FP)
        .textAlign(TextAlign.Start)
        .width('100%')
        .padding({ top: this.linePadVp(line) })
        // 听书状态下整行可点 ⇒ 弹「从此处听书」气泡（详见 tapLine / ListenBubble 注释）
        // ⚠️ 用**长按**而不是点击：整行铺满屏幕，onClick 会被父页的"点右 1/3 翻页"/"点中央出菜单"先接走，
        //    气泡永远不出现（用户实测反馈）。长按与点击手势不冲突。
        .bindPopup(this.popupShown(line), this.popupOpts(line))
    }
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：纯色打底 + 可选背景图（材质图 / 自定义图）
      //
      // ⚠️ `onAreaChange` 必须挂在**这个恒存在的节点**上（不能挂在正文 Column 上）：
      //   正文那块被 `this.ready` 门控，而 `ready` 又要等 `cpl/maxLines` 算出、
      //   而 `cpl/maxLines` 恰恰来自 `onAreaChange` ⇒ 挂在门内会形成死锁
      //   （永远测不到尺寸 ⇒ 永远用默认 20×20 分页 ⇒ 版式不对）。
      //   本节点是 100%×100% 的整块容器，报出来的就是父页给我们的完整尺寸。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.bgColor)
        .onAreaChange((_old: Area, newArea: Area) => {
          this.syncTextArea(Number(newArea.width) - 2 * this.sideInsetVp,
            Number(newArea.height) - this.topInsetVp - this.bottomInsetVp);
        })
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
        // ── 正文：**只渲染当前这一页** ─────────────────────────────────────────
        // 为什么不用 List/LazyForEach：一页最多十几段，直接 ForEach 更快；
        // 而且"换页 = 整块重建"正是无动画语义（这里没有任何滚动容器可以做跟手/惯性）。
        Column() {
          ForEach(this.curLines(), (line: EngineLine) => {
            this.LineView(line)
          }, (line: EngineLine): string => this.lineKey(line))
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: this.sideInsetVp,
          right: this.sideInsetVp,
          top: this.topInsetVp,
          bottom: this.bottomInsetVp
        })

        // ── 触摸分区：左 1/3 上一页 / 中 1/3 拉菜单 / 右 1/3 下一页 ─────────────
        // 点击是**主交互**（用户 2026-10-26：「主要以点击为主，横滑是附加」），
        // 三分区与沉浸听读层同款（`ImmersiveListenLayer()`）。
        Row() {
          Column()
            .layoutWeight(32)
            .height('100%')
            .onClick(() => {
              Haptics.tap();
              this.onTapPrev();
            })
          Column()
            .layoutWeight(36)
            .height('100%')
            .onClick(() => {
              Haptics.tap();
              this.onTap();
            })
          Column()
            .layoutWeight(32)
            .height('100%')
            .onClick(() => {
              Haptics.tap();
              this.onTapNext();
            })
        }
        .width('100%')
        .height('100%')
        // ★ 听书状态下长按 ⇒ 弹「从此处听书」气泡。
        //   必须挂在**这一层**（触摸分区 Row 在最上层，正文里的 Text 收不到事件），
        //   用落点 y 反算命中行，详见 `onBodyLongPress()` 注释。
        //   用普通 `gesture` 而非 priorityGesture：横滑翻页是 priorityGesture 的 Pan，
        //   两者类型不同（长按 vs 拖动）不会互抢。
        .gesture(LongPressGesture({ repeat: false, duration: 420 })
          .onAction((e: GestureEvent) => {
            // ⚠️ 不要写 `GestureEvent["fingerList"]`：ArkTS 禁用索引访问类型
            //    （`arkts-no-aliases-by-index`），这里靠推断即可。
            const fl = e.fingerList;
            const y: number = fl.length > 0 ? fl[0].localY : 0;
            this.onBodyLongPress(y);
          }))
        // ── 横滑翻页（2026-10-26 修「右滑误触关闭」）──────────────────────────
        // 用户口径：「就算完整的左右滑动手势也没问题…这应该是天生支持的」。
        // ⇒ 全宽横向 pan，松手过阈值即翻页（不跟手：无动画语义）。
        //
        // ⚠️⚠️ 必须用 `priorityGesture` 而**不是** `gesture`。真机日志实证
        //   （`17:13:51.499`）当时触摸链里只有 `PanRecognizer: { Stack }; { Row }; { Stack }`，
        //   本层的普通 `.gesture()` 优先级最低 ⇒ **向右滑**（回上一页）被系统侧滑返回
        //   或外层识别器抢走 ⇒ 整本书被 pop（日志 `17:13:52.935 GoBackground: reason: 4`）。
        //   向左滑（下一页）不冲突，所以只有右滑出问题 —— 与用户描述完全一致。
        //   官方语义（documentId `…/绑定手势方法/arkts-gesture-events-binding`）原文：
        //   「当父组件使用 priorityGesture 绑定与子组件**同类型**的手势时，**父组件优先识别**」。
        //   本工程同款修法已真机验证：`ReaderPage3` 下拉书签（`:8845` 起）。
        .priorityGesture(
          PanGesture({
            // dock 展开 / PDF 放大时关掉（`fingers: 9` 令单指双指都触发不了）——
            // 否则会抢走 dock 进度滑条的横向拖动（机理见 `gestureEnabled` 字段注释）
            fingers: this.gestureEnabled ? 1 : 9,
            distance: 12,
            direction: PanDirection.Horizontal
          })
            // ── 关键：**手势被识别时**就打时间戳 ────────────────────────────────
            // 系统侧滑返回可能在 `onActionEnd` 之前就把页面 pop 掉（真机日志
            // `18:30:42.579` pan 被 `T: Stack` 接受 → 7ms 后 `isPopPage: 1`），
            // 那时我们的 `onActionEnd` **根本不会跑** ⇒ 若只在 End 里打戳，
            // `Index.onBackPress()` 永远等不到这个戳、拦不住。
            // 所以在 `onActionStart` 就打，并保证**先于**系统判定写入。
            .onActionStart(() => {
              AppStorage.setOrCreate('NOANIM_SWIPE_AT', Date.now());
            })
            .onActionUpdate(() => {
              // 持续刷新：系统侧滑往往在 move 阶段就抢走，Start 可能来不及被我们拿到
              AppStorage.setOrCreate('NOANIM_SWIPE_AT', Date.now());
            })
            .onActionEnd((e: GestureEvent) => {
              const dx: number = e.offsetX;
              if (Math.abs(dx) < SWIPE_TRIGGER_VP) {
                return;
              }
              // 横滑也补一次轻震（点击路径的震动在各自 `onClick` 里，不会重复）
              Haptics.tick();
              // 左滑（dx < 0）= 下一页；右滑 = 上一页（与横滑翻页的直觉一致）
              this.turn(dx < 0 ? 1 : -1);
            })
        )
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
  }

  /** 当前页的行（`pageIdx` 越界时给空数组） */
  private curLines(): EngineLine[] {
    if (this.pageIdx < 0 || this.pageIdx >= this.flat.length) {
      return [];
    }
    return this.flat[this.pageIdx].lines;
  }
}
