import BookGroupsDao from './dao/BookGroupsDao'
import bookHistoryDao from './dao/BookHistoryDao'
import BooksDao from './dao/BooksDao'
import worksListsDao from './dao/WorksListsDao'
import BookmarksDao from './dao/BookmarksDao'
import readRecordDao from './dao/ReadRecordDao'
import readDailyDao from './dao/ReadDailyDao'

class DataBase {
  /**
   * 建表 + 迁移的完成信号（2026-10-20 新增）。
   *
   * ── 为什么需要 ────────────────────────────────────────────────────────────
   * `EntryAbility.onWindowStageCreate` 里是 `DbUtil.initDB(...).then(async () => {
   *   await DataBase.initAllTable() ... })` —— **不 await 整个链**，UI 照常加载。
   * 于是首屏（书架 `BookContent.aboutToAppear → getBookList`）可能在
   * "建表 / 补列" **还没跑完**时就发出查询。真机日志证据（`docs/日志.md`）：
   *   `19:46:16.193 duplicate column name: finishedTime ...`  ← 迁移还在跑
   *   `19:46:16.195 查询成功！查询行数：`                      ← 书架已经在查了
   *   33ms 后 `GetColumnIndex:Failed ...` → 闪退。
   *
   * 修法：暴露一个 Promise，任何"依赖表结构已就绪"的查询方先 `await` 它。
   * ⚠️ 它**永不会 reject**（内部吞掉异常并 resolve）——
   *   迁移失败时查询照样要能跑（缺列已由 `DbUtil.parseResultSet` 兜住），
   *   绝不能因为迁移挂了就让首屏永远不加载。
   */
  private readyPromise: Promise<void> | null = null;
  private readyResolve: (() => void) | null = null;

  /** 等待建表/迁移完成（幂等，可重复调用） */
  whenReady(): Promise<void> {
    if (this.readyPromise === null) {
      this.readyPromise = new Promise<void>((resolve: () => void) => {
        this.readyResolve = resolve;
      });
      // 已就绪分支：initAllTable 可能**早于**本次调用完成 ⇒ 用一个标志补齐，
      // 否则后来者会永远等下去（经典的"信号发完了才登记监听"竞态）。
      if (this.initDone) {
        this.readyResolve?.();
      }
    }
    return this.readyPromise;
  }

  /** `initAllTable()` 是否已经跑完（含失败） */
  private initDone: boolean = false;

  async initAllTable() {
    try {
      await this.doInitAllTable()
    } finally {
      // 无论成功失败都放行：迁移失败不该把首屏卡死
      this.initDone = true
      this.readyResolve?.()
    }
  }

  private async doInitAllTable() {
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
    // ★ 2026-10-13 新增：阅读数据模块的**日粒度时长表** `readDaily`。
    //   与 `bookmarks` / `readRecord` 是同一个坑的第三次预防 ——
    //   建表语句只在 `AppDatabase/index.ets` 的快照里，**没人调就永远不会建**。
    //   本表由 `ReadTimeRecorder` 写入（进书计时），`ReadDailyDao` 提供四档聚合。
    await readDailyDao.initTable()
    // ★ 2026-10-11 分类页签合并：书架顶部「漫画 / 有声书」两个入口已删除（只剩「书架」）。
    //   这里把历史数据（bookType / groupType / worksType = 1 或 2）一次性归一到 0，
    //   保证删入口不丢书；自带 Preferences 标志 ⇒ 只跑一次、失败下次重试。
    //   必须在**建表之后**调用（要 UPDATE 的四张表此时才存在）。
    await BooksDao.migrateBookTypeToShelf()
  }
}

const dataBase = new DataBase()

export default dataBase as DataBase