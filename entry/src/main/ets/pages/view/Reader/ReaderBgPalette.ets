/**
 * 阅读器「自定义背景色」的**无极调色盘**（2026-09-25 新增）。
 *
 * ── 它画的是什么 ──────────────────────────────────────────────────────────────
 * 三层线性渐变叠出来的**二维连续色域**（不是图片、不是 Canvas，全是声明式属性）：
 *   ① 底层：横向彩虹（色相 0→360°）—— `.linearGradient({ angle: 90, colors: [7 个色相停点] })`
 *   ② 上层-上半：白 → 透明      —— `.linearGradient({ angle: 180, colors: [白不透明, 白全透明] })`
 *   ③ 上层-下半：透明 → 黑      —— `.linearGradient({ angle: 180, colors: [黑全透明, 黑不透明] })`
 * 于是 `(x, y)` ↔ RGB 的映射是**闭式**的：横向定色相、纵向定"往白/往黑混多少"
 * （见 `ReaderCustomBg.paletteToRgb()`），**任意点都能取到确定颜色** ⇒ 真正的"无极"。
 *
 * ── 角度为什么是 90 / 180 ──────────────────────────────────────────────────────
 * SDK 原文（`…\ets\component\common.d.ts:3853-3873`，`LinearGradientOptions.angle`）：
 *   「Start angle of the linear gradient. **When the angle is 0 degrees, the gradient
 *     direction is from bottom to top** (that is, 0 o'clock direction). A positive value
 *     indicates a **clockwise** rotation from the origin, (0, 0). … Default value: **180**」
 * ⇒ 0° = 下→上，顺时针转 90° = **左→右**（色相横条），转 180° = **上→下**（明暗叠加）。
 *   同时注意同文件 `:3875-3877`：「**direction** … does not take effect when **angle** is set」
 *   ⇒ 这里只给 `angle`，不给 `direction`。
 *
 * ── 触摸坐标为什么直接除宽高就行 ────────────────────────────────────────────────
 * SDK 原文（同文件 `:9464-9477`，`TouchObject.x/y`）：
 *   「X/Y coordinate of the touch point in the **component coordinate system** based on the
 *     event-responsive component. Unit: **vp**.」
 * ⇒ `onTouch` 挂在色盘自己身上，`touches[0].x/y` 就是色盘内的 vp 坐标，
 *   而色盘宽高是固定常量 ⇒ 归一化 = `x / PALETTE_SIZE`。
 *
 * ── 与页面的分工 ──────────────────────────────────────────────────────────────
 * 本组件**不碰持久化、不碰 ReaderSetting**：只做"取色 → 回调"。
 * `onPick` 每次移动都回调（实时预览），`onCommit` 在抬手时回调（落盘时机由页面决定，
 * 避免拖动过程中每帧写一次 Preferences）。
 */
import { HapticTick } from '../../../common/utils/HapticTick';
import { ReaderCustomBg, RgbTriple } from '../../../common/utils/ReaderCustomBg';

/** 色盘边长（vp）。固定值 ⇒ 归一化坐标可以直接算，且与右侧 3 条 RGB 滑块同高。 */
const PALETTE_SIZE: number = 116;
/** 游标直径（vp） */
const MARKER_SIZE: number = 18;

@Component
export struct ReaderBgPalette {
  /** 当前 R/G/B（由页面单向传入；滑块改了颜色，游标就跟着走） */
  @Prop paletteR: number = 255;
  @Prop paletteG: number = 255;
  @Prop paletteB: number = 255;
  /** 拖动中实时回调（页面据此实时改 `themeColor` 并刷新阅读器） */
  onPick: (r: number, g: number, b: number) => void = (): void => {};
  /** 抬手回调（页面据此落盘） */
  onCommit: () => void = (): void => {};

  /** 色相彩虹的 7 个停点：红→黄→绿→青→蓝→品→红（首尾同色，保证 x=0 与 x=1 都是 0° 色相） */
  private hueStops(): Array<[ResourceColor, number]> {
    return [
      ['#FF0000', 0],
      ['#FFFF00', 1 / 6],
      ['#00FF00', 2 / 6],
      ['#00FFFF', 3 / 6],
      ['#0000FF', 4 / 6],
      ['#FF00FF', 5 / 6],
      ['#FF0000', 1]
    ];
  }

  private currentRgb(): RgbTriple {
    return ReaderCustomBg.make(this.paletteR, this.paletteG, this.paletteB);
  }

