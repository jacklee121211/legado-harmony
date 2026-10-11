import BookGroupsDao from './dao/BookGroupsDao'
import bookHistoryDao from './dao/BookHistoryDao'
import BooksDao from './dao/BooksDao'
import worksListsDao from './dao/WorksListsDao'
import BookmarksDao from './dao/BookmarksDao'
import readRecordDao from './dao/ReadRecordDao'

class DataBase {
  async initAllTable() {
    await BooksDao.initBooksTable()
    await BookGroupsDao.initGroupTable()
    await worksListsDao.initWorksListsTable()
    await bookHistoryDao.initBookHistoryTable()
    // ★ 2026-09-21 补：`bookmarks` 表此前**从未被创建** ——
    //   原 `initAllTable()` 漏掉了它，而 `AppDatabase/index.ets` 虽已定义建表语句
    //   却无人调用。真机实测报 `no such table: bookmarks`，
    //   书签写入返回 `{"code":14800021}`。
    // ★ 2026-09-28 书源/订阅体系整体移除：book_sources / rssSources / searchBooks
    //   等表定义与对应 DAO 一并删除，本地阅读器不再有任何联网取书路径。
    await BookmarksDao.initBookmarksTable()
    // ★ 2026-10-12 补：`readRecord` 表与 `bookmarks` 是**同一个坑的第二次发作** ——
    //   快照里早已定义（`AppDatabase/index.ets:1750`）但 `initAllTable()` 漏了它，
    //   且全工程没有任何 `createTable('readRecord')` ⇒ 真机 DB 里没这张表。
    //   后果：`BookRename.rename()` 的事务第 3 条（DELETE FROM readRecord）必然失败
    //   ⇒ 整笔回滚 ⇒ **重命名功能整体不可用**。
    //   真机证据（`docs/日志.md:10020-10024`）：
    //     `no such table: rea***ord in "DELETE FROM rea***ord ..."`
    //     `[RdbTag], 事务第 3 条失败，回滚`
    //     `BookRename.rename db failed: {"code":14800021}`
    await readRecordDao.initReadRecordTable()
    // ★ 2026-10-11 分类页签合并：书架顶部「漫画 / 有声书」两个入口已删除（只剩「书架」）。
    //   这里把历史数据（bookType / groupType / worksType = 1 或 2）一次性归一到 0，
    //   保证删入口不丢书；自带 Preferences 标志 ⇒ 只跑一次、失败下次重试。
    //   必须在**建表之后**调用（要 UPDATE 的四张表此时才存在）。
    await BooksDao.migrateBookTypeToShelf()
  }
}

const dataBase = new DataBase()

export default dataBase as DataBase