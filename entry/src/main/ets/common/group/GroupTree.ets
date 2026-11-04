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

  /**
   * 是否存在**互指环脏数据**（A.parent=B 且 B.parent=A 这一类）。
   *
   * 为什么要这个判定（2026-11-04，G1 后续）：
   *   G1 把 `descendantIds/subtreeIds/subtreeHeight` 从"环上栈溢出"改成"遇环即停"，
   *   代价是**环上只返回能收集到的那部分 id**。对展示无害，但对**破坏性写操作**（解散子树 /
   *   级联删除 / 移动子树）就是"静默部分成功"——按部分 id 真写库、还不报错。
   *   ⇒ 写库前必须先问这个：有环就拒绝并报错，把"静默半成功"改回"显式失败"。
   *
   * 自环（parentId === 自己）**不算**：`parentKey()` 已把它归一成根级，不会造成无限递归。
   *
   * 实现：对每个节点沿父链向上走，若回到起点即成环；步数受 `MAX_GROUP_DEPTH + 1` 限制，
   *   所以即使数据再脏也只走有限步（分组量级 < 1000，成本可忽略）。
   */
  hasCycle(): boolean {
    const ids: number[] = Array.from(this.byId.keys())
    for (const start of ids) {
      const self: BookGroups | undefined = this.byId.get(start)
      if (self === undefined) {
        continue
      }
      let cur: number = this.parentKey(self)
      let steps: number = 0
      while (cur !== 0 && steps <= MAX_GROUP_DEPTH + 1) {
        if (cur === start) {
          return true
        }
        const up: BookGroups | undefined = this.byId.get(cur)
        if (up === undefined) {
          break
        }
        cur = this.parentKey(up)
        steps++
      }
    }
    return false
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

  /**
   * 防环 guard —— `descendantIds` / `subtreeIds` / `subtreeHeight` 三条递归**唯一**的下行判定口。
   *
   * ── 为什么要有它（2026-11-04 G1）──────────────────────────────────────────
   * 这三条递归原来全无上界：数据里一旦出现环（`A.parentId = B` 且 `B.parentId = A`）就无限下钻
   * ⇒ `RangeError: Maximum call stack size exceeded`，把分组页/书架整页打挂。
   * 环是**存量脏数据**（早期导入、并发移动都可能留下），`canMoveTo()` 只能拦"新造的环"，
   * 管不了库里已经存在的环。
   *
   * ── 上界口径 ──────────────────────────────────────────────────────────────
   * 与 `depthOf()`(:126) / `pathOf()`(:146) / `isDescendantOf()`(:170) **逐字一致**：
   * `guard <= MAX_GROUP_DEPTH + 1`（最多下钻 12 层）。
   * 正常数据永远碰不到这个上界 —— `canMoveTo()` / `canCreateChild()` 保证树高 ≤ `MAX_GROUP_DEPTH`(=10)，
   * 所以**合法树的返回值与加 guard 前逐值相同**（单测里 77 条改前/改后逐字相同的断言兜底，
   * 见 `scripts/tests/group-tree.test.mjs`）。
   *
   * ── 两个条件缺一不可 ──────────────────────────────────────────────────────
   *   · `seen`：真正保证终止 —— 每个 groupId 只下行一次。树形数据每个节点只有一个父级
   *     （`childrenMap` 按 `parentKey()` 唯一挂载）⇒ 不可能重复到达 ⇒ **对合法数据零影响**；
   *   · `guard`：与既有三处同口径的兜底，防 `seen` 失效的极端脏数据（同一 groupId 重复出现）。
   */
  private canDescend(id: number, guard: number, seen: Set<number>): boolean {
    if (seen.has(id)) {
      return false
    }
    return guard <= MAX_GROUP_DEPTH + 1
  }

  /**
   * 子孙 id（不含自身，深度优先、先序）。
   *
   * ── 环上语义（2026-11-04 定义，勿改）──────────────────────────────────────
   * **遇环即停、返回已收集结果**，不抛异常。为什么这样定义：
   *   ① 用户此刻的诉求是"把分组打开、把书移走/删掉"，抛栈溢出会让整页白屏，
   *      连修数据的入口都进不去 —— 可用性优先于"严格报错"；
   *   ② "看到多少算多少"是可展示的降级结果（最深的几个子组可能少列），
   *      比"整页不可用"损失小；
   *   ③ 暴露脏数据另有通道：`isOrphan()` + `GroupStore.keptGroups()`，不靠让查询接口炸掉来实现。
   * 起点自身先占位到 `seen` ⇒ 环上也不会把自己当成自己的子孙（"不含自身"的约定不破）。
   */
  descendantIds(id: number): number[] {
    const out: number[] = []
    const seen: Set<number> = new Set<number>()
    seen.add(id)
    this.walkDescendants(id, 1, seen, out)
    return out
  }

  /** `descendantIds()` 的递归体；下行判定一律走 `canDescend()`，不要在这里再写上界 */
  private walkDescendants(pid: number, guard: number, seen: Set<number>, out: number[]): void {
    for (const child of this.childrenOf(pid)) {
      const cid: number | undefined = child.groupId
      if (cid === undefined) {
        continue
      }
      if (!this.canDescend(cid, guard, seen)) {
        continue
      }
      seen.add(cid)
      out.push(cid)
      this.walkDescendants(cid, guard + 1, seen, out)
    }
  }

  /**
   * 自身 + 子孙。
   * 自身不递归：防环 guard 由 `descendantIds()` 单点提供（单一通路，不重复写一遍上界），
   * 环上同样"遇环即停"且结果**不含重复 id**（起点只出现一次）。
   */
  subtreeIds(id: number): number[] {
    const out: number[] = [id]
    for (const d of this.descendantIds(id)) {
      out.push(d)
    }
    return out
  }

  /**
   * 子树高度（自身算 1 层）。
   * 环上语义同上：**遇环即停**，环上节点每个只计一次（`seen` 判重），不抛异常。
   */
  subtreeHeight(id: number): number {
    const seen: Set<number> = new Set<number>()
    seen.add(id)
    return this.heightFrom(id, 1, seen)
  }

  /** `subtreeHeight()` 的递归体；下行判定同样只走 `canDescend()` */
  private heightFrom(id: number, guard: number, seen: Set<number>): number {
    let h: number = 1
    for (const child of this.childrenOf(id)) {
      const cid: number | undefined = child.groupId
      if (cid === undefined) {
        continue
      }
      if (!this.canDescend(cid, guard, seen)) {
        continue
      }
      seen.add(cid)
      const ch: number = 1 + this.heightFrom(cid, guard + 1, seen)
      if (ch > h) {
        h = ch
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
      // 2026-11-04（批 C-17）：**不再 trim 存量名**，与 `BookGroupsDao.hasSiblingNamed()` 逐字对齐。
      //   旧写法 `(g.groupName ?? '').trim() === target` 会在内存侧把「分组 」与「分组」判为重名，
      //   而 DAO 侧是 `predicates.equalTo('groupName', name)`（SQL 精确比较、不 trim）⇒ 两处口径不同，
      //   表现为"界面说重名、数据库说没重名"（唯一索引建在原始值上，也认为两者不同）。
      //   ⇒ 统一为**精确比较**：输入侧两侧都 trim，存量值按原样比。
      if ((g.groupName ?? '') === target) {
        return true
      }
    }
    return false
  }
}