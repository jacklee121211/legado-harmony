// （2026-10-13 删除未使用的 `booksUtils` import —— 它在本文件里唯一的调用点是
//   已删掉的 `getOrder()`；现在排序直接在 SQL 里判 `order !== undefined`。）
import DbUtil from '../../common/utils/DbUtil';
import toolsUtils from '../../common/utils/ToolsUtils';
import AppDatabaseUtil from '../AppDatabaseUtil';
import { Books } from '../entities/Books';
import { BooksTypeSearchParams } from '../types/BooksType';
import { ColumnInfo, ColumnType } from '../types/ColumnInfo';
import { PreferencesUtil } from '@pura/harmony-utils';
import fs from '@ohos.file.fs';
// 诊断打点（2026-10-12）：`getLastReadBook()` 的书名键/命中行
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 「分类页签合并」迁移的一次性标志（Preferences 键）。
 * 见 `BooksDao.migrateBookTypeToShelf()`。
 */
const KEY_BOOKTYPE_MERGED: string = 'bookTypeMergedToShelfV1'

/**
 * 迁移**前**的原始值留档键（JSON：`BookTypeBackupRow[]`）。
 * 本迁移的 UPDATE 不可逆，这份留档是唯一可用的还原依据。
 */
const KEY_BOOKTYPE_BACKUP: string = 'bookTypeMergedToShelfV1_backup'

/** 迁移前留档用的一行（见 `BooksDao.backupBookTypeBeforeMerge()`） */
interface BookTypeBackupRow {
  id: number
  bookType: number
}

/** 单值 COUNT 查询的结果行（`countFinishedInRange` 用） */
interface CountRow {
  cnt: number
}

/** `PRAGMA table_info` 的单行（只需要列名，用于判断列是否存在） */
interface ColumnNameRow {
  name: string
}

/** 单值 COUNT 查询的列描述（`ADBUtil.getColumn` 只认快照里的列，聚合列必须自己给） */
const COUNT_COLUMN: ColumnInfo[] = [
  { name: 'cnt', columnName: 'cnt', type: ColumnType.LONG }
]

class BooksDao {
  TABLE_NAME: string = 'books'

  /**
   * 书架排序 SQL 子句（**唯一真源**，2026-10-19 新增）。
   *
   * ── 为什么要抽出来 ────────────────────────────────────────────────────────
   * 需求第 6 条：排序面板有 5 个档位（首字母 / 导入时间 / 最近阅读 / 格式 / 文件大小）
   * 且**每档双向**。原实现把 ORDER BY 写死在 `search()` 和 `searchPage()` **两处**，
   * 文件里已有一条注释警告「两处 ORDER BY 必须同步改，否则书架与管理页顺序会不一致」
   * （`:245-246`）。档位从 1 个变 10 个组合后，两处手抄必然分叉 ⇒ 收敛成这一个方法。
   *
   * ── 口径（逐条与用户敲定）────────────────────────────────────────────────
   * · 用户原话：「最近只有一种排序就是最近↓，然后其他的标签包括后续用户自定义的
   *   标签分组都会随着排序进行排序。」
   *   ⇒ `RECENT_READ` 档**恒为**"最近阅读降序"，面板不给它反向（见 `groupTypePanel.SortSection`）。
   *   这里为通用性仍保留 dir 参数，但调用方对 RECENT_READ 固定传 DESC。
   * · `isTop DESC` **永远排最前**：置顶是用户显式操作，不能被排序档冲掉
   *   （与改造前 `isTop DESC, …` 的既有语义一致）。
   * · `RECENT_READ` 的"没读过用 createTime 兜底"口径沿用 `:122` 与 `:247` 的既有实现。
   * · 首字母（拼音）**不在 SQL 里做** —— SQLite 没有拼音排序规则，具体见
   *   `BookContent.getBookList()` 的注释（用官方 `intl.Collator` 在内存里排）。
   *   这里给它一个稳定的兜底序（bookName），保证分页时不抖动。
   *
   * @param key 排序档位（`SortKey` 的数值，避免 DAO 反向依赖 UI 层枚举）
   * @param desc true = 降序
   */
  private buildOrderByClause(key: number | undefined, desc: boolean): string {
    const dir: string = desc ? 'DESC' : 'ASC';
    // 0 = 首字母 / 1 = 导入时间 / 2 = 最近阅读 / 3 = 格式 / 4 = 文件大小
    switch (key) {
      case 1:
        // 导入时间：稳定、无并列（createTime 是毫秒时间戳）
        return ` isTop DESC, createTime ${dir}`;
      case 2:
        // 最近阅读：读过的用 durChapterTime，没读过的用 createTime 兜底（既有口径）
        return ` isTop DESC, CASE WHEN durChapterTime = 0 THEN createTime ELSE durChapterTime END ${dir}, createTime DESC`;
      case 3:
        // 格式：按扩展名排序。
        // ⚠️ 这里**不能**用 `reverse()`/正则 —— SQLite 没有这两个函数（只有 instr/substr/
        //    replace 等内建）。原稿写过 `reverse_suffix()` 是**错的**，会在运行时直接抛
        //    "no such function"，整条查询失败 ⇒ 书架空白。
        // ⇒ 改用 `CASE` 枚举工程实际支持的导入后缀（与 `FormatFlags.importableExts()`
        //    白名单一致：txt/epub/mobi/azw/azw3/pdf/docx/doc），按扩展名字母序给定固定名次。
        //    未知后缀排最后。
        return ` isTop DESC, CASE
          WHEN bookUrl LIKE '%.azw' THEN 'azw'
          WHEN bookUrl LIKE '%.azw3' THEN 'azw3'
          WHEN bookUrl LIKE '%.doc' THEN 'doc'
          WHEN bookUrl LIKE '%.docx' THEN 'docx'
          WHEN bookUrl LIKE '%.epub' THEN 'epub'
          WHEN bookUrl LIKE '%.mobi' THEN 'mobi'
          WHEN bookUrl LIKE '%.pdf' THEN 'pdf'
          WHEN bookUrl LIKE '%.txt' THEN 'txt'
          ELSE 'zzz' END ${dir}, bookName ASC`;
      case 4:
        // 文件大小：0 表示"大小未知/未回填"⇒ 无论升降序都压到最后，避免脏数据占首位
        return ` isTop DESC, CASE WHEN fileSize IS NULL OR fileSize = 0 THEN 1 ELSE 0 END ASC, fileSize ${dir}, bookName ASC`;
      case 0:
      default:
        // 首字母（拼音）：SQL 侧无法拼音排序 ⇒ 只给 bookName 做**稳定兜底**，
        // 真正的顺序由调用方用 intl.Collator 在内存里重排（见 BookContent）。
        return ` isTop DESC, bookName ${dir}`;
    }
  }

