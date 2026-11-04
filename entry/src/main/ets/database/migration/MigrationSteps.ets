/**
 * **schema 迁移步骤表**（P4a，2026-11-04）。
 *
 * 规则（照抄 `SchemaVersion.ets` 里 `DbMigrationStep` 的约定）：
 *   · 数组**声明顺序 = 执行顺序**，`toVersion` 必须从 1 起、单调递增、不跳号；
 *   · 每一步必须**幂等**（`IF NOT EXISTS` / 先 PRAGMA 查再改 / 先去重再建索引）；
 *   · 每一步默认**不得**改表语义（不加列不删列不改列类型才是常态；
 *     真正要加列时才在这里加步骤，并同步改 `AppDatabase/index.ets` 快照 + `CURRENT_SCHEMA_VERSION`）。
 *     唯一的例外是 v2：删**已经在代码里彻底废弃、且行数为 0** 的遗留表（判据与理由见 v2 段注释）。
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

// ─────────────────────────────────────────────────────────────────────────────
// v2（2026-11-04）：清理「代码已彻底废弃 + 行数为 0」的遗留表
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 一张待清理的遗留表。
 *
 * `why` 只用于日志（说明"为什么这张表可以删"），不参与任何判断。
 */
interface LeftoverTable {
  tableName: string
  why: string
}

/**
 * 遗留表清单 —— **要清理的遗留表只往这里加一行**（v2 的单一真源）。
 *
 * ── 判据（三条同时成立才允许进这张表）────────────────────────────────────────
 * ① **建表语句已从 `AppDatabase/index.ets` 快照里删除** ⇒ 新库不会再建它，
 *    老库里的那份是历史残留（本工程快照现在只剩 books / book_groups / bookmarks / readDaily，
 *    已核对：`AppDatabase/index.ets` 里 `"tableName"` 仅这 4 处）；
 * ② **代码里零 SQL 引用**（`FROM/UPDATE/INTO <表名>` 全工程 0 命中，已 grep 核对）
 *    ⇒ 删掉不会有任何查询/写入走到它；
 * ③ **运行时行数必须为 0**（下面 `dropTableIfEmpty()` 现场数，>0 一律跳过）。
 *
 * ── 为什么"行数 0 才删"是硬门槛 ───────────────────────────────────────────────
 * 删表不可逆（SQLite 官方文档 `lang_droptable.html` 原文：
 *   "The dropped table is completely removed from the database schema and the disk file.
 *    The table can not be recovered."）。
 * 启动期迁移**不允许**替用户判断"这些行反正是没用数据" —— 只有 0 行才是零风险，
 * >0 行一律跳过并留日志，把决定权交给人（真机取证后再手工处理）。
 *
 * ── 幂等依据 ─────────────────────────────────────────────────────────────────
 * 三步都幂等到"表不存在也无害"：存在性查 `sqlite_master`（不存在 ⇒ 直接返回）、
 * 空表才执行 `DROP TABLE IF EXISTS`（SQLite 原文：
 *   "The optional IF EXISTS clause suppresses the error that would normally result
 *    if the table does not exist."
 *  ⇒ 即便存在性查询与 DROP 之间表被别人删了，也不会报错）。
 */
const LEFTOVER_TABLES: LeftoverTable[] = [
  {
    tableName: 'book_history',
    // 快照里已无此表；`BooksDao` 里针对它的 UPDATE 已于 2026-11-03（P7/L1）删除。
    why: '旧阅读历史表，建表语句与全部读写已从代码移除'
  },
  {
    tableName: 'readRecord',
    // 快照里已无此表；时长改由 `readDaily` 承担（`ReadDailyDao` 顶部注释）。
    why: '旧阅读时长表（零写入），时长已由 readDaily 承担'
  }
]

/** `SELECT name FROM sqlite_master …` 的单列结果行（与 v1 的 `IndexNameRow` 同结构，语义不同故独立声明） */
interface TableNameRow {
  name: string
}

/** `SELECT COUNT(*) AS n` 的单列结果行 */
interface CountRow {
  n: number
}

/** 只查一列 `name` 的列定义（表存在性） */
const TABLE_NAME_COLUMNS: ColumnInfo[] = [
  { name: 'name', columnName: 'name', type: ColumnType.STRING }
]

/** 只查一列 `n`（`COUNT(*)` 的别名）的列定义 */
const COUNT_COLUMNS: ColumnInfo[] = [
  { name: 'n', columnName: 'n', type: ColumnType.LONG }
]

/**
 * **v2 的唯一执行体**：存在性 → 行数 → `行数===0` 才 `DROP TABLE IF EXISTS`。
 *
 * 日志一律 `[DB-MIGRATE] v2 <表名>：…`，四类结论（不存在 / 存在+行数 / 跳过 / 已删）都留痕，
 * 真机排障时 `hdc hilog | findstr DB-MIGRATE` 就能判定"到底删没删、为什么"。
 *
 * 失败语义（故意**不**吞异常）：查询/删除失败一律往上抛 ⇒
 * `DbSchemaMigrator` 中止迁移、**不回写版本**、下次启动重试（步骤本身幂等，重跑零代价）。
 * 这与 v1「建索引失败只记日志」不同，因为两者的失败代价不对称：
 * 索引缺了应用层仍可保证唯一性，表删错了数据就没了 —— 所以这里宁可让版本卡住也不能假装成功。
 */
