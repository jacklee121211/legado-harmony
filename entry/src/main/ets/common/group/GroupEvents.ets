/**
 * 2026-11-02 新增（架构收敛 P0）：**唯一数据总线**。
 *
 * ── 为什么要它 ────────────────────────────────────────────────────────────
 * 收敛前有三套刷新信号、**121 处手工 bump**：
 *   `isBookRefreshing`(49) / `BOOK_IS_BOOK_GROUPS_REFRESHING`(44) / `MANAGE_SEL_VERSION_KEY`(16)。
 * 漏 bump 一处就出现"卡片不刷新、进去才看到"——用户实测的 U2/U4/U5 都是这类。
 *
 * ── 契约（冻结）───────────────────────────────────────────────────────────
 * · 一次操作**只发一次** `emit(changedGroupIds, changedBookIds)`；
 * · `version` 单调递增，订阅者据此判断"是否比我新"；
 * · 订阅者（页面）拿到 payload 后**自己决定**要不要重查（selector 化的起点），
 *   不再有"全局无脑刷新"那种"整树重建 → 闪烁"。
 */
export class GroupChangedPayload {
  version: number
  changedGroupIds: number[]
  changedBookIds: number[]

  constructor(version: number, groupIds: number[], bookIds: number[]) {
    this.version = version
    this.changedGroupIds = groupIds
    this.changedBookIds = bookIds
  }

  /** 是否涉及某个分组（含"全量变更"约定：changedGroupIds 为空表示结构变更） */
  touchesGroup(id: number): boolean {
    if (this.changedGroupIds.length === 0) {
      return true
    }
    return this.changedGroupIds.indexOf(id) >= 0
  }
}

export type GroupChangedListener = (p: GroupChangedPayload) => void

export class GroupEvents {
  /** 全局版本号（等价于旧的三个计数器合体） */
  static version: number = 0

  private static listeners: GroupChangedListener[] = []

  static subscribe(fn: GroupChangedListener): void {
    if (GroupEvents.listeners.indexOf(fn) < 0) {
      GroupEvents.listeners.push(fn)
    }
  }

  static unsubscribe(fn: GroupChangedListener): void {
    const idx: number = GroupEvents.listeners.indexOf(fn)
    if (idx >= 0) {
      GroupEvents.listeners.splice(idx, 1)
    }
  }

  /**
   * 发出**唯一一次**变更事件。
   * @param groupIds 受影响分组 id；**结构变更（增删/移动整棵）传空数组表示"全量"**
   * @param bookIds  受影响书籍 id（可选）
   */
  static emit(groupIds: number[], bookIds: number[] = []): void {
    GroupEvents.version++
    const payload: GroupChangedPayload = new GroupChangedPayload(GroupEvents.version, groupIds, bookIds)
    // 同步给仍用 @StorageProp 的旧组件（双轨期过渡，P4 后删除）
    AppStorage.setOrCreate<number>('GROUP_EVENT_VERSION', payload.version)
    const snapshot: GroupChangedListener[] = GroupEvents.listeners.slice(0)
    for (const fn of snapshot) {
      try {
        fn(payload)
      } catch (e) {
        console.error(`[GROUP-EVENT] listener failed: ${JSON.stringify(e)}`)
      }
    }
  }
}
