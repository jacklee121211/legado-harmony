/**
 * 无动画档**引擎直绘 PoC**（2026-11-05 阶段 1；只画字，不接任何交互）。
 *
 * 目的：证明「排版引擎自己画」与「现 ArkUI Text 树渲染」**逐像素等价** ——
 * 等价成立后（阶段 2），"算一套画一套"的三个接缝（横向断行/纵向计价/参数时序）
 * 从物理上消失，松弛与折行绊线都不再需要。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 架构（SDK 声明已核实，全部 @since ≤ 20，API 20 设备可用）
 * ══════════════════════════════════════════════════════════════════════════
 *   `image.createPixelMap` 后备像素图
 *     → `new drawing.Canvas(pixelMap)`（`@ohos.graphics.drawing.d.ts` 中 `Canvas`
 *        **只有** PixelMap 构造器，没有 CanvasRenderingContext2D 包装）
 *     → 段落**同参重排**（`buildPaintParagraph`，与分页同一份 `LineStyle`）
 *     → `Paragraph.getTextLines()`（@since 12）
 *     → `TextLine.paint(canvas, x, y)` **逐行**画进像素图（无需 clipRect）
 *     → ArkUI `Canvas.drawImage(pixelMap, 0, 0, wVp, hVp)` 1:1 上屏。
 *
 * 为什么逐行 paint 而不是整段 paint+裁剪：段落内行 y 用 `getLineHeight` 累加即可，
 * 天然只画本页的行区间（页首是段落中段时从 k1 起画），零裁剪、零越界。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 与现渲染的对齐契约（PoC 验收判据）
 * ══════════════════════════════════════════════════════════════════════════
 *   · 断行：与分页同一份 `LineStyle`（同宽/同字号/同字距/同 strut）⇒ 逐字一致；
 *   · 行 y：逐行累加 `heightPx + padTopPx`（与 `paginateLines` 同一算术），
 *     行内 y 用 `getLineHeight` 累加（不依赖"每行等高"假设）；
 *   · 行 x：左 inset（与 Text 树同锚点）；右松弛对直绘无意义（引擎永不二次折行）；
 *   · 缩进：源文本带 `\u3000\u3000` 前缀（`engineSourceText`，与分页同一条规则）；
 *   · [CANVASPROBE] 打印每次绘制的 run/k1/y，与老渲染 dump 的行 y 对比。
 *
 * ⚠️ PoC 边界：背景图（bgUri）未支持（仅纯色底，打日志说明）；高亮/气泡/手势不接。
 */

import { image } from '@kit.ImageKit';
import { drawing, text, common2D } from '@kit.ArkGraphics2D';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EngineLine, LineStyle, buildPaintParagraph, parseHexColor, LETTER_SPACING_FP } from './EngineLines';

const TAG: string = 'NoAnimCanvas';
const DOMAIN: number = 0x0000;

