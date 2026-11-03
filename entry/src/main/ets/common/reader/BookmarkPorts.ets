import bookmarksDao, { BookmarkRow } from '../../database/dao/BookmarksDao'

/**
 * 2026-11-03（阶段 Ⅴ-2）：**书签 lane 的唯一出入口**。
 *
 * ── 为什么需要它 ───────────────────────────────────────────────────────────
 * 收口前 `bookmarksDao` 被 **6 个文件、13 处**直接调用：
 *   `ReaderPage3`（加/删/列）、`PdfViewerPage`（判重/删/加/列/删）、`ReaderBookmarkDialog`（列）、
 *   `WifiBookServer`（传书端加/删/列）、`BookRename`（改名级联 + 随书清理）、`index`（建表）。
 * 于是"书签"这条事实有 6 个写入口 —— 与 Ⅱ-1 之前 `GroupMutation` 的缺口、Ⅴ-1 之前阅读进度
 * 的 4 个写点完全同类。
 *
 * ── 契约 ────────────────────────────────────────────────────────────────────
 * · 读（list / isMarked / exists）：一律走本类，页面不再碰 DAO；
 * · 写（add / removeByTime / removeAt / deleteByBookName / renameSqls）：**只允许本类调用 DAO**；
 * · **本类不广播书架刷新**：书签不影响书架列表/计数（`books` 表没变），广播是过度刷新。
 *   若将来出现"书签图标要同步到书架卡片"，在这里加一次 `ShelfRefresh.books()` 即可，仍是一处。
 *
 * ── 与既有实现的关系（行为等价）──────────────────────────────────────────────
 * 参数顺序、去重语义（`dedupeAtPosition` / `webKey` 存 `content`）、
 * "只写一次"的 SQL 判定全部原样透传，**不改任何 DAO 行为**。
 */
export class BookmarkPorts {
  // ── 读 ──────────────────────────────────────────────────────────────────

  /** 全部书签（按时间倒序，DAO 决定） */
  static async list(): Promise<BookmarkRow[]> {
    return await bookmarksDao.list()
  }

  /** 某本书某章的書签 */
  static async listByChapter(bookName: string, chapterIndex: number): Promise<BookmarkRow[]> {
    return await bookmarksDao.listByChapter(bookName, chapterIndex)
  }

  /** 该位置是否已加过书签（书内位置判定） */
  static async isMarked(bookName: string, chapterIndex: number, chapterPos: number): Promise<boolean> {
    return await bookmarksDao.isBookmarked(bookName, chapterIndex, chapterPos)
  }

  /** 同一稳定身份（网页端 `webKey`，存在 `content` 列）是否已存在 */
  static async exists(bookName: string, content: string): Promise<boolean> {
    return await bookmarksDao.existsByContent(bookName, content)
  }

  /** 书签总数（统计页用） */
  static async count(): Promise<number> {
    return await bookmarksDao.count()
  }

  // ── 写 ──────────────────────────────────────────────────────────────────

  /**
   * 加书签。
   * @param dedupeAtPosition true = 同位置已存在则直接返回 true（不重复插）
   * @param content 网页端用稳定身份 `webKey`（`章标题#段号#段首10字`），手机端一般留空
   */
  static async add(bookName: string, bookAuthor: string, chapterIndex: number, chapterPos: number,
    chapterName: string, bookText: string, dedupeAtPosition: boolean = false,
    content: string = ''): Promise<boolean> {
    return await bookmarksDao.add(bookName, bookAuthor, chapterIndex, chapterPos, chapterName, bookText,
      dedupeAtPosition, content)
  }

  /** 按主键毫秒时间戳删（网页端交付的 `time`；调用方必须已校验归属，见 WifiBookServer.marksdel） */
  static async removeByTime(time: number): Promise<boolean> {
    return await bookmarksDao.remove(time)
  }

  /** 按书内位置删（阅读页"再点一次取消书签"） */
  static async removeAt(bookName: string, chapterIndex: number, chapterPos: number): Promise<boolean> {
    return await bookmarksDao.removeAt(bookName, chapterIndex, chapterPos)
  }

  /** 删书时清理该书全部书签 */
  static async deleteByBookName(bookName: string): Promise<void> {
    await bookmarksDao.deleteByBookName(bookName)
  }

  /**
   * 改名级联：返回要并入改名前事务的 SQL 片段（`BookRename` 统一 `runInTransaction`）。
   * ⚠️ 只返回 SQL，不执行 —— 事务边界仍由 `BookRename` 单点持有。
   */
  static renameSqls(oldName: string, newName: string): string[] {
    return bookmarksDao.renameBookSqls(oldName, newName)
  }

  /** 建表/迁移（只在启动引导里调用一次） */
  static async initTable(): Promise<void> {
    await bookmarksDao.initBookmarksTable()
  }
}

export default BookmarkPorts
