/**
 * 多级分组（分组树）纯逻辑工具 —— 2026-11-01。
 *
 * 为什么单独一个文件：
 *   · 树形逻辑（深度/祖先/防环/子孙）会被「分组列表」「进入父组」「移动至」「解散/删除」
 *     四个界面共用，散落成四份必然分叉；
 *   · 全是**纯函数**，不碰数据库、不碰 UI，后续压缩包导入「按目录复刻分组」也能直接复用。
 *
 * 数据约定（与 `book_groups` 表一致）：
 *   · `parentId = 0` 表示根级；系统单元（分组=1/全部=2/未分组=3）同样按 0 处理；
 *   · 书籍仍挂在**叶子分组**上（`books.bookGroup = groupId`），父组本身也可直接放书；
 *   · 深度从 1 开始：根级 = 1，子级 = 2 …… 最大 `MAX_GROUP_DEPTH` = 10（2026-11-01 用户拍板）。
 */
import { BookGroups } from '../../database/entities/BookGroups'

/** 最大层级（根级 = 1 层） */
export const MAX_GROUP_DEPTH: number = 10

/** 移动/新建时的校验结果 */
export interface GroupMoveCheck {
  ok: boolean
  /** 失败原因（直接可展示给用户） */
  reason: string
}

/**
 * 分组树。构造时传**全量分组**（`BookGroupsDao.search()` 的结果即可），
 * 内部按 parentId 建索引，后续查询都是 O(1)/O(深度)。
 */
export class GroupTree {
  /** groupId -> 分组 */
  private byId: Map<number, BookGroups> = new Map<number, BookGroups>()
  /** parentId -> 子分组（保持传入顺序 = 数据库排序） */
  private childrenMap: Map<number, BookGroups[]> = new Map<number, BookGroups[]>()

  private constructor(list: BookGroups[]) {
    for (const g of list) {
      if (g.groupId === undefined) {
        continue
      }
      this.byId.set(g.groupId, g)
    }
    for (const g of list) {
      if (g.groupId === undefined) {
        continue
      }
      const pid: number = this.parentKey(g)
      const arr: BookGroups[] | undefined = this.childrenMap.get(pid)
      if (arr === undefined) {
        this.childrenMap.set(pid, [g])
      } else {
        arr.push(g)
      }
    }
  }

  static build(list: BookGroups[]): GroupTree {
    return new GroupTree(list)
  }

  /**
   * 取「有效 parentId」：父组不存在（脏数据/被删）时按根级处理，避免整棵树消失。
   */
  /**
   * 2026-11-01：是否为「孤儿分组」—— 父级在本列表里不存在，或 parentId 指向自己。
   * 这类数据会被 `parentKey()` 兜底成根级，导致"移动至/批量管理"里凭空多出同名根分组。
   * 展示端统一用本方法过滤，避免各处各写一遍。
   */
  isOrphan(g: BookGroups): boolean {
    const pid: number = g.parentId ?? 0
    if (pid <= 0) {
      return false
    }
    if (g.groupId !== undefined && pid === g.groupId) {
      return true
    }
    return !this.byId.has(pid)
  }

  private parentKey(g: BookGroups): number {
    const pid: number = g.parentId ?? 0
    if (pid <= 0) {
      return 0
    }
    if (!this.byId.has(pid)) {
      return 0
    }
    if (g.groupId !== undefined && pid === g.groupId) {
      return 0 // 自环脏数据
    }
    return pid
  }

  get(id: number | undefined): BookGroups | undefined {
    if (id === undefined) {
      return undefined
    }
    return this.byId.get(id)
  }

  /** 某父级下的直接子分组（parentId = 0 即根级） */
  childrenOf(parentId: number): BookGroups[] {
    const list: BookGroups[] = this.childrenMap.get(parentId > 0 ? parentId : 0) ?? []
    // 2026-11-01：根级统一剔除孤儿 —— 否则所有新调用点都会把"父亲不在列表"的分组
    //   当成根级重复展示（真机 212 现象）。显示端的 isOrphan 过滤保留作双保险。
    if (parentId <= 0) {
      return list.filter((g: BookGroups): boolean => !this.isOrphan(g))
    }
    return list
  }

  /** 根级分组 */
  roots(): BookGroups[] {
    return this.childrenOf(0)
  }

  /** 深度（根级 = 1）；找不到返回 0 */
  depthOf(id: number | undefined): number {
    if (id === undefined || id <= 0) {
      return 0
    }
    let depth: number = 1
    let cur: BookGroups | undefined = this.byId.get(id)
    /** 防环保险：最多走 MAX_GROUP_DEPTH + 1 步 */
    let guard: number = 0
    while (cur !== undefined && guard <= MAX_GROUP_DEPTH + 1) {
      const pid: number = this.parentKey(cur)
      if (pid === 0) {
        return depth
      }
      depth++
      cur = this.byId.get(pid)
      guard++
    }
    return depth
  }

