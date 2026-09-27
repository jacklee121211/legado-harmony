import { FieldsType } from './types/AppDatabaseType'
import { ColumnInfo, ColumnValue, ColumnType } from './types/ColumnInfo'
import AppDatabase from './AppDatabase'
import DbUtil from '../common/utils/DbUtil'

class AppDatabaseUtil {
  getCreateSql(tableName: string) {
    const entities = AppDatabase.database.entities
    const tableInfo = entities.find(item => item.tableName === tableName)
    return tableInfo?.createSql.replace('${TABLE_NAME}', tableName)
  }

  getFields(tableName: string): FieldsType[] | undefined {
    const entities = AppDatabase.database.entities
    const tableInfo = entities.find(item => item.tableName === tableName)
    return tableInfo?.fields
  }

  /**
   * 检测表中的字段是否缺失，缺失则 `ALTER TABLE ADD COLUMN`。
   *
   * ⚠️ 这是本项目**唯一的 schema 迁移实现**，且只支持「新增列」——
   *    改名 / 改类型 / 删列一律无处理（`AppDatabase.database.version` 声明了但无人读取）。
   *
   * 失败必须**可见**：旧实现用 `console.info('TagInfo Error:', …)` 把异常吞掉，
   * 结果是应用带着**残缺 schema** 继续跑，后续查询报错难以归因。
   * 现改为 `console.error` + 返回 `false` 供调用方判断。
   * 注意**不 rethrow** —— `DataBase.initAllTable()` 没有 try/catch，
   * 抛出会变成 unhandled rejection。
   *
   * @returns true = 迁移完成（含"无需迁移"）；false = 迁移失败，schema 可能不完整
   */
  async existsTable(tableName: string): Promise<boolean> {
    try {
      const rowNames = await DbUtil.queryRowNames(tableName);
      const fields = this.getFields(tableName)
      if (!fields?.length) {
        return true;
      }
      for (let index = 0; index < fields.length; index++) {
        const element = fields[index];
        if (!rowNames.includes(element.columnName)) {
          console.info(`TagInfo 数据表【${tableName}】缺失字段，开始新增字段：`, element.columnName)
          let executeSql =  `ALTER TABLE '${tableName}' ADD COLUMN '${element.columnName}' ${element.affinity}`
          if (element.defaultValue) {
            // DDL 无法参数绑定，只能拼串 ⇒ 单引号必须转义（SQLite 约定：'' 代表一个 '）
            executeSql += ` DEFAULT '${element.defaultValue.replace(/'/g, "''")}'`
          }
          await DbUtil.executeSql(executeSql)
          console.info('TagInfo', `数据表【${tableName}】新增字段【${element.columnName}】成功`)
        }
      }
      return true;
    } catch (e) {
      console.error(`TagInfo 数据表【${tableName}】字段迁移失败，schema 可能不完整：`, JSON.stringify(e))
      return false;
    }
  }

  getColumn(tableName: string) {
    const entities = AppDatabase.database.entities
    const tableInfo = entities.find(item => item.tableName === tableName)
    return this.fieldsToColumnInfo(tableInfo?.fields || [])
  }

  getAssignColumn(tableName: string, assignColumn: string[]) {
    const columns = this.getColumn(tableName)
    return columns.filter(item => assignColumn.includes(item.columnName))
  }

  fieldsToColumnInfo(fields: FieldsType[]): ColumnInfo[] {
    return fields.map(item => {
      const columnInfo: ColumnInfo = {
        name: item.fieldPath,
        // 数据库列名
        columnName: item.columnName,
        // 列类型
        type: item.boolean ? ColumnType.BOOLEAN : ColumnValue[item.affinity],
        defaultValue: item.defaultValue
      }
      return columnInfo
    })
  }
}

const appDatabaseUtil = new AppDatabaseUtil();
export default appDatabaseUtil as AppDatabaseUtil;