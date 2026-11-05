/**
 * 阅读进度的**内存透传**（2026-11-06，折叠形态切换专用）。
 *
 * ── 为什么需要它（真机日志实证）────────────────────────────────────────────
 * PuraX 折叠/展开时 `ReaderPage3` 会被**销毁重建**（同一本书两次 `startPlay`）：
 *
 *   22:28:07.752  startPlay from LOCAL: spine=0 domPos=15=0#0;@;0   ← 进外屏，读磁盘
 *   22:28:10.678  startPlay from LOCAL: spine=0 domPos=7=0#0;@;0    ← 展开重建，**又读磁盘**
 *
 * 重建时磁盘里还是**上一次落盘**的旧值（`7`），而内存里的当前位置是 `15`
 * ⇒ 用户看到"进度被重置"。根因不是读取逻辑写错，而是**写盘是异步/低频的，
 * 重建发生在写盘之前**。
 *
 * ── 职责边界（只做一件事）──────────────────────────────────────────────────
 *   · 只缓存"最近一次已知的阅读位置"，纯内存、不落盘、不参与任何业务判定；
 *   · 只对**同一个书**生效（`bookName` 不同即视为无效）；
 *   · 有过期时间：超过 [TTL_MS] 视为无效，避免"上次会话残留"顶掉磁盘真值。
 *
 * ⚠️ 它不替代磁盘进度，只是"重建前那一刻的内存快照"。读的时候先问它，
 *    它没过期且同一本书才用；否则照旧读磁盘 —— 这样即使这份缓存失效，
 *    行为退回改造前，不会引入新的"进度错乱"。
 */
export class ReaderPosMemory {
  /** 缓存有效期：重建通常发生在几秒内，5 分钟足够宽裕且不会造成跨会话误用 */
  static readonly TTL_MS: number = 5 * 60 * 1000

  private static bookName: string = ''
  private static spine: number = -1
  private static domPos: string = ''
  private static at: number = 0

  /**
   * 记一次当前位置。
   * 调用方 = **两个位置权威更新点**（2026-11-06 收口，单一通路）：
   * 分页档 `pageShow` / 自绘档 `applySelfDrawnPos`。
   * 形态切换沿**不再**调用 —— 那里拿到的 `bookData.localBookDurChapterPos`
   * 在自绘档是节流滞后值，会把更新点刚写的新快照顶旧。
   */
  static remember(bookName: string, spine: number, domPos: string): void {
    if (bookName.length === 0 || spine < 0) {
      return
    }
    ReaderPosMemory.bookName = bookName
    ReaderPosMemory.spine = spine
    ReaderPosMemory.domPos = domPos
    ReaderPosMemory.at = Date.now()
  }

  /** 取回上次记住的位置；不同书 / 过期 / 从未记录 ⇒ `null`（调用方回退磁盘） */
  static recall(bookName: string): ReaderPos | null {
    if (bookName.length === 0 || ReaderPosMemory.bookName !== bookName) {
      return null
    }
    if (ReaderPosMemory.spine < 0 || Date.now() - ReaderPosMemory.at > ReaderPosMemory.TTL_MS) {
      return null
    }
    const p: ReaderPos = new ReaderPos()
    p.spine = ReaderPosMemory.spine
    p.domPos = ReaderPosMemory.domPos
    return p
  }

  /** 主动作废（例如用户换了书、或磁盘值更新后确认已落盘） */
  static clear(): void {
    ReaderPosMemory.bookName = ''
    ReaderPosMemory.spine = -1
    ReaderPosMemory.domPos = ''
    ReaderPosMemory.at = 0
  }
}

/** `ReaderPosMemory.recall()` 的返回体（ArkTS 不允许返回匿名对象字面量做类型） */
export class ReaderPos {
  spine: number = 0
  domPos: string = ''
}
