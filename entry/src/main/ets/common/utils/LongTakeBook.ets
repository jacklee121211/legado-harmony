import { UIContext } from '@kit.ArkUI'
import { image } from '@kit.ImageKit'

/**
 * 一镜到底（书架 → 阅读器）· 飞行数据与几何 —— 2026-09-23
 *
 * ── 它是什么 ──────────────────────────────────────────────────────────────
 * 点书架封面时在这里「拍照」：封面在窗口里的矩形、圆角、图源、窗口尺寸。
 * 数据随路由参数（`ReaderRouteParam.longTake`）一起进阅读页，
 * `Index.ets` 的 `customTransition` delegate 用它推导全部动画初值（`LongTakeGeom`），
 * 进场与返回**共用同一份几何** ⇒ 返回必然回到原位。
 *
 * ── 几何模型（已用三方库真机日志逐位验证 5/5，见 docs/shelf-to-reader-longtake-spec.md §5.3）──
 * 飞行的"书"= 一个与窗口同尺寸的容器，套三层各司其职的变换：
 *   外层 translate(tx0, ty0) → 中层 scale(s0, 锚点 (0,0)) → 内层 clip(0,0,100%,clipH0)
 *   ⇒ 首帧：可见"书脸" = 封面矩形（位置、大小、圆角全对齐）；
 *   终态：s=1 / t=(0,0) / clip=100% ⇒ 正好是全屏阅读器，正文全程不重排（只动图形变换）。
 * 其中 clipH0 = 封面高 × 窗宽 / 封面宽 —— 专门选的一刀，保证"书脸"纵横比与封面**完全一致**，
 * 于是封面图直接铺满容器也不变形。
 *
 * ── 证据 ──────────────────────────────────────────────────────────────────
 * · `getRectangleById` 返回 `ComponentInfo`：`size`（px）+ `windowOffset`（相对窗口，px）
 *   （SDK `@ohos.arkui.componentUtils.d.ts:34-107`）。⚠️ 没有现成的 left/top 扁平字段，
 *   也没有 `cornerRadius` —— 三方库日志里的圆角是它调用方传参进来的，
 *   所以这里同样由调用方（列表 4vp / 宫格 10vp）换算成 px 传入。
 * · 查不到组件（id 失效 / 列表刚重建）时 `getRectangleById` 抛异常 ⇒ capture 返回 null，
 *   调用方退回普通转场（不阻塞点书）。
 * · 窗口尺寸借书架根节点 `main`（`Index.ets` 里 `.id('main')`，占满窗口）量得。
 */
export class LongTakeFlightData {
  /** 封面矩形（窗口坐标，px） */
  coverLeftPx: number = 0
  coverTopPx: number = 0
  coverWidthPx: number = 0
  coverHeightPx: number = 0
  /** 封面圆角（px）。渲染圆角 = 本地圆角 × 缩放，首帧与书架封面视觉一致 */
  radiusPx: number = 0
  /** 封面图源（与书架同源 ⇒ 命中图片缓存） */
  coverUrl: string = ''
  /** 窗口尺寸（px，借 'main' 量得） */
  winWidthPx: number = 0
  winHeightPx: number = 0
  /**
   * 书架定格快照（2026-09-23 五轮新增）。点击瞬间把整个书架截成一张图，
   * 垫在飞行书的底下当"世界"：系统中途会隐藏/恢复书架 NavBar（真机实测），
   * 原先露出来的是黑虚空（用户反馈"右侧有黑色区域，像遮罩"）——
   * 现在露出的是这张和真书架像素级一致的定格图，进出全程无缝。
   * 持有到返回动画结束（onDisAppear 清空），约一整屏内存（1320×2848×4 ≈ 15MB）。
   */
  backdrop: image.PixelMap | null = null
  /** 仅日志用 */
  bookName: string = ''

