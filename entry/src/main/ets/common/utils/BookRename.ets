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
import { Books } from '../../database/entities/Books'
import { PreferencesUtil } from '@pura/harmony-utils'
import { ReaderCustomBg } from './ReaderCustomBg'
import { ReaderFontLib } from './ReaderFontLib'

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
    'WebSync_',           // 网页同步进度  WifiBookServer.ets:1274,1294 / ReaderPage3.ets:2605,2621
    'WebSyncSeen_',       // 同步去重时间戳 ReaderPage3.ets:2705,2720,2729,2736
    ReaderCustomBg.KEY_PREFIX   // 每书自定义背景 ReaderCustomBg.ets:156,438（'ReaderBg_'）
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
    const sqls: string[] = [
      // ① 书本身
      `UPDATE books SET bookName = '${esc(newN)}', updateTime = ${ts} WHERE id = ${bookId}`,
      // ② 书签
      `UPDATE bookmarks SET bookName = '${esc(newN)}' WHERE bookName = '${esc(oldN)}'`,
      // ③ 阅读时长：PK 是 (deviceId, bookName) ⇒ 先删掉"新名字已存在的那些设备行"，
      //    否则 UPDATE 会撞主键导致**整笔回滚**（这是本清单里最容易漏的一处）
      `DELETE FROM readRecord WHERE bookName = '${esc(newN)}' AND deviceId IN (SELECT deviceId FROM readRecord WHERE bookName = '${esc(oldN)}')`,
      `UPDATE readRecord SET bookName = '${esc(newN)}' WHERE bookName = '${esc(oldN)}'`,
      // ④ 浏览历史
      `UPDATE book_history SET bookName = '${esc(newN)}' WHERE bookName = '${esc(oldN)}'`
    ]

    try {
      await DbUtil.runInTransaction(sqls)
    } catch (err) {
      console.error('BookRename.rename db failed: ' + JSON.stringify(err))
      res.reason = 'db'
      res.message = '保存失败（已回滚，数据未改动）'
      return res
    }

    // Preferences 键迁移 + 书名清单元素迁移（都无事务；失败只记录，
    // DB 已成功 ⇒ 不反向回滚，宁可留下"设置没跟过来"也不能让书处于半改名状态）
    this.migratePrefKeys(oldN, newN)
    this.migrateNameLists(oldN, newN)

    res.ok = true
    res.reason = 'ok'
    res.message = '已重命名'
    return res
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
