/**
 * @author 2008
 * @datetime 2024/8/05 22:34
 * @className: BookHistoryDao
 * 书籍浏览历史
 */
import DbUtil from '../../common/utils/DbUtil';
import { sqlEscape } from '../SqlSafe';
import AppDatabaseUtil from '../AppDatabaseUtil';
import { BookHistory } from '../entities/BookHistory';
import { BookHistoryTypeParams } from '../types/BookHistoryType';
import { ColumnInfo } from '../types/ColumnInfo';

class BookHistoryDao {
  TABLE_NAME: string = 'book_history'

  // 创建book_history数据表
  async initBookHistoryTable() {
    try {
      const createSql = AppDatabaseUtil.getCreateSql(this.TABLE_NAME);
      if (!createSql) {
        return
      }
      await DbUtil.createTable(createSql)
      await AppDatabaseUtil.existsTable(this.TABLE_NAME)
      return
    } catch (err) {
      console.info('TagInfo', JSON.stringify(err))
    }
  }

  async search(params?:BookHistoryTypeParams) {
    const type = params?.type
    const sort = params?.sort
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      let sql = `SELECT * FROM ${this.TABLE_NAME}`;
      // 动态添加 WHERE 子句
      let whereClause: string[] = [];
      if (type !== undefined){
        whereClause.push(`bookType = ${type} OR bookType = 123`);
      }
      // 如果有 where 子句，添加 WHERE 关键字
      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }
      sql += ` ORDER BY`;
      if (sort !== undefined) {
        sql += ` ${sort === 0 ? 'durChapterTime' : 'updateTime'} DESC`
      } else {
        sql += ` durChapterTime DESC`;
      }
      const bookHistoryDbList = await DbUtil.querySqlForList<BookHistory>(sql, column);

      return bookHistoryDbList
    } catch (err) {
      console.log("TagInfo", JSON.stringify(err))
      return []
    }
  }
  async searchLimit() {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      let sql = `SELECT * FROM ${this.TABLE_NAME}`;
      // 动态添加 WHERE 子句
      let whereClause: string[] = [];

      // 如果有 where 子句，添加 WHERE 关键字
      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }
      sql += `
  ORDER BY
     durChapterTime DESC
     LIMIT 1
`;
      const bookHistoryDbList = await DbUtil.querySqlForList<BookHistory>(sql, column);
      return bookHistoryDbList
    } catch (err) {
      console.log("TagInfo", JSON.stringify(err))
      return []
    }
  }

  async insert(bookHistory: BookHistory) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('id', bookHistory.id)
      const count = await DbUtil.queryForCount(predicates, column)
      if (count > 0) {
        this.update(bookHistory)
        return true
      }
      bookHistory.createTime = Date.now()
      await DbUtil.insert(this.TABLE_NAME, bookHistory, column)
      console.log('TagInfo', '创建成功')
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  async update(bookHistory: BookHistory) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('id', bookHistory.id)
      const count = await DbUtil.queryForCount(predicates, column)
      if (count === 0 && bookHistory instanceof BookHistory) {
        this.insert(bookHistory)
        return true
      }
      bookHistory.updateTime = Date.now()
      bookHistory.durChapterTime = Date.now()
      await DbUtil.update(predicates, bookHistory, column)
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  //删除阅读历史记录
  async deleteBookHistory(id: number) {
    try {
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('id', id)
      await DbUtil.delete(predicates)
      return true
    }  catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  /**
   * 改名迁移（按书名）：`UPDATE book_history SET bookName = 新 WHERE bookName = 旧`。
   * 返回 SQL 字符串是**刻意的** —— 调用方（`BookRename`）要把派生表迁移放进
   * `DbUtil.runInTransaction(sqls: string[])`，事务只接受字符串数组。
   */
  renameBookSqls(oldName: string, newName: string): string[] {
    const o: string = sqlEscape(oldName)
    const n: string = sqlEscape(newName)
    return [`UPDATE ${this.TABLE_NAME} SET bookName = '${n}' WHERE bookName = '${o}'`]
  }

  /** 删书清理：清掉该书名的全部浏览历史（谓词版，不拼 SQL、无需转义） */
  async deleteByBookName(bookName: string): Promise<void> {
    const n: string = (bookName ?? '').trim()
    if (n === '') {
      return
    }
    const predicates = DbUtil.getPredicates(this.TABLE_NAME)
    predicates.equalTo('bookName', n)
    await DbUtil.delete(predicates)
  }

  async deleteAllBookHistory() {
    try {
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      await DbUtil.delete(predicates)
      return true
    }  catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

}


const bookHistoryDao = new BookHistoryDao()
export default bookHistoryDao as BookHistoryDao