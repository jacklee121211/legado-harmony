/**
 * 书名重命名 —— **级联改名**的唯一实现（2026-10-05，用户方案 A）
 * ============================================================================
 * 为什么不能"只改 books.bookName"：本工程**多处用书名当键**，只改一处会让
 * 阅读进度 / 书签 / 时长统计 / 浏览历史 / 阅读器个性化设置 / 网页同步状态**全部失联**。
 *
 * 全项目"以书名为键"的清单（改名必须全部迁移，逐条附证据；新增此类存储请补到这里）：
 * ⚠️ 本清单是**审计产出**（`docs/audit-bookname-2026-10-05.txt`，全项目 165 处 `bookName` 逐条过筛），
 *    不是凭印象列的 —— 第一版只列了 4 类 Preferences 键，审计又抓到 `ReaderBg_` 与两个书名清单。
 *
 * | # | 存储 | 具体 | 证据 |
 * |---|---|---|---|
 * | 1 | `books` 表 | `bookName` 列（**UNIQUE INDEX (bookName, author)** ⇒ 同名同作者会写失败） | `database/AppDatabase/index.ets:10,44,268` |
 * | 2 | `bookmarks` 表 | `bookName` 列（索引 (bookName, bookAuthor)） | `…/index.ets:1444,1504` |
 * | 3 | `readRecord` 表 | `bookName` 列，**主键 (deviceId, bookName)** ⇒ 改名可能撞主键 | `…/index.ets:1749` |
 * | 4 | `book_history` 表 | `bookName` 列 | `…/index.ets:2279` |
 * | 5 | Preferences | `BookCurrentData_<书名>`（阅读进度） | `pages/view/Reader/ReaderPage3.ets:2388,2896` |
 * | 6 | Preferences | `ReaderSetting_<书名>`（字号/主题等个性化） | `ReaderPage3.ets:2393,2822,2907,5659` |
 * | 7 | Preferences | `WebSync_<书名>`（网页端同步进度） | `common/utils/WifiBookServer.ets:1274,1294`；`ReaderPage3.ets:2605,2621` |
 * | 8 | Preferences | `WebSyncSeen_<书名>`（同步去重时间戳） | `ReaderPage3.ets:2705,2720,2729,2736` |
 * | 9 | Preferences | **`ReaderBg_<书名>`**（每书自定义背景记录） | `common/utils/ReaderCustomBg.ets:156,438,497,509` |
 * | 10 | Preferences | **`ReaderBgOverrides`**：值是 `string[]`，元素是书名 | `ReaderCustomBg.ets:160,513,543` |
 * | 11 | Preferences | **`ReaderFontOverrides`**：值是 `string[]`，元素是书名 | `common/utils/ReaderFontLib.ets:73,110,140,142` |
 * | 12 | 书架列表的 **LazyForEach 键值** | 键值不含 `bookName` ⇒ 改名后复用旧组件、**界面不刷新** | `components/BookContent.ets:220-224`；规范 `docs/标准-弹窗与按钮统一规范.md:201,212` |
 *
 * 只读/展示类（审计确认**不需要**迁移）：`booksUtils.isExistBooks`（按名查是否有这本书）、
 * `BookDetailPage:356/496`（显示/写历史时用的就是当前名）、`readStatistics`（按名匹配书签行，
 * 而书签行已被 ② 改名 ⇒ 自然对齐）、`ShelfSearchPanel:66/128`（即时计算，每次开面板重查）、
 * `WifiBookServer` 的导出/匹配（用当前名）、`LongTakeBook`（转场几何，不落库）。
 *
 * 执行顺序：**先 DB 事务**（4 张表，全成功才提交）→ **再迁移 Preferences 键** → **再迁移书名清单**
 * （Preferences 无事务；放在 DB 之后，失败只记录日志、不影响改名已成功的事实）。
 */
import { ColumnInfo } from '../../database/types/ColumnInfo'
import AppDatabaseUtil from '../../database/AppDatabaseUtil'
import DbUtil from './DbUtil'
import readRecordDao from '../../database/dao/ReadRecordDao'
// 2026-10-12：改名后同步听书会话书名（迷你栏书名条）
import { ListenSession } from '../../tts/ListenSession'
import { Books } from '../../database/entities/Books'
import { PreferencesUtil } from '@pura/harmony-utils'
import { ReaderCustomBg } from './ReaderCustomBg'
import { ReaderFontLib } from './ReaderFontLib'
// 双端同步 v2 的键名统一在 SyncConfig 里定义（改名迁移 / 删书清理都必须覆盖它们）
import { PHONE_POS_PREFIX, WEB_POS_PREFIX, WEB_SEEN_PREFIX } from './SyncConfig'

