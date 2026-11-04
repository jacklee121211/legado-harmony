// 阅读器**会话状态（ReaderSession）**（2026-11-04 P3 批 A-4：从 `ReaderPage3.ets` 搬出）。
//
// ── 为什么要有这个类（判据来自 `docs/待办-统一清单-2026-11-03.md` §43.5）──────────
// A-3 收尾时列出的三条"不能搬"理由里，前两条都是**状态归属**问题，不是函数纯度问题：
//   ① 节流字段 `lastPersistAt`、查库去重键 `bmProbeKey` 还挂在页面上 ⇒ 只搬函数＝一份状态两个家；
//   ② 调用点分散在 `pageShow` / `aboutToDisappear` / `onScrollPos` ⇒ 搬函数必然搬时序。
// 本批先把**状态**收到一处（本类），时序一行不动；函数搬运只在"时序不变"的前提下做。
//
// ── 这 5 个字段为什么能收进来（逐个交代）──────────────────────────────────────
// | 字段 | 原位置 | 读/写点 | 是否 `@State` | 收进来的理由 |
// |---|---|---|---|---|
// | `pageRange`     | `ReaderPage3:1458` | 27 处 | **否**（`private`） | 精确定位状态机的"当前页范围"，纯内部数据，不参与渲染 |
// | `locateTarget`  | `ReaderPage3:1459` | 11 处 | **否** | 同上（待跳转目标） |
// | `flipSearch`    | `ReaderPage3:1460` | 13 处 | **否** | 同上（逐页逼近兜底的搜索态） |
// | `lastPersistAt` | `ReaderPage3:623`  |  2 处 | **否** | 进度落库 5 秒节流的时间戳，只在 `persistReadProgress` 内读写 |
// | `bmProbeKey`    | `ReaderPage3:586`  |  3 处 | **否** | 书签查库去重键，只在 `syncBookmarkState` / `toggleBookmark` 内读写 |
// 五个字段**全部不是** `@State`/`@StorageLink`/`@Watch` 目标 ⇒ 收进普通 class 不会动渲染，
// 这是本批能"零时序变化"的前提（`ReaderPage3:1457` 原注释即写明「精确定位状态机」）。
//
// ── 本批搬进来的函数（2 个）───────────────────────────────────────────────────
// · `persistReadProgress` —— 只依赖 `bookData` + `lastPersistAt` + `ReaderPorts`（写库窄口）；
// · `checkFinished`       —— 只依赖 `bookData` + `ReaderPorts`。
// 两者都**不碰 `@State`、不碰 `UIContext`、不发事件**，且都没有调用方时序要求（`void` 返回）。
//
// ⚠️ 函数体除 `this.<成员>` → 本类字段 / 显式形参外**逐字未改**（连注释一起搬）：
//   值的来源、判断顺序、节流阈值（5000ms）、SQL 语义全部原样。
//   唯一的结构性变化：`this.bookData`（页面 `@State bookData: Books`）→ 显式形参 `book`。
//
// ── 本批**刻意不搬**（仍留 `ReaderPage3.ets`，理由逐条见 A-4 报告）─────────────
// · `syncBookmarkState` —— 结果直接写 `@State isBookmarked`（`ReaderPage3:584`，顶栏图标实心/空心），
//   而且读 `catalogIndexForSpine()`（页面目录表）；本类只承载它的去重键 `bmProbeKey`。
// · `toggleBookmark` —— 写/删书签行 + **两个 toast**（`getUIContext().getPromptAction().showToast`）
//   + 写 `@State isBookmarked` + 调 `currentPageFirstLine()`（会写 `TtsEngine` 预览缓存）。
//   搬它等于把 UIContext 传进来，属于"@State/UI 强依赖"⇒ 按任务口径不搬。
// · `flushReadProgressThenNotifyShelf` —— 本批未被点名（属"发事件"类，下一批连同时序一起搬）。
//   ✅ 2026-11-04（P3 批 A-5）**已搬**：见本文件「四、出站发布与退书结算」段；页面只留调用点。
//
// ── 为什么不把 `bookData` 也收进来 ─────────────────────────────────────────
// 页面 `bookData` 是 `@State`，且在 `aboutToAppear` 里**整体替换对象**
// （`ReaderPage3:4202 this.bookData = temp.bookData`、`:4203` 再用 Preferences 覆盖一次）。
// 若本类持有它的引用，进书瞬间会拿到 `new Books()` 这个空壳 ⇒ 写库写错书。
// 故一律**显式形参传入**（`book: Books`），本类不持有任何书籍数据（单一真源仍在页面）。
//
// 回退：删本文件，把 5 个字段与 2 个函数的函数体原样搬回 `ReaderPage3.ets`（`git revert` 本批提交）。