  /**
   * 点击那一刻拍下封面几何。任何一步失败都返回 null ⇒ 调用方走普通转场。
   *
   * @param ui          UIContext（组件内 `this.getUIContext()`）
   * @param componentId 封面节点的 `.id()`（列表/宫格各自生成，见 BookContent）
   * @param radiusPx    封面圆角（px，调用方已按 vp→px 换算）
   * @param coverUrl    封面图源
   * @param bookName    日志用书名
   */
  static capture(ui: UIContext, componentId: string, radiusPx: number,
    coverUrl: string, bookName: string): LongTakeFlightData | null {
    try {
      const info = ui.getComponentUtils().getRectangleById(componentId)
      const win = ui.getComponentUtils().getRectangleById('main')
      const f = new LongTakeFlightData()
      f.coverLeftPx = info.windowOffset.x
      f.coverTopPx = info.windowOffset.y
      f.coverWidthPx = info.size.width
      f.coverHeightPx = info.size.height
      f.radiusPx = radiusPx
      f.coverUrl = coverUrl
      f.winWidthPx = win.size.width
      f.winHeightPx = win.size.height
      f.bookName = bookName
      // 书架定格快照：等渲染完再截（SDK 原文建议开启 waitUntilRenderFinished），
      // 失败不阻塞点书（返回 null 由调用方走普通转场；成功则垫底当"世界"）
      try {
        f.backdrop = ui.getComponentSnapshot().getSync('main', { waitUntilRenderFinished: true })
        console.info('LTBOOK', `capture backdrop ok book=${bookName}`)
      } catch (e2) {
        f.backdrop = null
        console.info('LTBOOK', `capture backdrop failed: ${(e2 as Error).message}`)
      }
      console.info('LTBOOK',
        `capture id=${componentId} book=${bookName} cover=(${f.coverLeftPx},${f.coverTopPx} ` +
        `${f.coverWidthPx}x${f.coverHeightPx}) r=${radiusPx} win=${f.winWidthPx}x${f.winHeightPx}`)
      return f
    } catch (e) {
      console.info('LTBOOK', `capture id=${componentId} failed: ${(e as Error).message}`)
      return null
    }
  }
}

/**
 * 由 `LongTakeFlightData` 推导的全部动画初值（**vp**），delegate 一次性算好，
 * 进场 / 返回两段编排共用同一实例 ⇒ 返回必然精确回到出发点。
 * 字段说明见类头注释的几何模型。
 */
export class LongTakeGeom {
  /** 初始缩放 = 封面宽 / 窗宽 */
  s0: number = 1
  /** 初始平移（vp）= 封面左上角（缩放锚点是内容 (0,0)，平移即"摆到封面位置"） */
  tx0: number = 0
  ty0: number = 0
  /** 初始裁切高度（vp）= 封面高 × 窗宽 / 封面宽（保封面纵横比的一刀） */
  clipH0: number = 0
  /** 终态裁切高度（vp）= 窗口高 */
  clipH1: number = 0
  /** 封面圆角本地值（vp）：视觉圆角 = 本值 × 当前缩放 ⇒ 首帧与书架一致 */
  coverRadius: number = 0

  static from(f: LongTakeFlightData, ui: UIContext): LongTakeGeom {
    const g = new LongTakeGeom()
    g.s0 = f.coverWidthPx / f.winWidthPx
    g.tx0 = ui.px2vp(f.coverLeftPx)
    g.ty0 = ui.px2vp(f.coverTopPx)
    g.clipH0 = ui.px2vp(f.coverHeightPx / g.s0)
    g.clipH1 = ui.px2vp(f.winHeightPx)
    g.coverRadius = ui.px2vp(f.radiusPx) / g.s0
    console.info('LTBOOK',
      `geom book=${f.bookName} s0=${g.s0} t=(${g.tx0},${g.ty0}) clipH=${g.clipH0}→${g.clipH1} r0=${g.coverRadius}`)
    return g
  }
}