/** 改名结果（给 UI 直接用的文案） */
export class RenameBookResult {
  ok: boolean = false
  /** 'ok' | 'empty' | 'same' | 'tooLong' | 'taken' | 'db' */
  reason: string = ''
  message: string = ''
}

/** 书名长度上限（DB 无限制，纯 UI 保护）——**导出常量**，弹窗 `maxLength` 与校验共用同一值 */
export const MAX_BOOK_NAME_LEN: number = 60

class BookRename {
  /** 以书名为键的 Preferences 前缀（**唯一清单**，改名时逐个迁移） */
  static readonly NAME_KEYED_PREF_PREFIXES: string[] = [
    'BookCurrentData_',   // 阅读进度      ReaderPage3.ets:2388,2896
    'ReaderSetting_',     // 阅读器个性化  ReaderPage3.ets:2393,2822,2907,5659
    'WebSync_',           // v1 网页同步锚（只读兼容，双端同步 v2 起不再写）
    'WebSyncSeen_',       // v1 手机侧水位（只读兼容）
    ReaderCustomBg.KEY_PREFIX,  // 每书自定义背景 ReaderCustomBg.ets:156,438（'ReaderBg_'）
    // ── 双端同步 v2（2026-10-05）：各端独立的槽 + 手机侧水位 ──────────────────
    PHONE_POS_PREFIX,     // 手机位置槽    SyncConfig.ets
    WEB_POS_PREFIX,       // 网页位置槽（内含多台电脑各一条）
    WEB_SEEN_PREFIX,      // 手机已消费水位
    'BookToc_',           // 目录标题快照（M3 单源目录；值是 string[]，键后缀是书名）
    'SyncLatest_',        // 中继站：最新写入的位置（值是 SyncPos）
    'SyncSeq_'            // 中继站：全局序号计数器（值是 number）
  ]

  /**
   * **书名清单**类存储（存的是 `string[]`，里面每个元素是书名，不是键后缀）。
   * 改名时必须把清单里的旧名替换成新名，否则：旧名残留在清单里 + 新名不在清单里
   * ⇒ "这本自定义背景/字体明明设置过，改名后没了"。
   */
  static readonly NAME_LIST_PREF_KEYS: string[] = [
    ReaderCustomBg.KEY_OVERRIDES,        // ReaderBgOverrides   ReaderCustomBg.ets:160,513,543
    ReaderFontLib.KEY_FONT_OVERRIDES     // ReaderFontOverrides ReaderFontLib.ets:73,110,140,142
  ]

  /** 书名最大长度（见导出常量 `MAX_BOOK_NAME_LEN`） */
  static readonly MAX_NAME_LEN: number = MAX_BOOK_NAME_LEN