// ── P3 批 A-5（2026-11-04）：出站发布（4 个 `publish*`）+ 退书结算 搬进来的判据 ──────
// 判据仍是 A-3/A-4 那三条，本批全部满足：
//   ① **都是"出站"**：只把页面事实写到 AppStorage（`LT_PAGE_BG*` / `READER_READ_MODE`）/
//      Preferences（`BookToc_*`）/ `ContinueBridge`（不落盘）/ `books` 表（经 `ReaderPorts`）；
//   ② **不碰 `@State`**：五个函数的执行体里没有一行给状态变量赋值（只读）；
//   ③ **不碰 UIContext / UI**：没有 toast、没有 `getUIContext()`、没有刷新器。
// ⇒ 唯一"页面私有"的东西是**读到的值**（书 / 排版设置 / 阅读方式 / 自绘层位置），
//   一律走显式入参 `PublishFacts` / `Books` / `string[]` 传进来 —— 本类**不持有**任何页面
//   状态对象的引用（理由同上面「为什么不把 bookData 也收进来」：`@State` 对象在
//   `aboutToAppear` 会被整体替换成新实例，持引用就会拿到空壳/旧壳）。
//
// ⚠️ **时序一行未动**（这是本批唯一的风险面，逐条交代）：
//   · `flushReadProgressThenNotifyShelf` 仍是 `async`，调用点仍在 `aboutToDisappear()`
//     同一行、仍然**不 await**（转场不被落库拖住）；
//   · 4 个 `publish*` 全部保持**同步 void**，没有引入 await/Promise，
//     调用点位置（`aboutToAppear` 的 setPageConfig 旁 / `pageShow` / `onScrollPos` 尾部 /
//     `onSentence` 回调 / `loadReadMode` / `switchReadMode`）逐处不变；
//   · 唯一改动是每个调用点从 `this.xxx()` 变成 `this.session.xxx(入参)`，
//     入参在**同一行同一时刻**求值（读的都是当时的字段值，无副作用）。
//
// ── 本批刻意**没搬**的 ──────────────────────────────────────────────────────
// · `publishContinueStateWith` 的 **调用方**只有本段的两个方法 ⇒ 它跟着搬（否则两个家）；
// · 模式的"哪一档算无动画"仍留在页面（`READ_MODE_NONE` 是 `ReaderPage3` 的模块常量，
//   `ReaderConst` 里没有它）⇒ `publishReadModeFlag(noAnim: boolean)` 只收**判定结果**，
//   键名 `READER_READ_MODE` 与 `'none' / ''` 的映射口径集中在本类（写入端唯一）。


import { readerCore } from '@kit.ReaderKit';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { Books } from '../../database/entities/Books';
import { TtsEngine, TtsSegmentPos } from '../../tts/TtsEngine';
import { ReaderCustomBg, ReaderBgRecord } from '../utils/ReaderCustomBg';
import { ContinueBridge, ContinuePayload } from '../utils/ContinueBridge';
import UiMotion from '../utils/UiMotion';
import ReaderPorts from './ReaderPorts';
import { PageRange } from './ReaderCalibMath';
import { ReaderPosition, currentPosition, domPosFor } from './ReaderProgressIo';

// ══════════════════════════════════════════════════════════════════════════════
// 一、定位状态机的两个类型（`ReaderPage3.ets` 原第 163-193 行，逐字搬来，类型只留一份）
// ══════════════════════════════════════════════════════════════════════════════

/** 定位目标（ReaderKit 坐标） */
export interface LocateTarget {
  spine: number;
  node: number;
  char: number;
  /** true = 自动跟随（不弹 toast） */
  silent: boolean;
  /**
   * true = **禁止"逐页逼近"兜底**（2026-09-21 新增）。
   *
   * 背景（真机反馈）：「我的 → 书签」点一条书签跳到阅读页后，**界面点不动、像有蒙版**。
   * 根因就是本文件的定位兜底：`startPlay` 没落到位时会走 `beginSearch` / `stepSearch`
   * **逐页翻页逼近**，上限 `s.flips >= 60`（最多连续重排 60 页）。这段时间里阅读器一直在
   * 重新分页，用户看到的就是"完全没反应"。
   *
   * 书签里存的 `chapterPos` 是**当时那一页的块节点号**，一旦与当前排版不符（旧书签尤其如此），
   * 就必然触发这条兜底 ⇒ 必须给它一个"宁可不准、也不要卡住"的档位。
   * 置 true 后：落不到目标就**停在当前章**（`finishLocate(target, false)`），不再翻页搜索。
   */
  noFallback?: boolean;
}

