/**
 * **PDF 阅读页（官方 PdfView 组件版）** —— 2026-10-20 用户拍板的新主路径。
 *
 * ── 为什么推翻重做 ──────────────────────────────────────────────────────────
 * 旧方案「pdfService 逐页渲染成图 → 自写 zip 拼 epub → ReaderKit」真机实测
 * （`docs/日志.md` 2026-10-20）：234 页 84.6 秒 / 278 页 65.2 秒，全程主线程串行，产物 82~90MB。
 * 换官方 PdfView：`open done: 27 ms, pages=167`。
 *
 * ── 官方能力取证（`@hms.officeservice.PdfView.d.ets` / `pdfservice.d.ts`）──────
 * · `PdfView{ controller, pageLayout, isContinuous, showScroll, pageFit }`
 * · `PdfController.loadDocument(path, password?, initPageIndex?, onProgress?)` @since 5.0.0(12)
 *   onProgress 返回非 0 会**取消加载** ⇒ 固定 `return 0`
 * · `getPageCount() / getPageIndex() / goToPage(i)`、`setPageZoom(0.1~10)`、`setPageFit(PageFit)`
 * · `getPagePixelMap(pageIndex, isSync?): Promise<PixelMap>` —— 官方注释 **"Obtains the thumbnail"**
 *
 * ── 2026-10-20 第二轮实测修复（用户反馈 7 条）────────────────────────────────
 * ① **顶栏整行点不动**：上一版把顶栏和 dock 塞进同一个满屏 Column，顶栏被后面的 `Blank`
 *    盖住 ⇒ 命中落在 Blank 上。现在顶栏是**独立层**（在点击遮罩之下、dock 之上），
 *    且隐藏时**不进节点树**（PdfView 是原生 surface，层级更敏感）。
 * ② **状态栏黑遮罩 / 状态栏不回来**：PDF 页没接管窗口沉浸状态。现在与 ReaderPage3
 *    完全同一套：进页延迟 `LT_ENTER_DUR + 60` 后 `freezeTopRect()` + `toggleWindowSystemBar(...)`；
 *    退页走 `Index.releaseReaderImmersive()` 同款三件事（还原避让 / 恢复系统栏 / 还原底色）。
 * ③ **进目录先空白几秒**：先渲染面板外壳，再排"当前页那一屏 9 张"的缩略图任务；
 *    每张落位单独刷新（`thumbTick` 只用于提示刷新，不再等全部就绪）。
 * ④ **设置面板取消**（用户拍板：PDF 里没意义），夜间直接放 dock。
 */
import AppRouter from '../../../common/router/AppRouter';
import { common } from '@kit.AbilityKit';
import { PdfView, pdfService, pdfViewManager } from '@kit.PDFKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { Books } from '../../../database/entities/Books';
import BooksDao from '../../../database/dao/BooksDao';
import BookmarksDao, { BookmarkRow } from '../../../database/dao/BookmarksDao';
import { AntiPeep } from '../../../common/utils/AntiPeep';
import { Haptics } from '../../../common/utils/Haptics';
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion';
import MySetConstants from '../../../common/constants/MySetConstants';
import { OfflineMode } from '../../../common/utils/OfflineMode';
import { VipManager } from '../../../common/utils/VipManager';
import { WindowAbility } from '../../../entryability/WindowAbility';

const DOMAIN: number = 0x0000;
const TAG: string = 'PdfViewer';
/** 目录缩略图：3 列 × 3 行 = 一屏 9 张，下划继续加载（用户 2026-10-20 指定） */
const THUMB_COLS: number = 3;
const THUMB_ROWS: number = 3;

@Component
export default struct PdfViewerPage {
  /**
   * 路由参数（由 `Index.appRoutes` 注入）。
   * 为什么改 NavDestination 而不是 @Entry + router：见 `AppRouter.RouteName.PDF_VIEWER` 注释
   * —— `systemTransition` 只存在于 NavDestination，router 页面没有转场动画。
   */
  @Prop initParam: Books = new Books();
  @State book: Books = new Books();
  @State loading: boolean = true;
  @State loadingText: string = '正在打开 PDF…';
  @State errorMsg: string = '';
  @State pageIndex: number = 0;
  @State pageCount: number = 0;
  /** dock 是否展开（单击屏幕中心切换） */
  @State isShowSetting: boolean = false;
  @State nightMode: boolean = false;
  @StorageLink('antiPeepDlpOn') antiPeepDlpOn: boolean = false;
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0;
  /** 沉浸期被 reezeTopRect() 冻结的顶部避让值（≈38.81vp），顶栏让位用（与 ReaderPage3 同源） */
  @StorageLink('topRectHeight') topRectHeight: number = 0;
  @State isBookmarked: boolean = false;
  @State antiPeepScale: number = 1;
  @State bookmarkScale: number = 1;
  // 信息窗
  @State infoWinOn: boolean = false;
  @State readerStatusBarOn: boolean = false;
  @State infoClockText: string = '';
  @State infoWinBookmarkShow: boolean = true;
  @State infoWinAntiPeepShow: boolean = true;
  private infoTicker: number = -1;
  // dock 面板：0=无 1=目录 2=书签
  @State dockPane: number = 0;
  /** 缩略图就绪计数（只为触发刷新） */
  @State thumbTick: number = 0;
  @State bookmarkRows: BookmarkRow[] = [];
  private thumbs: Map<number, image.PixelMap> = new Map();
  private thumbLoading: Set<number> = new Set();
  private lastSavedPage: number = -1;
  private controller: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private loaded: boolean = false;
  private disposed: boolean = false;

