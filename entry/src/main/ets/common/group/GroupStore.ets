import { BookGroups } from '../../database/entities/BookGroups'
import BookGroupsDao from '../../database/dao/BookGroupsDao'
import { GroupTree } from './GroupTree'

/**
 * 2026-11-02 新增（架构收敛 P0）：**唯一分组树真源**。
 *
 * ── 为什么要它 ────────────────────────────────────────────────────────────
 * 收敛前全工程有 **22 处 `GroupTree.build(...)`**，书架/批量页/各个弹窗各建一棵树、
 * 各自过滤（孤儿、隐藏、顶层…），于是出现"批量里更新了、单书弹窗还是旧的"。
 * 现在只允许 `GroupStore` 持有 `groups[]` 与 `GroupTree`，其它地方**只读**。
 *
 * ── 约定 ─────────────────────────────────────────────────────────────────
 * · `refresh()` 从库里整取后**整体替换**引用（不做增量、不原地改），保证读者不会读到半更新状态；
 * · 隐藏集合由这里统一算（`!g.show`，因为 RDB 的 show 是 number(0/1)）；
 * · 页面禁止再自行 build 树；需要派生数据时用本类的只读方法。
 */
export class GroupStore {
  private static _groups: BookGroups[] = []
  private static _tree: GroupTree | null = null
  private static _loaded: boolean = false

  /** 从数据库整取并重建树（唯一写入口：GroupMutation 成功后调用） */
  static async refresh(): Promise<void> {
    const list: BookGroups[] = await BookGroupsDao.search()
    GroupStore.apply(list)
  }

  /** 供"已经拿到全量分组"的调用方直接灌入（避免重复查库） */
  static apply(list: BookGroups[]): void {
    GroupStore._groups = list
    GroupStore._tree = GroupTree.build(list)
    GroupStore._loaded = true
  }

  static async ensure(): Promise<void> {
    if (!GroupStore._loaded) {
      await GroupStore.refresh()
    }
  }

  static isLoaded(): boolean {
    return GroupStore._loaded
  }

  static groups(): BookGroups[] {
    return GroupStore._groups
  }

  static tree(): GroupTree | null {
    return GroupStore._tree
  }

  static find(id: number): BookGroups | undefined {
    for (const g of GroupStore._groups) {
      if ((g.groupId ?? -1) === id) {
        return g
      }
    }
    return undefined
  }

  static childrenOf(parentId: number): BookGroups[] {
    if (GroupStore._tree === null) {
      return []
    }
    return GroupStore._tree.childrenOf(parentId)
  }

  static subtreeIds(id: number): number[] {
    if (GroupStore._tree === null) {
      return [id]
    }
    return GroupStore._tree.subtreeIds(id)
  }

  /**
   * 2026-11-02（P1-2 预备）：按"书籍类型"过滤后的分组列表。
   * 供书架/批量页替换各自 `BookGroupsDao.search({type})` 用（收敛后统一从这里取）。
   */
  static groupsOfType(type: number): BookGroups[] {
    const out: BookGroups[] = []
    for (const g of GroupStore._groups) {
      // 2026-11-02 真机对照修正：**系统分组（未分组等）必须保留** ——
      //   真机上「未分组」的 groupType 是 123，若只按 `groupType === type` 过滤，
      //   未分组卡片会整块消失（s4 截图已证）。系统分组一律放行。
      if (g.isSystem) {
        out.push(g)
        continue
      }
      if (g.groupType === undefined || g.groupType === type) {
        out.push(g)
      }
    }
    return out
  }

  /** 2026-11-02（P1-2 预备）：剔除孤儿分组（父级缺失/自环）后的列表 */
  static keptGroups(): BookGroups[] {
    const out: BookGroups[] = []
    const tree: GroupTree | null = GroupStore._tree
    if (tree === null) {
      return GroupStore._groups
    }
    for (const g of GroupStore._groups) {
      if (!tree.isOrphan(g)) {
        out.push(g)
      }
    }
    return out
  }

  /**
   * 需要从书籍查询里排除的分组（所有 `show=false` 分组的整棵子树）。
   * ⚠️ RDB 的 `show` 是 number(0/1)：判定必须用 `!g.show`。
   */
  static hiddenIds(): number[] {
    const out: number[] = []
    if (GroupStore._tree === null) {
      return out
    }
    for (const g of GroupStore._groups) {
      if (!g.show && g.groupId !== undefined) {
        for (const id of GroupStore._tree.subtreeIds(g.groupId)) {
          if (out.indexOf(id) < 0) {
            out.push(id)
          }
        }
      }
    }
    return out
  }
}
