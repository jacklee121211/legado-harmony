/**
 * SQL 单引号转义 —— **全工程唯一实现**（2026-11-03 A1 收敛）。
 *
 * ── 为什么有它 ────────────────────────────────────────────────────────────────
 * 改造前这条转义规则有 **3 份各自实现**，语义靠人同步：
 *   · `database/dao/BookmarksDao.ets:39`  `function esc(s)`
 *   · `database/dao/ReadRecordDao.ets:46`  `function esc(s)`
 *   · `common/utils/BookRename.ets:89`     `BookRename.esc()`
 * ⇒ 统一到这里，三处改为引用（保留本地别名 `esc` 只为不扩大调用点改动面）。
 *
 * ── 什么时候才该用它 ──────────────────────────────────────────────────────────
 * **优先不用它**：能用谓词的写操作一律走 `DbUtil.update / delete`（`RdbPredicates`
 * 走参数传递，天然免疫引号问题）——`BooksDao.renameBook()` 就是这么做的。
 * 只有"必须拼 SQL 字符串"的场景才用本函数，例如
 * `DbUtil.runInTransaction(sqls: string[])`（事务只接受 SQL 字符串，见 `DbUtil.ets:102`）。
 *
 * ── 它做了什么 ────────────────────────────────────────────────────────────────
 * 只把单引号翻倍（SQL 标准转义）。**不做**反斜杠处理：SQLite 不认 `\'` 这种转义，
 * 用反斜杠反而会改变语义。
 */
export function sqlEscape(s: string): string {
  return (s ?? '').replace(/'/g, "''")
}
