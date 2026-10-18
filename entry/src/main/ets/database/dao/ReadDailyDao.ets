/**
 * 阅读时长 **日粒度** 表的 DAO（2026-10-13 新建）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么不用工程里已有的 `readRecord` 表（这是本模块最关键的一条结论）
 * ══════════════════════════════════════════════════════════════════════════
 * `readRecord` 的建表 SQL 原文（`database/AppDatabase/index.ets:1756`）：
 *   `CREATE TABLE IF NOT EXISTS readRecord (deviceId TEXT NOT NULL, bookName TEXT NOT NULL,
 *    readTime INTEGER NOT NULL DEFAULT 0, lastRead INTEGER NOT NULL DEFAULT 0,
 *    PRIMARY KEY(deviceId, bookName))`
 * ⇒ 它只有「每本书一个累计秒数 + 最后一次阅读时间」两个量，**没有任何按天/按小时的维度**。
 *   而本模块要的是「某月 Top 榜 / 某月逐日曲线 / 某天每小时分布」——
 *   这些都无法从"一个累计值"还原出来，**必须按天（再按小时）落行**。
 *   另外 `readRecord` 全工程零写入（`ReadRecordDao.ets:36-39` 自述 +
 *   `BookDetailPage.ets:404-406` 记录），不能指望它。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 表结构（唯一真源在 `database/AppDatabase/index.ets` 的 `readDaily` 实体块）
 * ══════════════════════════════════════════════════════════════════════════
 *   dayKey     'YYYY-MM-DD'（**本地时区**，由 `ReadTimeRecorder` 生成）
 *   hourKey    0~23
 *   bookId     `books.id`
 *   seconds    该 (天, 小时, 书) 桶内的净阅读秒数
 *   sessionNum 该桶内的**会话次数**（一次"进书→离开/切后台"算一次）
 *   maxSession 该桶内**单次最长**会话秒数
 *   lastAt     最后一次写入时间戳（排障用）
 *   主键 (dayKey, hourKey, bookId)
 *
 * ── 刻意**不存 bookName**（很关键）─────────────────────────────────────────
 * 书名会改（`BookRename`）。若把书名冗余进本表，改名就要级联改这张表，
 * 又是一条"漏一处就不一致"的链（`bookmarks` / `readRecord` 都吃过这个亏）。
 * 本表只认 `bookId`，显示书名/封面时**现查 `books`** ⇒
 *   ① 改名自动生效；② 换封面自动生效（配合 `BOOK_IS_BOOK_REFRESHING` 重查）；
 *   ③ 删书后本表的孤儿行不会被显示（查询时按 `books` 过滤/映射）——
 *      再由 `purgeBook()` 在删书路径里兜底清掉。
 *
 * ── 四档怎么算（同一个表，只换 WHERE）───────────────────────────────────────
 *   日 `dayKey = 'YYYY-MM-DD'` · 月 `LIKE 'YYYY-MM-%'` · 年 `LIKE 'YYYY-%'`
 *   自定义 `dayKey BETWEEN a AND b` · 总 `1=1`
 *   （dayKey 是定长 'YYYY-MM-DD' ⇒ LIKE 前缀匹配天然正确，不需要额外列）
 */
import DbUtil from '../../common/utils/DbUtil'
import AppDatabaseUtil from '../AppDatabaseUtil'
import { ColumnInfo, ColumnType } from '../types/ColumnInfo'

const TABLE: string = 'readDaily'

/** 周期描述（UI 只传它，SQL 全在这里生成） */
export interface ReadPeriod {
  /** 'day' | 'month' | 'year' | 'all' | 'range' */
  mode: string
  /** day:'YYYY-MM-DD' · month:'YYYY-MM' · year:'YYYY' · range:起始'YYYY-MM-DD' */
  from: string
  /** 仅 range 用：结束 'YYYY-MM-DD'（含当天） */
  to: string
}

/** 聚合桶行：bucket = 桶标签（'YYYY-MM-DD' / 'YYYY-MM' / '0'~'23' / 书 id 字符串） */
export interface ReadBucketRow {
  bucket: string
  seconds: number
}

/** 一个周期的汇总（**一次 SQL 全拿到**，避免多次往返） */
export interface ReadTotalRow {
  /** 总秒数 */
  seconds: number
  /** 有记录的天数（COUNT DISTINCT dayKey） */
  days: number
  /** 读过的书数（COUNT DISTINCT bookId） */
  books: number
  /** 该周期内单次最长会话秒数 */
  longest: number
  /** 会话次数（SUM sessionNum）——「N 次」文案用 */
  sessions: number
}

/** 内部：读改写用的当前值 */
interface ReadAccRow {
  seconds: number
}

