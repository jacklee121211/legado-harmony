import booksUtils from '../../common/utils/booksUtils';
import DbUtil from '../../common/utils/DbUtil';
import toolsUtils from '../../common/utils/ToolsUtils';
import AppDatabaseUtil from '../AppDatabaseUtil';
import { Books } from '../entities/Books';
import { BooksTypeSearchParams } from '../types/BooksType';
import { ColumnInfo, ColumnType } from '../types/ColumnInfo';
import { PreferencesUtil } from '@pura/harmony-utils';

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

class BooksDao {
  TABLE_NAME: string = 'books'

  // 创建books数据表
  async initBooksTable() {
    try {
      const createSql = AppDatabaseUtil.getCreateSql(this.TABLE_NAME);
      if (!createSql) {
        return
      }
      await DbUtil.createTable(createSql)
      // ── finishedTime 列迁移（2026-09-21）──────────────────────────────────
      // `CREATE TABLE IF NOT EXISTS` 对**已存在**的表不会补列，而本工程
      // `AppDatabase/index.ets` 的 `formatVersion` 固定为 1、**没有任何 upgrade 路径**
      // （全文件无 ALTER/version 分支）。所以后加的列必须在这里显式补。
      // 对"列已存在"的报错**必须容忍** —— 新装用户走 createSql 建好列后会命中这里。
      try {
        await DbUtil.executeSql('ALTER TABLE books ADD COLUMN finishedTime INTEGER NOT NULL DEFAULT 0')
      } catch (e) {
        // 列已存在（新装/已迁移）⇒ 正常情况，忽略
      }
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
    let sort = 0
    if (order !== undefined){
      sort = booksUtils.getOrder(order)
    }
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
      if (order !== undefined) {
        switch (sort){
          case 0:
            sql += ` isTop DESC, durChapterTime DESC`;
            break;
          case 1:
            sql += ` isTop DESC, latestChapterTime DESC`;
            break;
          case 2:
            sql += ` isTop DESC, sort ASC`;
            break;
        }
      } else {
        sql += ` isTop DESC, createTime DESC`;
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
    let sort = 0;
    if (order !== undefined) {
      sort = booksUtils.getOrder(order);
    }

    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      let sql = `SELECT * FROM ${this.TABLE_NAME}`;
      const whereClause: string[] = this.buildWhereClause(param);

      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }

      sql += ` ORDER BY`;
      if (order !== undefined) {
        switch (sort) {
          case 0:
            sql += ` isTop DESC, durChapterTime DESC, createTime DESC`;
            break;
          case 1:
            sql += ` isTop DESC, latestChapterTime DESC,updateTime DESC`;
            break;
          case 2:
            sql += ` isTop DESC, sort ASC`;
            break;
        }
      } else {
        sql += ` isTop DESC, createTime DESC`;
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