@Component
export struct ReaderPageNoAnimCanvas {
  /** 当前页的行（父页 `flat[pageIdx].lines`，与分页同一份数据） */
  @Prop @Watch('onSourceChange') lines: EngineLine[] = [];
  /** 分页用的同一份排版参数（父页 `buildLineStyle()` 产物：宽/字号/字距/strut 全在里面） */
  @Prop @Watch('onSourceChange') style: LineStyle = new LineStyle();
  /** 段落全文提供者（父页 chapTexts）——行缓存构建时取段原文（异常兜底用） */
  paraText: (paraIndex: number) => string = (_pi: number): string => '';
  @Prop @Watch('onSourceChange') fontColor: string = '#000000';
  @Prop @Watch('onSourceChange') bgColor: string = '#FFFFFF';
  /** 背景图 URI（'' = 纯色底）；异步加载，完成后重绘（cover 居中裁剪，与老树 ImageCover 同观感） */
  @Prop @Watch('onBgUriChange') bgUri: string = '';
  @Prop @Watch('onSourceChange') topInsetVp: number = 0;
  @Prop @Watch('onSourceChange') bottomInsetVp: number = 0;
  @Prop @Watch('onSourceChange') sideInsetVp: number = 20;
  /** 页容器尺寸（vp，父页实测缓存；Canvas 节点 100%×100%，像素图按其 px 尺寸建） */
  @Prop @Watch('onSourceChange') containerWvp: number = 0;
  @Prop @Watch('onSourceChange') containerHvp: number = 0;
  // ── 阶段 2：TTS 高亮（父页算好"本页是否命中"再传：hlPara = 本页命中的段号，-1 = 无）──
  @Prop @Watch('onHighlightChange') hlPara: number = -1;
  @Prop @Watch('onHighlightChange') hlFrom: number = -1;
  @Prop @Watch('onHighlightChange') hlTo: number = -1;
  /** 朗读句切换代数：同段内 from/to 不变也要重画高亮 ⇒ 父页每句 +1 */
  @Prop @Watch('onHighlightChange') hlSerial: number = 0;

  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  /** 高亮层（阶段 2）：独立 Canvas，透明底；句切换只重画这一层，正文不重排不重绘 */
  private hlCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private pixelMap: image.PixelMap | null = null;
  private pmWpx: number = 0;
  private pmHpx: number = 0;
  private pending: boolean = false;
  /**
   * 行缓存（正文 repaint 时填写）：行级 Paragraph 与落位（px）。
   * ⚠️ 直绘逐行 justify（2026-11-05）：每行**单独**排一个单行 Paragraph——
   *    非段末行按「可用宽 − 引擎行自然宽(widthPx) − 2px」摊回字距，行尾顶到边；
   *    行箱 layout 宽给 avail+SLACK，单行内容物理上不可能二次折行（直绘专属安全性）。
   *    度量闭环：widthPx 与补偿后的绘制同属一个引擎，无跨引擎度量差。
   * 高亮层复用同一批实例做 `getRectsForRange`（区间映射到行内偏移）。
   * 数组下标 = 页内行序（与父页 lines 一一对应）。
   */
  private rowCache: (RowEntry | null)[] = [];
  /** 背景图（bgUri 异步解码产物；null = 无图/加载中/失败 → 纯色底） */
  private bgPixelMap: image.PixelMap | null = null;
  /** 背景图原始尺寸（cover 裁剪算 srcRect 用） */
  private bgW: number = 0;
  private bgH: number = 0;

  private vp2px(v: number): number {
    return this.getUIContext().vp2px(v);
  }

  aboutToAppear(): void {
    // @Prop 初值不触发 @Watch：挂载时若已带背景图 URI，这里补一次加载
    if (this.bgUri.length > 0) {
      this.loadBg();
    }
  }

  onSourceChange(): void {
    this.requestRepaint();
  }

  /** 句切换 / 高亮区间变化 ⇒ 只重画顶层（正文零重排零重绘，双分层的意义） */
  onHighlightChange(): void {
    this.repaintHighlight();
  }

  /** 背景图 URI 变化 ⇒ 异步解码（完成/失败都重绘：失败回落纯色底） */
  onBgUriChange(): void {
    this.loadBg();
  }