/** 内部：最近 N 天（算连续天数） */
interface ReadDayRow {
  dayKey: string
}

const COL_BUCKET: ColumnInfo[] = [
  { name: 'bucket', columnName: 'bucket', type: ColumnType.STRING },
  { name: 'seconds', columnName: 'seconds', type: ColumnType.LONG }
]

const COL_TOTAL: ColumnInfo[] = [
  { name: 'seconds', columnName: 'seconds', type: ColumnType.LONG },
  { name: 'days', columnName: 'days', type: ColumnType.LONG },
  { name: 'books', columnName: 'books', type: ColumnType.LONG },
  { name: 'longest', columnName: 'longest', type: ColumnType.LONG },
  { name: 'sessions', columnName: 'sessions', type: ColumnType.LONG }
]

const COL_ACC: ColumnInfo[] = [
  { name: 'seconds', columnName: 'seconds', type: ColumnType.LONG }
]

const COL_DAY: ColumnInfo[] = [
  { name: 'dayKey', columnName: 'dayKey', type: ColumnType.STRING }
]

/**
 * 把外部字符串收进"只可能是数字和连字符"的字符集。
 * 双保险：dayKey 只由本模块的 `ReadTimeRecorder` 生成（本就是 'YYYY-MM-DD'），
 * 但拼串进 SQL 前一律过一遍，杜绝任何注入/脏数据把 SQL 拼坏。
 */
function safeKey(s: string): string {
  return (s ?? '').replace(/[^0-9-]/g, '')
}

/** 整数化 + 下界保护（秒数只接受正整数） */
function safeSec(n: number): number {
  if (typeof n !== 'number' || !Number.isFinite(n)) {
    return 0
  }
  return Math.max(0, Math.floor(n))
}

/**
 * 时间戳 → 'YYYY-MM-DD'（**本地时区**）。
 *
 * ⚠️ 刻意**不用** `toISOString()`：那是 UTC，会在东八区把晚 8 点之后的阅读
 *    算到"第二天"，日榜 / 连续天数 / 月榜归属全错。这里手工拼本地年月日。
 *
 * 为什么是模块级函数而不是类的静态方法：本工程的 DAO 一律
 * `export default xxxDao as XxxDao`（默认导出的是**实例**），静态方法无法通过
 * 该默认导出访问；导出成函数才能被 `ReadTimeRecorder` 直接 import。
 */
export function dayKeyOf(ts: number): string {
  const d: Date = new Date(ts)
  return pad4(d.getFullYear()) + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate())
}

export function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString()
}

export function pad4(n: number): string {
  const s: string = n.toString()
  if (s.length >= 4) {
    return s
  }
  return '0' + s
}

class ReadDailyDao {
  TABLE_NAME: string = TABLE

  /** 建表（幂等）。必须由 `database/index.ets` 的 `initAllTable()` 调用 */
  async initTable(): Promise<void> {
    try {
      const createSql = AppDatabaseUtil.getCreateSql(this.TABLE_NAME)
      if (!createSql) {
        // 快照里没有本表 ⇒ 说明实体块没加进 AppDatabase/index.ets（见该文件 readDaily 块）
        console.error('ReadDailyDao.initTable: 快照缺少 readDaily 建表语句')
        return
      }
      await DbUtil.createTable(createSql)
    } catch (e) {
      console.error('ReadDailyDao.initTable, Error, ' + JSON.stringify(e))
    }
  }

  /** 表是否可用（rdbStore 未就绪 / 表不存在时，本 DAO 全部方法都走空结果，不抛到 UI） */
  private ready(): boolean {
    return DbUtil.rdbStore !== undefined
  }

  /** 周期 → WHERE 子句 */
  private where(p: ReadPeriod): string {
    if (p === undefined || p === null) {
      return '1 = 1'
    }
    const mode: string = p.mode ?? 'all'
    if (mode === 'day') {
      return `dayKey = '${safeKey(p.from)}'`
    }
    if (mode === 'month' || mode === 'year') {
      return `dayKey LIKE '${safeKey(p.from)}-%'`
    }
    if (mode === 'range') {
      return `dayKey >= '${safeKey(p.from)}' AND dayKey <= '${safeKey(p.to)}'`
    }
    return '1 = 1'
  }