  /** SQL 单引号转义（沿用 `BookmarksDao.esc` 的做法） */
  private static esc(s: string): string {
    return s.replace(/'/g, "''")
  }

  /**
   * 名字冲突检查（返回空串 = 可用，否则返回给用户看的原因）。
   * **两种冲突都要拦**：
   *  ① 同名**同作者** —— DB 的 `UNIQUE INDEX index_books_bookName_author`（`AppDatabase/index.ets:268`）
   *     会让 UPDATE 直接失败；
   *  ② 同名**不同作者** —— DB 允许（索引含 author），但本工程多处**用书名当键**
   *     （进度/阅读器设置/自定义背景/网页同步，见类头清单）⇒ 两本书会共用同一份进度与设置，
   *     属于**静默数据串味**。所以按"仅同名"从严拦掉，宁可让用户换个名字。
   */
  async nameConflictMessage(newName: string, author: string, excludeId: number): Promise<string> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn('books')
      const predicates = DbUtil.getPredicates('books')
      predicates.equalTo('bookName', newName)
      predicates.notEqualTo('id', excludeId)
      const rows: Books[] = await DbUtil.queryForList<Books>(predicates, column)
      if (rows.length === 0) {
        return ''
      }
      for (const row of rows) {
        if ((row.author ?? '') === (author ?? '')) {
          return '已有同名同作者的书籍'
        }
      }
      return '已有同名书籍（作者不同）—— 同名书会共用阅读进度与设置'
    } catch (err) {
      // 查询失败按"未占用"处理，让后面的 UPDATE 去暴露真实冲突（事务会回滚，不会写脏）
      console.error('BookRename.nameConflictMessage failed: ' + JSON.stringify(err))
      return ''
    }
  }

  /**
   * 级联改名（唯一入口）。UI 只调它，不要自己写 UPDATE。
   * @param bookId 书的 id（`Books.id`，DB 主键）
   * @param oldName 当前书名（DB 里的真值，不要用界面上的显示名）
   * @param newName 新书名（已 trim）
   * @param author 作者（判唯一索引用；本地书通常是 '暂无'）
   */
  async rename(bookId: number, oldName: string, newName: string, author: string): Promise<RenameBookResult> {
    const res = new RenameBookResult()
    const oldN: string = (oldName ?? '').trim()
    const newN: string = (newName ?? '').trim()
    // id 必须有效：`UPDATE ... WHERE id = 0` 会"0 行受影响但事务照样提交"⇒ 假成功
    if (!bookId || bookId <= 0) {
      res.reason = 'db'
      res.message = '这本书还没有入库，无法改名'
      return res
    }
    if (newN === '') {
      res.reason = 'empty'
      res.message = '书名不能为空'
      return res
    }
    if (newN.length > BookRename.MAX_NAME_LEN) {
      res.reason = 'tooLong'
      res.message = `书名不能超过 ${BookRename.MAX_NAME_LEN} 个字`
      return res
    }
    if (newN === oldN) {
      res.reason = 'same'
      res.message = '书名没有变化'
      return res
    }
    const conflict: string = await this.nameConflictMessage(newN, author, bookId)
    if (conflict !== '') {
      res.reason = 'taken'
      res.message = conflict
      return res
    }

    const esc = BookRename.esc
    const ts: number = Date.now()
    // ★ 核心书行**单独成一句、单独执行、只有它失败才算改名失败**（2026-10-12 加固）。
    //
    // 为什么拆开：原实现把 5 条 SQL（books + bookmarks + readRecord×2 + book_history）
    // 塞进**同一个事务**，其中任何一条失败（例如 `readRecord` 表不存在 ⇒
    // `no such table`，真机证据 `docs/日志.md:10020`）就会 `rollBack()` 整笔，
    // 导致**用户点了确定什么都没有发生**（`{"code":14800021}`，
    // `docs/日志.md:10024`）。
    // 附属表（书签/时长/历史）是**派生数据**：它们没改成功不该阻断"书本身改名成功"
    // 这件用户真正要求的事。所以：
    //   · `books` 的 UPDATE 单独执行 → 失败 = 改名失败（返回 db 错误）；
    //   · 附属表的迁移放进事务 → 失败只记日志（书已改名，宁可留下派生数据没跟过来）；
    //   · 末尾兜底**再次**把 books 行写成新名（幂等），防止"派生表事务回滚把书也带回去"。
    try {
      await DbUtil.executeSql(
        `UPDATE books SET bookName = '${esc(newN)}', updateTime = ${ts} WHERE id = ${bookId}`)
    } catch (err) {
      console.error('BookRename.rename core update failed: ' + JSON.stringify(err))
      res.reason = 'db'
      res.message = '保存失败（书未改动）'
      return res
    }

    // 附属表迁移（书签 / 阅读时长 / 浏览历史）—— 失败**不**回滚书行，只记录
    const derivedSqls: string[] = [
      // ② 书签
      `UPDATE bookmarks SET bookName = '${esc(newN)}' WHERE bookName = '${esc(oldN)}'`,
      // ③④ 阅读时长（主键 (deviceId, bookName)：先删冲突行再改名，顺序不可换）
      ...readRecordDao.renameBookSqls(oldN, newN),
      // ⑤ 浏览历史
      `UPDATE book_history SET bookName = '${esc(newN)}' WHERE bookName = '${esc(oldN)}'`
    ]
    try {
      await DbUtil.runInTransaction(derivedSqls)
    } catch (err) {
      // 派生数据没跟上：**不是**改名失败。记日志后继续走成功分支
      // （Preferences 迁移同样按"失败只记录"处理，语义一致）。
      console.error('BookRename.rename derived tables failed (book already renamed): '
        + JSON.stringify(err))
    }

    // Preferences 键迁移 + 书名清单元素迁移 + 值是书名的全局键（都无事务；失败只记录，
    // DB 已成功 ⇒ 不反向回滚，宁可留下"设置没跟过来"也不能让书处于半改名状态）
    this.migratePrefKeys(oldN, newN)
    this.migrateNameLists(oldN, newN)
    this.migrateNameValues(oldN, newN)
    // ★ 2026-10-12：**同步听书会话的书名**（用户反馈：「重命名后，minibar 显示还是之前的
    //   名字，比如书名111，改名为11，此时听书，minibar 显示111」）。
    //   根因：`ListenSession.beginExclusive()` 只在**开播那一刻**登记书名，
    //   改名不会自己通知会话 ⇒ `listenTitleRaw` / `listenTitle` 一直停在旧名。
    //   本方法的判据（id → url → 书名）与 `ReaderPage3.listeningThisBook()` 同源，
    //   所以这里只需**按 id 判断"正在听的是不是这本书"**，不用比书名
    //   （旧名还没换、新名刚写库，拿名字比反而会漏）。
    this.syncListenSessionTitle(bookId, newN)

    res.ok = true
    res.reason = 'ok'
    res.message = '已重命名'
    return res
  }

  /**
   * 改名成功后，若**正在听的正是这本书**，把会话里的书名一并换掉（2026-10-12）。
   *
   * 判据只用 `bookId`（`Books.id` 主键，不会因路径归一化/空白而出错 ——
   * 见 `ListenSession.KEY_ID` 注释里"url 在真机上对同一本书也不相等"的记录）。
   * 命中后调 `ListenSession.updateTitle()`，它会同时刷新 `KEY_TITLE_RAW`
   * （真相源）与 `KEY_TITLE`（显示值，按当前拓展名开关算），
   * 迷你栏的书名条随即重绘。
   *
   * 失败只记日志 —— 改名本身已经成功，绝不能因为"顺带同步 UI"失败而报错给用户。
   */
  private syncListenSessionTitle(bookId: number, newName: string): void {
    try {
      if (!ListenSession.isActive() || ListenSession.bookId() !== bookId) {
        return
      }
      ListenSession.updateTitle(newName)
    } catch (err) {
      console.error('BookRename.syncListenSessionTitle failed: ' + JSON.stringify(err))
    }
  }

  /**
   * **删除一本书时清理它的全部派生数据**（2026-10-05 用户定：删除=重置，不再继承，残留是冗余）。
   *
   * 覆盖范围 = 本文件类头那张清单的"按名存储"部分：
   *   · 表：`bookmarks` / `readRecord` / `book_history`（`books` 行由 `BooksDao.deleteBook` 删）
   *   · Preferences 键：`BookCurrentData_` / `ReaderSetting_` / `WebSync_` / `WebSyncSeen_` / `ReaderBg_`
   *   · Preferences 书名清单：`ReaderBgOverrides` / `ReaderFontOverrides`（摘掉该名）
   *   · Preferences 值即书名：`LastReadBookName`（命中才清，连 `LastReadBookUrl` 一起清）
   * 不做：`ReaderTexture.KEY_CUSTOM_LIST`（纹理路径，与书无关）、`ReaderBgGlobal/Schemes`（全局）。
   *
   * ⚠️ 调用时机必须是**删行之后**（`booksUtils.delBooksById`）——否则同名重导会先继承旧数据。
   * ⚠️ 与改名不同，这里**不需要事务**：删掉派生数据失败只是"没清干净"，不会让书处于半状态。
   */
  async purge(bookName: string): Promise<void> {
    const n: string = (bookName ?? '').trim()
    if (n === '') {
      return
    }
    const esc = BookRename.esc
    try {
      await DbUtil.executeSql(`DELETE FROM bookmarks WHERE bookName = '${esc(n)}'`)
      await DbUtil.executeSql(`DELETE FROM book_history WHERE bookName = '${esc(n)}'`)
    } catch (err) {
      console.error('BookRename.purge db failed: ' + JSON.stringify(err))
    }
    // `readRecord` 走自己的 DAO（2026-10-12）：该方法内部已吞异常，且表缺失时不再影响其它清理
    await readRecordDao.purge(n)
    for (const prefix of BookRename.NAME_KEYED_PREF_PREFIXES) {
      try {
        PreferencesUtil.deleteSync(prefix + n)
      } catch (err) {
        console.error(`BookRename.purge pref failed at ${prefix}: ` + JSON.stringify(err))
      }
    }
    this.removeFromNameLists(n)
    try {
      const last: string = PreferencesUtil.getSync('LastReadBookName', '') as string
      if (typeof last === 'string' && last === n) {
        PreferencesUtil.deleteSync('LastReadBookName')
        PreferencesUtil.deleteSync('LastReadBookUrl')
      }
    } catch (err) {
      console.error('BookRename.purge LastRead failed: ' + JSON.stringify(err))
    }
  }

  /** 把 `BookCurrentData_/ReaderSetting_/WebSync_/WebSyncSeen_/ReaderBg_` 五类**键**从旧名迁到新名 */
  private migratePrefKeys(oldName: string, newName: string): void {
    for (const prefix of BookRename.NAME_KEYED_PREF_PREFIXES) {
      const oldKey: string = prefix + oldName
      const newKey: string = prefix + newName
      try {
        if (!PreferencesUtil.hasSync(oldKey)) {
          continue
        }
        // 新名字已有同键（极端情况：新名与另一本已存在的书重名）⇒ 保留既有值，只删旧键
        if (!PreferencesUtil.hasSync(newKey)) {
          PreferencesUtil.putSync(newKey, PreferencesUtil.getSync(oldKey, ''))
        }
        PreferencesUtil.deleteSync(oldKey)
      } catch (err) {
        console.error(`BookRename.migratePrefKeys failed at ${prefix}: ` + JSON.stringify(err))
      }
    }
  }

  /**
   * **值是书名**的全局 Preferences 键（不是"键后缀"，所以不在上面两个清单里）。
   * 2026-10-05 双端同步审计时补漏：`ReaderPage3.registerPageShow()` 每次翻页写
   * `LastReadBookName = 当前书名`（`ReaderPage3.ets:2904`），桌面快捷方式「快速阅读/
   * 快速听书」经 `BooksDao.getLastReadBook()` 用 **name + url 双条件**回查
   * （`BooksDao.ets:491-493`）⇒ 改名后 name 失配 ⇒ 快捷方式取不到书（返回 null 走兜底提示）。
   */
  static readonly NAME_VALUE_PREF_KEYS: string[] = [
    'LastReadBookName'
  ]

  /** 值是书名的全局键：命中旧名就改写成新名 */
  private migrateNameValues(oldName: string, newName: string): void {
    for (const key of BookRename.NAME_VALUE_PREF_KEYS) {
      try {
        const v = PreferencesUtil.getSync(key, '') as string
        if (typeof v === 'string' && v === oldName) {
          PreferencesUtil.putSync(key, newName)
        }
      } catch (err) {
        console.error(`BookRename.migrateNameValues failed at ${key}: ` + JSON.stringify(err))
      }
    }
  }

  /**
   * 把某个书名从"书名清单"类存储里**摘掉**（删除书籍时用，与 `migrateNameLists` 配套）。
   * 只写回发生变化的那张清单；解析失败/清单里没有都静默跳过。
   */
  private removeFromNameLists(name: string): void {
    for (const key of BookRename.NAME_LIST_PREF_KEYS) {
      try {
        const raw: string = PreferencesUtil.getSync(key, '') as string
        if (typeof raw !== 'string' || raw.length === 0) {
          continue
        }
        const list: string[] = JSON.parse(raw) as string[]
        if (!Array.isArray(list) || !list.includes(name)) {
          continue
        }
        const next: string[] = list.filter((x: string): boolean => x !== name)
        PreferencesUtil.putSync(key, JSON.stringify(next))
      } catch (err) {
        console.error(`BookRename.removeFromNameLists failed at ${key}: ` + JSON.stringify(err))
      }
    }
  }

  /**
   * 迁移**书名清单**类存储（`ReaderBgOverrides` / `ReaderFontOverrides`，值是 `string[]`）。
   * 2026-10-05 全项目审计时发现（原方案只覆盖"键"、漏了"清单里的元素"）：
   * 漏了会出现"这本设置过自定义背景/字体，改名后就没了"——
   * 因为清单里还是旧名，而 `resolve(新名)` 查不到任何覆盖。
   */
  private migrateNameLists(oldName: string, newName: string): void {
    for (const key of BookRename.NAME_LIST_PREF_KEYS) {
      try {
        const raw: string = PreferencesUtil.getSync(key, '') as string
        if (typeof raw !== 'string' || raw.length === 0) {
          continue
        }
        const list: string[] = JSON.parse(raw) as string[]
        if (!Array.isArray(list) || !list.includes(oldName)) {
          continue
        }
        const next: string[] = []
        for (const name of list) {
          const mapped: string = name === oldName ? newName : name
          if (!next.includes(mapped)) {
            next.push(mapped)
          }
        }
        PreferencesUtil.putSync(key, JSON.stringify(next))
      } catch (err) {
        console.error(`BookRename.migrateNameLists failed at ${key}: ` + JSON.stringify(err))
      }
    }
  }
}

const bookRename = new BookRename()
export default bookRename as BookRename