  private loadBg(): void {
    const uri: string = this.bgUri;
    if (uri.length === 0) {
      this.bgPixelMap = null;
      this.bgW = 0;
      this.bgH = 0;
      this.requestRepaint();
      return;
    }
    image.createImageSource(uri).createPixelMap().then((pm: image.PixelMap) => {
      // URI 已变（快速切主题/换图）⇒ 丢弃过期解码结果
      if (uri !== this.bgUri) {
        return;
      }
      this.bgPixelMap = pm;
      pm.getImageInfo().then((info: image.ImageInfo) => {
        this.bgW = info.size.width > 0 ? info.size.width : 0;
        this.bgH = info.size.height > 0 ? info.size.height : 0;
        this.requestRepaint();
      }).catch((): void => {
        this.requestRepaint();
      });
    }).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, '[CANVASPROBE] 背景图解码失败 %{public}s: %{public}s',
        uri, e instanceof Error ? e.message : String(e));
      this.bgPixelMap = null;
      this.requestRepaint();
    });
  }

  build() {
    Stack() {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .onAreaChange((_old: Area, n: Area) => {
          this.onSize(Number(n.width), Number(n.height));
        })
        .onReady(() => {
          this.requestRepaint();
        })
      Canvas(this.hlCtx)
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .onReady(() => {
          this.repaintHighlight();
        })
    }
  }

  /** 容器尺寸变化 ⇒ 重建后备像素图（尺寸没变不重建） */
  private onSize(wVp: number, hVp: number): void {
    if (wVp <= 0 || hVp <= 0) {
      return;
    }
    const wPx: number = Math.round(this.vp2px(wVp));
    const hPx: number = Math.round(this.vp2px(hVp));
    if (wPx === this.pmWpx && hPx === this.pmHpx && this.pixelMap !== null) {
      return;
    }
    this.pmWpx = wPx;
    this.pmHpx = hPx;
    this.createPixelMap(wPx, hPx);
  }

  private createPixelMap(wPx: number, hPx: number): void {
    const buf: ArrayBuffer = new ArrayBuffer(wPx * hPx * 4);
    const opts: image.InitializationOptions = {
      size: { width: wPx, height: hPx },
      srcPixelFormat: image.PixelMapFormat.BGRA_8888
    };
    image.createPixelMap(buf, opts).then((pm: image.PixelMap) => {
      this.pixelMap = pm;
      this.requestRepaint();
    }).catch((): void => {
      this.pixelMap = null;
      hilog.warn(DOMAIN, TAG, '[CANVASPROBE] createPixelMap failed %{public}dx%{public}d', wPx, hPx);
    });
  }

  /** 合并重绘请求：@Watch 风暴 / 尺寸风暴只画最后一帧 */
  private requestRepaint(): void {
    if (this.pending) {
      return;
    }
    this.pending = true;
    setTimeout((): void => {
      this.pending = false;
      this.repaint();
    }, 0);
  }

  private repaint(): void {
    const pm: image.PixelMap | null = this.pixelMap;
    if (pm === null || this.pmWpx <= 0 || this.pmHpx <= 0) {
      return;
    }
    const lines: EngineLine[] = this.lines;
    if (lines.length === 0) {
      return;
    }
    const t0: number = Date.now();
    const cv: drawing.Canvas = new drawing.Canvas(pm);
    this.fillBg(cv);
    // 背景图：纯色底之上 cover 居中裁剪（等比放大至覆盖、裁掉溢出边缘），与老树 ImageCover 同观感
    const bg: image.PixelMap | null = this.bgPixelMap;
    if (bg !== null && this.bgW > 0 && this.bgH > 0) {
      const scale: number = Math.max(this.pmWpx / this.bgW, this.pmHpx / this.bgH);
      const srcW: number = this.pmWpx / scale;
      const srcH: number = this.pmHpx / scale;
      const srcX: number = (this.bgW - srcW) / 2;
      const srcY: number = (this.bgH - srcH) / 2;
      cv.drawImageRectWithSrc(bg,
        { left: srcX, top: srcY, right: srcX + srcW, bottom: srcY + srcH },
        { left: 0, top: 0, right: this.pmWpx, bottom: this.pmHpx });
    }
    // 页内容变化 ⇒ 行缓存整体重建（下标 = 页内行序；高亮层复用同一批实例）
    this.rowCache = new Array<(RowEntry | null)>(lines.length).fill(null);
    const topPx: number = this.vp2px(this.topInsetVp);
    const xPx: number = this.vp2px(this.sideInsetVp);
    // 排版箱宽（px）：与分页同一个数（style.widthPx = vp2px(areaW)）
    const boxPx: number = this.style.widthPx > 0 ? this.style.widthPx : 1;
    let yPx: number = topPx;
    let painted: number = 0;
    let justRows: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const line: EngineLine = lines[i];
      // 段末行判定：下一行不同段 / 页内最后一行 —— 段末行保持自然（不补偿）
      const isParaEnd: boolean = (i + 1 >= lines.length) || (lines[i + 1].paraIndex !== line.paraIndex);
      const entry: RowEntry | null = this.paintLine(cv, line, xPx, yPx, boxPx, isParaEnd);
      if (entry !== null) {
        this.rowCache[i] = entry;
        painted++;
        if (entry.justified) {
          justRows++;
        }
      }
      yPx += line.heightPx + line.padTopPx;
    }
    // 上屏：像素图（px）1:1 贴到 Canvas（vp 区域）
    this.ctx.clearRect(0, 0, this.containerWvp, this.containerHvp);
    this.ctx.drawImage(pm, 0, 0, this.containerWvp, this.containerHvp);
    hilog.info(DOMAIN, TAG,
      '[CANVASPROBE] paint lines=%{public}d ok=%{public}d just=%{public}d yEnd=%{public}s 耗时%{public}dms',
      lines.length, painted, justRows, yPx.toFixed(1), Date.now() - t0);
    this.repaintHighlight();
  }

  /**
   * 重画高亮层：透明底清空后，遍历**行缓存**，命中段与行区间的交集映射到行内偏移，
   * 用**该行的 Paragraph** 取矩形叠画（逐行 justify 后矩形与补偿字形同源同位）。
   * 老树高亮色 `rgba(0,125,255,0.20)`；radius 4 在 20% 透明度下不可辨，先 fillRect（记档）。
   */
  private repaintHighlight(): void {
    this.hlCtx.clearRect(0, 0, this.containerWvp, this.containerHvp);
    if (this.hlPara < 0 || this.hlFrom < 0 || this.hlTo <= this.hlFrom) {
      return;
    }
    const xPx: number = this.vp2px(this.sideInsetVp);
    this.hlCtx.fillStyle = 'rgba(0,125,255,0.20)';
    let boxSeq: number = 0;
    for (let i = 0; i < this.rowCache.length; i++) {
      const entry: RowEntry | null = this.rowCache[i];
      if (entry === null || entry.line === null || entry.para === null) {
        continue;
      }
      const line: EngineLine = entry.line;
      if (line.paraIndex !== this.hlPara) {
        continue;
      }
      // 段内偏移交集 → 行内偏移（行文本含缩进前缀：首行 +prefixLen）
      const from: number = Math.max(this.hlFrom, line.charFrom);
      const to: number = Math.min(this.hlTo, line.charTo);
      if (from >= to) {
        continue;
      }
      const rStart: number = from - line.charFrom + line.prefixLen;
      const rEnd: number = to - line.charFrom + line.prefixLen;
      let boxes: text.TextBox[] = [];
      try {
        boxes = entry.para.getRectsForRange({ start: rStart, end: rEnd },
          text.RectWidthStyle.TIGHT, text.RectHeightStyle.TIGHT);
      } catch (e) {
        continue;
      }
      for (let b = 0; b < boxes.length; b++) {
        const r: common2D.Rect = boxes[b].rect;
        const xVp: number = this.px2vp(xPx + r.left);
        const yVp: number = this.px2vp(entry.paintY + r.top);
        const wVp: number = this.px2vp(r.right - r.left);
        const hVp: number = this.px2vp(r.bottom - r.top);
        this.hlCtx.fillRect(xVp, yVp, wVp, hVp);
        boxSeq++;
      }
    }
    if (boxSeq > 0) {
      hilog.info(DOMAIN, TAG, '[CANVASPROBE] hl boxes=%{public}d para=%{public}d', boxSeq, this.hlPara);
    }
  }

  private px2vp(v: number): number {
    const d: number = this.vp2px(1);
    return d > 0 ? v / d : v;
  }

  /**
   * 画一行（直绘逐行 justify 核心）：
   * · 行文本 = `line.text`（引擎切片，含缩进前缀）——内容不变，只调字距；
   * · 非段末/非标题行：`addPx = (排版箱 − 引擎行自然宽(widthPx) − 2px) ÷ 全行字符数`
   *   （分母含前缀：字距作用于全部字符；上限 1.2 字宽）→ 行尾顶到边；
   * · 行箱 layout 宽 = 排版箱 + SLACK：**单行内容物理上不可能二次折行**（直绘专属安全性）；
   * · 度量闭环：widthPx 与绘制同属一个引擎，无跨引擎度量差。
   * paint y = 节点顶 + 段前距（单行段落顶 = 行框顶，无 TextLine.paint 的自然位置坑）。
   * 返回行缓存条目；null = 段文本缺失/排版失败（跳过该行）。
   */
  private paintLine(cv: drawing.Canvas, line: EngineLine, xPx: number, yTopPx: number,
    boxPx: number, isParaEnd: boolean): RowEntry | null {
    const raw: string = this.paraText(line.paraIndex);
    if (raw.length === 0) {
      hilog.warn(DOMAIN, TAG, '[CANVASPROBE] 段文本缺失 para=%{public}d', line.paraIndex);
      return null;
    }
    // 逐行 justify（基线 = 引擎自量的本行自然宽）
    let lsFp: number = LETTER_SPACING_FP;
    let justified: boolean = false;
    if (!isParaEnd && !line.isTitle && line.widthPx > 0 && line.text.length >= 2) {
      const deltaPx: number = boxPx - line.widthPx - 2;
      if (deltaPx > 0) {
        const limitPx: number = this.style.fontSizePx * 1.2;
        const addPx: number = Math.min(deltaPx, limitPx) / line.text.length;
        const d: number = this.fp2px(1);
        lsFp = LETTER_SPACING_FP + (d > 0 ? addPx / d : addPx);
        justified = true;
      }
    }
    // 单行样式：同参 clone + 行箱余量 + 行字距
    const rowStyle: LineStyle = cloneLineStyle(this.style);
    rowStyle.widthPx = boxPx + ROW_BOX_SLACK_PX;
    rowStyle.letterSpacingPx = this.fp2px(lsFp);
    const para: text.Paragraph = buildPaintParagraph(line.text, rowStyle, line.isTitle);
    if (para.getLineCount() <= 0) {
      return null;
    }
    // 字形顶 = 节点顶 + 段前距；裁剪带 = 分页计价的同一个行带（padTop + heightPx）
    const paintY: number = yTopPx + line.padTopPx;
    cv.save();
    cv.clipRect({ left: 0, top: yTopPx, right: this.pmWpx, bottom: yTopPx + line.padTopPx + line.heightPx });
    para.paint(cv, xPx, paintY);
    cv.restore();
    const entry: RowEntry = new RowEntry();
    entry.para = para;
    entry.paintY = paintY;
    entry.line = line;
    entry.justified = justified;
    return entry;
  }

  private fp2px(v: number): number {
    return this.getUIContext().fp2px(v);
  }

  private fillBg(cv: drawing.Canvas): void {
    const brush: drawing.Brush = new drawing.Brush();
    brush.setColor(parseHexColor(this.bgColor));
    cv.attachBrush(brush);
    cv.drawRect({ left: 0, top: 0, right: this.pmWpx, bottom: this.pmHpx });
    cv.detachBrush();
  }
}