  /** 游标左上角位置（vp）：把归一化坐标换算成"圆心落在该点"的左上角 */
  private markerLeft(): number {
    const p = ReaderCustomBg.paletteMarker(this.currentRgb());
    return ReaderCustomBg.clamp01(p[0]) * PALETTE_SIZE - MARKER_SIZE / 2;
  }

  private markerTop(): number {
    const p = ReaderCustomBg.paletteMarker(this.currentRgb());
    return ReaderCustomBg.clamp01(p[1]) * PALETTE_SIZE - MARKER_SIZE / 2;
  }

  /**
   * 游标不透明度：色盘**画不出**的色（例如 RGB 滑块调出来的灰 `#808080`，
   * 或 `(128,64,64)` 这种 max≠255 且 min≠0 的色）只显示"最接近点"，
   * ⇒ 画淡一半，让用户看得出"当前色不在色盘上"，而不是以为游标就是精确值。
   * 阈值 6 的依据：色盘内颜色的往返误差 ≤ 2（实测最大 1.0），
   * 取 6 留出余量又远小于"离盘色"的实际距离（灰 #808080 实测 dist ≈ 181）。
   */
  private markerOpacity(): number {
    const p = ReaderCustomBg.paletteMarker(this.currentRgb());
    return p[2] <= 6 ? 1 : 0.45;
  }

  /** 一次取色：归一化 → RGB → 回调（带线性震动，与滑块同款节流） */
  private pickAt(x: number, y: number): void {
    const nx = ReaderCustomBg.clamp01(x / PALETTE_SIZE);
    const ny = ReaderCustomBg.clamp01(y / PALETTE_SIZE);
    const rgb = ReaderCustomBg.paletteToRgb(nx, ny);
    if (rgb.r === this.paletteR && rgb.g === this.paletteG && rgb.b === this.paletteB) {
      return;
    }
    HapticTick.tick();
    this.onPick(rgb.r, rgb.g, rgb.b);
  }

  build() {
    Stack() {
      // ── 色域本体（三层渐变）────────────────────────────────────────────────
      // ⚠️ 这里**不用 `.clip(true)`**：SDK 原文（`…\ets\component\common.d.ts:21196-21197`）
      //    「`@deprecated since 12` / `@useinstead CommonMethod#clipShape`」
      //    ⇒ 新代码不该再引入一个废弃 API。改用**逐层自带的圆角**：
      //      底层四角全圆，上半只圆上两角、下半只圆下两角 —— 视觉与"裁剪成圆角矩形"完全一致。
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(10)
          .linearGradient({ angle: 90, colors: this.hueStops() })

        // 上下两半的明暗叠加（放在同一个 Column 里各占一半高度）
        Column() {
          Column()
            .width('100%')
            .layoutWeight(1)
            .borderRadius({ topLeft: 10, topRight: 10 })
            .linearGradient({
              angle: 180,
              colors: [['rgba(255,255,255,1)', 0], ['rgba(255,255,255,0)', 1]]
            })
          Column()
            .width('100%')
            .layoutWeight(1)
            .borderRadius({ bottomLeft: 10, bottomRight: 10 })
            .linearGradient({
              angle: 180,
              colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,1)', 1]]
            })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')

      // ── 游标：白圈 + 当前色内芯（任何底色上都看得见）────────────────────────
      Stack() {
        Column()
          .width(MARKER_SIZE)
          .height(MARKER_SIZE)
          .borderRadius(MARKER_SIZE / 2)
          .backgroundColor('#FFFFFF')
        Column()
          .width(MARKER_SIZE - 6)
          .height(MARKER_SIZE - 6)
          .borderRadius((MARKER_SIZE - 6) / 2)
          .backgroundColor(ReaderCustomBg.hexOf(this.currentRgb()))
          .borderWidth(1)
          .borderColor('rgba(0,0,0,0.25)')
      }
      .width(MARKER_SIZE)
      .height(MARKER_SIZE)
      // position = 相对父容器左上角的绝对定位（不影响其它子节点布局）
      .position({ x: this.markerLeft(), y: this.markerTop() })
      // 离盘色画淡（见 `markerOpacity()`）
      .opacity(this.markerOpacity())
    }
    .width(PALETTE_SIZE)
    .height(PALETTE_SIZE)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down || e.type === TouchType.Move) {
        const list = (e.touches !== undefined && e.touches.length > 0) ? e.touches : e.changedTouches;
        if (list !== undefined && list.length > 0) {
          this.pickAt(list[0].x, list[0].y);
        }
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.onCommit();
      }
    })
  }
}
