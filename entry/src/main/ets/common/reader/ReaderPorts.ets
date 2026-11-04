import { Books } from '../../database/entities/Books'
import BooksDao from '../../database/dao/BooksDao'
import { ShelfRefresh } from '../shelf/ShelfRefresh'

/**
 * 2026-11-03（阶段 Ⅴ-1）：**阅读器对外的两个窄接口**（进书快照 / 退书结算）。
 *
 * ── 为什么必须有它 ───────────────────────────────────────────────────────────
 * 阅读器（`ReaderPage3` / `PdfViewerPage`）原来自己拿 `BooksDao` 写 `books` 表：
 *   · `ReaderPage3`（历史行号 `:735` 节流保存 / `:799` 退出前补写 / `:765` 读完标记）
 *   · `PdfViewerPage:349`（PDF 换页保存）
 * ★ 2026-11-04（P3 批 A-4）**审计点已收拢**（下面是改后的真实位置）：
 *   · `common/reader/ReaderSession.ets:121`（`persistReadProgress`，写调用 `:133`）
 *   · `common/reader/ReaderSession.ets:155`（`checkFinished`，写调用 `:165`）
 *   · `ReaderPage3:634`（`flushReadProgressThenNotifyShelf` → `settleOnExit`）
 *   · `PdfViewerPage:352`（→ `settleOnExit`）
 *   ⇒ `ReaderPage3` 的写点 **3 → 1**（全仓仍 4 处，但全部经本类窄口，无一处直接碰 `BooksDao`）。
 * ★ 2026-11-04（P3 批 A-5）**审计点再收拢**（`flushReadProgressThenNotifyShelf` 也搬进 `ReaderSession`）：
 *   · `common/reader/ReaderSession.ets:133`（`persistReadProgress` → `saveProgress`）
 *   · `common/reader/ReaderSession.ets:165`（`checkFinished` → `markFinished`）
 *   · `common/reader/ReaderSession.ets`（`flushReadProgressThenNotifyShelf` → `settleOnExit`）
 *   · `PdfViewerPage:352`（→ `settleOnExit`）
 *   ⇒ `ReaderPage3` 的写点 **1 → 0**（该文件已不 import 本类）；全仓仍 4 处，全经本类窄口。
 * 于是"阅读进度"这条事实有 4 个写点，且各自决定是否 `await`、是否广播书架刷新 ——
 * 这正是本项目反复吃亏的模式（同一语义多条写入口）。
 *
 * ── 契约（用户 2026-11-03 定的边界）──────────────────────────────────────────
 * 阅读器只允许两个动作：
 *   ① **进书取快照**：`enterBook(bookId)` / `snapshotOf(book)` —— **只读**，不改任何状态；
 *   ② **退书结算**：`settleOnExit(...)` —— 写最终进度 + 广播书架刷新（一次）。
 * 其余一律不动：阅读器内部的排版/翻页/听书状态**不经过这里**。
 *
 * ── 与既有实现的关系（行为等价，勿改语义）──────────────────────────────────
 * · `stampReadProgress` 的 SQL 与节流（5 秒）都保留：节流仍在调用方（阅读器）判，
 *   因为"多久落一次库"是阅读体验参数，不是数据契约；
 * · `markFinished` 的"只写一次"由 `BooksDao` 的 SQL 保证（`finishedTime IS NULL OR = 0`）；
 * · 退出结算必须 **先 await 写库、再自增刷新键**（`ShelfRefresh.books()`），
 *   否则书架重查会读到旧行（2026-10-07 已踩，见 `ReaderSession.flushReadProgressThenNotifyShelf` 注释）。
 */
export interface ReaderBookSnapshot {
  /** `books.id`；<=0 表示这次进书没有可写的实体行（搜索→详情→直接阅读等路径） */
  bookId: number
  bookName: string
  bookGroup: number
  durChapterIndex: number
  durChapterTitle: string
  totalChapterNum: number
  finishedTime: number
}

export class ReaderPorts {
  /**
   * ① 进书快照（纯投影，不查库）。
   *
   * 用于阅读器**已经持有** `Books` 对象的场景（书架/详情页把书带进来了）——
   * 保持"单一数据来源"，不在这里再查一次库（避免比它带来的那个对象更新/更旧的分叉）。
   */
  static snapshotOf(book: Books): ReaderBookSnapshot {
    const snap: ReaderBookSnapshot = {
      bookId: book.id ?? 0,
      bookName: book.bookName ?? '',
      bookGroup: book.bookGroup ?? 3,
      durChapterIndex: book.durChapterIndex ?? 0,
      durChapterTitle: book.durChapterTitle ?? '',
      totalChapterNum: book.totalChapterNum ?? 0,
      finishedTime: book.finishedTime ?? 0
    }
    return snap
  }

  /**
   * ① 进书快照（按 id 读一行）。只给"只有 id、没有实体"的入口用。
   * @returns null = 库里没有这一行（调用方应据此跳过所有写操作，而不是拿 id<=0 硬写）
   */
  static async enterBook(bookId: number): Promise<ReaderBookSnapshot | null> {
    if (bookId <= 0) {
      return null
    }
    try {
      const rows: Books[] = await BooksDao.getBookByIds([bookId])
      if (rows.length === 0) {
        return null
      }
      return ReaderPorts.snapshotOf(rows[0])
    } catch (e) {
      console.error('[READER-PORT] enterBook failed: ' + JSON.stringify(e))
      return null
    }
  }

  /**
   * 阅读中保存进度（调用方自己决定节流节奏）。
   * @returns true = 已提交（bookId>0 且没抛错）
   */
  static async saveProgress(snap: ReaderBookSnapshot, index: number, chapterTitle: string,
    totalChapterNum: number): Promise<boolean> {
    if (snap.bookId <= 0) {
      return false
    }
    try {
      await BooksDao.stampReadProgress(snap.bookId, index, chapterTitle, totalChapterNum)
      return true
    } catch (e) {
      // 落库失败不得影响阅读
      console.error('[READER-PORT] saveProgress failed: ' + JSON.stringify(e))
      return false
    }
  }

  /** 读完标记（SQL 保证只写一次；重复调用安全） */
  static async markFinished(snap: ReaderBookSnapshot): Promise<boolean> {
    if (snap.bookId <= 0) {
      return false
    }
    try {
      await BooksDao.markFinished(snap.bookId)
      return true
    } catch (e) {
      console.error('[READER-PORT] markFinished failed: ' + JSON.stringify(e))
      return false
    }
  }

  /**
   * ② 退书结算：写最终进度（不节流）→ 刷新书架。
   *
   * ⚠️ 顺序不可调：必须 `await` 写库之后再 `ShelfRefresh.books()`，
   *   否则书架重查读到旧行，"刚读完的书不回顶"（2026-10-07 真机实证）。
   */
  static async settleOnExit(snap: ReaderBookSnapshot, index: number, chapterTitle: string,
    totalChapterNum: number): Promise<void> {
    if (snap.bookId > 0) {
      await ReaderPorts.saveProgress(snap, index, chapterTitle, totalChapterNum)
    }
    // 广播语义与传书入库（WifiBookServer.registerImportedBook）一致：自增刷新键
    ShelfRefresh.books()
  }
}

export default ReaderPorts
