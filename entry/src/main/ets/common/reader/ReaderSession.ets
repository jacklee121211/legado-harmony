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
//
// ── 为什么不把 `bookData` 也收进来 ─────────────────────────────────────────
// 页面 `bookData` 是 `@State`，且在 `aboutToAppear` 里**整体替换对象**
// （`ReaderPage3:4202 this.bookData = temp.bookData`、`:4203` 再用 Preferences 覆盖一次）。
// 若本类持有它的引用，进书瞬间会拿到 `new Books()` 这个空壳 ⇒ 写库写错书。
// 故一律**显式形参传入**（`book: Books`），本类不持有任何书籍数据（单一真源仍在页面）。
//
// 回退：删本文件，把 5 个字段与 2 个函数的函数体原样搬回 `ReaderPage3.ets`（`git revert` 本批提交）。

import { Books } from '../../database/entities/Books';
import ReaderPorts from './ReaderPorts';
import { PageRange } from './ReaderCalibMath';

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
}

export default ReaderSession;