  /**
   * 累加秒数（**心跳与结算都走这里**）。
   * 行不存在就建行（sessionNum / maxSession 先置 0，由 `finishSession()` 补）。
   */
  async addSeconds(dayKey: string, hourKey: number, bookId: number, sec: number): Promise<void> {
    const s: number = safeSec(sec)
    const b: number = Math.floor(bookId)
    if (s <= 0 || b <= 0 || !this.ready()) {
      return
    }
    const d: string = safeKey(dayKey)
    const h: number = Math.max(0, Math.min(23, Math.floor(hourKey)))
    const now: number = Date.now()
    try {
      const rows = await DbUtil.querySqlForList<ReadAccRow>(
        `SELECT IFNULL(seconds, 0) AS seconds FROM ${TABLE} ` +
        `WHERE dayKey = '${d}' AND hourKey = ${h} AND bookId = ${b}`, COL_ACC)
      if (rows.length === 0) {
        await DbUtil.executeSql(
          `INSERT INTO ${TABLE} (dayKey, hourKey, bookId, seconds, sessionNum, maxSession, lastAt) ` +
          `VALUES ('${d}', ${h}, ${b}, ${s}, 0, 0, ${now})`)
      } else {
        await DbUtil.executeSql(
          `UPDATE ${TABLE} SET seconds = IFNULL(seconds, 0) + ${s}, lastAt = ${now} ` +
          `WHERE dayKey = '${d}' AND hourKey = ${h} AND bookId = ${b}`)
      }
    } catch (e) {
      // 写时长失败绝不影响阅读（与 ReadRecordDao 同口径）
      console.error('ReadDailyDao.addSeconds, Error, ' + JSON.stringify(e))
    }
  }

  /**
   * 一次会话结束：次数 +1、单次最长取 MAX。
   *
   * ⚠️ 跨小时/跨天的会话，`dayKey/hourKey` 记在**会话起点**所在桶 ——
   *    「单次最长」是个标量，只能挂在一个桶上；挂在起点最符合"这一觉从何时开始"的直觉。
   */
  async finishSession(dayKey: string, hourKey: number, bookId: number, sessionSec: number): Promise<void> {
    const s: number = safeSec(sessionSec)
    const b: number = Math.floor(bookId)
    if (s <= 0 || b <= 0 || !this.ready()) {
      return
    }
    const d: string = safeKey(dayKey)
    const h: number = Math.max(0, Math.min(23, Math.floor(hourKey)))
    try {
      await DbUtil.executeSql(
        `UPDATE ${TABLE} SET sessionNum = IFNULL(sessionNum, 0) + 1, ` +
        `maxSession = MAX(IFNULL(maxSession, 0), ${s}), lastAt = ${Date.now()} ` +
        `WHERE dayKey = '${d}' AND hourKey = ${h} AND bookId = ${b}`)
    } catch (e) {
      console.error('ReadDailyDao.finishSession, Error, ' + JSON.stringify(e))
    }
  }

  /** 周期汇总（秒数 / 天数 / 书数 / 单次最长 / 次数）—— 一次 SQL */
  async totals(p: ReadPeriod): Promise<ReadTotalRow> {
    const empty: ReadTotalRow = { seconds: 0, days: 0, books: 0, longest: 0, sessions: 0 }
    if (!this.ready()) {
      return empty
    }
    try {
      const rows = await DbUtil.querySqlForList<ReadTotalRow>(
        `SELECT IFNULL(SUM(seconds), 0) AS seconds, ` +
        `COUNT(DISTINCT dayKey) AS days, ` +
        `COUNT(DISTINCT bookId) AS books, ` +
        `IFNULL(MAX(maxSession), 0) AS longest, ` +
        `IFNULL(SUM(sessionNum), 0) AS sessions ` +
        `FROM ${TABLE} WHERE ${this.where(p)}`, COL_TOTAL)
      if (rows.length === 0) {
        return empty
      }
      const r: ReadTotalRow = rows[0]
      return {
        seconds: r.seconds ?? 0,
        days: r.days ?? 0,
        books: r.books ?? 0,
        longest: r.longest ?? 0,
        sessions: r.sessions ?? 0
      }
    } catch (e) {
      console.error('ReadDailyDao.totals, Error, ' + JSON.stringify(e))
      return empty
    }
  }

  /**
   * 逐日桶（月/年/区间档的柱状图）：bucket = 'YYYY-MM-DD'。
   * 分组与排序都直接用 `dayKey`（定长 ⇒ 字典序 == 时间序）。
   */
  async bucketsDaily(p: ReadPeriod): Promise<ReadBucketRow[]> {
    return this.buckets('dayKey', 'dayKey ASC', p)
  }

  /** 逐月桶（年/总档的柱状图）：bucket = 'YYYY-MM'（同样定长 ⇒ 字典序即时间序） */
  async bucketsMonthly(p: ReadPeriod): Promise<ReadBucketRow[]> {
    const expr: string = `substr(dayKey, 1, 7)`
    return this.buckets(expr, `${expr} ASC`, p)
  }

