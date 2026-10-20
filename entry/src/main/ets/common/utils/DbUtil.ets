/**
 * Copyright (C), 2024-06-24
 * @author LinXun
 * @date 2024-06-24 11:47
 * @version 1.0
 * @description: 数据库工具类封装
 */
import { relationalStore, ValuesBucket, ValueType } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import CommonConstants from '../constants/CommonConstants';
import Logger from './Logger';
import { ColumnInfo, ColumnType } from '../../database/types/ColumnInfo';

class DbUtil {
  // 数据库实例
  rdbStore: relationalStore.RdbStore | undefined = undefined;
  /**
   * 初始化数据库
   * @param context 上下文
   * @returns
   */
  initDB(context: common.UIAbilityContext): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      relationalStore.getRdbStore(context, CommonConstants.STORE_CONFIG)
        .then(rdbStore => {
          this.rdbStore = rdbStore;
          Logger.debug(`[${CommonConstants.RDB_TAG}]`, 'rdbStore 初始化成功');
          resolve();
        })
        .catch((reason: string) => {
          Logger.error(`[${CommonConstants.RDB_TAG}]`, 'rdbStore 初始化失败', JSON.stringify(reason));
          reject(reason);
        })
    });
  }

  /**
   * 创建relationalStore.RdbPredicates对象
   * @param tableName
   * @returns relationalStore.RdbPredicates
   */
  getPredicates (tableName: string) {
    return new relationalStore.RdbPredicates(tableName)
  }
  /**
   * 删除数据库
   * @param context
   * @returns
   */
  deleteDB(context: common.UIAbilityContext): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.rdbStore === undefined) {
        resolve();
      }
      relationalStore.deleteRdbStore(context, CommonConstants.STORE_CONFIG, (error) => {
        if (error) {
          Logger.error(`[${CommonConstants.RDB_TAG}]`, 'rdbStore 删除失败', JSON.stringify(error));
          reject(error);
        }
        this.rdbStore = undefined;
        resolve();
      })
    });
  }
  /**
   * 创建表
   * @param createSQL 创建表语句
   * @returns
   */
  createTable(createSQL: string): Promise<void> {
    return this.executeSql(createSQL)
  }
  /**
   * 执行任意sql语句
   * @param executeSql 任意sql语句
   * @returns
   */
  executeSql(executeSql: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.rdbStore?.executeSql(executeSql)
        .then(() => {
          console.info('TagInfo', '执行成功')
          Logger.debug(`[${CommonConstants.RDB_TAG}]`,'执行成功');
          resolve();
        })
        .catch((reason: string) => {
          console.info('TagInfo Error:', reason)
          Logger.error(`[${CommonConstants.RDB_TAG}]`,'执行失败', JSON.stringify(reason));
          reject(reason);
        })
    });
  }
  /**
   * **事务**执行多条 SQL：全部成功才 `commit`，任一失败 `rollBack`（2026-10-05，书名级联改名用）。
   *
   * SDK 依据：`relationalStore.RdbStore.beginTransaction(): void`
   * （`@ohos.data.relationalStore.d.ts:5351`，@since 9），同接口 `commit()` / `rollBack()`。
   * 为什么需要它：改名要同时改 4 张表（books / bookmarks / readRecord / book_history），
   * 中途失败会留下"半改名"的脏数据（进度、书签按书名作键 ⇒ 直接失联）。
   * ⚠️ 事务里只用 `executeSql`；不要把 `query`/`insert` 等回调式 API 混进来打断事务边界。
   */
  runInTransaction(sqls: string[]): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const store: relationalStore.RdbStore | undefined = this.rdbStore
      if (store === undefined) {
        reject('rdbStore is undefined')
        return
      }
      try {
        store.beginTransaction()
      } catch (e) {
        reject(e)
        return
      }
      const runNext = (i: number): void => {
        if (i >= sqls.length) {
          try {
            store.commit()
            Logger.debug(`[${CommonConstants.RDB_TAG}]`, `事务提交成功，共 ${sqls.length} 条`)
            resolve()
          } catch (e) {
            reject(e)
          }
          return
        }
        store.executeSql(sqls[i])
          .then(() => {
            runNext(i + 1)
          })
          .catch((reason: string) => {
            Logger.error(`[${CommonConstants.RDB_TAG}]`, `事务第 ${i + 1} 条失败，回滚`, JSON.stringify(reason))
            try {
              store.rollBack()
            } catch (e) {
              // 回滚本身失败：只记录，仍抛原始错误
            }
            reject(reason)
          })
      }
      runNext(0)
    })
  }
  /**
   * 获取数据表的所有列名
   * @param tableName 表名
   * @returns string[]
   */
  queryRowNames(tableName: string): Promise<string[]> {
    return new Promise<string[]>((resolve, reject) => {
      this.rdbStore?.querySql(`PRAGMA  table_info(${tableName})`)
        .then((result) => {
          let rowNames: string[] = [];
          if (result.rowCount <= 0) {
            Logger.debug('无结果');
            resolve(rowNames);
          }
          while (!result.isAtLastRow) {
            result.goToNextRow();
            const row = result.getRow()
            rowNames.push(row.name as string)
          }
          Logger.debug(`[${CommonConstants.RDB_TAG}]`,'执行成功');
          resolve(rowNames);
        })
        .catch((reason: string) => {
          Logger.error(`[${CommonConstants.RDB_TAG}]`,'执行失败', JSON.stringify(reason));
          reject(reason);
        })
    });
  }
  /**
   * 插入数据
   * @param tableName 表名
   * @param obj
   * @param columns
   * @returns
   */
  insert(tableName: string, obj: object, columns: ColumnInfo[]): Promise<number> {
    return new Promise((resolve, reject) => {
      // 1.构建新增数据
      let value = this.buildValueBucket(obj, columns);
      // 2.新增
      this.rdbStore?.insert(tableName, value, (err, id) => {
        if (err) {
          Logger.error(`[${CommonConstants.RDB_TAG}]`,'新增失败！', JSON.stringify(err));
          reject(err);
        } else {
          Logger.debug(`[${CommonConstants.RDB_TAG}]`,'新增成功！新增id：', id.toString());
          resolve(id);
        }
      })
    });
  }
  /**
   * 删除数据
   * @param predicates 条件
   * @returns
   */
  delete(predicates: relationalStore.RdbPredicates): Promise<number> {
    return new Promise((resolve, reject) => {
      this.rdbStore?.delete(predicates, (err, rows) => {
        if (err) {
          Logger.error(`[${CommonConstants.RDB_TAG}]`,'删除失败!,', JSON.stringify(err));
          reject(err);
        } else {
          Logger.debug(`[${CommonConstants.RDB_TAG}]`,'删除成功！删除行数：', rows.toString());
          resolve(rows);
        }
      })
    });
  }
  /**
   * 查询数据
   * @param predicates 条件
   * @param columns
   * @returns
   */
  querySqlForList<T> (sql: string, columns: ColumnInfo[]): Promise<T[]> {
    return new Promise((resolve, reject) => {
      this.rdbStore?.querySql(sql, (err, result) => {
        if (err) {
          Logger.error(`[${CommonConstants.RDB_TAG}]`,'查询失败!',JSON.stringify(err));
          reject(err);
        } else {
          Logger.debug(`[${CommonConstants.RDB_TAG}]`,'查询成功！查询行数：', result.rowCount.toString());
          resolve(this.parseResultSet(result, columns));
          result.close();
        }
      })
    });
  }
  /**
   * 查询数据
   * @param predicates 条件
   * @param columns
   * @returns
   */
  queryForList<T> (predicates: relationalStore.RdbPredicates, columns: ColumnInfo[]): Promise<T[]> {
    return new Promise((resolve, reject) => {
      this.rdbStore?.query(predicates, columns.map(info => info.columnName), (err, result) => {
        if (err) {
          Logger.error(`[${CommonConstants.RDB_TAG}]`,'查询失败!',JSON.stringify(err));
          reject(err);
        } else {
          Logger.debug(`[${CommonConstants.RDB_TAG}]`,'查询成功！查询行数：', result.rowCount.toString());
          resolve(this.parseResultSet(result, columns));
          result.close();
        }
      })
    });
  }
  /**
   * 查询数据个数
   * @param predicates
   * @param columns
   * @returns
   */
  queryForCount (predicates: relationalStore.RdbPredicates, columns: ColumnInfo[]): Promise<number> {
    return new Promise((resolve, reject) => {
      this.rdbStore?.query(predicates, columns.map(info => info.columnName), (err, result) => {
        if (err) {
          Logger.error(`[${CommonConstants.RDB_TAG}]`,'查询失败!',JSON.stringify(err));
          reject(err);
        } else {
          Logger.debug(`[${CommonConstants.RDB_TAG}]`,'查询成功！查询行数：', result.rowCount.toString());
          resolve(result.rowCount);
        }
      })
    });
  }
  /**
   * 更新数据
   * @param predicates
   * @param obj
   * @param columns
   * @returns
   */
  update(predicates: relationalStore.RdbPredicates, obj: object, columns: ColumnInfo[]): Promise<number> {
    return new Promise((resolve, reject) => {
      // 1.构建更新数据
      let value = this.buildValueBucket(obj, columns);
      // 2.更新
      this.rdbStore?.update(value, predicates, (err, result) => {
        if (err) {
          Logger.error(`[${CommonConstants.RDB_TAG}]`, '更新失败！', JSON.stringify(err));
          reject(err);
        } else {
          Logger.debug(`[${CommonConstants.RDB_TAG}]`, '更新成功！更新行数：', result.toString());
          resolve(result);
        }
      })
    });
  }
  /**
   * 解析结果集
   * @param result
   * @param columns
   * @returns
   */
  parseResultSet<T> (result: relationalStore.ResultSet, columns: ColumnInfo[]): T[] {
    // 1.声明最终返回的结果
    let arr: T[] = [];
    // 2.判断是否有结果
    if (result.rowCount <= 0) {
      Logger.debug('无结果');
      return arr;
    }
    // 3.处理结果
    while (!result.isAtLastRow) {
      // 3.1 去下一行
      // ⚠️ 2026-10-20：`goToNextRow()` 同样可能抛（结果集被并发关闭等），
      //    同一类未捕获异常照样 = 进程被杀 ⇒ 这里也必须兜住。
      try {
        result.goToNextRow();
      } catch (e) {
        Logger.error(`[${CommonConstants.RDB_TAG}]`, 'goToNextRow 失败，终止本次解析',
          JSON.stringify(e));
        return arr;
      }
      // 3.2 解析这行数据，转为对象
      let obj: ValuesBucket | Record<string, undefined> = {};
      columns.forEach(info => {
        // ★★ 2026-10-20 闪退修复（真机实测）：**列不存在时必须跳过，不能直接取值** ★★
        //
        // ── 事故现象（`docs/日志.md:1030` / `:2081`）────────────────────────────
        //   安装新版本后一进书架就闪退，`Kill Reason:Js Error`：
        //     `GetColumnIndex:Failed, columnName : fil***, errCode : 0`
        //     `GetLong:throw error: code = 14800013, message = Resultset is empty or
        //      column index is out of bounds.`
        //     `at anonymous entry (DbUtil.ets:318:26)`
        //
        // ── 根因 ──────────────────────────────────────────────────────────────
        //   本方法的 `columns` 来自 `AppDatabaseUtil.getColumn()`，它返回的是
        //   **`AppDatabase/index.ets` 编译期快照里的全部列名**，与实际数据库表结构
        //   **完全脱钩**。一旦快照比真表多一列（新加的列还没 ALTER 成功、或 ALTER
        //   被时序打断），`getColumnIndex()` 就返回 **-1**，而 `getLong(-1)` 会抛
        //   `14800013` —— 这个异常**没有被任何 try/catch 接住**，直接冒泡到 NAPI 层
        //   ⇒ 进程被系统杀掉（`RecordAppWithReason ... Kill Reason:Js Error`）。
        //
        // ── 为什么要在这一层兜 ────────────────────────────────────────────────
        //   逐列 try/catch 或逐查询改调用点都治标：只要有一处查询漏改，仍然是闪退。
        //   这里是所有 SQL 查询的**唯一收口**（`querySqlForList` / `queryForList` 都走它），
        //   在此处"列不存在 ⇒ 置 undefined"能一次性消灭**整类**闪退。
        //   ⚠️ 语义：缺列等价于"该字段没有值"，与 `buildValueBucket` 跳过 undefined 的
        //     既有约定一致（`DbUtil.ets:299` 附近注释），读取方一律 `?? 0` 兜底。
        let idx: number = -1;
        try {
          idx = result.getColumnIndex(info.columnName);
        } catch (e) {
          idx = -1;
        }
        if (idx < 0) {
          // 列不在本次结果集里（表结构与快照不一致）⇒ 跳过该字段，不影响其他列
          Logger.warn(`[${CommonConstants.RDB_TAG}]`,
            `列不存在，已跳过: ${info.columnName}（表结构与快照不一致，检查 initBooksTable 的 ALTER）`);
          return;
        }
        let val: ValueType | Uint8Array | undefined = undefined;
        try {
          switch (info.type) {
            case ColumnType.LONG:
              val = result.getLong(idx);
              break;
            case ColumnType.DOUBLE:
              val = result.getDouble(idx);
              break;
            case ColumnType.STRING:
              val = result.getString(idx);
              break;
            case ColumnType.BLOB:
              val = result.getBlob(idx);
              break;
            case ColumnType.BOOLEAN:
              val = !!result.getLong(idx)
              break;
          }
        } catch (e) {
          // 单列取值失败（类型不符等）⇒ 置空即可，绝不让整条查询/整个进程失败
          Logger.error(`[${CommonConstants.RDB_TAG}]`,
            `取值失败，已置空: ${info.columnName}`, JSON.stringify(e));
          val = undefined;
        }
        obj[info.name] = val === '' ? undefined : val;
      })
      // 3.3 将对象填入结果数组
      arr.push(obj as T);
    }
    return arr;
  }
  /**
   * 构建值集
   * @param obj
   * @param columns
   * @returns
   */
  buildValueBucket(obj: object, columns: ColumnInfo[]): ValuesBucket {
    let value: ValuesBucket = {};
    columns.forEach(info => {
        if (typeof obj[info.name] !== 'undefined') {
        value[info.columnName] = obj[info.columnName];
      }
    });
    return value;
  }
}
// 导出
let dbUtil: DbUtil = new DbUtil();
export default dbUtil as DbUtil;