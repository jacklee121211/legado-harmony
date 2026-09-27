import BookGroupsDao from './dao/BookGroupsDao'
import bookHistoryDao from './dao/BookHistoryDao'
import BooksDao from './dao/BooksDao'
import worksListsDao from './dao/WorksListsDao'
import BookmarksDao from './dao/BookmarksDao'

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
  }
}

const dataBase = new DataBase()

export default dataBase as DataBase