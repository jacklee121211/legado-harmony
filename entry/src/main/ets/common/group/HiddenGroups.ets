/**
 * 2026-11-02 新增：**全局隐藏分组集合**（下沉到查询层用）。
 *
 * ── 为什么需要它 ─────────────────────────────────────────────────────────
 * 原先隐藏分组过滤靠 `BooksDao` 的**实例字段** `hiddenGroupIds`，只有
 * `BookContent` 的列表/计数会去设置它；搜索页等其它调用方忘了设置就**漏过滤**
 * （隐藏组里的书仍能被搜到）。这里改成"模块级单一真相"：
 *   · 任何分组可见性/结构变化的入口调用 `bookGroupUtils.refreshHiddenGroupIds()`；
 *   · `BooksDao` 的 `buildWhereClause` / `getBookCount` **无条件**读它；
 * ⇒ 调用方不需要记得设置，漏过滤在结构上不可能再发生。
 *
 * ⚠️ RDB 读出的 `show` 是 number(0/1)，判定一律用 `!g.show`（真机实证）。
 */
export class HiddenGroups {
  /** 需要从所有书籍查询/计数中排除的分组 id（含被隐藏分组的整棵子树） */
  static ids: number[] = []

  static set(ids: number[]): void {
    HiddenGroups.ids = ids
  }

  static clear(): void {
    HiddenGroups.ids = []
  }
}
