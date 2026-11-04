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
import { EngineLine, LineStyle, buildPaintParagraph, engineSourceText } from './EngineLines';

const TAG: string = 'NoAnimCanvas';
const DOMAIN: number = 0x0000;

@Component
export struct ReaderPageNoAnimCanvas {
  /** 当前页的行（父页 `flat[pageIdx].lines`，与分页同一份数据） */
  @Prop @Watch('onSourceChange') lines: EngineLine[] = [];
  /** 分页用的同一份排版参数（父页 `buildLineStyle()` 产物：宽/字号/字距/strut 全在里面） */
  @Prop @Watch('onSourceChange') style: LineStyle = new LineStyle();
  /** 段落全文提供者（父页 chapTexts）——直绘必须用**整段**文本重排，断行才与分页一致 */
  paraText: (paraIndex: number) => string = (paraIndex: number): string => '';
  @Prop @Watch('onSourceChange') fontColor: string = '#000000';
  @Prop @Watch('onSourceChange') bgColor: string = '#FFFFFF';
  @Prop bgUri: string = '';
  @Prop @Watch('onSourceChange') topInsetVp: number = 0;
  @Prop @Watch('onSourceChange') bottomInsetVp: number = 0;
  @Prop @Watch('onSourceChange') sideInsetVp: number = 20;
  /** 页容器尺寸（vp，父页实测缓存；Canvas 节点 100%×100%，像素图按其 px 尺寸建） */
  @Prop @Watch('onSourceChange') containerWvp: number = 0;
  @Prop @Watch('onSourceChange') containerHvp: number = 0;

  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private pixelMap: image.PixelMap | null = null;
  private pmWpx: number = 0;
  private pmHpx: number = 0;
  private pending: boolean = false;

  private vp2px(v: number): number {
    return this.getUIContext().vp2px(v);
  }

  onSourceChange(): void {
    this.requestRepaint();
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onAreaChange((_old: Area, n: Area) => {
        this.onSize(Number(n.width), Number(n.height));
      })
      .onReady(() => {
        this.requestRepaint();
      })
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
    if (this.bgUri.length > 0) {
      hilog.warn(DOMAIN, TAG, '[CANVASPROBE] bgUri 未支持（PoC 只画纯色底）');
    }
    const t0: number = Date.now();
    const cv: drawing.Canvas = new drawing.Canvas(pm);
    this.fillBg(cv);
    const topPx: number = this.vp2px(this.topInsetVp);
    const xPx: number = this.vp2px(this.sideInsetVp);
    let yPx: number = topPx;
    let i: number = 0;
    let runCount: number = 0;
    let okRuns: number = 0;
    while (i < lines.length) {
      const first: EngineLine = lines[i];
      let j: number = i + 1;
      while (j < lines.length && lines[j].paraIndex === first.paraIndex) {
        j++;
      }
      // run = lines[i..j)：同一段的连续行；行带 = [yPx, yPx+advance)，与分页同一算术
      let advance: number = 0;
      for (let k = i; k < j; k++) {
        advance += lines[k].heightPx + lines[k].padTopPx;
      }
      if (this.paintRun(cv, lines, i, j, xPx, yPx, yPx + advance) > 0) {
        okRuns++;
      }
      yPx += advance;
      i = j;
      runCount++;
    }
    // 上屏：像素图（px）1:1 贴到 Canvas（vp 区域）
    this.ctx.clearRect(0, 0, this.containerWvp, this.containerHvp);
    this.ctx.drawImage(pm, 0, 0, this.containerWvp, this.containerHvp);
    hilog.info(DOMAIN, TAG,
      '[CANVASPROBE] paint lines=%{public}d runs=%{public}d ok=%{public}d yEnd=%{public}s 耗时%{public}dms',
      lines.length, runCount, okRuns, yPx.toFixed(1), Date.now() - t0);
  }