  /**
   * 确保 `books` 表存在指定列；缺了就 ALTER 补上（**幂等、自愈**，2026-10-20）。
   *
   * ── 为什么不能只靠 "ALTER 报错就 catch 掉" ────────────────────────────────
   * 原来两处迁移都写成「`try { ALTER ... } catch (e) { }`」并把异常注释成"列已存在"，
   * 这个写法有两个盲区（2026-10-20 真机闪退的间接原因）：
   *   ① **无法区分**"列已存在"（正常）与"ALTER 因别的原因失败"（异常）——
   *      后者会让表**永久缺列**，而代码以为已经建好了；
   *   ② 没有任何**产线证据**：真机上到底是哪条 ALTER 失败、错在哪儿，日志里看不出来。
   *
   * ── 现在的做法 ────────────────────────────────────────────────────────────
   * 先查 `PRAGMA table_info(books)` 拿**真实列名**，只在确实缺列时才 ALTER：
   *   · 不存在 ⇒ 执行 ALTER，并把结果记进日志（成功/失败都记）；
   *   · 已存在 ⇒ 什么都不做（不再制造 duplicate column 噪音）。
   * 无论 ALTER 成败，本次调用都**不抛异常**（迁移失败不应阻断启动）；
   * 下次启动会**再检查一次** ⇒ 天然自愈。
   *
   * 依据：`PRAGMA table_info` 是 SQLite 的标准内省语句——
   *   documentId `FAQ/本地数据和文件/本地数据库管理/关系型数据库RDB支持哪些搜索能力/
   *   faqs-local-database-management-23` 原文：「SQL查询：SQLite 支持标准的 SQL 查询语法…」
   */
  private async ensureColumn(columnName: string, columnDef: string): Promise<void> {
    try {
      const infoRows: ColumnInfo[] = [
        { name: 'name', columnName: 'name', type: ColumnType.STRING }
      ];
      const rows: ColumnNameRow[] = await DbUtil.querySqlForList<ColumnNameRow>(
        `PRAGMA table_info(${this.TABLE_NAME})`, infoRows);
      const exists: boolean = rows.some((r: ColumnNameRow) => r.name === columnName);
      if (exists) {
        return;
      }
      await DbUtil.executeSql(
        `ALTER TABLE ${this.TABLE_NAME} ADD COLUMN ${columnName} ${columnDef}`);
      console.info('TagInfo', `ensureColumn: 已补列 ${columnName}`);
    } catch (e) {
      // 补列失败不影响启动；下次启动会重试（自愈）
      console.info('TagInfo', `ensureColumn failed: ${columnName}`, JSON.stringify(e));
    }
  }

  // 创建books数据表
  async initBooksTable() {
    try {
      const createSql = AppDatabaseUtil.getCreateSql(this.TABLE_NAME);
      if (!createSql) {
        return
      }
      await DbUtil.createTable(createSql)
      // ── 后加列的迁移（幂等自愈，2026-10-20 重写）────────────────────────────
      // `CREATE TABLE IF NOT EXISTS` 对**已存在**的表不会补列，而本工程
      // `AppDatabase/index.ets` 的 `formatVersion` 固定为 1、**没有任何 upgrade 路径**
      // ⇒ 后加的列必须在这里显式补。
      // ⚠️ 必须用 `ensureColumn()`（先 PRAGMA 查真实列名再补），
      //    不要退回 "try ALTER / catch 吞掉" 的写法 —— 理由见 ensureColumn 的注释。
      await this.ensureColumn('finishedTime', 'INTEGER NOT NULL DEFAULT 0')
      // 2026-10-19 排序面板「文件大小」用；缺它会直接导致书架查询闪退
      // （`getColumnIndex` 返回 -1 的连锁，修复见 `DbUtil.parseResultSet`）。
      await this.ensureColumn('fileSize', 'INTEGER NOT NULL DEFAULT 0')
      await AppDatabaseUtil.existsTable(this.TABLE_NAME)
      return
    } catch (err) {
      console.info('TagInfo', JSON.stringify(err))
    }
  }

  async search(param?:BooksTypeSearchParams) {
    let searchKey = param?.searchKey ?? '';
    let type = param?.type;
    let bookGroup = param?.bookGroup;
    let order = param?.order;
    // ── 2026-10-13 清理死代码：「更新排序 / 手动排序」已无 UI 入口 ──────────────
    // 证据：`IndexSearchType.ets:28-29` 原文
    //   「2026-10-01（用户）：「最近阅读」的排序弹窗（更新排序/手动排序）功能已废，
    //     直接删除——标题恢复为纯文字（无下拉箭头、无点击、无 popup）。」
    // 且全工程只有 `newAddShelf.ets:100` 给过 `searchValue` 赋值（那是搜索关键词，
    // 不是排序）⇒ 书架链上 `searchValue` 恒为 `'最近阅读'`。
    // ⇒ 原来那套 `getOrder()` + `switch(sort)` 三选一恒走 case 0，case 1/2 是死分支。
    //   本方法保留 `order` 参数（调用方仍在传），但语义收窄成"是否指定了排序"：
    //   指定 = 最近阅读；不指定 = 按导入时间（下面两个分支**行为与改造前完全一致**）。
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      let sql = `SELECT * FROM ${this.TABLE_NAME}`;
      // 动态添加 WHERE 子句
      let whereClause: string[] = [];
      if (type !== undefined) {
        whereClause.push(`bookType = ${type}`);
      }
      if (bookGroup !== undefined && bookGroup !== 2) {
        whereClause.push(`bookGroup = ${bookGroup}`);
      }
      if (searchKey) {
        whereClause.push(`(
        bookName LIKE '%${searchKey}%'
        OR author LIKE '%${searchKey}%'
        OR originName LIKE '%${searchKey}%'
      )`);

      }
      // 如果有 where 子句，添加 WHERE 关键字
      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }
      sql += ` ORDER BY`;
      // ── 2026-10-19：排序统一走 `buildOrderByClause()`（唯一真源）──────────────
      // 优先用新的 `sortKey` / `sortDir`；只有它们都没传时才回落到旧的 `order` 语义
      // （传了 = 最近阅读，不传 = 导入时间），保证既有调用点行为不变。
      // ⚠️ 与 `searchPage()` 必须走同一个方法 —— 否则书架与管理页顺序分叉
      //    （该坑在旧注释与 `docs/标准-弹窗与按钮统一规范.md` 里都记过）。
      if (param?.sortKey !== undefined) {
        sql += this.buildOrderByClause(param.sortKey, (param.sortDir ?? 1) === 1);
      } else if (order !== undefined) {
        // 旧语义：「最近阅读」。其口径与 SortKey.RECENT_READ（2）逐字一致。
        sql += this.buildOrderByClause(2, true);
      } else {
        // 旧语义：导入时间降序。与 SortKey.IMPORT_TIME（1）降序一致。
        sql += this.buildOrderByClause(1, true);
      }

