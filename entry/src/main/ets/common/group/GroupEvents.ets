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

  /**
   * 「渲染广播已入队」标志（2026-11-03 双轨收口）。
   *
   * ── 背景：为什么需要这条补发通道 ──────────────────────────────────────────
   * 本工程现在有**两种订阅形态**：
   *   · 新：`GroupEvents.subscribe(fn)` —— 带 payload（精确 groupIds/bookIds）；
   *   · 旧：`ShelfRefresh` 的两个 AppStorage 计数器 + `@StorageProp(@Watch)` —— 无 payload，
   *     "加一就整片重查"。今天仍有 ~28 个组件在用旧形态（清单见 `docs/待办-统一清单-2026-11-03.md` §27）。
   * 问题：**只有 `GroupMutation` 会 emit**。凡是"绕过 GroupMutation 直接 bump 计数器"的写路径
   * （UI 里 `ShelfRefresh.groups()` 之后没有领域事件），事件订阅方就**永远收不到通知** ⇒
   * 这正是双轨最危险的一面：新增的事件订阅者会静默漏刷新。
   *
   * 解法：让 `ShelfRefresh` 在 bump 计数器的同时也**补发一次事件**，且同一微任务内只补一次，
   * 并在这期间已经有精确事件时不补（避免同一次操作触发两轮监听器）。
   */
  private static bumpPending: boolean = false

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
    // 2026-11-03（双轨收口）：这里原来还有一行把版本号镜像到 AppStorage 的 `GROUP_EVENT_VERSION`
    //   —— 注释写的是"同步给仍用 @StorageProp 的旧组件（双轨期过渡，P4 后删除）"。
    //   实测全仓**只有这一行写、没有任何一处读**（`@StorageProp/@StorageLink/AppStorage.get` 全 0），
    //   ⇒ 空转的桥，已删。旧组件走的是 `ShelfRefresh` 的两个计数器（见该文件），不是这个键。
    const snapshot: GroupChangedListener[] = GroupEvents.listeners.slice(0)
    // ── 2026-11-02 第 24 轮（D7）：**发端探针**，补上取证盲区 ─────────────────────
    // 为什么必须有这行：`[GRP-EVENT] 结构变更 → 已清空选中集` 是在 `BookManagePage` 的
    // **监听器**里打的（`BookManagePage.ets:300-307`），所以"JSAPP 里没有 GRP-EVENT"
    // 有两种完全不同的原因：① emit 没执行；② emit 执行了但当时没有订阅者（批量页没挂载）。
    // 有了本行就能三态区分：
    //   · 连 `[GRP-EMIT]` 都没有        ⇒ 根本没发事件（写库路径没走到 emit）
    //   · `[GRP-EMIT] … listeners=0`    ⇒ 发了，但没人订阅（页面没打开，属设计如此）
    //   · `[GRP-EMIT] … listeners>0` 而没有 `[GRP-EVENT]` ⇒ 订阅者在，但判定条件没命中
    // `listeners` 是**发事件那一刻**的订阅者数量。纯日志、零行为变化。
    console.log(`[GRP-EMIT] v=${payload.version} groups=[${groupIds.join(',')}]`
      + ` books=[${bookIds.join(',')}] listeners=${snapshot.length}`)
    for (const fn of snapshot) {
      try {
        fn(payload)
      } catch (e) {
        console.error(`[GROUP-EVENT] listener failed: ${JSON.stringify(e)}`)
      }
    }
  }

  /**
   * `ShelfRefresh` 专用：**从"只 bump 了计数器"的写路径补发一次结构变更事件**。
   *
   * 语义：
   *   · 同一微任务内多次调用只补发一次（`bumpPending`）；
   *   · 若这段时间内已经有精确事件（`GroupMutation.emit` 把 version 推高了），**不再补发**
   *     —— 避免同一次用户操作让监听器跑两遍（选择集清空是幂等的，但重复重查没有意义）；
   *   · payload 一律是 `([], [])` = 结构变更（接收方按"全量"处理），因为旧计数器本来就不带信息。
   *
   * ⚠️ 不要从 UI 直接调本方法 —— 唯一调用点是 `common/shelf/ShelfRefresh.ets`（闸门 `group-event-exit` 守着）。
   */
  static emitFromBump(): void {
    if (GroupEvents.bumpPending) {
      return
    }
    const versionAtSchedule: number = GroupEvents.version
    GroupEvents.bumpPending = true
    Promise.resolve().then(() => {
      GroupEvents.bumpPending = false
      if (GroupEvents.version !== versionAtSchedule) {
        // 期间已有精确事件（例如 GroupMutation 的 afterChange）⇒ 精确的优先，不补发
        return
      }
      GroupEvents.emit([], [])
    })
  }
}