  /** 从根到自身的路径（含自身） */
  pathOf(id: number | undefined): BookGroups[] {
    const out: BookGroups[] = []
    if (id === undefined || id <= 0) {
      return out
    }
    let cur: BookGroups | undefined = this.byId.get(id)
    let guard: number = 0
    while (cur !== undefined && guard <= MAX_GROUP_DEPTH + 1) {
      out.unshift(cur)
      const pid: number = this.parentKey(cur)
      if (pid === 0) {
        break
      }
      cur = this.byId.get(pid)
      guard++
    }
    return out
  }

  /** 路径名（用于面包屑）：`['父组','子组']` */
  pathNames(id: number | undefined): string[] {
    return this.pathOf(id).map((g: BookGroups): string => g.groupName)
  }

  /** 是否是 `ancestorId` 的子孙（不含自身） */
  isDescendantOf(nodeId: number, ancestorId: number): boolean {
    if (nodeId <= 0 || ancestorId <= 0 || nodeId === ancestorId) {
      return false
    }
    let cur: BookGroups | undefined = this.byId.get(nodeId)
    let guard: number = 0
    while (cur !== undefined && guard <= MAX_GROUP_DEPTH + 1) {
      const pid: number = this.parentKey(cur)
      if (pid === 0) {
        return false
      }
      if (pid === ancestorId) {
        return true
      }
      cur = this.byId.get(pid)
      guard++
    }
    return false
  }

  /** 子孙 id（不含自身，深度优先） */
  descendantIds(id: number): number[] {
    const out: number[] = []
    const walk = (pid: number): void => {
      for (const child of this.childrenOf(pid)) {
        if (child.groupId !== undefined) {
          out.push(child.groupId)
          walk(child.groupId)
        }
      }
    }
    walk(id)
    return out
  }

  /** 自身 + 子孙 */
  subtreeIds(id: number): number[] {
    const out: number[] = [id]
    for (const d of this.descendantIds(id)) {
      out.push(d)
    }
    return out
  }

  /** 子树高度（自身算 1 层） */
  subtreeHeight(id: number): number {
    let h: number = 1
    for (const child of this.childrenOf(id)) {
      if (child.groupId !== undefined) {
        const ch: number = 1 + this.subtreeHeight(child.groupId)
        if (ch > h) {
          h = ch
        }
      }
    }
    return h
  }

  /**
   * 能否把 `nodeId` 移到 `newParentId` 下（0 = 根级）。
   * 规则（2026-11-01）：① 不能移到自己或自己的子孙下（防环）；② 移动后子树不得超 MAX_GROUP_DEPTH。
   */
  canMoveTo(nodeId: number, newParentId: number): GroupMoveCheck {
    if (this.byId.get(nodeId) === undefined) {
      return { ok: false, reason: '分组不存在' }
    }
    if (nodeId === newParentId) {
      return { ok: false, reason: '不能移动到自身' }
    }
    if (newParentId > 0 && this.byId.get(newParentId) === undefined) {
      return { ok: false, reason: '目标分组不存在' }
    }
    if (this.isDescendantOf(newParentId, nodeId)) {
      return { ok: false, reason: '不能移动到自己的子目录里' }
    }
    const targetDepth: number = newParentId > 0 ? this.depthOf(newParentId) : 0
    const height: number = this.subtreeHeight(nodeId)
    if (targetDepth + height > MAX_GROUP_DEPTH) {
      return { ok: false, reason: `最多 ${MAX_GROUP_DEPTH} 层，移动后会超出` }
    }
    return { ok: true, reason: '' }
  }

  /** 能否在 `parentId` 下新建子分组 */
  canCreateChild(parentId: number): GroupMoveCheck {
    const pid: number = parentId > 0 ? parentId : 0
    if (pid > 0 && this.byId.get(pid) === undefined) {
      return { ok: false, reason: '父分组不存在' }
    }
    if (pid > 0 && this.depthOf(pid) >= MAX_GROUP_DEPTH) {
      return { ok: false, reason: `最多 ${MAX_GROUP_DEPTH} 层，不能继续嵌套` }
    }
    return { ok: true, reason: '' }
  }

  /** 同父下是否已有同名分组（重名检查，排除自身） */
  hasSiblingNamed(parentId: number, name: string, excludeId?: number): boolean {
    const target: string = (name ?? '').trim()
    if (target === '') {
      return false
    }
    for (const g of this.childrenOf(parentId)) {
      if (excludeId !== undefined && g.groupId === excludeId) {
        continue
      }
      if ((g.groupName ?? '').trim() === target) {
        return true
      }
    }
    return false
  }
}
