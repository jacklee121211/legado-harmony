import { BookGroups } from '../../database/entities/BookGroups'
import { GroupTree } from './GroupTree'

/**
 * 2026-11-03（P6 / B1）：**筛选视图**的唯一建树出口。
 *
 * ── 为什么还需要它（GroupStore 已经是真源了）────────────────────────────────
 * `GroupStore` 持有的是**全量**分组树（`BookGroupsDao.search()` 全表）。但有两类视图
 * 天生需要"只含一部分分组"的树，它们的节点集合与真源不同：
 *   · 书架「分组」页：只显示 `show = true` 且属于当前 tab 类型的分组；
 *   · 「移动至分组 / 分组管理」弹窗：`isManageMode` 要连隐藏分组一起显示，普通模式只显示 `show`。
 * 这两类视图**不是**真源，也不该把过滤后的列表灌回 `GroupStore`（会把真源弄脏）。
 *
 * ── 收敛前的问题 ─────────────────────────────────────────────────────────────
 * 这种"按过滤后的列表建树"散在 3 个文件里（`BookSelectGroupDialog` 2 处、
 * `BookContentRefresh` 1 处），加上 `GroupStore` 自己 1 处、`bookGroupUtils` 2 处、
 * `BookManagePage` 1 处兜底 —— 全工程 8 处 `GroupTree.build(...)`。
 *
 * ── 现在 ────────────────────────────────────────────────────────────────────
 * 建树只剩两个落点：
 *   ① `GroupStore.apply()` —— **真源**（全量）；
 *   ② 本文件 —— **筛选视图**（按调用方给的列表）。
 * 其余地方一律 `GroupStore.reload()/tree()` 或 `FilteredTree.build(list)`。
 */
export class FilteredTree {
  /**
   * 按调用方给的（可能已过滤/已排序的）分组列表建一棵树。
   *
   * ⚠️ 只用于**只读渲染视图**；不要把它 `apply` 回 `GroupStore`（那会把真源替换成子集）。
   * @param list 已经按业务过滤好的分组列表
   */
  static build(list: BookGroups[]): GroupTree {
    return GroupTree.build(list)
  }
}

export default FilteredTree
