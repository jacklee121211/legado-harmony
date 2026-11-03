/**
 * **schema 迁移步骤表**（P4a，2026-11-04）。
 *
 * 规则（照抄 `SchemaVersion.ets` 里 `DbMigrationStep` 的约定）：
 *   · 数组**声明顺序 = 执行顺序**，`toVersion` 必须从 1 起、单调递增、不跳号；
 *   · 每一步必须**幂等**（`IF NOT EXISTS` / 先 PRAGMA 查再改 / 先去重再建索引）；
 *   · 每一步**不得**改表语义（不加列不删列不改列类型是**本批任务**的约束，
 *     真正要加列时才在这里加步骤，并同步改 `AppDatabase/index.ets` 快照 + `CURRENT_SCHEMA_VERSION`）。
 *
 * ── v1（基线）为什么"几乎不做事"──────────────────────────────────────────────
 * 「建表 / 补列」的**唯一实现**已经在各 DAO 的 `initXxxTable()` 里，并且
 * `DataBase.doInitAllTable()` 每轮启动都无条件跑（`CREATE TABLE IF NOT EXISTS`、
 * `PRAGMA table_info` 后补列），本来就是幂等自愈的。
 * 把它们再抄一份进迁移步骤 = 同一语义两处实现（必然漂），所以这里**只做委托**。
 *
 * v1 真正新增的只有一件事：把「显式 DDL 补偿」的**唯一索引**纳入版本化流程，
 * 并在迁移日志里**回读校验**它到底建成了没有。
 */
import DbUtil from '../../common/utils/DbUtil'
import { ColumnInfo, ColumnType } from '../types/ColumnInfo'
import bookGroupsDao from '../dao/BookGroupsDao'
import { DbMigrationStep, MIGRATION_TAG } from './SchemaVersion'

/** `sqlite_master.name` 单列结果行（与 `BooksDao.ensureColumn` 的 ColumnNameRow 同写法） */
interface IndexNameRow {
  name: string
}

/** 唯一索引名（与 `BookGroupsDao.ensureSiblingUniqueIndex` 里的常量同值，两边必须一致） */
const GROUP_SIBLING_INDEX: string = 'index_book_groups_parentId_groupName'

/** 只查一列 name 的列定义 */
const INDEX_NAME_COLUMNS: ColumnInfo[] = [
  { name: 'name', columnName: 'name', type: ColumnType.STRING }
]

/**
 * v1 基线 · `book_groups` 同级同名唯一索引。
 *
 * 为什么需要它：`AppDatabase/index.ets` 快照里的 `indices` 数组**全工程没有任何代码执行**
 * （`doInitAllTable()` 只调各 DAO 的 `initXxxTable()`，它们只跑 `createSql` 建表）
 * ⇒ 索引只能靠显式 DDL 补，这段补偿逻辑的唯一实现在
 * `BookGroupsDao.ensureSiblingUniqueIndex()`（内含 parentId 归一 + 同父同名去重 + CREATE UNIQUE INDEX）。
 *
 * 这里**委托**而不是复制：复制必然漂（去重口径、parentId 归一只在 DAO 那边维护）。
 * 副作用是升级那一轮启动它会跑两遍（`initGroupTable` 一次 + 本步骤一次），
 * 因为它三步全幂等，跑两遍是零代价的。
 *
 * ⚠️ 不抛异常：该 DAO 方法的既定约定是「唯一性不是安全边界，建失败只记日志，
 *    绝不卡首屏」（见 `BookGroupsDao.ets:96-99`）。所以"v1 完成"不保证索引一定建成，
 *    真正的兜底是 `initGroupTable()` **每轮启动**都会再调一次。
 *    本步骤额外做一次 `sqlite_master` 回读，把结果打进 `[DB-MIGRATE]` 日志，
 *    让"索引到底在不在"在真机日志里可直接判定。
 */
async function baselineGroupSiblingIndex(): Promise<void> {
  await bookGroupsDao.ensureSiblingUniqueIndex()

  // 回读校验（只读，不改数据）：索引存在性必须可观测
  try {
    const rows: IndexNameRow[] = await DbUtil.querySqlForList<IndexNameRow>(
      `SELECT name FROM sqlite_master WHERE type = 'index' AND name = '${GROUP_SIBLING_INDEX}'`,
      INDEX_NAME_COLUMNS)
    const present: boolean = rows.length > 0
    if (present) {
      console.info(`[${MIGRATION_TAG}] v1 校验：唯一索引 ${GROUP_SIBLING_INDEX} 存在`)
    } else {
      console.error(`[${MIGRATION_TAG}] v1 校验：唯一索引 ${GROUP_SIBLING_INDEX} **缺失**` +
        `（已委托 ensureSiblingUniqueIndex 重建；下一轮 initGroupTable 还会再试一次）`)
    }
  } catch (e) {
    console.error(`[${MIGRATION_TAG}] v1 校验：回读 sqlite_master 失败`, JSON.stringify(e))
  }
}

/**
 * 迁移步骤表 —— **加新版本只往这里追加**。
 *
 * | toVersion | 名称 | 做什么 | 幂等依据 |
 * |---|---|---|---|
 * | 1 | 基线：book_groups 同级同名唯一索引 | 委托 `ensureSiblingUniqueIndex()` 建索引 + 回读校验 | UPDATE 归一/去重可重入；`CREATE UNIQUE INDEX IF NOT EXISTS` |
 */
export const MIGRATION_STEPS: DbMigrationStep[] = [
  {
    toVersion: 1,
    name: '基线：book_groups 同级同名唯一索引',
    run: baselineGroupSiblingIndex
  }
]