  /**
   * 画一个 run（同段连续行 `[from..to)`）：**整段 paint + 行带裁剪**。
   *
   * ⚠️ 为什么不用 `TextLine.paint` 逐行画：真机实测（2026-11-05）`TextLine.paint(cv,x,y)`
   *    虽然文档写「(x,y) = 行框左上角」，实际字形落在 `painted + 段内自然位置`
   *    （行距呈 2:1 交替错乱，截图 `_dsh_shots/2026-11-05-stage0/poc-C.png`）。
   *    `Paragraph.paint` 是整段标准语义（段落顶 = (x,y)），配合裁剪只暴露本页行带。
   *
   * 落位算式：段落顶 y = `glyphTop − natY(k1)`，其中 natY(k1) = 段内前 k1 行行高累加。
   *    该式**自消去**——paint 内部行 k 的字形顶 = y + natY(k)，代回得
   *    glyphTop − natY(k1) + natY(k1) = glyphTop，与 natY 的取值无关（哪怕它有怪癖）。
   * 裁剪带 = `[yTopPx, yNextTopPx)`（本 run 的节点带，含首行段前距；与老 Text 树节点带一致）。
   * 返回画出的行数；≤0 = 匹配失败（PoC 记录并跳过）。
   */
  private paintRun(cv: drawing.Canvas, lines: EngineLine[], from: number, to: number,
    xPx: number, yTopPx: number, yNextTopPx: number): number {
    const first: EngineLine = lines[from];
    const raw: string = this.paraText(first.paraIndex);
    if (raw.length === 0) {
      hilog.warn(DOMAIN, TAG, '[CANVASPROBE] 段文本缺失 para=%{public}d', first.paraIndex);
      return -1;
    }
    const src: string = engineSourceText(raw, first.isTitle);
    const para: text.Paragraph = buildPaintParagraph(src, this.style, first.isTitle);
    const metrics: text.LineMetrics[] = para.getLineMetrics();
    const indentLen: number = first.isTitle ? 0 : 2;
    // 匹配 k1：页首行的 charFrom（段内偏移，不含缩进）落在重排段落的哪一行
    const want: number = first.charFrom + indentLen;
    let k1: number = -1;
    for (let k = 0; k < metrics.length; k++) {
      if (want >= metrics[k].startIndex && want < metrics[k].endIndex) {
        k1 = k;
        break;
      }
    }
    const runLen: number = to - from;
    if (k1 < 0 || k1 + runLen > metrics.length) {
      hilog.warn(DOMAIN, TAG,
        '[CANVASPROBE] 行匹配失败 para=%{public}d charFrom=%{public}d runLen=%{public}d 引擎行数=%{public}d k1=%{public}d',
        first.paraIndex, first.charFrom, runLen, metrics.length, k1);
      return -1;
    }
    let natY: number = 0;
    for (let k = 0; k < k1; k++) {
      natY += para.getLineHeight(k);
    }
    // 本 run 首行字形顶 = 节点顶 + 段前距（与老 Text 树：字形在节点顶 + padding 处一致）
    const glyphTop: number = yTopPx + lines[from].padTopPx;
    cv.save();
    cv.clipRect({ left: 0, top: yTopPx, right: this.pmWpx, bottom: yNextTopPx });
    para.paint(cv, xPx, glyphTop - natY);
    cv.restore();
    hilog.info(DOMAIN, TAG,
      '[CANVASPROBE] run para=%{public}d k1=%{public}d n=%{public}d band=[%{public}s,%{public}s) glyphTop=%{public}s natY=%{public}s',
      first.paraIndex, k1, runLen, yTopPx.toFixed(1), yNextTopPx.toFixed(1),
      glyphTop.toFixed(1), natY.toFixed(1));
    return runLen;
  }

  private fillBg(cv: drawing.Canvas): void {
    const brush: drawing.Brush = new drawing.Brush();
    brush.setColor(parseHexColor(this.bgColor));
    cv.attachBrush(brush);
    cv.drawRect({ left: 0, top: 0, right: this.pmWpx, bottom: this.pmHpx });
    cv.detachBrush();
  }
}

/** '#RGB' / '#RRGGBB' / '#AARRGGBB' → common2D.Color；非法输入回退白底 */
function parseHexColor(s: string): common2D.Color {
  const fail: common2D.Color = { alpha: 255, red: 255, green: 255, blue: 255 };
  if (s.length < 4 || s.charAt(0) !== '#') {
    return fail;
  }
  const hex: string = s.substring(1);
  if (hex.length === 3) {
    const r = parseInt(hex.charAt(0) + hex.charAt(0), 16);
    const g = parseInt(hex.charAt(1) + hex.charAt(1), 16);
    const b = parseInt(hex.charAt(2) + hex.charAt(2), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return fail;
    }
    return { alpha: 255, red: r, green: g, blue: b };
  }
  if (hex.length !== 6 && hex.length !== 8) {
    return fail;
  }
  let alpha = 255;
  let idx = 0;
  if (hex.length === 8) {
    alpha = parseInt(hex.substring(0, 2), 16);
    idx = 2;
  }
  const r2 = parseInt(hex.substring(idx, idx + 2), 16);
  const g2 = parseInt(hex.substring(idx + 2, idx + 4), 16);
  const b2 = parseInt(hex.substring(idx + 4, idx + 6), 16);
  if (isNaN(alpha) || isNaN(r2) || isNaN(g2) || isNaN(b2)) {
    return fail;
  }
  return { alpha: alpha, red: r2, green: g2, blue: b2 };
}