  /**
   * 逐小时桶（日档的 24 小时柱）：bucket = '0'~'23'。
   * ⚠️ 排序必须按 **hourKey 数值**：按 bucket 文本排会得到 0,1,10,11,2…（10 点排到 2 点前面）。
   */
  async bucketsHourly(p: ReadPeriod): Promise<ReadBucketRow[]> {
    return this.buckets('hourKey', 'hourKey ASC', p)
  }

  /** 按书聚合（Top 榜）：bucket = bookId 字符串，按时长降序 */
  async topBooks(p: ReadPeriod, limit: number): Promise<ReadBucketRow[]> {
    const lim: number = Math.max(1, Math.min(50, Math.floor(limit)))
    return this.buckets('bookId', `seconds DESC LIMIT ${lim}`, p)
  }

  /**
   * 通用分组查询（**唯一的 SQL 拼装点**）。
   *
   * @param groupExpr 分组表达式（同时被 CAST 成文本作为 bucket 返回）
   * @param orderClause 完整的排序子句（**不含** `ORDER BY` 关键字以外的东西，也不含 GROUP BY）
   * @param p 周期
   */
  private async buckets(groupExpr: string, orderClause: string, p: ReadPeriod): Promise<ReadBucketRow[]> {
    if (!this.ready()) {
      return []
    }
    try {
      // ⚠️ 这里**只能有一个 ORDER BY**：分组表达式与排序表达式分开传参，
      //    早前版本把 "ORDER BY seconds DESC" 当附加串拼进来，会拼出两个 ORDER BY（SQL 语法错）。
      const sql: string =
        `SELECT CAST(${groupExpr} AS TEXT) AS bucket, IFNULL(SUM(seconds), 0) AS seconds ` +
        `FROM ${TABLE} WHERE ${this.where(p)} ` +
        `GROUP BY ${groupExpr} ORDER BY ${orderClause}`
      const rows = await DbUtil.querySqlForList<ReadBucketRow>(sql, COL_BUCKET)
      return rows
    } catch (e) {
      console.error('ReadDailyDao.buckets, Error, ' + JSON.stringify(e))
      return []
    }
  }

  /**
   * 连续阅读天数（从今天往回数）。
   * 今天还没读不算断 —— 只要昨天开始连着有记录就算"连续"，
   * 否则用户每天早上打开 App 都会看到连续天数被清零。
   */
  async streakDays(): Promise<number> {
    if (!this.ready()) {
      return 0
    }
    try {
      const rows = await DbUtil.querySqlForList<ReadDayRow>(
        `SELECT DISTINCT dayKey FROM ${TABLE} ORDER BY dayKey DESC LIMIT 400`, COL_DAY)
      if (rows.length === 0) {
        return 0
      }
      const set: Set<string> = new Set<string>()
      for (let i = 0; i < rows.length; i++) {
        set.add(rows[i].dayKey)
      }
      // 从今天或昨天起，逐天往回数
      let cursor: number = Date.now()
      if (!set.has(dayKeyOf(cursor))) {
        cursor = cursor - 86400000
      }
      let n: number = 0
      while (set.has(dayKeyOf(cursor))) {
        n++
        cursor = cursor - 86400000
        if (n > 4000) {
          break // 防御：绝不死循环
        }
      }
      return n
    } catch (e) {
      console.error('ReadDailyDao.streakDays, Error, ' + JSON.stringify(e))
      return 0
    }
  }

  /** 删书清理：清掉这本书的全部时长行 */
  async purgeBook(bookId: number): Promise<void> {
    const b: number = Math.floor(bookId)
    if (b <= 0 || !this.ready()) {
      return
    }
    try {
      await DbUtil.executeSql(`DELETE FROM ${TABLE} WHERE bookId = ${b}`)
    } catch (e) {
      console.error('ReadDailyDao.purgeBook, Error, ' + JSON.stringify(e))
    }
  }

  /** 是否有任何数据（一级卡的空态判定用） */
  async hasAnyData(): Promise<boolean> {
    if (!this.ready()) {
      return false
    }
    try {
      const rows = await DbUtil.querySqlForList<ReadAccRow>(
        `SELECT IFNULL(SUM(seconds), 0) AS seconds FROM ${TABLE}`, COL_ACC)
      return rows.length > 0 && (rows[0].seconds ?? 0) > 0
    } catch (e) {
      return false
    }
  }

  /**
   * 时间戳 → 'YYYY-MM-DD'（**本地时区**）。
   * （实现已上移到模块级 `dayKeyOf()`，见文件中部 —— 默认导出是实例，静态方法拿不到。）
   */
}

const readDailyDao = new ReadDailyDao()
export default readDailyDao as ReadDailyDao
