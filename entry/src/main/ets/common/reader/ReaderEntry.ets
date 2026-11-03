import { UIContext } from '@kit.ArkUI'
import { Books } from '../../database/entities/Books'
import AppRouter, { PdfRouteParam, ReaderRouteParam, RouteName } from '../router/AppRouter'
import { FMT_MASTER_ENABLED, FMT_PDF_ENABLED, FMT_PDF_USE_PDFVIEW, isPdfPath } from '../format/FormatFlags'
import { coverCorners } from '../utils/CoverSource'
import { ezCustomTransition, LongTakeTransitionParam } from '../ezlt'
import UiMotion from '../utils/UiMotion'

/**
 * 2026-11-03（P1 / R1）：**唯一的阅读入口**。
 *
 * ── 为什么需要它 ───────────────────────────────────────────────────────────
 * 收口前，"这本书该进哪个阅读页"的判断散在两处，且**两处都不是全量**：
 *   · 只有 `BookInfos`（列表）与 `BookInfoGrids`（宫格）做了 PDF 判定 → `PDF_VIEWER`；
 *   · 另外 **6 个入口**（继续阅读/接续、书籍详情 ×3、我的中心、阅读统计）**一律** `push(READER)`
 *     ⇒ 同一本 PDF 从"书架"点进去是 `PdfViewerPage`，从"继续阅读"点进去却是 `ReaderPage3`
 *     （靠 `isPdfBook` 缩放态兜着）⇒ **同一本书两套阅读体验**。
 *   · 而 `BookInfos` 与 `BookInfoGrids` 里那两段判定又是**逐字重复**的两份。
 *
 * ── 三概念（用户口径）───────────────────────────────────────────────────────
 *   txt / 非 txt（epub、mobi、azw3）→ `READER`（`ReaderPage3` 内部再按翻页模式分流）
 *   pdf                            → `PDF_VIEWER`（`PdfViewerPage`）
 *   `.doc` 预览态仍由调用方先行拦截（`UnsupportedDoc`，需要页面级 context，不在本类职责内）
 *
 * ── 用法 ────────────────────────────────────────────────────────────────────
 *   ① 简单入口（不需要"转场进行中"闸）：
 *        `ReaderEntry.open(this.getUIContext(), book)`           // 无封面飞行
 *        `ReaderEntry.open(this.getUIContext(), book, { longtakeId: this.longtakeId })`
 *   ② 需要先建参数、延后再推（书架点书有"转场进行中"闸，见 `BookInfos.openReaderWhenIdle`）：
 *        `const launch = ReaderEntry.prepare(uiCtx, book, { longtakeId })`
 *        `… 等转场收尾 …`  `ReaderEntry.launch(launch)`
 *   ③ 调用方已经自己拼好了 `ReaderRouteParam`（继续阅读会带字体/接续坐标等额外字段）：
 *        `ReaderEntry.open(uiCtx, book, { param: rp })`
 *
 * ⚠️ 一镜到底参数**必须在点击瞬间**用封面 id 拍几何（`generateLongTakeParam`）⇒ `prepare()` 要
 *    在点击回调里同步调用，不要等"闸"放行之后再拍。
 */
export interface ReaderOpenOpts {
  /** 封面视图的 `.id()`；空串/未传 = 不演一镜到底 */
  longtakeId?: string
  /** 调用方已构造好的 READER 参数（带额外字段时用）；给了它就以它的 `bookData` 为准 */
  param?: ReaderRouteParam
  /**
   * 封面显示宽度（决定传给 session 的四角圆角）：**列表 60 / 宫格 100**，默认 60。
   * 依据：`BookInfos` 列表封面 `.borderRadius(coverCorners(60))`、`BookInfoGrids` 宫格 `coverCorners(100)`。
   */
  coverWidth?: number
  /** 传给 `generateLongTakeParam(uiCtx, id, N)` 的 N：列表 **4**、宫格 **10**，默认 4 */
  longtakeCorner?: number
}

/** `prepare()` 的产物：决定进哪个页 + 已带好一镜到底参数的路由参数 */
export class ReaderLaunch {
  isPdf: boolean = false
  readerParam: ReaderRouteParam | null = null
  pdfParam: PdfRouteParam | null = null
}

export class ReaderEntry {
  /** 是否走 PDF 阅读页（`PDF_VIEWER`）；其余一律 `READER` */
  static isPdfBook(book: Books): boolean {
    if (!(FMT_MASTER_ENABLED && FMT_PDF_ENABLED && FMT_PDF_USE_PDFVIEW)) {
      return false
    }
    return isPdfPath(book.bookUrl ?? '')
  }

  /**
   * 建参数（**同步**，必须在点击回调里调）：决定 pdf/reader，并按封面 id 拍一镜到底几何。
   * 不动页面栈 —— 由 `launch()` 真正推。
   */
  static prepare(uiCtx: UIContext, book: Books, opts?: ReaderOpenOpts): ReaderLaunch {
    const out = new ReaderLaunch()
    const lt = ReaderEntry.buildLongTake(uiCtx, opts?.longtakeId, opts?.coverWidth, opts?.longtakeCorner)
    if (ReaderEntry.isPdfBook(book)) {
      out.isPdf = true
      const pp: PdfRouteParam = { bookData: book }
      if (lt !== undefined) {
        pp.longTakeTransitionParam = lt
      }
      out.pdfParam = pp
      return out
    }
    const rp: ReaderRouteParam = opts?.param !== undefined ? opts.param : { bookData: book }
    if (lt !== undefined) {
      rp.longTakeTransitionParam = lt
    }
    out.readerParam = rp
    return out
  }

  /** 按 `prepare()` 的结论推路由；返回是否推成功（含 pdf 分支的失败日志） */
  static launch(plan: ReaderLaunch): boolean {
    if (plan.isPdf && plan.pdfParam !== null) {
      const ok: boolean = AppRouter.push(RouteName.PDF_VIEWER, plan.pdfParam)
      if (!ok) {
        console.error('open pdf viewer failed: route stack not ready')
      }
      return ok
    }
    if (plan.readerParam !== null) {
      return AppRouter.push(RouteName.READER, plan.readerParam)
    }
    return false
  }

  /** 一步到位：建参数 + 推路由（不需要"转场进行中"闸的入口用这个） */
  static open(uiCtx: UIContext, book: Books, opts?: ReaderOpenOpts): boolean {
    return ReaderEntry.launch(ReaderEntry.prepare(uiCtx, book, opts))
  }

  /** 一镜到底参数：封面 id 缺失或设备不允许 ⇒ undefined（阅读页自然走普通转场） */
  private static buildLongTake(uiCtx: UIContext, longtakeId?: string, coverWidth?: number,
    longtakeCorner?: number): LongTakeTransitionParam | undefined {
    const id: string = longtakeId ?? ''
    if (!UiMotion.longTakeAllowed() || id === '') {
      return undefined
    }
    // 2026-10-05（方案 A）：把封面当前的四角圆角（书脊式不对称）传给 session，
    // 否则飞行封面用统一圆角、起飞/落位帧与书架封面对不上。
    // 宽度/圆角由调用方给：**列表 60/4、宫格 100/10**（见 `ReaderOpenOpts`）。
    const w: number = coverWidth !== undefined && coverWidth > 0 ? coverWidth : 60
    const corner: number = longtakeCorner !== undefined && longtakeCorner > 0 ? longtakeCorner : 4
    AppStorage.setOrCreate(UiMotion.LT_COVER_CORNERS_KEY, coverCorners(w))
    return ezCustomTransition.generateLongTakeParam(uiCtx, id, corner)
  }
}

export default ReaderEntry
