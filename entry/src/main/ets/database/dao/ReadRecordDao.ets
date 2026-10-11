/**
 * 阅读时长表 `readRecord` 的 DAO（2026-10-12 新建）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么现在才建它 —— 与 `bookmarks` 是**同一个坑的第二次发作**
 * ══════════════════════════════════════════════════════════════════════════
 * 本工程建表是**懒建表**：`database/index.ets` 的 `initAllTable()` 逐个调
 * `XxxDao.initXxxTable()`，而表定义（`AppDatabase/index.ets`）只是**离线快照** ——
 * `AppDatabaseUtil.getCreateSql()` 从快照里取 SQL，**没人调用就永远不会建表**。
 *
 * `readRecord` 正是如此：
 *   · 快照里有定义 —— `AppDatabase/index.ets:1749-1750`
 *       `CREATE TABLE IF NOT EXISTS readRecord (deviceId TEXT NOT NULL, bookName TEXT NOT NULL,
 *        readTime INTEGER NOT NULL DEFAULT 0, lastRead INTEGER NOT NULL DEFAULT 0,
 *        PRIMARY KEY(deviceId, bookName))`
 *   · `initAllTable()` 里**没有它** —— `database/index.ets:8-25` 只建
 *       books / book_groups / works_lists / book_history / bookmarks
 *   · 全工程没有任何 `initReadRecordTable` / `createTable('readRecord')`
 *
 * ⇒ 真机 DB 里**从来没有这张表**。真机日志（`docs/日志.md:10020`）原文：
 *   `no such table: rea***ord in "DELETE FROM rea***ord WHERE boo*** = '***.t**'
 *    AND dev*** IN (SELECT dev*** FROM rea***ord WHERE boo*** = '***.t**')"`
 *   （`docs/日志.md:10021`）`PrintInfoForDbError:DbError errCode:27394103`
 *   （`docs/日志.md:10023`）`[RdbTag], 事务第 3 条失败，回滚`
 *   （`docs/日志.md:10024`）`BookRename.rename db failed: {"code":14800021}`
 *
 * 2026-09-21 修 `bookmarks` 时（`BookmarksDao.initBookmarksTable` 的类注释）已经踩过
 * 一次「快照有定义、无人建表」，当时只补了 `bookmarks`，`readRecord` 被漏下 ——
 * 后果是**改名功能整体不可用**（改名事务第 3 条必失败 ⇒ 整笔回滚）。
 *
 * ── 本 DAO 的职责（刻意保持最小）────────────────────────────────────────────
 * ① `initReadRecordTable()`：把表建出来（幂等，`CREATE TABLE IF NOT EXISTS`）；
 * ② `renameBook(oldName, newName)` / `purge(bookName)`：改名级联与删书清理
 *    （原先这两段 SQL 直接写在 `BookRename` 里，现在收拢到表自己的 DAO）。
 *
 * ⚠️ 本表当前**全工程零写入**（`BookDetailPage.ets:402` 注释已记：「真正的阅读时长
 *    数据源 `readRecord` 表全工程零写入」）。也就是说：建表只为让**改名/删书路径
 *    不再崩**，表本身仍是空表。这是**刻意的最小改动** —— 本次不引入阅读时长写入，
 *    避免把不可本地验证的业务改动混进 bug 修复。
 */
import DbUtil from '../../common/utils/DbUtil'
import AppDatabaseUtil from '../AppDatabaseUtil'
import { ColumnInfo } from '../types/ColumnInfo'

/** SQL 单引号转义（与 `BookRename.esc` / `BookmarksDao.esc` 同款） */
function esc(s: string): string {
  return (s ?? '').replace(/'/g, "''")
}

class ReadRecordDao {
  TABLE_NAME: string = 'readRecord'

  /**
   * 建 `readRecord` 表（幂等）。**必须由 `initAllTable()` 调用** ——
   * 不调用则表不存在，改名事务第 3 条必然失败（见类头证据链）。
   */
  async initReadRecordTable(): Promise<void> {
    try {
      const createSql = AppDatabaseUtil.getCreateSql(this.TABLE_NAME)
      if (!createSql) {
        return
      }
      await DbUtil.createTable(createSql)
    } catch (e) {
      console.error('initReadRecordTable, Error, ', JSON.stringify(e))
    }
  }

  /**
   * 改名级联：把本表里旧书名的行迁到新书名。
   *
   * ⚠️ 主键是 `(deviceId, bookName)`（`AppDatabase/index.ets:1750`）⇒ 必须**先删**掉
   * 「新书名在同一 deviceId 上已存在的行」，否则随后的 UPDATE 会撞主键、整笔事务回滚。
   * 这是本表最容易漏的一处（原先写在 `BookRename.rename` 的 SQL 数组里，顺序已经是对的，
   * 迁移到本方法时**顺序必须保持不变**）。
   *
   * @returns 执行的 SQL 条数（2 条）—— 供调用方拼进同一个事务
   */
  renameBookSqls(oldName: string, newName: string): string[] {
    const o: string = esc(oldName)
    const n: string = esc(newName)
    return [
      // ① 先清掉会撞主键的冲突行（同一 deviceId 上已经有新书名的行）
      `DELETE FROM ${this.TABLE_NAME} WHERE bookName = '${n}' AND deviceId IN `
        + `(SELECT deviceId FROM ${this.TABLE_NAME} WHERE bookName = '${o}')`,
      // ② 再把旧书名整体改成新书名
      `UPDATE ${this.TABLE_NAME} SET bookName = '${n}' WHERE bookName = '${o}'`
    ]
  }

  /** 删书清理：清掉这本书的全部阅读时长行 */
  async purge(bookName: string): Promise<void> {
    const n: string = (bookName ?? '').trim()
    if (n === '') {
      return
    }
    try {
      await DbUtil.executeSql(`DELETE FROM ${this.TABLE_NAME} WHERE bookName = '${esc(n)}'`)
    } catch (err) {
      console.error('ReadRecordDao.purge failed: ' + JSON.stringify(err))
    }
  }

  /** 表是否真的存在（排障用：`PRAGMA table_info` 查不到列即不存在） */
  async exists(): Promise<boolean> {
    try {
      const cols: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME)
      const names: string[] = await DbUtil.queryRowNames(this.TABLE_NAME)
      return names.length > 0 && cols.length > 0
    } catch (err) {
      console.error('ReadRecordDao.exists failed: ' + JSON.stringify(err))
      return false
    }
  }
}

const readRecordDao = new ReadRecordDao()
export default readRecordDao as ReadRecordDao