/** 翻页搜索兜底：startPlay 未把我们送到目标时，按 (节点,字符) 双坐标逐页逼近 */
export interface FlipSearch {
  target: LocateTarget;
  dir: number;      // 1=向后翻 -1=向前翻
  flips: number;    // 已翻页数（上限保护）
  fixes: number;    // 已换向校正次数（上限保护）
  lastNode: number; // 最近一次 pageShow 的页首块节点号（去重防过期数据）
  lastChar: number; // 最近一次 pageShow 的页内字符偏移
}

// ══════════════════════════════════════════════════════════════════════════════
// 二、会话状态（5 个字段的**唯一**归属处）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 出站发布用的**页面事实快照**（P3 批 A-5 新增）。
 *
 * 对应原 `ReaderPage3` 里被 4 个 `publish*` 随手读到的页面字段：
 * `this.bookData`（@State）/ `this.readerSetting`（@State）/ `this.readMode`（@State）/
 * `this.selfDrawnModeOn()` / `this.scrollSpine` / `this.scrollNode`（普通成员）。
 *
 * ⚠️ 这只是"当次调用的入参打包"，**不是**第二份状态：调用点在**同一行同一时刻**现取现传，
 *   本类用完即弃、不缓存、不持有 —— 避免 `@State bookData` 在 `aboutToAppear` 被整体替换后
 *   本类还攥着旧壳（见文件头「为什么不把 bookData 也收进来」）。
 */
export interface PublishFacts {
  /** 当前书籍（原 `this.bookData`） */
  book: Books;
  /** 当前排版/外观设置（原 `this.readerSetting`） */
  setting: readerCore.ReaderSetting;
  /** 当前阅读方式（原 `this.readMode`；0=仿真 / 1=横滑 / 2=滚动 / 3=无动画） */
  readMode: number;
  /** 当前是否处于**任一自绘层**（原 `this.selfDrawnModeOn()`；滚动 / 无动画 = true） */
  selfDrawn: boolean;
  /** 自绘层实时章节号（原 `this.scrollSpine`；分页模式该值无意义，`selfDrawn=false` 时不被读） */
  scrollSpine: number;
  /** 自绘层实时块节点号（原 `this.scrollNode`；同上） */
  scrollNode: number;
}

/**
 * 阅读器**一次进书会话**的可变状态。
 *
 * 刻意**不加** `@Observed`：这 5 个字段原就不是响应式数据（见文件头表格），
 * 加装饰器会改变 ArkUI 的依赖收集行为 —— 那是行为变化，不是搬家。
 */
export class ReaderSession {
  // 精确定位状态机（ReaderKit 坐标系：spine / 块节点 / 节点内字符）
  // 原 `ReaderPage3.ets:1458`
  pageRange: PageRange | null = null;
  // 原 `ReaderPage3.ets:1459`
  locateTarget: LocateTarget | null = null;
  // 原 `ReaderPage3.ets:1460`
  flipSearch: FlipSearch | null = null;

  /** 上次写数据库的时刻（节流用，避免每次翻页都落库）—— 原 `ReaderPage3.ets:623` */
  lastPersistAt: number = 0;

  /** 最近一次书签状态探测的位置，避免重复查询 —— 原 `ReaderPage3.ets:586` */
  bmProbeKey: string = '';

  // ════════════════════════════════════════════════════════════════════════════
  // 三、写库函数（`ReaderPage3` 原第 630-647 行 / 662-677 行，函数体逐字搬来）
  // ════════════════════════════════════════════════════════════════════════════

