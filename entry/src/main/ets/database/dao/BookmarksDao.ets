import DbUtil from '../../common/utils/DbUtil'
import AppDatabaseUtil from '../AppDatabaseUtil'
import { ColumnInfo } from '../types/ColumnInfo'

/**
 * 书签记录（`bookmarks` 表）。
 *
 * ⚠️ **背景（2026-09-21 取证）**：本工程底座**没有书签功能** ——
 * `bookmarks` 表是从原 Android Legado 移植时**原样带过来的遗留物**：
 * 全工程没有任何代码写它/读它，也没有"添加书签"的入口。
 * 表结构（`AppDatabase/index.ets:1445`）：
 * ```
 * CREATE TABLE `bookmarks` (
 *   `time` INTEGER NOT NULL, `bookName` TEXT NOT NULL, `bookAuthor` TEXT NOT NULL,
 *   `chapterIndex` INTEGER NOT NULL, `chapterPos` INTEGER NOT NULL,
 *   `chapterName` TEXT NOT NULL, `bookText` TEXT NOT NULL, `content` TEXT NOT NULL,
 *   PRIMARY KEY(`time`))
 * ```
 * 其中 `bookText` 正是为"记录书签处那一页的文本"预留的（需求：**该页首行前 10 个字符**）。
 *
 * 本 DAO 目前只提供**计数与列表读取**，供「我的 → 书签」展示真实数据。
 * 在书签功能（写入端 + 入口）落地之前，它的真实结果就是 **0** ——
 * 这不是 bug，而是"表是空的"。刻意保留真实查询而非硬编码 0。
 */

/** 书签行（对齐 `bookmarks` 表列） */
export interface BookmarkRow {
  time: number
  bookName: string
  bookAuthor: string
  chapterIndex: number
  chapterPos: number
  chapterName: string
  bookText: string
  content: string
}