      const bookDbList = await DbUtil.querySqlForList<Books>(sql, column);
      console.log("TagInfo", '书籍：' + bookDbList.length)
      return bookDbList
    } catch (err) {
      console.log("TagInfo", JSON.stringify(err))
      return []
    }
  }

  //获取书籍总数量
  async getBookCount(param?: BooksTypeSearchParams) {
    let type = param?.type;
    let bookGroup = param?.bookGroup;
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('bookType', type)
      if (bookGroup !== undefined && bookGroup !== 2) {
        predicates.equalTo('bookGroup', bookGroup)
      }
      const count = await DbUtil.queryForCount(predicates, column)
      return count
    } catch (e){
      console.log("TagInfo", JSON.stringify(e))
      return 0
    }
  }

  /**
   * 列表 / 计数共用的 WHERE 子句（**唯一来源**，2026-10-06）。
   *
   * ⚠️ `searchPage`（分组内列表）与 `queryBookIds`（"共N本"计数）必须共用本方法：
   *    两处口径一旦分叉，就会出现「卡片写共8本、点进去只有3本」。
   * 分支语义逐字节保留原 `searchPage` 的实现，**不要改**：
   *   · `type`          → `bookType = type`；
   *   · `bookGroup = 4` → `bookGroup = 4 or isLocalBook = true`（本地组兼容存量 isLocalBook 书）；
   *   · `bookGroup = 3` → `bookGroup = 3 or (bookGroup = 4 and isLocalBook = true)`
   *       未分组（v3.21）：新导入书 bookGroup=3；存量导入书仍为 4（本地组）
   *       ⇒ 用 isLocalBook 兜底把它们也列进"未分组"（用户口径：未归组即未分组）；
   *   · `bookGroup = 2` → 不加分组条件（"全部"）。
   */
  private buildWhereClause(param?: BooksTypeSearchParams): string[] {
    const searchKey: string = param?.searchKey ?? '';
    const type = param?.type;
    const bookGroup = param?.bookGroup;
    const whereClause: string[] = [];

    if (type !== undefined) {
      whereClause.push(`bookType = ${type}`);
    }
    if (bookGroup !== undefined && bookGroup !== 2) {
      if (bookGroup === 4) {
        whereClause.push(`bookGroup = ${bookGroup} or isLocalBook = ${true}`);
      } else if (bookGroup === 3) {
        whereClause.push(`bookGroup = ${bookGroup} or (bookGroup = 4 and isLocalBook = ${true})`);
      } else {
        whereClause.push(`bookGroup = ${bookGroup}`);
      }
    }
    if (searchKey) {
      whereClause.push(`(
                bookName LIKE '%${searchKey}%'
                OR author LIKE '%${searchKey}%'
                OR originName LIKE '%${searchKey}%'
            )`);
    }
    return whereClause;
  }

  /**
   * 取某个分组下的书籍 id（**只取 id**）——「共N本」这类计数展示专供。
   *
   * 为什么不能读 `book_groups.bookIds`（真机 + 源码双取证，2026-10-06）：
   *   ① 那一列是历史冗余：只有「移动分组」会追加（`bookGroupUtils.updateAddBookIds`），
   *      导入/删除都不同步；真机 novel.db 实测 `groupId=6`（自建分组"1"）名下有 8 本书
   *      （`books.bookGroup=6`），而 `book_groups.bookIds` 是**空串**；
   *   ② `DbUtil.parseResultSet` 把空串读成 `undefined`（`DbUtil.ets:333`
   *      `obj[info.name] = val === '' ? undefined : val`）⇒ `bookIds?.length || 0` 恒为 0
   *      ⇒ 真机界面就是"1 · 共0本"（未分组因为 BookFolder 里单独现算过才显示真实值）。
   * 本方法 WHERE 与 `searchPage` 同源 ⇒ 「共N本」== 点进分组后列表的条数。
   */
  async queryBookIds(param?: BooksTypeSearchParams): Promise<string[]> {
    try {
      const whereClause: string[] = this.buildWhereClause(param);
      let sql = `SELECT id FROM ${this.TABLE_NAME}`;
      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }
      const idColumn: ColumnInfo[] = [{ name: 'id', columnName: 'id', type: ColumnType.LONG }];
      const rows: Books[] = await DbUtil.querySqlForList<Books>(sql, idColumn);
      return rows.map((item: Books): string => String(item.id ?? ''));
    } catch (err) {
      console.log('queryBookIds, Error, ', JSON.stringify(err));
      return [];
    }
  }

  async searchPage(param?: BooksTypeSearchParams, pageNumber: number = 1, pageSize: number = 21) {
    let order = param?.order;
    // 2026-10-13 清死代码：原来的 `getOrder()` + `switch(sort)` 恒走 case 0，
    // 「更新排序 / 手动排序」已无 UI 入口（证据见本文件 `search()` 里的同段注释）。

    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      let sql = `SELECT * FROM ${this.TABLE_NAME}`;
      const whereClause: string[] = this.buildWhereClause(param);

      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }

      sql += ` ORDER BY`;
      // ── 2026-10-19：与 `search()` **走同一个方法**（唯一真源）────────────────
      // 这里原本是手抄的一份 ORDER BY，文件里早有注释警告两处必须同步。
      // 现在档位从 1 个变 5×2 个组合，手抄必然分叉 ⇒ 统一调 `buildOrderByClause()`。
      if (param?.sortKey !== undefined) {
        sql += this.buildOrderByClause(param.sortKey, (param.sortDir ?? 1) === 1);
      } else if (order !== undefined) {
        sql += this.buildOrderByClause(2, true);
      } else {
        sql += this.buildOrderByClause(1, true);
      }

      // pageSize <= 0 ⇒ 不加 LIMIT（全量）。管理页需要列出全部书籍，
      // 旧实现写死 (1,100) 导致超过 100 本只显示 100 本（2026-09-24 用户反馈）。
      if (pageSize > 0) {
        const offset = (pageNumber - 1) * pageSize;
        sql += ` LIMIT ${pageSize} OFFSET ${offset}`;
      }

      const bookDbList = await DbUtil.querySqlForList<Books>(sql, column);
      console.log("TagInfo", '书籍：' + bookDbList.length)
      return bookDbList;
    } catch (err) {
      console.log("TagInfo", JSON.stringify(err))
      return [];
    }
  }

  /**
   * 存量书的 `fileSize` 回填（2026-10-19 新增，一次性）。
   *
   * ── 为什么需要 ────────────────────────────────────────────────────────────
   * `fileSize` 是后加的列，老库里全为 0 ⇒ 排序面板的「文件大小」对存量书无效
   * （`buildOrderByClause` 的 case 4 会把 0 压到最后，表现为"点了没反应"）。
   * 首次启动时本方法逐本 `fs.statSync` 回填一次，之后由 `FileHandler.CopyFile`
   * 在导入时直接写入。
   *
   * ── 设计取舍 ──────────────────────────────────────────────────────────────
   * · 只处理 `fileSize = 0` 且 `isLocalBook = 1` 的行：网络书源的书没有本地文件，
   *   本来就不该有大小；
   * · 用 Preferences 一次性标志去重，避免每次冷启动都扫一遍；
   * · `statSync` 失败（文件已被用户删除）→ 写 0，**不阻塞**其他书；
   * · 全程 `await` 串行 + try/catch：回填只是"让排序更准"，
   *   任何一步失败都不该拖慢/搞崩书架首屏。
   *
   * 一键回退：删掉 `BookContent.aboutToAppear` 里对它的调用即可，
   * 存量书的大小排序会退回"全部按 0 压最后"的行为。
   */
  async backfillFileSize(): Promise<void> {
    // 一次性标志（与工程既有命名风格一致，见 `KEY_BOOKTYPE_MERGED`）
    const KEY: string = 'shelfFileSizeBackfilledV1';
    try {
      if (PreferencesUtil.getSync(KEY, false) === true) {
        return;
      }
      // 只查"缺大小 + 本地书"的行，避免全表扫
      const rows: Books[] = await DbUtil.querySqlForList<Books>(
        `SELECT id, bookUrl FROM ${this.TABLE_NAME} WHERE isLocalBook = 1 AND (fileSize IS NULL OR fileSize = 0)`,
        AppDatabaseUtil.getAssignColumn(this.TABLE_NAME, ['id', 'bookUrl', 'fileSize']));
      let fixed: number = 0;
      for (const row of rows) {
        const id: number | undefined = row.id;
        const path: string | undefined = row.bookUrl;
        if (id === undefined || path === undefined || path.length === 0) {
          continue;
        }
        let size: number = 0;
        try {
          size = fs.statSync(path).size;
        } catch (e) {
          // 文件不存在（用户删了文件没删书）⇒ 保持 0
          size = 0;
        }
        try {
          // 只写这一列，不动其他字段（避免把内存里的旧快照覆盖回去）
          await DbUtil.executeSql(
            `UPDATE ${this.TABLE_NAME} SET fileSize = ${Math.floor(size)} WHERE id = ${Math.floor(id)}`);
          fixed++;
        } catch (e) {
          // 单行失败不影响其余
        }
      }
      // 只有在**确实扫过**之后才置标志：否则一次异常会导致以后永不回填
      PreferencesUtil.putSync(KEY, true);
      console.log('TagInfo', `backfillFileSize: 处理 ${rows.length} 本，成功 ${fixed} 本`);
    } catch (err) {
      console.log('TagInfo', 'backfillFileSize Error', JSON.stringify(err));
    }
  }

  async batchInsert(books: Books[]) {
    try {
      for (let index = 0; index < books.length; index++) {
        const book = books[index];
        await this.insert(book)
      }
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  async insert(books: Books) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      if (books.id) {
        const predicates = DbUtil.getPredicates(this.TABLE_NAME);
        predicates.equalTo('id', books.id)
        const count = await DbUtil.queryForCount(predicates, column)
        if (count > 0) {
          // ⚠️ 2026-10-01 必须 await：原裸调 `this.update(books)` 不等待，insert 在 UPDATE
          // 提交**前**就 resolve ⇒ 调用方（如 CoverStyleDialog 换封面）紧接着广播
          // BOOK_IS_BOOK_REFRESHING，书架重查读到的还是旧行 ⇒ 界面不更新，要等下次
          // 手动刷新才好（真机日志 2.md 16:56 单本封面保存后弹窗/书架均不联动）。
          await this.update(books)
          return true
        }
      }
      books.createTime = Date.now()
      // ⚠️ 必须把新 rowid **回填**到对象上（T5-1 的前置条件）。
      //    `DbUtil.insert` 本就 resolve 了 rowid（DbUtil.ets:133-139 `resolve(id)`），
      //    但旧实现丢弃了返回值 ⇒ 调用方手里的 `Books` 没有 id，
      //    只有"从数据库回读"的对象才带 id（依赖"恰好"而非"保证"）。
      //    另：`buildValueBucket` 会跳过 undefined 字段（DbUtil.ets:299），
      //    故 id 未设时 SQLite 按 `INTEGER PRIMARY KEY`（rowid 别名）自动分配并返回。
      const newId: number = await DbUtil.insert(this.TABLE_NAME, books, column)
      if (newId > 0) {
        books.id = newId
      }
      console.log('TagInfo', '创建成功', newId)
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  async update(books: Books) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('id', books.id)
      const count = await DbUtil.queryForCount(predicates, column)
      if (count === 0 && books instanceof Books) {
        this.insert(books)
        return true
      }
      await DbUtil.update(predicates, books, column)
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }
  //置顶
  // ⚠️ 逐本 await 写入（2026-09-29，审核问题②）：forEach 裸调 + 不等待 ⇒ 调用方
  // 拿到 resolve 时写库未完成，随即重查列表查到旧值（"置顶后不实时更新"根因之一）。
  async isUpdateBookTop(id: number, isTop: boolean) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('id', id)
      const count = await DbUtil.queryForList<Books>(predicates, column)
      // 旧实现误判 `column.length > 0`（列定义恒非空）—— 应判**查询结果**
      if (count.length > 0) {
        for (const item of count) {
          item.isTop = isTop
          item.updateTime = Date.now()
          await this.update(item)
        }
        return true
      }
      return false
    } catch (err) {
      console.log('isUpdateBookTop, Error, ', JSON.stringify(err))
      return false
    }
  }
  //批量更新书籍分组
  async batchUpdateBookGroup(id: number[],groupId:number) {
    try {
      for (let index = 0; index < id.length; index++) {
       this.updateBookGroup(id[index],groupId)
      }
      return true
    } catch (err) {
      console.log('batchUpdateBookGroup, Error, ', JSON.stringify(err))
      return false
    }
  }
  //更新书籍分组
  async updateBookGroup(bookIds: number|number[],groupId:number) {
    try {
      let Ids: number[] = toolsUtils.numberArrays(bookIds)
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const validIds = Ids.filter(id => typeof id === 'number');
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.in('id', validIds)
      const count = await DbUtil.queryForList<Books>(predicates, column)
      if (count.length > 0) {
        count.forEach(async (item) => {
          item.bookGroup = groupId
          await this.update(item)
        })
        return true
      }
      return false
    } catch (err) {
      console.log('updateBookGroup, Error, ', JSON.stringify(err))
      return false
    }
  }

  //根据书籍获取旧的分组Id
  async getBookIdsByGroupId(ids: number[]) {
    let BookGroupId: Record<number, number> = {};
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);

      // 确保 ids 数组的每个元素都是数字
      const validIds = ids.filter(id => typeof id === 'number');

      // 创建查询条件，查找所有给定的 id
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.in('id', validIds);  // 使用 in 条件一次性查找多个 id

      // 执行一次查询获取所有匹配的书籍
      const books = await DbUtil.queryForList<Books>(predicates, column);

      // 遍历查询结果，将书籍的 bookGroup 分组
      books.forEach(book => {
        const bookId = book.id;  // 获取书籍的 id
        if (bookId !== undefined) {
          if (!BookGroupId[bookId]) {
            BookGroupId[bookId] = 0;
          }
          BookGroupId[bookId] = book.bookGroup ?? 0;
        }
      });

      return BookGroupId;
    } catch (e) {
      console.log('getBookIdsByGroupId, Error, ', JSON.stringify(e));
      return [];
    }
  }

  //根据分组获取书籍id
  async queryBooksByGroupId(groupId: number[]){
    let GroupBookId: number[] = [];
    try {
      // 确保 ids 数组的每个元素都是数字
      const validIds = groupId.filter(id => typeof id === 'number');
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.in('bookGroup', validIds)
      // 执行一次查询获取所有匹配的书籍
      const books = await DbUtil.queryForList<Books>(predicates, column);
      // 遍历查询结果，将书籍的 bookGroup 分组
      books.forEach(book => {
        const bookId = book.id;  // 获取书籍的 id
        if (bookId !== undefined) {
          GroupBookId.push(bookId)
        }
      });
      return GroupBookId
    } catch (e) {
      console.log('queryBooksByGroupId, Error, ', JSON.stringify(e));
      return []
    }
  }

  //删除订阅源历史记录
  async deleteBook(id: number[]) {
    try {
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.in('id', id)
      await DbUtil.delete(predicates)
      return true
    }  catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  //根据分组id统计书籍数量
  async countBookByGroup(groupId: number) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('bookGroup', groupId)
      const count = await DbUtil.queryForCount(predicates, column)
      return count
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return 0
    }
  }

  //分组删除情况下根据删除分组id查询书籍更新未分组
  async queryBookByGroup(groupId: number[],updateGroupId: number) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.in('bookGroup', groupId)
      const bookDbList = await DbUtil.queryForList<Books>(predicates, column)
      if (bookDbList.length > 0) {
        bookDbList.forEach((item) => {
          item.bookGroup = updateGroupId
          this.update(item)
        })
      }
    } catch (e) {
      console.log('TagInfo, Error, ', JSON.stringify(e))
    }
  }

  // 校验当前书籍是否存在书架中
  async isExistBooks(bookUrl?: string, bookName?: string): Promise<Books[]> {
    if (!bookUrl || !bookName) {
      console.warn('bookUrl or bookName is missing.');
      return [];
    }

    const column = AppDatabaseUtil.getColumn(this.TABLE_NAME);
    const predicates = DbUtil.getPredicates(this.TABLE_NAME);
    predicates.equalTo('bookUrl', bookUrl);
    predicates.equalTo('bookName', bookName);

    try {
      const books = await DbUtil.queryForList<Books>(predicates, column);
      return books || [];
    } catch (err) {
      console.error('isExistBooks, Error:', err);
      return [];
    }
  }


  //根据书籍Id获取书籍
  async getBookByIds(ids: number[]): Promise<Books[]> {

    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);

      // 确保 ids 数组的每个元素都是数字
      const validIds = ids.filter(id => typeof id === 'number');
      if (validIds.length === 0) return []
      // 创建查询条件，查找所有给定的 id
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.in('id', validIds);  // 使用 in 条件一次性查找多个 id

      // 执行一次查询获取所有匹配的书籍
      const books = await DbUtil.queryForList<Books>(predicates, column);

      return books;
    } catch (e) {
      console.log('getBookIds, Error, ', JSON.stringify(e));
      return [];
    }
  }
  /**
   * 取「真正最后一次阅读」的书（桌面快捷方式「快速听书 / 快速阅读」用）。
   *
   * ## 为什么**不能**用 `durChapterTime` 排序（实测踩坑记录）
   * 初版实现按 `durChapterTime DESC` + `greaterThan('durChapterTime', 0)` 取第一条，
   * **真机实测始终返回 null**（日志：`quickAction=listen` 后 10ms 就弹了"还没有阅读记录"）。
   * 查证原因：**当前阅读页 `ReaderPage3` 根本不写数据库的 `durChapterTime`** ——
   * 全文件对 `durChapterTime` / `BookHistory` / `updateBook` 的引用数为 **0**；
   * 它把进度存在 **Preferences** 的 `BookCurrentData_<书名>`（见 `ReaderPage3:482-488`）。
   * 会写 `durChapterTime` 的只有**旧**阅读页 `ReaderPage2:883`、`BookDetailPage:374`
   * 与 `BookHistoryUtils`，当前路径一个都不过。⇒ 该字段对所有用新阅读页读过的书恒为 0，
   * 过滤条件把所有书都排除了。
   *
   * ## 现方案：读「阅读页自己写的标记」
   * `ReaderPage3.registerPageShow()` 在每次翻页时写入
   * `LastReadBookName` / `LastReadBookUrl` 两个 Preferences 键。
   * 这里按这两个键回查 `books` 表拿完整 `Books` 对象（阅读页需要完整 bookData）。
   * 不按 `bookName` 单独查是为了避免同名不同源的书串台。
   *
   * @returns 最近阅读的书；无标记或表里查不到时返回 null（由调用方走兜底提示）
   */
  async getLastReadBook(): Promise<Books | null> {
    try {
      const name = PreferencesUtil.getSync('LastReadBookName', '') as string;
      const url = PreferencesUtil.getSync('LastReadBookUrl', '') as string;
      // ★ 诊断打点（2026-10-12）：本方法是「书架听书圆形按钮」定位目标书的唯一入口，
      //   而它用的是 **Preferences 里的 `LastReadBookName`** 去 `books` 表按名回查
      //   （不是按 id）⇒ **改名后这个键必须已经迁到新名**，否则有两种失败形态：
      //     ① 查不到 ⇒ 返回 null（用户点圆形"没反应"）；
      //     ② 查到了**同名另一行** ⇒ 书名条显示的是那一行的名字（用户报的"名字不统一"）。
      //   这两行日志把键值与命中行一起打出来，一次复现就能定性。
      hilog.info(0x0000, 'listenSession',
        'getLastReadBook: key name=%{public}s url=%{public}s', name, url);
      if (typeof name !== 'string' || name.length === 0) {
        return null;
      }
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('bookName', name);
      if (typeof url === 'string' && url.length > 0) {
        predicates.equalTo('bookUrl', url);
      }
      const books = await DbUtil.queryForList<Books>(predicates, column);
      hilog.info(0x0000, 'listenSession',
        'getLastReadBook: hit=%{public}d firstId=%{public}d firstName=%{public}s',
        books.length, books.length > 0 ? (books[0].id ?? -1) : -1,
        books.length > 0 ? (books[0].bookName ?? '') : '');
      if (books.length === 0) {
        return null;
      }
      return books[0];
    } catch (e) {
      console.log('getLastReadBook, Error, ', JSON.stringify(e));
      return null;
    }
  }

  /**
   * 「读过」计数：有阅读记录的书（`durChapterTime > 0`）。
   * 与「读完」**相互独立** —— 删除读过记录不影响读完记录（见 `clearReadRecord`）。
   */
  async countRead(): Promise<number> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const p = DbUtil.getPredicates(this.TABLE_NAME);
      p.greaterThan('durChapterTime', 0);
      const list = await DbUtil.queryForList<Books>(p, column);
      return list.length;
    } catch (e) {
      console.log('countRead, Error, ', JSON.stringify(e));
      return 0;
    }
  }

  /**
   * 「读完」计数：**曾经**读到过末章（`finishedTime > 0`）。
   * 只写一次（读到末章时若为 0 才写），所以"读完后回第一章重看"仍算读完、
   * "同一本第二次到 100%" 不会重复计。
   */
  async countFinished(): Promise<number> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const p = DbUtil.getPredicates(this.TABLE_NAME);
      p.greaterThan('finishedTime', 0);
      const list = await DbUtil.queryForList<Books>(p, column);
      return list.length;
    } catch (e) {
      console.log('countFinished, Error, ', JSON.stringify(e));
      return 0;
    }
  }

  /**
   * 「读完」计数（**限定时间区间**）：`finishedTime` 落在 `[startMs, endMs]` 内的本数。
   *
   * 为什么需要"区间"版（2026-10-13 阅读数据模块）：
   * 「本日/本月/本年读完几本」必须按周期统计，而 `countFinished()` 只有总数。
   * 「读完」的数据源刻意**不用**新的时长表 `readDaily` ——
   * `finishedTime` 是"曾经读到末章"的一次性标记，**历史数据本来就有**，
   * 用它统计可以让日月年三档一上线就显示真实值（时长则只能从功能上线后积累）。
   */
  async countFinishedInRange(startMs: number, endMs: number): Promise<number> {
    try {
      const s: number = Math.floor(startMs)
      const e: number = Math.floor(endMs)
      const rows = await DbUtil.querySqlForList<CountRow>(
        `SELECT COUNT(*) AS cnt FROM ${this.TABLE_NAME} ` +
        `WHERE finishedTime > 0 AND finishedTime >= ${s} AND finishedTime <= ${e}`,
        COUNT_COLUMN)
      return rows.length > 0 ? (rows[0].cnt ?? 0) : 0
    } catch (e2) {
      console.log('countFinishedInRange, Error, ', JSON.stringify(e2))
      return 0
    }
  }

  /** 「读过」列表：按最后阅读时间倒序 */
  async listRead(): Promise<Books[]> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const p = DbUtil.getPredicates(this.TABLE_NAME);
      p.greaterThan('durChapterTime', 0);
      p.orderByDesc('durChapterTime');
      return await DbUtil.queryForList<Books>(p, column);
    } catch (e) {
      console.log('listRead, Error, ', JSON.stringify(e));
      return [];
    }
  }

  /** 「读完」列表：按首次读完时间倒序 */
  async listFinished(): Promise<Books[]> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const p = DbUtil.getPredicates(this.TABLE_NAME);
      p.greaterThan('finishedTime', 0);
      p.orderByDesc('finishedTime');
      return await DbUtil.queryForList<Books>(p, column);
    } catch (e) {
      console.log('listFinished, Error, ', JSON.stringify(e));
      return [];
    }
  }

  /**
   * 删除「读过」记录 —— **只删记录，不删书**。
   * 按用户口径：清掉该书的阅读进度字段，让它从「读过」列表消失；
   * **刻意不动 `finishedTime`** ⇒ 若它曾读完，「读完」里仍保留（三项相互独立）。
   */
  async clearReadRecord(id: number): Promise<boolean> {
    if (id === undefined || id === null || id <= 0) {
      return false;
    }
    try {
      await DbUtil.executeSql(
        `UPDATE books SET durChapterTime = 0, durChapterIndex = 0, durChapterPos = 0,`
          + ` durChapterTitle = '' WHERE id = ${Math.floor(id)}`)
      return true;
    } catch (e) {
      console.log('clearReadRecord, Error, ', JSON.stringify(e));
      return false;
    }
  }

  /** 删除「读完」记录 —— 只清 `finishedTime`，不影响「读过」与书签 */
  async clearFinishRecord(id: number): Promise<boolean> {
    if (id === undefined || id === null || id <= 0) {
      return false;
    }
    try {
      await DbUtil.executeSql(
        `UPDATE books SET finishedTime = 0 WHERE id = ${Math.floor(id)}`)
      return true;
    } catch (e) {
      console.log('clearFinishRecord, Error, ', JSON.stringify(e));
      return false;
    }
  }

  /** 标记「读完」（只写一次：已是 >0 则不动）——由阅读页读到末章时调用 */
  async markFinished(id: number): Promise<void> {
    if (id === undefined || id === null || id <= 0) {
      return;
    }
    try {
      await DbUtil.executeSql(
        `UPDATE books SET finishedTime = ${Date.now()} WHERE id = ${Math.floor(id)} AND (finishedTime IS NULL OR finishedTime = 0)`)
    } catch (e) {
      console.log('markFinished, Error, ', JSON.stringify(e));
    }
  }

  /**
   * 写入「阅读进度 + 最后阅读时间」到数据库。
   *
   * ⚠️ **为什么必须由阅读页显式调用**（2026-09-21 真机取证）：
   * 当前阅读页 `ReaderPage3` 把进度只写进 **Preferences**（`BookCurrentData_<书名>`），
   * **从不写数据库的 `durChapterTime`** —— 全文件对该字段引用数为 0。
   * 而会写它的只有**旧**阅读页 `ReaderPage2`、`BookDetailPage`、`BookHistoryUtils`，当前路径一个都不过。
   * 后果有两个（都已被实测确认）：
   *   ① `books` 表 `durChapterTime` 恒为 0 ⇒「我的 → 读过」计数永远是 0；
   *   ② 书架「最近阅读」排序（`BooksDao:63` `isTop DESC, durChapterTime DESC`）同样失效；
   *   ③ 桌面快捷方式「快速听书/快速阅读」也因此取不到"最后阅读"（已改用独立标记绕过）。
   * 本方法就是把这个缺口补上。
   *
   * @param chapterTitle 传空串时**不改**该列（避免阅读页还没拿到章节名时把它清空）
   * @param totalChapterNum 总章数；传 0 时**不改**该列。
   *
   * ⚠️ **`totalChapterNum` 为什么必须在这里补写**（2026-09-21 真机日志取证）：
   * 全工程对 `books.totalChapterNum` 只有**一个**写入点 —— `ReaderPage3.ets:652`
   * `this.bookData.totalChapterNum = this.CatalogList.totalCount()`，它只改**内存对象**，
   * 从不落库 ⇒ 数据库里恒为 `0`。
   * 后果（真机日志 `catalog list length: 765` 说明内存里其实是 765）：
   *   ① 「我的 → 读过」的进度百分比 `(cur+1)/total` 除零 ⇒ 恒 0%；
   *   ② 书签列表进度百分比同源除零 ⇒ 恒 0%；
   *   ③ `ReaderPage3.checkFinished()` 首行 `if (total <= 0) return` ⇒「读完」永不触发、计数恒 0。
   * 故在此连同进度一起补写（传 0 表示本次拿不到，保留原值，不覆盖）。
   */
  async stampReadProgress(id: number, chapterIndex: number, chapterTitle: string,
    totalChapterNum: number = 0): Promise<void> {
    if (id === undefined || id === null || id <= 0) {
      return;
    }
    try {
      const t = Date.now();
      const idx = Math.max(0, Math.floor(chapterIndex));
      const total = Math.max(0, Math.floor(totalChapterNum || 0));
      const totalSql = total > 0 ? `, totalChapterNum = ${total}` : '';
      if (chapterTitle.length > 0) {
        await DbUtil.executeSql(
          `UPDATE books SET durChapterTime = ${t}, durChapterIndex = ${idx},`
            + ` durChapterTitle = '${chapterTitle.replace(/'/g, "''")}'${totalSql}`
            + ` WHERE id = ${Math.floor(id)}`);
      } else {
        await DbUtil.executeSql(
          `UPDATE books SET durChapterTime = ${t}, durChapterIndex = ${idx}${totalSql}`
            + ` WHERE id = ${Math.floor(id)}`);
      }
    } catch (e) {
      console.log('stampReadProgress, Error, ', JSON.stringify(e));
    }
  }

  //部分更新
  async partialUpdate(books: Books) {
    if (!(books instanceof Books)) {
      console.warn('Invalid Books instance.');
      return;
    }
    // ⚠️ id 缺失时必须直接返回（T5-8 核查发现的一致性问题）。
    //    旧实现把可能为 undefined 的 id 直接传给 `predicates.equalTo('id', …)`，
    //    全靠"底层抛错被下面的 catch 吃掉"或"= NULL 恒不匹配"才没出事 —— 是**运气**不是设计。
    //    同一工程内 `SubscriptionDao.ets:97` 就有正确写法：
    //      `if (rssSource.id !== 0 && rssSource.id !== undefined) { predicates.equalTo('id', …) }`
    //    典型触发路径：搜索 → 详情页 → 直接阅读（该路径的 bookData 无 id，见 T5-1 第 ② 步查证）。
    if (books.id === undefined || books.id === null || books.id <= 0) {
      console.warn('partialUpdate skipped: book id is missing.');
      return;
    }

    const column = this.getPartialColumn();
    const predicates = DbUtil.getPredicates(this.TABLE_NAME);
    predicates.equalTo('id', books.id);

    try {
      const count = await DbUtil.queryForCount(predicates, column);

      if (count > 0) {
        await DbUtil.update(predicates, books, column);
      } else {
        console.warn('No records found for update.');
      }
    } catch (err) {
      console.error('Error in partialUpdate:', err);
    }
  }

  getPartialColumn(): ColumnInfo[] {
    return AppDatabaseUtil.getAssignColumn(this.TABLE_NAME, ['id',
      'latestChapterTitle', 'latestChapterTime', 'lastCheckTime',
      'lastCheckCount', 'totalChapterNum', 'durChapterTitle',
      'durChapterIndex', 'durChapterPos', 'durChapterTime',
      'wordCount', 'syncTime', 'updateTime'
    ]);
  }

  /**
   * 统计**除给定 id 之外**还有多少书引用同一张自定义封面（删书清理封面文件用）。
   *
   * 为什么需要引用计数（2026-10-13）：批量封面（`coverInfoDialog.applyGroupCover`）
   * 会把**同一个** `customCoverUrl` 写给范围内每一本书 —— 删掉其中一本时若直接
   * `unlink` 那个文件，其余书的封面会全部变成死链。只有计数为 0 才能真删。
   *
   * 自带封面（`builtinCoverUrl`）不需要计数：文件名由**该书**的文件名派生，一书一份。
   *
   * 依据（SDK `@ohos.data.relationalStore.d.ts`）：
   *   `notIn(field: string, value: Array<ValueType>): RdbPredicates;`（@since 9）
   */
  async countCustomCoverRefsExcluding(uri: string, excludeIds: number[]): Promise<number> {
    if (uri === undefined || uri === null || uri === '' || excludeIds.length === 0) {
      return 0;
    }
    try {
      const validIds: number[] = excludeIds.filter((id: number): boolean => typeof id === 'number');
      if (validIds.length === 0) {
        return 0;
      }
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('customCoverUrl', uri);
      predicates.notIn('id', validIds);
      return await DbUtil.queryForCount(predicates, column);
    } catch (e) {
      // 查询失败时**保守返回 1**（当作"还有人用"）⇒ 宁可不删文件，也不删出死链
      console.log('countCustomCoverRefsExcluding, Error, ', JSON.stringify(e));
      return 1;
    }
  }

  /**
   * 一次性迁移：把「漫画 / 有声书」两个分类页签的数据并回「书架」。
   *
   * 背景（2026-10-11 用户裁定）：书架顶部三个页签（小说/漫画/有声书）在实现上只是
   * `Books.bookType` 的 SQL 分区，而漫画/有声书没有任何对应的渲染与导入格式
   * ⇒ 两个入口删除，只剩「书架」。
   *
   * ⚠️ 删入口不能丢数据：历史上如果用户站在那两个页签下导入过书，
   *    `FileHandler.CopyFile(src, currentIndex)` 会把 `bookType` 记成 1/2
   *    （`FileHandler.ets:82`）⇒ 入口删掉后这些书**在界面上再也查不到**
   *    （`BooksDao.buildWhereClause` 的 `bookType = type` 恒为 0）。
   *    同理，在这两个页签下自建的分组 `groupType` 记成 1/2
   *    （`BookSelectGroupDialog.ets:213` `bookGroups.groupType = this.currentIndex`）、
   *    书单 `worksType` 也按大类分过档。
   *
   * 做法：UPDATE 三张表，把 1/2 一律归一成 0。
   *  · 幂等：Preferences 标志 `bookTypeMergedToShelfV1`，跑过一次就不再跑；
   *  · 失败**不打标志** ⇒ 下次启动重试（与 `FileHandler.seedDefaultBook` 同款约定）；
   *  · 顺序：在 `DataBase.initAllTable()` 建表**之后**调用（三张表此时必存在）。
   *
   * 回退：把下面 `KEY_BOOKTYPE_MERGED` 对应的 Preferences 值清掉即可再跑一次；
   *   若已迁移又想退回三页签，只能靠备份 —— 本迁移**不可逆**（符合用户选择：归到书架、不丢书）。
   */
  /**
   * 回退说明（「删掉漫画/有声书两个页签」这一版改动）：
   *  · 代码侧 —— `git checkout` 本文件 + `database/index.ets` + `IndexShelf.ets` +
   *    `readStatistics.ets` + `readTabs.ets` + `groupTypePanel.ets` + `BookBodyContent.ets`，
   *    即可恢复三页签（`IndexShelf.titleArray` 是唯一入口清单）。
   *  · 数据侧 —— 下面的 UPDATE 是**原地覆盖、不可逆**。所以迁移**之前**已把「将被改动的
   *    主键 + 原 bookType」序列化进 Preferences（键 `bookTypeMergedToShelfV1_backup`）。
   *    要还原：取出该 JSON，按 id 逐条 `UPDATE books SET bookType = ?` 即可
   *    （应用内没有 SQL 控制台 ⇒ 手工手段是 hdc 拉库，或临时写一段一次性代码执行）。
   *  · 留档只覆盖 `books`：`book_groups` / `works_lists` / `book_history` 三张表在本工程
   *    里**没有写入 1/2 的入口**（`newBookShelf.ets:168,499` 恒写 0；
   *    `BookSelectGroupDialog.ets:213` 写的是当前大类 = 0），实际不会产生这两档数据。
   */
  async migrateBookTypeToShelf(): Promise<void> {
    if (PreferencesUtil.getSync(KEY_BOOKTYPE_MERGED, false) === true) {
      console.info('TagInfo', 'migrateBookTypeToShelf: already done, skip');
      return;
    }
    try {
      await this.backupBookTypeBeforeMerge()
      await DbUtil.executeSql(
        `UPDATE ${this.TABLE_NAME} SET bookType = 0 WHERE bookType = 1 OR bookType = 2`)
      await DbUtil.executeSql(
        `UPDATE book_groups SET groupType = 0 WHERE groupType = 1 OR groupType = 2`)
      await DbUtil.executeSql(
        `UPDATE works_lists SET worksType = 0 WHERE worksType = 1 OR worksType = 2`)
      // book_history 的 bookType 只在「浏览历史」里用，那个入口早已摘除；
      // 一并归一，保证存量数据不会在别处按旧口径被过滤掉。
      await DbUtil.executeSql(
        `UPDATE book_history SET bookType = 0 WHERE bookType = 1 OR bookType = 2`)
      PreferencesUtil.putSync(KEY_BOOKTYPE_MERGED, true)
      console.info('TagInfo', 'migrateBookTypeToShelf: done (bookType/groupType/worksType -> 0)');
    } catch (e) {
      // 不打标志 ⇒ 下次启动重试。必须留原因（上一版种书迁移静默失败吃过亏）。
      console.error('TagInfo', 'migrateBookTypeToShelf failed: ' + JSON.stringify(e));
    }
  }

  /**
   * 迁移**前**留档：把 `bookType = 1/2` 的书的 `{id, bookType}` 存进 Preferences，
   * 作为「万一要退回三页签」的唯一还原依据（UPDATE 本身不可逆）。
   * ⚠️ 留档失败**不阻断迁移**（它是附加保障，不是前置条件），但必须留痕。
   */
  private async backupBookTypeBeforeMerge(): Promise<void> {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      // ⚠️ 必须 `SELECT *`：`DbUtil.parseResultSet` 会对 `column` 里的**每一列**调
      //    `result.getColumnIndex(name)`，只 SELECT 少数字段会让其余列索引为 -1 而读崩。
      const rows: Books[] = await DbUtil.querySqlForList<Books>(
        `SELECT * FROM ${this.TABLE_NAME} WHERE bookType = 1 OR bookType = 2`, column);
      const backup: BookTypeBackupRow[] = [];
      for (const r of rows) {
        backup.push({ id: r.id ?? -1, bookType: r.bookType });
      }
      PreferencesUtil.putSync(KEY_BOOKTYPE_BACKUP, JSON.stringify(backup));
      console.info('TagInfo', 'migrateBookTypeToShelf: backed up ' + backup.length + ' row(s)');
    } catch (e) {
      console.error('TagInfo', 'backupBookTypeBeforeMerge failed: ' + JSON.stringify(e));
    }
  }
}


const booksDao = new BooksDao()
export default booksDao as BooksDao