  aboutToAppear(): void {
    // 参数由父级 NavDestination 注入（`@Prop initParam`），不再走 router.getParams
    if (this.initParam !== undefined && this.initParam !== null) {
      this.book = this.initParam;
    }
    if ((this.book.bookUrl ?? '').length === 0) {
      hilog.error(DOMAIN, TAG, 'initParam missing bookUrl');
    }
    this.infoWinOn = PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN, true) as boolean;
    this.readerStatusBarOn =
      PreferencesUtil.getSync(MySetConstants.SET_READER_STATUS_BAR, false) as boolean;
    this.infoWinBookmarkShow =
      PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN_BOOKMARK, true) as boolean;
    this.infoWinAntiPeepShow =
      PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN_ANTIPEEP, true) as boolean;
    AntiPeep.ensureInit(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.open();
    this.refreshBookmarkState();
    this.startInfoTicker();
    // 沉浸态：与 ReaderPage3 完全同一套（延迟到转场结束后做，避免转场中世界跳变）
    setTimeout((): void => {
      if (this.disposed) {
        return;
      }
      this.enterImmersive();
    }, UiMotion.LT_ENTER_DUR + 60);
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.stopInfoTicker();
    this.saveProgress();
    this.releaseThumbs();
    this.exitImmersive();
    if (this.loaded) {
      try {
        this.controller.releaseDocument();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'releaseDocument failed');
      }
      this.loaded = false;
    }
  }

  /**
   * 进入沉浸：与 `ReaderPage3.aboutToAppear` 尾部那段**逐条对齐**（2026-09-22 屏闪修复）。
   * `freezeTopRect()` 必须先于 `toggleWindowSystemBar`（否则避让被改成 0，整页上移）。
   */
  private enterImmersive(): void {
    try {
      WindowAbility.getInstance().freezeTopRect();
      const ctx = this.getUIContext().getHostContext();
      if (this.readerStatusBarOn) {
        WindowAbility.getInstance().toggleWindowSystemBar(['status'], ctx);
        WindowAbility.getInstance().setStatusBarTransparent(this.nightMode);
      } else {
        WindowAbility.getInstance().toggleWindowSystemBar([], ctx);
      }
      hilog.info(DOMAIN, TAG, 'enterImmersive statusBar=%{public}s', String(this.readerStatusBarOn));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'enterImmersive failed %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 退出沉浸。
   *
   * ⚠️ 2026-10-20 真机实测修正：**不能在这里自己恢复系统栏**。
   * 症状：「退出 PDF 回书架，书架/主题/设置/我的 全都有黑色遮罩」。
   * 原因：`Index.ets` 的 `NavDestination.onDisAppear → releaseReaderImmersive()` **已经**做了
   * `restoreTopRect + toggleWindowSystemBar(['status','navigation']) + restoreStatusBarBackground`；
   * 我在这里再写一遍，两次异步的 `setWindowSystemBarEnable` / `setWindowSystemBarProperties`
   * 在返回转场期间互相覆盖，状态栏底色被留在"半透明/黑"的状态。
   * ⇒ 本页只做**与渲染相关**的清理，窗口级状态一律交给 `Index.releaseReaderImmersive()`（唯一来源）。
   */
  private exitImmersive(): void {
    hilog.info(DOMAIN, TAG, 'exitImmersive: window state restored by Index.releaseReaderImmersive');
  }

  // ────────────────────────────────────────────────────────────────────────
  // 打开 / 进度
  // ────────────────────────────────────────────────────────────────────────
  private open(): void {
    const path: string = this.book.bookUrl ?? '';
    if (path.length === 0) {
      this.loading = false;
      this.errorMsg = '这本书没有可读的文件';
      return;
    }
    const t0: number = Date.now();
    hilog.info(DOMAIN, TAG, 'open begin path=%{public}s', path);
    let startPage: number = this.book.durChapterIndex ?? 0;
    if (startPage < 0) {
      startPage = 0;
    }
    this.controller.loadDocument(path, '', startPage, (progress: number) => {
      this.loadingText = '正在打开 PDF… ' + Math.round(progress) + '%';
      return 0;
    }).then((res: pdfService.ParseResult) => {
      this.loading = false;
      if (res !== pdfService.ParseResult.PARSE_SUCCESS) {
        this.errorMsg = 'PDF 打开失败（代码 ' + res + '）';
        hilog.error(DOMAIN, TAG, 'loadDocument failed code=%{public}d', res);
        return;
      }
      this.loaded = true;
      try {
        this.pageCount = this.controller.getPageCount();
        this.pageIndex = this.controller.getPageIndex();
      } catch (e) {
        this.pageCount = 0;
      }
      hilog.info(DOMAIN, TAG, 'open done: %{public}d ms, pages=%{public}d startPage=%{public}d',
        Date.now() - t0, this.pageCount, this.pageIndex);
      // 页码跟踪：注册官方滚动监听（否则 pageIndex 永远停在打开时那一页 ⇒ 书签永远第 1 页）
      this.registerPageTracking();
      this.refreshBookmarkState();
    }).catch((e: BusinessError) => {
      this.loading = false;
      this.errorMsg = 'PDF 打开失败：' + (e?.message ?? '未知错误');
      hilog.error(DOMAIN, TAG, 'loadDocument throw %{public}s', JSON.stringify(e));
    });
  }

  // ────────────────────────────────────────────────────────────────────────
  // 当前页码跟踪（2026-10-20 真机 bug 修复：书签永远存到第 1 页）
  //
  // ── 为什么之前永远是第 1 页 ─────────────────────────────────────────────
  // 旧实现只在 `PdfView.onAreaChange` 里读一次 `getPageIndex()`。`onAreaChange` 只在
  // **布局尺寸变化**时触发，滚动根本不触发 ⇒ `pageIndex` 永远是打开时的 0。
  //
  // ── 官方给的两个事实（SDK `@hms.officeservice.PdfView.d.ets`）──────────────
  // 1) `getPageIndex(): number` —— 注释原文 "Obtains the index of the current PDF page."
  //    @since 5.0.0(12)。这是**官方定义的当前页**。
  // 2) `registerScrollListener(listener: Callback<ScrollParam>)`，`ScrollParam` 字段原文：
  //    · `offsetX/offsetY`: "Offset along the X/Y axis. The value ranges from 0 to 1,
  //      indicating 0% to 100%."
  //    · `pdfWidth/pdfHeight`: "Total width/height of the PDF page **after scaling**, in px."
  //    · `viewWidth/viewHeight`: "Controller width/height, in px."
  //
  // ── 判定规则（用户 2026-10-20 指定："哪一页占比更大，谁就当书签"）──────────
  // 主口径 = `getPageIndex()`（官方当前页语义）；
  // 交叉校验 = 用 ScrollParam 算"视口中线落在第几页"：
  //   视口中线在文档里的像素位置 = offsetY × (N×pdfHeight − viewHeight) + viewHeight/2
  //   页码 = floor(该位置 / pdfHeight)
  // 两者不一致时以 ScrollParam 计算结果为准（它不依赖内部状态刷新时机），并在日志里打点，
  // 方便下一轮用真实数据复核。
  // ────────────────────────────────────────────────────────────────────────
  private pageTrackingOn: boolean = false;

  private registerPageTracking(): void {
    if (this.pageTrackingOn) {
      return;
    }
    try {
      this.controller.registerScrollListener((p: pdfViewManager.ScrollParam) => {
        this.onPdfScrolled(p);
      });
      this.pageTrackingOn = true;
      hilog.info(DOMAIN, TAG, 'registerScrollListener ok');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'registerScrollListener failed %{public}s', JSON.stringify(e));
    }
  }

  /** 滚动回调：高频，只做"页码可能变了才继续"的轻判断 */
  private onPdfScrolled(p: pdfViewManager.ScrollParam): void {
    if (!this.loaded) {
      return;
    }
    let byApi: number = -1;
    try {
      byApi = this.controller.getPageIndex();
    } catch (e) {
      byApi = -1;
    }
    const byRatio: number = this.pageByViewportCenter(p);
    const page: number = byRatio >= 0 ? byRatio : byApi;
    if (page < 0 || page === this.pageIndex) {
      return;
    }
    this.pageIndex = page;
    this.saveProgress();
    this.refreshBookmarkState();
    hilog.info(DOMAIN, TAG,
      'page -> %{public}d (api=%{public}d ratio=%{public}d offsetY=%{public}s pdfH=%{public}d viewH=%{public}d)',
      page, byApi, byRatio, p.offsetY.toFixed(4), Math.round(p.pdfHeight), Math.round(p.viewHeight));
  }

  /**
   * 按"视口中线落在第几页"算当前页（用户指定的"占比更大"口径）。
   * ScrollParam 语义见官方注释（offsetY 归一化 0~1，pdfHeight 是缩放后**单页**高度 px）。
   * 取不到有效值时返回 -1，让调用方回退到 `getPageIndex()`。
   */
  private pageByViewportCenter(p: pdfViewManager.ScrollParam): number {
    if (p === undefined || p === null || this.pageCount <= 0) {
      return -1;
    }
    const pageH: number = p.pdfHeight;
    const viewH: number = p.viewHeight;
    if (!(pageH > 0) || !(viewH > 0)) {
      return -1;
    }
    const totalH: number = pageH * this.pageCount;
    const scrollable: number = Math.max(0, totalH - viewH);
    const center: number = p.offsetY * scrollable + viewH / 2;
    let idx: number = Math.floor(center / pageH);
    if (idx < 0) {
      idx = 0;
    }
    if (idx > this.pageCount - 1) {
      idx = this.pageCount - 1;
    }
    return idx;
  }
  private syncPage(): void {
    if (!this.loaded) {
      return;
    }
    try {
      const idx: number = this.controller.getPageIndex();
      if (idx === this.pageIndex) {
        return;
      }
      this.pageIndex = idx;
      this.saveProgress();
      this.refreshBookmarkState();
    } catch (e) {
      // 文档尚未就绪
    }
  }

  private saveProgress(): void {
    if (!this.loaded || this.pageCount <= 0) {
      return;
    }
    const idx: number = this.pageIndex;
    if (idx === this.lastSavedPage) {
      return;
    }
    this.lastSavedPage = idx;
    const id: number = this.book.id ?? 0;
    if (id <= 0) {
      hilog.warn(DOMAIN, TAG, 'saveProgress skipped: book id missing');
      return;
    }
    // ⚠️ 2026-10-20 真机 bug 根治：**必须用 `stampReadProgress` + 广播书架刷新**。
    // 旧实现只调 `partialUpdate`：
    //   ① `partialUpdate` 只写 `getPartialColumn()` 里的列，`durChapterTime` 虽在列内，
    //      但书架"最近阅读"排序依赖的是**刷新信号**，光写库不会触发重排；
    //   ② 结果就是用户看到的「书架不再排序、看完回到列表位置不变」。
    // ReaderPage3 的做法是 `stampReadProgress(...)` 落库 + `BOOK_IS_BOOK_REFRESHING` 自增触发
    // `BookContent` 的 `@StorageLink@Watch` 重查 —— 这里完全对齐。
    BooksDao.stampReadProgress(id, idx, this.pageTitle(idx), this.pageCount).then((): void => {
      const tick: number = (AppStorage.get<number>('BOOK_IS_BOOK_REFRESHING') ?? 0) + 1;
      AppStorage.setOrCreate('BOOK_IS_BOOK_REFRESHING', tick);
    }).catch((e: Error): void => {
      hilog.warn(DOMAIN, TAG, 'save progress failed %{public}s', e.message);
    });
  }

  private close(): void {
    try {
      // 走 NavPathStack 进来的页面**必须** pop()：用 router.back() 会把整个 Index 弹掉
      // （`AppRouter` 头部注释里的成对规则）
      AppRouter.pop();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'back failed');
    }
  }

  private goToPage(idx: number): void {
    if (!this.loaded || idx < 0 || idx >= this.pageCount) {
      return;
    }
    try {
      this.controller.goToPage(idx);
      this.pageIndex = idx;
      this.dockPane = 0;
      this.isShowSetting = false;
      this.saveProgress();
      this.refreshBookmarkState();
      hilog.info(DOMAIN, TAG, 'goToPage %{public}d', idx);
    } catch (e) {
      this.toast('跳转失败');
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // 书签（PDF 口径：chapterIndex = 页码）
  // ────────────────────────────────────────────────────────────────────────
  private pageTitle(idx: number): string {
    return '第 ' + (idx + 1) + ' 页';
  }

  private async refreshBookmarkState(): Promise<void> {
    try {
      const name: string = this.book.bookName ?? '';
      this.isBookmarked = await BookmarksDao.isBookmarked(name, this.pageIndex, 0);
    } catch (e) {
      this.isBookmarked = false;
    }
  }

  private async toggleBookmark(): Promise<void> {
    const name: string = this.book.bookName ?? '';
    const idx: number = this.pageIndex;
    try {
      if (this.isBookmarked) {
        const ok: boolean = await BookmarksDao.removeAt(name, idx, 0);
        this.isBookmarked = false;
        this.toast(ok ? '已移除书签' : '移除失败');
      } else {
        const ok: boolean = await BookmarksDao.add(name, this.book.author ?? '', idx, 0,
          this.pageTitle(idx), this.pageTitle(idx), true);
        this.isBookmarked = ok;
        this.toast(ok ? ('已添加书签 · ' + this.pageTitle(idx)) : '添加失败');
      }
      if (this.dockPane === 2) {
        await this.loadBookmarkList();
      }
    } catch (e) {
      this.toast('书签操作失败');
    }
  }

  private async loadBookmarkList(): Promise<void> {
    try {
      const all: BookmarkRow[] = await BookmarksDao.list();
      const name: string = this.book.bookName ?? '';
      const mine: BookmarkRow[] = [];
      for (const r of all) {
        if (r.bookName === name) {
          mine.push(r);
        }
      }
      mine.sort((a: BookmarkRow, b: BookmarkRow) => a.chapterIndex - b.chapterIndex);
      this.bookmarkRows = mine;
    } catch (e) {
      this.bookmarkRows = [];
    }
  }

  private async removeBookmark(time: number): Promise<void> {
    await BookmarksDao.remove(time);
    await this.loadBookmarkList();
    await this.refreshBookmarkState();
    this.toast('已删除书签');
  }

  // ────────────────────────────────────────────────────────────────────────
  // 信息窗
  // ────────────────────────────────────────────────────────────────────────
  private startInfoTicker(): void {
    this.updateClock();
    if (this.infoTicker === -1) {
      this.infoTicker = setInterval(() => {
        this.updateClock();
      }, 1000);
    }
  }

  private stopInfoTicker(): void {
    if (this.infoTicker !== -1) {
      clearInterval(this.infoTicker);
      this.infoTicker = -1;
    }
  }

  private updateClock(): void {
    if (!this.infoWinOn) {
      return;
    }
    const d: Date = new Date();
    this.infoClockText = String(d.getHours()).padStart(2, '0') + ':'
      + String(d.getMinutes()).padStart(2, '0') + ':'
      + String(d.getSeconds()).padStart(2, '0');
  }

  /**
   * 顶部让位 —— **逐字对齐 `ReaderPage3.readerTopInset()`**（2026-10-20 真机反馈修复）。
   *
   * ── 上一版为什么错 ──────────────────────────────────────────────────────
   * 我原来写成"状态栏关 ⇒ 返回 0"，于是顶栏贴到屏幕最上沿（用户原话：
   * 「顶栏直接到系统状态栏的位置去了」），而开关一开又变成 38.81 ⇒ **同一个顶栏位移 38.81vp**。
   *
   * ── 正确口径（与阅读器同源）──────────────────────────────────────────────
   * · 状态栏关（默认沉浸）：返回 `this.topRectHeight` —— 沉浸期的 `avoidAreaChange` 被
   *   `WindowAbility.freezeTopRect()` 拦下**不更新**，所以它仍是进书前的实测值 ≈38.81vp，
   *   正好等于状态栏高度 ⇒ 顶栏落在"原状态栏下沿"，与开关打开时**同一位置**，不再跳。
   * · 状态栏开：返回 `AppStorage['stateHeight']`（`EntryAbility` 启动时按
   *   `AvoidAreaType.TYPE_SYSTEM` 写入的 vp 值），取不到回落本项目实测 38.81vp。
   */
  private readerTopInset(): number {
    if (!this.readerStatusBarOn) {
      return this.topRectHeight;
    }
    const h: number = AppStorage.get<number>('stateHeight') ?? 0;
    return h > 0 ? h : 38.81;
  }

  // ────────────────────────────────────────────────────────────────────────
  // 缩略图磁盘缓存（2026-10-20 用户提议"导入时预处理，进目录直接读缓存"）
  //
  // 为什么**不做**"导入时全量预处理"：用户选这条路线的核心理由就是"打开即读"
  // （167 页全量渲染 = 又变回旧方案的分钟级）。真正的问题是
  // `PdfController.getPagePixelMap` 逐页 Promise，首次进目录全是转圈、
  // 第二次才出来（因为它命中了 PdfView 内部缓存）。
  // ⇒ 折中：**进目录时才**把当前屏 9 张落盘缓存，下次进目录**先读盘**（零渲染等待），
  //    滚动到没缓存的页再现场取并补写缓存。缓存目录 `filesDir/pdf_thumbs/<bookId>_<size>/N.jpg`。
  // ────────────────────────────────────────────────────────────────────────
  private thumbCacheDir(): string {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return ctx.filesDir + '/pdf_thumbs/' + String(this.book.id ?? 0);
  }

  private thumbCachePath(i: number): string {
    return this.thumbCacheDir() + '/' + i + '.jpg';
  }

  private ensureThumbDir(): void {
    try {
      const dir: string = this.thumbCacheDir();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // 建不了就走内存路径
    }
  }

  /** 命中的磁盘缓存 → 直接给 Image 一个 `file://`（零渲染等待） */
  @State thumbFiles: Map<number, string> = new Map();

  private thumbFromDisk(i: number): string {
    const cached: string | undefined = this.thumbFiles.get(i);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const p: string = this.thumbCachePath(i);
      if (fs.accessSync(p) && fs.statSync(p).size > 0) {
        const uri: string = 'file://' + p;
        this.thumbFiles.set(i, uri);
        return uri;
      }
    } catch (e) {
      // 缺失
    }
    return '';
  }

  // ────────────────────────────────────────────────────────────────────────
  // 缩略图（3×3 懒加载；先出壳再逐张落位）
  // ────────────────────────────────────────────────────────────────────────
  private async ensureThumb(i: number): Promise<void> {
    if (i < 0 || i >= this.pageCount || this.thumbs.has(i) || this.thumbLoading.has(i)) {
      return;
    }
    if (this.thumbFromDisk(i) !== '') {
      // 已有磁盘缓存，UI 直接按 file:// 渲染，不用再取像素
      this.thumbTick++;
      return;
    }
    this.thumbLoading.add(i);
    try {
      const pm: image.PixelMap = await this.controller.getPagePixelMap(i, false);
      if (pm !== undefined && pm !== null) {
        this.thumbs.set(i, pm);
        this.thumbTick++;
        // 落盘缓存（下次进目录直接读盘；失败不影响本次显示）
        this.saveThumbToDisk(i, pm).catch(() => {
        });
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'thumb %{public}d failed', i);
    } finally {
      this.thumbLoading.delete(i);
    }
  }

  /** PixelMap → JPEG 落盘（PackingOption 官方字段：format / quality 必填） */
  private async saveThumbToDisk(i: number, pm: image.PixelMap): Promise<void> {
    try {
      this.ensureThumbDir();
      const packer: image.ImagePacker = image.createImagePacker();
      const opt: image.PackingOption = { format: 'image/jpeg', quality: 60 };
      const buf: ArrayBuffer = await packer.packToData(pm, opt);
      const f = fs.openSync(this.thumbCachePath(i),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, buf);
      } finally {
        fs.closeSync(f);
      }
      packer.release().catch(() => {
      });
      this.thumbFiles.set(i, 'file://' + this.thumbCachePath(i));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'thumb save %{public}d failed', i);
    }
  }

  /** 只排"当前页所在那一屏"的 9 张（避免 167 页一次性发起） */
  private scheduleThumbs(firstPage: number): void {
    const from: number = Math.max(0, firstPage - (firstPage % THUMB_COLS));
    const end: number = Math.min(this.pageCount, from + THUMB_COLS * THUMB_ROWS);
    hilog.info(DOMAIN, TAG, 'scheduleThumbs %{public}d..%{public}d', from, end);
    for (let i = from; i < end; i++) {
      this.ensureThumb(i);
    }
  }

  private releaseThumbs(): void {
    this.thumbs.forEach((pm: image.PixelMap) => {
      pm.release().catch(() => {
      });
    });
    this.thumbs.clear();
  }

  private pageList(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.pageCount; i++) {
      out.push(i);
    }
    return out;
  }

  // ────────────────────────────────────────────────────────────────────────
  // 图标 / 颜色 / 小工具
  // ────────────────────────────────────────────────────────────────────────
  private bookmarkIcon(): Resource {
    return this.isBookmarked ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark');
  }

  private antiPeepIcon(): Resource {
    return this.antiPeepDlpOn ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye');
  }

  private toggleAntiPeep(): void {
    if (this.antiPeepDlpOn) {
      AntiPeep.setDlp(false);
      this.toast('阅读防窥已关闭');
    } else {
      AntiPeep.requestDlpOn();
      this.toast('阅读防窥已开启');
    }
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (e) {
      // 忽略
    }
  }

  private pageBg(): ResourceColor {
    return this.nightMode ? '#1A1A1A' : '#FFFFFF';
  }

  private fgColor(): ResourceColor {
    return this.nightMode ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)';
  }

  private barBg(): ResourceColor {
    return this.nightMode ? 'rgba(31, 31, 31, 0.92)' : 'rgba(250, 250, 250, 0.94)';
  }

  // ────────────────────────────────────────────────────────────────────────
  // UI
  // ────────────────────────────────────────────────────────────────────────
  @Builder
  TopBar() {
    Row({ space: 8 }) {
      Image($r('app.media.ic_public_return_left'))
        .fillColor(this.fgColor())
        .width(24)
        .height(24)
        .responseRegion({ x: -10, y: -10, width: 44, height: 44 })
        .onClick(() => {
          Haptics.tap();
          this.close();
        })
      Text(this.book.bookName ?? 'PDF')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.fgColor())
        .fontSize(15)

      if (OfflineMode.showReadingEnhancements()) {
        if (!VipManager.isVip()) {
          Text('VIP')
            .fontSize(9)
            .fontWeight(600)
            .fontColor('#B8860B')
            .backgroundColor('rgba(255, 215, 0, 0.28)')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
        }
        SymbolGlyph(this.antiPeepIcon())
          .fontSize(22)
          .fontColor([this.fgColor()])
          .symbolEffect(new ReplaceSymbolEffect(), this.antiPeepDlpOn ? 1 : 0)
          .scale({ x: this.antiPeepScale, y: this.antiPeepScale })
          .margin({ right: 12 })
          .responseRegion({ x: -11, y: -11, width: 44, height: 44 })
          .onClick(() => {
            Haptics.tap();
            if (!VipManager.isVip()) {
              this.toast('阅读防窥是会员功能');
              return;
            }
            runJellyClick((v: number) => {
              this.antiPeepScale = v;
            });
            this.toggleAntiPeep();
          })
      }

      SymbolGlyph(this.bookmarkIcon())
        .fontSize(22)
        .fontColor([this.fgColor()])
        .symbolEffect(new ReplaceSymbolEffect(), this.isBookmarked ? 1 : 0)
        .scale({ x: this.bookmarkScale, y: this.bookmarkScale })
        .responseRegion({ x: -11, y: -11, width: 44, height: 44 })
        .onClick(() => {
          Haptics.tap();
          runJellyClick((v: number) => {
            this.bookmarkScale = v;
          });
          this.toggleBookmark();
        })
    }
    .width('90%')
    .padding({ top: 12, left: 20, right: 20, bottom: 12 })
    .borderRadius(16)
    .clip(true)
    .backgroundColor(this.barBg())
    .margin({ top: this.readerTopInset() + 12 })
  }

  @Builder
  InfoWindow() {
    Row() {
      Row({ space: 4 }) {
        if (!this.readerStatusBarOn && this.infoClockText.length > 0) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(16)
            .fontColor([this.fgColor()])
          Text(this.infoClockText)
            .fontSize(13)
            .fontColor(this.fgColor())
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Start)

      Row({ space: 8 }) {
        if (this.infoWinBookmarkShow && this.isBookmarked) {
          SymbolGlyph(this.bookmarkIcon()).fontSize(16).fontColor([this.fgColor()])
        }
        if (this.infoWinAntiPeepShow && this.antiPeepDlpOn) {
          SymbolGlyph(this.antiPeepIcon()).fontSize(16).fontColor([this.fgColor()])
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.End)
    }
    .width('90%')
    .padding({ left: 4, right: 4 })
    .margin({ top: this.readerTopInset() + 12 })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 目录：3×3 缩略图，下划继续加载 */
  @Builder
  CatalogGrid() {
    Column() {
      Text('目录 · 共 ' + this.pageCount + ' 页')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 10, bottom: 8 })
      Grid() {
        ForEach(this.pageList(), (idx: number) => {
          GridItem() {
            Stack({ alignContent: Alignment.BottomEnd }) {
              if (this.thumbs.has(idx)) {
                Image(this.thumbs.get(idx))
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Contain)
                  .borderRadius(6)
              } else if (this.thumbFromDisk(idx) !== '') {
                // 磁盘缓存命中：直接 file:// 渲染（"第二次进目录才出来"的根治）
                Image(this.thumbFromDisk(idx))
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Contain)
                  .borderRadius(6)
              } else {
                Column() {
                  LoadingProgress().width(18).height(18).color($r('app.color.text_tertiary'))
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .backgroundColor($r('app.color.page_bg'))
                .borderRadius(6)
              }
              Text(String(idx + 1))
                .fontSize(11)
                .fontColor(Color.White)
                .backgroundColor('#99000000')
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(4)
                .margin({ right: 4, bottom: 4 })
            }
            .width('100%')
            .aspectRatio(0.72)
            .border({
              width: idx === this.pageIndex ? 2 : 1,
              color: idx === this.pageIndex ? '#FF1F6FEB' : '#33888888'
            })
            .borderRadius(6)
            .onClick(() => {
              Haptics.tap();
              this.goToPage(idx);
            })
            .onAppear(() => {
              this.ensureThumb(idx);
            })
          }
          .margin(4)
        }, (idx: number) => 'pg-' + idx + '-' + (this.thumbs.has(idx) ? '1' : '0'))
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsGap(2)
      .columnsGap(2)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  BookmarkList() {
    Column() {
      Text('书签 · 共 ' + this.bookmarkRows.length + ' 条')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 10, bottom: 8 })
      if (this.bookmarkRows.length === 0) {
        Column({ space: 8 }) {
          Text('还没有书签').fontSize(13).fontColor($r('app.color.text_secondary'))
          Text('点顶栏的「书签」图标可给当前页加书签')
            .fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.bookmarkRows, (r: BookmarkRow) => {
            ListItem() {
              Row({ space: 12 }) {
                Text(String(r.chapterIndex + 1))
                  .fontSize(13)
                  .width(44)
                  .textAlign(TextAlign.Center)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.pageTitle(r.chapterIndex))
                  .fontSize(14)
                  .layoutWeight(1)
                  .fontColor($r('app.color.text_primary'))
                Text('删除')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    Haptics.tap();
                    this.removeBookmark(r.time);
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 12 })
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(10)
              .onClick(() => {
                Haptics.tap();
                this.goToPage(r.chapterIndex);
              })
            }
          }, (r: BookmarkRow) => 'bm-' + r.time)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** dock：目录 / 书签 / 夜间（设置整块取消） */
  @Builder
  DockBar() {
    Row() {
      this.DockItem(1, '目录', $r('sys.symbol.list_square'))
      this.DockItem(2, '书签', $r('sys.symbol.bookmark'))
      this.DockItem(0, this.nightMode ? '日间' : '夜间', $r('sys.symbol.moon'))
    }
    .width('90%')
    .height(64)
    .justifyContent(FlexAlign.SpaceAround)
    .backgroundColor(this.barBg())
    .borderRadius(20)
    .margin({ bottom: 24 + this.bottomRectHeight / 2 })
  }

  @Builder
  DockItem(pane: number, label: string, icon: Resource) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([pane === 0 ? this.fgColor()
          : (this.dockPane === pane ? '#FF1F6FEB' : this.fgColor())])
      Text(label)
        .fontSize(11)
        .fontColor(pane === 0 ? this.fgColor()
          : (this.dockPane === pane ? '#FF1F6FEB' : this.fgColor()))
    }
    .width(72)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      Haptics.tap();
      if (pane === 0) {
        this.toggleNight();
        return;
      }
      if (this.dockPane === pane) {
        this.dockPane = 0;
        return;
      }
      this.dockPane = pane;
      if (pane === 1) {
        const first: number =
          Math.max(0, this.pageIndex - (this.pageIndex % (THUMB_COLS * THUMB_ROWS)));
        this.scheduleThumbs(first);
      } else if (pane === 2) {
        this.loadBookmarkList();
      }
    })
  }

  private toggleNight(): void {
    this.nightMode = !this.nightMode;
    if (this.readerStatusBarOn) {
      WindowAbility.getInstance().setStatusBarTransparent(this.nightMode);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        Stack({ alignContent: Alignment.Center }) {
          if (this.errorMsg.length > 0) {
            Column({ space: 12 }) {
              Text(this.errorMsg)
                .fontSize(14)
                .textAlign(TextAlign.Center)
                .fontColor($r('app.color.text_secondary'))
                .padding({ left: 32, right: 32 })
              Button('返回书架')
                .fontSize(14)
                .height(40)
                .width(140)
                .backgroundColor($r('app.color.sub_btn_bg'))
                .fontColor($r('app.color.sub_btn_fg'))
                .onClick(() => {
                  this.close();
                })
            }
          } else {
            PdfView({
              controller: this.controller,
              pageLayout: pdfService.PageLayout.LAYOUT_SINGLE,
              isContinuous: true,
              showScroll: false,
              pageFit: pdfService.PageFit.FIT_WIDTH
            })
              .width('100%')
              .height('100%')
              .onAreaChange(() => {
                this.syncPage();
              })
            if (this.loading) {
              Column({ space: 12 }) {
                LoadingProgress().width(44).height(44).color($r('app.color.text_secondary'))
                Text(this.loadingText).fontSize(13).fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor(this.pageBg())
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(this.pageBg())
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBg())

      // ① 单击/双击热区（2026-10-20 新增双击存书签）
      //    · 单击 = 开关顶栏 + dock
      //    · 双击 = **存/删当前页书签**（用户 2026-10-20 指定；顶栏书签图标同步变色）
      //
      // ── 为什么用 `HitTestMode.Transparent` ──────────────────────────────────
      // 这个模式让**下层 `PdfView` 也收到触摸** ⇒ 双击时官方自己的缩放手势仍然有效，
      // 本层只"旁听"，不会把 PdfView 的交互吞掉。
      //
      // ── 官方依据（SDK `component/gesture.d.ts`）──────────────────────────
      // · `TapGesture(value?: TapGestureParameters)`，`TapGestureParameters{ count?: number, fingers?: number }`
      //   （:1280 / :1357，@since 7）
      // · `GestureGroup(mode: GestureMode, ...gesture: GestureType[])`（@since 7）；
      //   `GestureMode.Parallel` 官方注释原文（:171）：
      //   "Registered gestures are recognized concurrently until all gestures are recognized."
      //
      // ── 已知代价（用户已确认可接受）──────────────────────────────────────
      // 单击会有约 300ms 等待（官方 TapGesture 文档：同时绑定单击+双击时，单击要等双击判定失败）。
      // 双击时单击会先生效 ⇒ dock 闪一下；用户原话"也无所谓，我们主要是实现功能"。
      if (!this.loading && this.errorMsg.length === 0 && this.dockPane === 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.isShowSetting ? '#33000000' : '#00000000')
          .hitTestBehavior(HitTestMode.Transparent)
          .gesture(
            GestureGroup(GestureMode.Parallel,
              TapGesture({ count: 1 }).onAction(() => {
                Haptics.tap();
                this.isShowSetting = !this.isShowSetting;
              }),
              TapGesture({ count: 2 }).onAction(() => {
                // 双击存/删书签：与顶栏图标同一套 `toggleBookmark`（已存则删、未存则加）
                Haptics.tap();
                this.toggleBookmark();
              })
            )
          )
      }

      // ② 信息窗（全屏阅读态）
      if (!this.isShowSetting && this.infoWinOn) {
        this.InfoWindow()
      }

      // ③ 顶栏（独立层容器：占满屏、内容顶对齐、`Transparent` 让空白处点击继续往下走）
      if (this.isShowSetting) {
        Column() {
          this.TopBar()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
      }


      // ⑤ dock（贴底）
      // ⚠️ 2026-10-20：**不能给这层包一层 `HitTestMode.None` 的全屏 Column** ——
      //    工程已知坑（AGENTS.md）：`None` 只让组件自身退出命中，**子节点照样吃触摸**；
      //    但反过来"外层满屏容器 + 内部按钮"这种结构很容易被上层的透明层压住。
      //    这里改成**只放 dock 本身**（不再包满屏 Column），位置由外层 Stack 的
      //    `Alignment.Bottom` 决定 —— 结构越扁越不容易抢不到点击。
      if (this.isShowSetting) {
        Row() {
          this.DockBar()
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Bottom)
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ⑥ 面板（目录/书签）：Bottom Sheet，点上半区关闭
      if (this.dockPane > 0) {
        Column() {
          Blank().onClick(() => {
            Haptics.tap();
            this.dockPane = 0;
          })
          Column() {
            if (this.dockPane === 1) {
              this.CatalogGrid()
            } else {
              this.BookmarkList()
            }
            this.DockBar()
          }
          .width('100%')
          .height('62%')
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.barBg())
          .borderRadius({ topLeft: 20, topRight: 20 })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }
}