/** 行箱横向余量（px）：layout 宽 = 排版箱 + 此值 ⇒ 单行内容永不折行 */
const ROW_BOX_SLACK_PX: number = 16;

/** 行缓存条目（高亮层与正文共用同一 Paragraph 实例） */
class RowEntry {
  /** 该行的单行 Paragraph（已按补偿后字距 layout；补偿公式见 paintLine） */
  para: text.Paragraph | null = null;
  /** 该行的 paint y（px，节点顶 + 段前距） */
  paintY: number = 0;
  /** 行对象（高亮映射：charFrom/charTo/prefixLen/isTitle） */
  line: EngineLine | null = null;
  /** 本行是否做了字距补偿（段末行/标题行为 false） */
  justified: boolean = false;
}

/** LineStyle 逐字段拷贝（class 无结构化克隆；漏字段 = 隐蔽排版分叉，新增字段必须同步） */
function cloneLineStyle(s: LineStyle): LineStyle {
  const c: LineStyle = new LineStyle();
  c.fontSizePx = s.fontSizePx;
  c.lineHeightPx = s.lineHeightPx;
  c.indentSlots = s.indentSlots;
  c.gapPx = s.gapPx;
  c.widthPx = s.widthPx;
  c.pageHeightPx = s.pageHeightPx;
  c.fontFamily = s.fontFamily;
  c.fontWeight = s.fontWeight;
  c.fontPath = s.fontPath;
  c.titleFontScale = s.titleFontScale;
  c.letterSpacingPx = s.letterSpacingPx;
  c.titleWeight = s.titleWeight;
  c.color = s.color;
  return c;
}