/** SQL 单引号转义（书名/正文里出现 `'` 会让语句断裂） */
function esc(s: string): string {
  return (s ?? '').replace(/'/g, "''")
}

class BookmarksDao {
  TABLE_NAME: string = 'bookmarks'

  /**
   * 建 `bookmarks` 表。
   *
   * ⚠️ **必须显式建表** —— 真机实测（2026-09-21 15:19）报 `no such table: bookmarks`，
   * `add()` 返回 `{"code":14800021}`。根因：`database/index.ets` 的 `initAllTable()`
   * 只初始化 8 张表（书源/订阅/books/groups/worksLists/bookHistory/rssSources/
   * bookSourceGroup），**`bookmarks` 不在其中** —— 虽然 `AppDatabase/index.ets:1445`
   * 已定义好建表语句，但**没有代码去调用它**。
   * 这正是底座"有表无功能"的另一半：表不但没人用，连建都没建。
   */
  async initBookmarksTable(): Promise<void> {
    try {
      const createSql = AppDatabaseUtil.getCreateSql(this.TABLE_NAME)
      if (!createSql) {
        return
      }
      await DbUtil.createTable(createSql)
    } catch (e) {
      console.log('initBookmarksTable, Error, ', JSON.stringify(e))
    }
  }

  /**
   * 新增/更新书签。
   * `bookText` 按用户口径存**存书签时那一页首行前 10 个字符**
   * （调用方 `ReaderPage3` 用 `TtsEngine.currentNodeTexts()[pageRange.startNode]` 取首行）。
   *
   * @param dedupeAtPosition 2026-10-05：同 `(bookName, chapterIndex, chapterPos)` 已有书签时
   *   **不再重复插入**（返回 true）。手机端"点图标加/取消"依赖内存里的 `isBookmarked` 缓存，
   *   缓存过期时会重复插行（审计 4.4）⇒ 这里做最后一道兜底。
   * @param content 2026-10-05：原本恒为 `''`，现用作**网页书签的稳定身份**
   *   （`webKey = 章标题#段号#段首10字`），供服务端按它去重（该列原先无任何消费者）。
   */
  async add(bookName: string, bookAuthor: string, chapterIndex: number, chapterPos: number,
    chapterName: string, bookText: string,
    dedupeAtPosition: boolean = false, content: string = ''): Promise<boolean> {
    let t = Date.now()
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME)
      if (dedupeAtPosition) {
        const p = DbUtil.getPredicates(this.TABLE_NAME)
        p.equalTo('bookName', bookName)
        p.equalTo('chapterIndex', Math.floor(chapterIndex))
        p.equalTo('chapterPos', Math.floor(chapterPos))
        const n: number = await DbUtil.queryForCount(p, column)
        if (n > 0) {
          return true
        }
      }
      // ── 主键毫秒去重（2026-10-05 修，审计 H5）──────────────────────────────────
      // 本表 `PRIMARY KEY(time)`（`AppDatabase/index.ets:1445`）+ `INSERT OR REPLACE`
      // ⇒ 同一毫秒落两条（例如网页与手机同时加书签、或连点）时，**后者静默替换前者**，
      // 前一条无日志地消失。这里先探一下该毫秒是否被占用，占用就顺延 1ms（最多探 50 次）。
      const deadline: number = Date.now() + 50
      while (t < deadline) {
        const p = DbUtil.getPredicates(this.TABLE_NAME)
        p.equalTo('time', t)
        const occupied: number = await DbUtil.queryForCount(p, column)
        if (occupied === 0) {
          break
        }
        t++
      }
      await DbUtil.executeSql(
        'INSERT OR REPLACE INTO bookmarks'
          + ' (time, bookName, bookAuthor, chapterIndex, chapterPos, chapterName, bookText, content)'
          + ` VALUES (${t}, '${esc(bookName)}', '${esc(bookAuthor)}',`
          + ` ${Math.floor(chapterIndex)}, ${Math.floor(chapterPos)},`
          + ` '${esc(chapterName)}', '${esc(bookText)}', '${esc(content)}')`)
      return true
    } catch (e) {
      console.log('bookmarks add, Error, ', JSON.stringify(e))
      return false
    }
  }

  /** 按 `content`（网页书签的稳定身份 `webKey`）判断某本书是否已有该书签（2026-10-05 去重） */
  async existsByContent(bookName: string, content: string): Promise<boolean> {
    if (content === '') {
      return false
    }
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME)
      const p = DbUtil.getPredicates(this.TABLE_NAME)
      p.equalTo('bookName', bookName)
      p.equalTo('content', content)
      const list = await DbUtil.queryForList<BookmarkRow>(p, column)
      return list.length > 0
    } catch (e) {
      console.log('bookmarks existsByContent, Error, ', JSON.stringify(e))
      return false
    }
  }

  /** 该位置是否已有书签（判断图标实心/空心） */
  async isBookmarked(bookName: string, chapterIndex: number, chapterPos: number): Promise<boolean> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME)
      const p = DbUtil.getPredicates(this.TABLE_NAME)
      p.equalTo('bookName', bookName)
      p.equalTo('chapterIndex', Math.floor(chapterIndex))
      p.equalTo('chapterPos', Math.floor(chapterPos))
      const list = await DbUtil.queryForList<BookmarkRow>(p, column)
      return list.length > 0
    } catch (e) {
      console.log('bookmarks isBookmarked, Error, ', JSON.stringify(e))
      return false
    }
  }

  /** 按位置删除书签（切换用） */
  async removeAt(bookName: string, chapterIndex: number, chapterPos: number): Promise<boolean> {
    try {
      await DbUtil.executeSql(
        `DELETE FROM bookmarks WHERE bookName = '${esc(bookName)}'`
          + ` AND chapterIndex = ${Math.floor(chapterIndex)}`
          + ` AND chapterPos = ${Math.floor(chapterPos)}`)
      return true
    } catch (e) {
      console.log('bookmarks removeAt, Error, ', JSON.stringify(e))
      return false
    }
  }

  /** 书签总数 */
  async count(): Promise<number> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME)
      const p = DbUtil.getPredicates(this.TABLE_NAME)
      const list = await DbUtil.queryForList<BookmarkRow>(p, column)
      return list.length
    } catch (e) {
      console.log('bookmarks count, Error, ', JSON.stringify(e))
      return 0
    }
  }

  /** 书签列表（按时间倒序，最新在前） */
  async list(): Promise<BookmarkRow[]> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME)
      const p = DbUtil.getPredicates(this.TABLE_NAME)
      p.orderByDesc('time')
      return await DbUtil.queryForList<BookmarkRow>(p, column)
    } catch (e) {
      console.log('bookmarks list, Error, ', JSON.stringify(e))
      return []
    }
  }

  /**
   * 删除单条书签 —— **只删书签**，不影响「读过」「读完」记录
   * （三项相互独立，2026-09-21 用户明确要求）。
   */
  async remove(time: number): Promise<boolean> {
    if (time === undefined || time === null || time <= 0) {
      return false
    }
    try {
      await DbUtil.executeSql(`DELETE FROM bookmarks WHERE time = ${Math.floor(time)}`)
      return true
    } catch (e) {
      console.log('bookmarks remove, Error, ', JSON.stringify(e))
      return false
    }
  }
}

const bookmarksDao = new BookmarksDao()
export default bookmarksDao as BookmarksDao