  /**
   * 把阅读进度落到 `books` 表（5 秒节流）。
   * 见 `BooksDao.stampReadProgress` 注释：这是当前阅读页**唯一的**进度落库点。
   * 没有它，「我的 → 读过」永远是 0、书架"最近阅读"排序也失效。
   *
   * @param book 当前书籍（原 `this.bookData`，页面 `@State`）
   */
  persistReadProgress(book: Books): void {
    try {
      const id = book.id ?? 0
      if (id <= 0) {
        return // 无 id 的路径（如搜索→详情→直接阅读）无法按 id 更新，跳过
      }
      const now = Date.now()
      if (now - this.lastPersistAt < 5000) {
        return
      }
      this.lastPersistAt = now
      // 2026-11-03（Ⅴ-1）：写入走阅读器窄口（节流仍在上面判 —— 那是体验参数，不是数据契约）
      ReaderPorts.saveProgress(ReaderPorts.snapshotOf(book), book.durChapterIndex ?? 0,
        book.durChapterTitle ?? '', book.totalChapterNum ?? 0)
    } catch (e) {
      // 忽略：落库失败不得影响阅读
    }
  }

  /**
   * 「读完」判定 —— 读到**最后一章**时写 `finishedTime`。
   *
   * 口径（2026-09-21 用户拍板）：「打开到最后一章就算读完」。
   * 为什么放宽：原实现额外要求 `TtsEngine.currentNodeTexts()` 非空、且
   * `TtsEngine.currentChapter() === durChapterIndex`，也就是**必须开着听书**才可能判定。
   * 但「读过/读完」的主体场景恰恰是**纯默读**，于是「读完」恒为 0。
   *
   * 为什么进度**会回退**却不能只看 `durChapterIndex`：读完后回第一章重看时
   * `durChapterIndex` 会变小。故写入走 `BooksDao.markFinished()`，其 SQL 带
   * `AND (finishedTime IS NULL OR finishedTime = 0)` —— **只写一次**，重复到达末章
   * 不会改时间、也不会重复计数。
   *
   * @param book 当前书籍（原 `this.bookData`，页面 `@State`）
   */
  checkFinished(book: Books): void {
    try {
      const total = book.totalChapterNum ?? 0
      const idx = book.durChapterIndex ?? 0
      if (total <= 0 || idx < total - 1) {
        return
      }
      // 到了末章 ⇒ 标记读完（SQL 保证只写一次）
      const id = book.id ?? 0
      if (id > 0) {
        ReaderPorts.markFinished(ReaderPorts.snapshotOf(book))
      }
    } catch (e) {
      // 忽略：读完判定失败不得影响翻页
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 四、出站发布与退书结算（`ReaderPage3` 原第 610-636 / 3963-4007 / 4797-4836 /
  //     10882-11012 / 11923-11939 行，函数体与注释逐字搬来）
  //
  // 入参口径：一律**显式**传入当次调用读到的事实，本类不缓存、不持有页面状态对象。
  //   理由见文件头「为什么不把 bookData 也收进来」——`@State` 对象会被整体替换。
  // ════════════════════════════════════════════════════════════════════════════

  /**
   * 阅读会话结束 ⇒ **先落库最终进度，再广播书架刷新**（2026-10-07）。
   *
   * ── 缺口 ────────────────────────────────────────────────────────────────
   * 书架列表的唯一数据刷新通道是 AppStorage 键 `BOOK_IS_BOOK_REFRESHING`
   * （`BookContent` `@StorageLink+@Watch` ⇒ 重查数据库，排序 SQL 为
   * `isTop DESC, durChapterTime DESC`，见 `BooksDao.searchPage`）。本页写进度的
   * `persistReadProgress()` 只落库、从不广播；而阅读页是 NavDestination，
   * pop 回书架时宿主 `Index.onPageShow()` **不会触发**（Index.ets :331 注释已实证）
   * ⇒ 「看完书回书架，刚读的书不置顶、'读到第X章'停在旧值」，要手动下拉刷新。
   *
   * ── 为什么必须 await 落库完成后再广播 ────────────────────────────────────
   * `stampReadProgress` 是异步 UPDATE；先广播后落库的话，书架重查会读到**旧行**
   * （与 `BooksDao.ets` 「网络导入竞态」注释同一坑：信号到了、行还没写进去 ⇒
   * 界面不更新，要等下次）。所以这里 await 到 UPDATE 提交再自增广播键。
   *
   * ── 调用点 ──────────────────────────────────────────────────────────────
   * `aboutToDisappear()`（pop 转场结束、组件销毁时触发，见 Index.ets LTBOOK
   * 日志注记 onDisappear 晚于 transition finish）——此时书架刚可见，重查在落地后
   * 一两帧内完成，与下拉刷新同量级开销。兜底语义：即使 5 秒节流吞掉了最后一次
   * `persistReadProgress()`，退出前这里也会把最终进度补写进去。
   *
   * ⚠️ 本方法**故意不 await**（调用点亦然）：转场结束不能被落库拖住；上面那段
   *   "await 后再广播"是**本方法内部**的顺序，与调用方是否 await 无关。
   *
   * @param book 当前书籍（原 `this.bookData`，页面 `@State`）
   */
  async flushReadProgressThenNotifyShelf(book: Books): Promise<void> {
    // 2026-11-03（Ⅴ-1）：退书结算收敛为**一个窄口调用**（内部：await 写库 → 再广播书架刷新）
    await ReaderPorts.settleOnExit(ReaderPorts.snapshotOf(book), book.durChapterIndex ?? 0,
      book.durChapterTitle ?? '', book.totalChapterNum ?? 0)
  }

  /**
   * 把「内容页长什么样」发布给书架→阅读器一镜到底的飞行层（七轮 2026-09-30）。
   *
   * ── 为什么需要 ────────────────────────────────────────────────────────────
   * 真机日志（`Downloads\2.md`）实证：返回一开始 NavDestination 就进 `onHidden`
   * （22:07:16.894），而我们的自定义转场 22:07:16.895 才起 ⇒ 阅读器的 RS surface
   * 那一层不再合成（截图逐像素也证明：飞行书盒子内部能看到书架自己的黑色标题字）
   * ⇒ 飞行层裁剪层是"空的"，没被封面盖住的地方直接漏出书架定格图
   * （用户原话："原位有一本书在，然后我们的书关闭动画缩放完又落在上面了"）。
   * 飞行层拿不到 `readerSetting`（它是页面私有状态）⇒ 由本页把页面外观发布到 AppStorage，
   * 飞行层照它铺一层底衬（见 `Index.ets` 飞行分支的裁剪层 / `UiMotion.LT_PAGE_BG`）。
   *
   * ── 调用点 ────────────────────────────────────────────────────────────────
   * 每个**真正改页面外观**的地方，紧挨着既有的 `setPageConfig(...)`：
   * 推荐色、自定义颜色、材质/纹理背景、日夜标准色、`aboutToAppear` 首次下发。
   * 幂等、无副作用（只写两个 AppStorage 字符串）。
   *
   * @param setting 当前排版/外观设置（原 `this.readerSetting`，页面 `@State`）
   */
  publishLtPageBg(setting: readerCore.ReaderSetting): void {
    if (!UiMotion.LT_PAGE_BG) {
      return
    }
    // 背景图：`themeBgImg` 是**沙箱路径**（见 applyTextureBg / applyComposedBg）；
    // ⚠️ `Image` **不接受裸沙箱路径**，必须转成沙箱 URI —— 官方 FAQ
    // `FAQ/UI框架/组件使用/Image组件如何读入沙箱内的图片/faqs-arkui-154` 原文：
    //   「Image组件**不能直接传入应用沙箱路径**，需要传入应用沙箱URI。…调用
    //    `fileUri.getUriFromPath` 方法将沙箱路径转化为沙箱 URI，传入之后即可正常显示沙箱图片。」
    // （API：`fileUri.getUriFromPath(path: string): string`，SDK `@ohos.file.fileuri.d.ts`，
    //   @since 15，会抛 401 ⇒ 必须包 try/catch。）
    // 非绝对路径（例如 themeBgImg 里存的是 rawfile 名）一律不发布图片，只留纯色底。
    const raw: string = setting.themeBgImg ?? ''
    let img: string = ''
    if (raw.startsWith('/')) {
      try {
        img = fileUri.getUriFromPath(raw)
      } catch (e) {
        img = ''
        hilog.info(0x0000, 'testTag', 'LTBOOK publish page bg img uri failed: %{public}s',
          (e as BusinessError)?.message ?? 'error')
      }
    }
    AppStorage.setOrCreate(UiMotion.LT_PAGE_BG_KEY, setting.themeColor ?? '')
    AppStorage.setOrCreate(UiMotion.LT_PAGE_IMG_KEY, img)
    hilog.info(0x0000, 'testTag', 'LTBOOK publish page bg color=%{public}s img=%{public}s',
      setting.themeColor ?? '', img)
  }

  /**
   * 发布目录标题快照（M3 单源目录，2026-10-05）。
   *
   * 目的：让电脑端与手机端**用同一份章节划分**（现在两端各切各的：手机 ReaderKit、
   * 网页空行+标题正则 ⇒ 章号/百分比/书签位置全都对不上，只能靠文本模糊匹配）。
   *
   * 为什么只发布"标题"而字符偏移交给服务端算：详见 WifiBookServer.locateToc 注释 ——
   * 只有在服务端才能在**正在下发的那一串解码文本**上定位，避免"两端口径不同 ⇒ 偏移全错"。
   * 只在标题数组变化时写盘（开书高频，避免每次都写）。
   *
   * @param bookName 书名（原 `this.bookData?.bookName ?? ''`）
   * @param titles 目录标题数组（原方法内从 `this.CatalogList` 逐个 `catalogName` 取的循环，
   *   现由调用点在**同一时刻**建好后传入 —— 取数时机与内容逐项一致）
   */
  publishBookToc(bookName: string, titles: string[]): void {
    try {
      const name: string = bookName
      if (name === '') {
        return
      }
      const n: number = titles.length
      if (n <= 0) {
        return
      }
      const key: string = `BookToc_${name}`
      const next: string = JSON.stringify(titles)
      let prev = ''
      try {
        prev = PreferencesUtil.getSync(key, '') as string
      } catch (e) {
        prev = ''
      }
      if (prev !== next) {
        PreferencesUtil.putSync(key, next)
        hilog.info(0x0000, 'testTag', 'bookToc published: %{public}d titles', n)
      }
    } catch (e) {
      hilog.error(0x0000, 'testTag', `publishBookToc failed: ${(e as Error).message}`)
    }
  }

  /**
   * 应用接续（无缝流转，2026-10-24）：把"此刻读到哪儿 + 用什么排版"登记到
   * `ContinueBridge`（AppStorage，不落盘），供 `EntryAbility.onContinue()` 打包进
   * `wantParam` 送到对端。
   *
   * ── 带什么 / 不带什么（用户 2026-10-24 拍板）─────────────────────────────
   * ✅ 带：字体、字重、字色、主题色、背景、日/夜、翻页模式、进度（双坐标）
   * ❌ 不带：字号、行距 —— 每块屏幕按自己的尺寸排版，**布局不变**
   *
   * 调用点：`pageShow`（分页模式每次翻页）、`onScrollPos` 尾部（滚动模式每次滚动）。
   * ⚠️ 滚动模式**不能**挂在 `persistScrollProgress()` 里 —— 那个被
   *   `SCROLL_PERSIST_GAP_MS` 节流，快速滚动时会上报旧位置（真机日志 01:18:00 实证）。
   */
  publishContinueState(facts: PublishFacts): void {
    // 位置统一走 `currentPosition()`（滚动=实时值 / 分页=pageShow 值）
    const pos: ReaderPosition = currentPosition(facts.selfDrawn, facts.scrollSpine,
      facts.scrollNode, facts.book.localBookDurChapterPos, this.pageRange);
    // 双坐标：domPos 与 (node, char) 一并带（对端 domPos 异常时用 node/char 重算）
    this.publishContinueStateWith(facts, pos.spine, domPosFor(pos.node, pos.char),
      pos.node, pos.char, TtsEngine.getState() !== 'stopped');
  }

  /**
   * 听书进度上报（2026-10-24 新增）。
   *
   * 官方《常见接续场景体验建议》对「新闻阅读」类明确要求同步「阅读**及听书**进度」。
   * `TtsEngine.currentSegment()` 给的是同一套 ReaderKit 坐标（spine / 块节点 / 节点内字符），
   * 用 `domPosFor(node, char)` 换算成字符级 DOM 锚点 ⇒ 对端能精确落到"正在听的那句"。
   *
   * 调用点：TTS 的「按句推进」回调（`onSentence` 分支）—— 每推进一句刷新一次，
   * 频率与听书进度显示一致，不额外增加唤醒。
   */
  publishListenState(facts: PublishFacts): void {
    // ⚠️ 用公开的 `getState()`，不要用 `TtsEngine.isPlaying()`（那是 private）
    if (TtsEngine.getState() === 'stopped') {
      return;
    }
    const seg: TtsSegmentPos | null = TtsEngine.currentSegment();
    if (seg === null || seg.spineIndex < 0) {
      return;
    }
    this.publishContinueStateWith(facts, seg.spineIndex,
      domPosFor(seg.nodeIndex, seg.charStart ?? 0),
      seg.nodeIndex, seg.charStart ?? 0, true);
  }

  /** 用指定落点发布接续态（阅读/听书分支共用；`listen` 仅用于标记来源） */
  publishContinueStateWith(facts: PublishFacts, spineIndex: number, domPos: string,
    nodeIndex: number, charOffset: number, listen: boolean): void {
    const name: string = facts.book.bookName ?? '';
    if (name.length === 0) {
      return;
    }
    let bgJson: string = '';
    try {
      const rec: ReaderBgRecord | null = ReaderCustomBg.loadBook(name);
      if (rec !== null) {
        const s: string = JSON.stringify(rec);
        bgJson = s.length <= 4000 ? s : '';
      }
    } catch (e) {
      bgJson = '';
    }
    const payload: ContinuePayload = {
      bookName: name,
      bookUrl: facts.book.bookUrl ?? '',
      chapterTitle: facts.book.durChapterTitle ?? '',
      spineIndex: spineIndex,
      domPos: domPos,
      nodeIndex: nodeIndex,
      charOffset: charOffset,
      // ✅ 带：字体/字重/字色/主题色/背景/日夜/翻页模式
      // ❌ 不带：字号/行距（屏幕比例不同，真正影响体验的只有这两个）
      fontName: facts.setting.fontName ?? '',
      fontPath: facts.setting.fontPath ?? '',
      fontWeight: facts.setting.fontWeight ?? 0,
      fontColor: facts.setting.fontColor ?? '',
      themeColor: facts.setting.themeColor ?? '',
      themeBgImg: facts.setting.themeBgImg ?? '',
      nightMode: facts.setting.nightMode === true,
      // ⚠️⚠️ 2026-10-24 修（真机日志定案）：**必须报 `readMode`，不能报 `readerSetting.flipMode`**。
      //   事故（`docs/日志.md` 00:12:41）：源端在**上下滚动**档接续，对端收到 `flipMode=1`
      //   ⇒ 变成横滑。
      //   根因：`loadReadMode()` 里只有分页两档会回写 `readerSetting.flipMode`
      //     （`if (m === CURL || m === SLIDE) { … }`），**滚动档不回写** ⇒ 滚动时
      //     `readerSetting.flipMode` 仍是上一次分页的旧值（'0'/'1'），于是上报的是脏数据。
      //   真正的权威状态是 `@State readMode`
      //   （0=仿真 / 1=横滑 / 2=滚动 / 3=无动画，见 `READ_MODE_*` 常量）。
      //   '3' 的跨版本兼容（2026-10-26 用户拍板"支持就支持，不支持就降级"）：
      //   老版本对端把 '3' 解析成仿真（`applyContinue` 里三元链的兜底），
      //   不崩溃、只是降级 —— 对端升级后自然就是无动画。
      flipMode: String(facts.readMode),
      bgJson: bgJson,
      sessionId: '',
      listenMode: listen
    };
    ContinueBridge.publish(payload);
  }

  /**
   * 把"当前是否无动画阅读档"同步到 AppStorage，供 `Index.ets` 的 `onBackPress()` 判定
   * （2026-10-26 新增）。
   *
   * 为什么必须走 AppStorage 而不是本页自己的判断：真机日志实证
   * （`Documents\日志` 18:30:42.579）—— 右滑时 `PAN RACC, T: Stack`（系统侧滑返回）
   * 抢走手势，紧接着 `isPopPage: 1` 把整本书 pop 掉，而 `NavDestination.onBackPressed`
   * **根本没被触发**（日志无 `PDFZOOM` 行）⇒ 侧滑返回只在 `@Entry` 页面层可拦。
   * 本页的 `priorityGesture` 对它无效（那是系统级识别器，不是组件树父手势）。
   *
   * ⚠️ 取值只用 `'none'` / `''` 两种：`''` = 不是无动画档（不拦返回）。
   *    仿真/横滑由引擎自己处理左右滑、上下滚动档右滑是加书签，都不该吞掉整页返回。
   *
   * @param noAnim 是否处于无动画档（原 `this.readMode === READ_MODE_NONE` —— 判定仍在页面：
   *   门禁口径 `noAnimModeOn()` 还多两条件（预览格式 / 转换失败），**不可**拿来顶替本判定）
   */
  publishReadModeFlag(noAnim: boolean): void {
    AppStorage.setOrCreate('READER_READ_MODE', noAnim ? 'none' : '');
  }
}

export default ReaderSession;