async function dropTableIfEmpty(tableName: string, why: string): Promise<void> {
  // ① 存在性（只读 sqlite_master，不碰任何数据）
  const existsRows: TableNameRow[] = await DbUtil.querySqlForList<TableNameRow>(
    `SELECT name FROM sqlite_master WHERE type = 'table' AND name = '${tableName}'`,
    TABLE_NAME_COLUMNS)
  if (existsRows.length === 0) {
    console.info(`[${MIGRATION_TAG}] v2 ${tableName}：表不存在 ⇒ 跳过 DROP（幂等；原因：${why}）`)
    return
  }

  // ② 行数（空表判定）
  const countRows: CountRow[] = await DbUtil.querySqlForList<CountRow>(
    `SELECT COUNT(*) AS n FROM ${tableName}`, COUNT_COLUMNS)
  const rowCount: number = countRows.length > 0 ? (countRows[0].n ?? 0) : 0
  console.info(`[${MIGRATION_TAG}] v2 ${tableName}：表存在，行数=${rowCount}（原因：${why}）`)

  // ③ 只有 0 行才删；>0 行**绝不删**用户数据
  if (rowCount > 0) {
    console.warn(`[${MIGRATION_TAG}] v2 ${tableName}：表存在，行数=${rowCount} > 0 ⇒ **跳过 DROP**，` +
      `保留全部数据、不改任何一行（原因：${why}；如需清理请人工确认真机数据后处理）`)
    return
  }

  await DbUtil.executeSql(`DROP TABLE IF EXISTS ${tableName}`)
  console.info(`[${MIGRATION_TAG}] v2 ${tableName}：表存在，行数=0 ⇒ 已执行 DROP TABLE IF EXISTS`)
}

/**
 * v2 步骤：逐表清理（2026-11-04）。
 *
 * 为什么是"逐表 try/catch + 末尾汇总抛错"而不是"一张失败就整体退出"：
 * 两张表互不相关，第一张失败没理由让第二张不试；但只要有任意一张失败，
 * 本步骤就**必须**抛错 ⇒ 版本不推进 ⇒ 下次启动重试（否则这张表永远没人再管）。
 */
async function dropLeftoverEmptyTables(): Promise<void> {
  const failures: string[] = []
  for (let i = 0; i < LEFTOVER_TABLES.length; i++) {
    const item: LeftoverTable = LEFTOVER_TABLES[i]
    try {
      await dropTableIfEmpty(item.tableName, item.why)
    } catch (e) {
      const detail: string = JSON.stringify(e)
      failures.push(`${item.tableName}(${detail})`)
      console.error(`[${MIGRATION_TAG}] v2 ${item.tableName}：处理失败 ⇒ 未删任何数据，` +
        `本次中止迁移、下次启动重试：${detail}`)
    }
  }
  if (failures.length > 0) {
    throw new Error(`v2 有 ${failures.length} 张遗留表处理失败：${failures.join('; ')}`)
  }
}

/**
 * 迁移步骤表 —— **加新版本只往这里追加**。
 *
 * | toVersion | 名称 | 做什么 | 幂等依据 |
 * |---|---|---|---|
 * | 1 | 基线：book_groups 同级同名唯一索引 | 委托 `ensureSiblingUniqueIndex()` 建索引 + 回读校验 | UPDATE 归一/去重可重入；`CREATE UNIQUE INDEX IF NOT EXISTS` |
 * | 2 | 清理遗留空表：book_history / readRecord | 存在性 → `COUNT(*)` → **仅 0 行** 才 `DROP TABLE IF EXISTS`；>0 行跳过并 warn | 表不存在 ⇒ 直接返回；`DROP TABLE IF EXISTS` 对已消失的表不报错 |
 * | 3 | books(bookName, author) 唯一索引 | `CREATE UNIQUE INDEX IF NOT EXISTS`；失败只记日志、不阻断启动 | `IF NOT EXISTS`；导入侧先改名（批 R-2）保证无重复 |
 */
// 2026-11-04（决策 3 / 批 R-3）：给 books(bookName, author) 建唯一索引，作为"同名同作者"的最后一道兜底。
//   为什么现在才加：导入侧（FileHandler.CopyFile / WifiBookServer）已先做改名与撞名拦截（批 R-2），
//   数据面已证不重复（设备实测 64 本 0 重复；用户手工导入同名两次得到 "江山美色.txt (2)" / "(3)"）。
//   为什么失败不阻断：老库里若真有历史重复，CREATE UNIQUE INDEX 会抛错；
//   此时**只记日志、继续启动**，导入侧仍由 BookNaming 改名兜底 —— 宁可少一道兜底，也不能卡死用户。
export async function bookNameAuthorUniqueIndex(): Promise<void> {
  const INDEX_NAME: string = 'index_books_bookName_author'
  try {
    await DbUtil.executeSql('CREATE UNIQUE INDEX IF NOT EXISTS ' + INDEX_NAME + ' ON books(bookName, author)')
    console.info('[' + MIGRATION_TAG + '] v3 唯一索引就绪 index=' + INDEX_NAME)
  } catch (e) {
    console.error('[' + MIGRATION_TAG + '] v3 建索引失败（不阻断启动；导入侧仍有 BookNaming 改名兜底）', JSON.stringify(e))
  }
}
export const MIGRATION_STEPS: DbMigrationStep[] = [
  {
    toVersion: 1,
    name: '基线：book_groups 同级同名唯一索引',
    run: baselineGroupSiblingIndex
  },
  {
    toVersion: 2,
    name: '清理遗留空表：book_history / readRecord',
    run: dropLeftoverEmptyTables
  },
  {
    toVersion: 3,
    name: 'books(bookName, author) 唯一索引（同名兜底）',
    run: bookNameAuthorUniqueIndex
  }
]
