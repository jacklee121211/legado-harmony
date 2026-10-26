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

/** 一页 = 一条扁平记录（跨章连续寻址用；`spine` 让上报坐标不依赖窗口起点） */
export class FlatPage {  spine: number;
  /** 本页切片（切片 = [节点号, 起始字符, 结束字符]） */
  segs: number[][];
  /** 稳定键 */
  key: string;

  constructor(spine: number, segs: number[][], key: string) {
    this.spine = spine;
    this.segs = segs;
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
  @Prop fontName: string = '鸿蒙黑体';
  @Prop fontSize: number = 18;
  @Prop fontWeight: number = 400;
  @Prop fontColor: string = '#000000';
  /** 行高（fp）= readerSetting.lineHeight × fontSize × effectiveLineMul() */
  @Prop lineHeightFp: number = 34;
  /** 段首缩进（fp）= fontSize × 2 */
  @Prop indentFp: number = 36;
  /** 段间距系数（em）—— 必须与 `ReaderScrollView.SCROLL_PARA_GAP_EM` 一致（0.45） */
  @Prop gapEm: number = 0.45;
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
  @Prop @Watch('onInitSerialChange') initSerial: number = 0;

  // ── 定位请求（TTS 跟随 / 目录 / 书签 / 模式交接）─────────────────────────
  @Prop seekSpine: number = 0;
  @Prop seekNode: number = 0;
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
  @Prop fontSerial: number = 0;

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
  onPos: (spine: number, node: number, endNode: number) => void = () => {};
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
  @State ready: boolean = false;
  @State errText: string = '';

  /** 已载入的章区间（闭区间；-1 = 还没加载） */
  private loadedFirst: number = -1;
  private loadedLast: number = -1;
  /** spine → 该章分页结果（窗口内缓存，反复翻页零重算） */
  private chapPages: Map<number, PaginateResult> = new Map<number, PaginateResult>();
  /** spine → 该章块节点文本（渲染时同步取，绝不在 build 里 await） */
  private chapTexts: Map<number, string[]> = new Map<number, string[]>();
  /** 载入中标记（防重入） */
  private loadingTop: boolean = false;
  private loadingBottom: boolean = false;
  /** 每行字数 / 每页行数（由实测文本区尺寸算出） */
  private cpl: number = 20;
  private maxLines: number = 20;
  /** 实测文本区宽高（vp）；0 = 还不知道 */
  private areaW: number = 0;
  private areaH: number = 0;
  /** 首屏还没就绪时到来的定位请求（-1 = 无）—— 理由见滚动层同名注释 */
  private pendingSeekSpine: number = -1;
  private pendingSeekNode: number = 0;

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
   * 由实测文本区尺寸算出 `cpl` / `maxLines`。
   * @returns true = 尺寸确实变了（调用方据此决定要不要重排窗口）
   *
   * `cpl` 用 `floor(宽 / 字宽)`，字宽取字号（工程实测 `HL_ADVANCE_RATIO = 1.0`，
   * 中文等宽于字号 ⇒ 与 `ReaderPage3.cplFor()` 同一口径）。
   * `maxLines` 用 `floor(可用高 / 行高)` —— 段间距在分页时以 `gapLines` 计入，
   * 不从这里扣，否则会与 `gapLines()` 双算。
   */
  private applyLayout(): boolean {
    if (this.areaW <= 0 || this.areaH <= 0) {
      return false;
    }
    const cpl: number = Math.max(4, Math.floor(this.areaW / Math.max(1, this.fontSize)));
    const maxLines: number = Math.max(1, Math.floor(this.areaH / Math.max(1, this.lineHeightFp)));
    if (cpl === this.cpl && maxLines === this.maxLines && this.ready) {
      return false;
    }
    this.cpl = cpl;
    this.maxLines = maxLines;
    return true;
  }

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
      const nodes: string[] = buildChapterNodes(content).nodes;
      const res: PaginateResult = paginateNodes(nodes, this.cpl, this.maxLines, this.gapLines());
      this.chapTexts.set(spine, nodes);
      this.chapPages.set(spine, res);
      hilog.info(DOMAIN, TAG,
        'loadChapter spine=%{public}d nodes=%{public}d pages=%{public}d cpl=%{public}d maxLines=%{public}d',
        spine, nodes.length, res.pages.length, this.cpl, this.maxLines);
      return res.pages.length;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loadChapter %{public}d failed: %{public}s',
        spine, e instanceof Error ? e.message : String(e));
      return 0;
    }
  }

  /** 把 [from..to] 章拼进扁平页数组（分页缓存全清，按新几何重建） */
  private async buildFlat(from: number, to: number): Promise<FlatPage[]> {
    this.chapPages.clear();
    this.chapTexts.clear();
    const out: FlatPage[] = [];
    for (let s = from; s <= to; s++) {
      const n: number = await this.loadChapter(s);
      if (n <= 0) {
        continue;
      }
      const res: PaginateResult | undefined = this.chapPages.get(s);
      if (res === undefined) {
        continue;
      }
      for (let p = 0; p < res.pages.length; p++) {
        out.push(new FlatPage(s, res.pages[p], `n-${s}-${p}`));
      }
    }
    return out;
  }

  /** 重建窗口：以 `spine` 为中心装 [spine-1 .. spine+1]，并定位到包含 `node` 的页 */
  private async rebuildWindow(spine: number, node: number, first: boolean): Promise<void> {
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

    const at: number = Math.max(0, this.indexOfNode(flat, target, node));
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
  private indexOfNode(flat: FlatPage[], spine: number, node: number): number {
    const res: PaginateResult | undefined = this.chapPages.get(spine);
    if (res === undefined || res.pages.length === 0) {
      return -1;
    }
    // 1) 章内页号：`pageOfNode` 是"该节点起始页"，直接查
    let local: number = -1;
    if (node >= 0 && node < res.pageOfNode.length) {
      local = res.pageOfNode[node];
    }
    if (local < 0) {
      // 该节点不渲染（空块）⇒ 往后找第一个渲染块（宁可粗略也不跳空）
      for (let i = Math.max(0, node); i < res.pageOfNode.length; i++) {
        if (res.pageOfNode[i] >= 0) {
          local = res.pageOfNode[i];
          break;
        }
      }
    }
    if (local < 0) {
      local = 0;
    }
    // 2) 章首页在扁平数组里的起点
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
    if (pg.segs.length === 0) {
      return;
    }
    const a: number[] = pg.segs[0];
    const b: number[] = pg.segs[pg.segs.length - 1];
    this.onPos(pg.spine, a[0], b[0] >= a[0] ? b[0] : a[0]);
  }  // ══════════════════════════════════════════════════════════════════════════
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
    const res: PaginateResult | undefined = this.chapPages.get(next);
    if (n <= 0 || res === undefined) {
      return;
    }
    const merged: FlatPage[] = this.flat.slice();
    for (let p = 0; p < res.pages.length; p++) {
      merged.push(new FlatPage(next, res.pages[p], `n-${next}-${p}`));
    }
    this.flat = merged;
    hilog.info(DOMAIN, TAG, 'appendNext spine=%{public}d pages=%{public}d total=%{public}d',
      next, res.pages.length, merged.length);
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
    const res: PaginateResult | undefined = this.chapPages.get(prev);
    if (n <= 0 || res === undefined) {
      return;
    }
    const shift: number = res.pages.length;
    const merged: FlatPage[] = [];
    for (let p = 0; p < shift; p++) {
      merged.push(new FlatPage(prev, res.pages[p], `n-${prev}-${p}`));
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
    const idx: number = this.indexOfNode(this.flat, spine, node);
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
    const nd: number = anchor !== null && anchor.segs.length > 0 ? anchor.segs[0][0] : this.initNode;
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
  private isHlSeg(seg: number[]): boolean {
    if (this.hlFrom < 0 || seg[0] !== this.hlNode) {
      return false;
    }
    if (this.pageIdx < 0 || this.pageIdx >= this.flat.length) {
      return false;
    }
    return this.flat[this.pageIdx].spine === this.hlSpine;
  }

  /**
   * 段渲染键：**高亮那一段**把句序号与字体代数拼进键里，逼 ArkUI 重建它 ——
   * 否则会复用旧组件、高亮不移动（与滚动层 `rowKey()` 同款做法）。
   */
  private segKey(seg: number[]): string {
    const base: string = `s-${seg[0]}-${seg[1]}-${seg[2]}-f${this.fontSerial}`;
    return this.isHlSeg(seg) ? `${base}-h${this.hlSerial}` : base;
  }

  /** 段文本（同步从本章缓存取，绝不 await） */
  private segText(seg: number[]): string {
    if (this.pageIdx < 0 || this.pageIdx >= this.flat.length) {
      return '';
    }
    const nodes: string[] | undefined = this.chapTexts.get(this.flat[this.pageIdx].spine);
    if (nodes === undefined) {
      return '';
    }
    const i: number = seg[0];
    if (i < 0 || i >= nodes.length) {
      return '';
    }
    return nodes[i].substring(seg[1], seg[2]);
  }

  @Builder
  SegView(seg: number[]) {
    if (this.isHlSeg(seg)) {
      Text() {
        Span(this.segText(seg).substring(0,
          Math.min(Math.max(0, this.hlFrom - seg[1]), this.segText(seg).length)))
        Span(this.segText(seg).substring(
          Math.min(Math.max(0, this.hlFrom - seg[1]), this.segText(seg).length),
          Math.min(Math.max(0, this.hlTo - seg[1]), this.segText(seg).length)))
          .textBackgroundStyle({ color: 'rgba(0, 125, 255, 0.20)', radius: 4 })
        Span(this.segText(seg).substring(
          Math.min(Math.max(0, this.hlTo - seg[1]), this.segText(seg).length)))
      }
      .fontSize(this.fontSize)
      .fontWeight(scrollFontWeight(this.fontWeight, this.weightOffset))
      .fontFamily(this.fontName)
      .fontColor(this.fontColor)
      .lineHeight(this.lineHeightFp)
      .textIndent(seg[1] === 0 ? this.indentFp : 0)
      // 两端对齐：与引擎内部 `textAlign: 2` 一致（见 `ReaderScrollView` 文件头取证）
      .textAlign(TextAlign.JUSTIFY)
      .width('100%')
      // 段间距：与上下滚动层同一系数
      .padding({ top: this.fontSize * this.gapEm })
    } else {
      Text(this.segText(seg))
        .fontSize(this.fontSize)
        .fontWeight(scrollFontWeight(this.fontWeight, this.weightOffset))
        .fontFamily(this.fontName)
        .fontColor(this.fontColor)
        .lineHeight(this.lineHeightFp)
        .textIndent(seg[1] === 0 ? this.indentFp : 0)
        .textAlign(TextAlign.JUSTIFY)
        .width('100%')
        .padding({ top: this.fontSize * this.gapEm })
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
          ForEach(this.curSegs(), (seg: number[]) => {
            this.SegView(seg)
          }, (seg: number[]): string => this.segKey(seg))
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

  /** 当前页切片（`pageIdx` 越界时给空数组） */
  private curSegs(): number[][] {
    if (this.pageIdx < 0 || this.pageIdx >= this.flat.length) {
      return [];
    }
    return this.flat[this.pageIdx].segs;
  }
}
