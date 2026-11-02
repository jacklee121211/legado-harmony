/**
 * 2026-11-02 新增（架构收敛 P3 骨架）：**唯一弹窗宿主**。
 *
 * ── 为什么要有它 ──────────────────────────────────────────────────────────
 * 收敛前：全工程 **74 处** `new CustomDialogController(`、**194 处** `.close()`，
 * 每个调用点自己 new、自己 close；于是出现用户实测的"移动至弹窗吃过亏"：
 * 父弹窗留着旧快照等子弹窗返回 ⇒ 子退父进拿到的是过期数据。
 *
 * ── 铁律（真源文档 S7）───────────────────────────────────────────────────
 * 1. **一次性实例**：controller 不复用，关闭即释放；
 * 2. **父先真关**：打开子弹窗之前，必须先 `close()` 父（父不得挂起等待）；
 * 3. **子退重建父**：子关闭后，父通过 `builder` **重新 new 一次**（重新取数），
 *    不是"复活旧实例"；
 * 4. 调用点只描述"要开哪个弹窗 + 回调"，**不许**自己持有 controller。
 *
 * ⚠️ 本轮只做骨架，未接线；P3 逐模块替换（先分组域 30 处，再全局 74 处）。
 */
export class DialogHost {
  private static current: CustomDialogController | null = null
  /** 叠在 `current` 之上的子弹窗（如「分组管理 → 长按分组 → 删除/解散确认」这种二级短确认框） */
  private static nested: CustomDialogController[] = []

  /** 打开一个弹窗（若已有弹窗，先真关它，再开新的） */
  static open(controller: CustomDialogController): void {
    DialogHost.closeCurrent()
    DialogHost.current = controller
    try {
      controller.open()
    } catch (e) {
      console.error(`[DIALOG-HOST] open failed: ${JSON.stringify(e)}`)
      DialogHost.current = null
    }
  }

  /** 可空版本：null 时什么都不做（页面里 xxx?.open() 的无痛替换） */
  static openIf(controller: CustomDialogController | null | undefined): void {
    if (controller === null) {
      return
    }
    DialogHost.open(controller as CustomDialogController)
  }

  /**
   * 打开一个**叠在父弹窗之上**的子弹窗 —— **不真关父**。
   *
   * ── 为什么需要它（2026-11-02 第 25 轮 B1b 新增）────────────────────────────
   * `open()` 强制执行 S7「父先真关」，但工程里有几类弹窗**按设计必须让父窗活着**：
   *   · 「分组管理 → 长按分组 →（删除/解散/恢复显示）二级短确认框」——
   *     `BookSelectGroupDialog.ets:1013` 原文：「本弹窗是**叠在分组管理之上**的二级短确认框」
   *     `:1025` 又写：「只清引用，**分组管理弹窗本身不动**」；
   *   · 「移动至 → 新建分组（连续创建）」—— `:642-655` 原文：父弹窗**不关**，
   *     否则 `@CustomDialog` 的 `@State` 实例被销毁，新建的分组再也刷不回列表（2026-10-13 踩过）。
   * ⇒ 这些点用 `open()` 会把父窗连带关掉（`@CustomDialog` 实例销毁），
   *   正是上面注释里点名的那两个坑。所以给它们一个**显式**入口，语义写清楚、可审计。
   *
   * 收尾规则：父窗真关时（`closeCurrent()`）会**连带关闭**所有 nested 子弹窗，
   * 避免"父没了、子还挂着"的僵尸弹窗。
   */
  static openNested(controller: CustomDialogController | null | undefined): void {
    if (controller === null || controller === undefined) {
      return
    }
    const c: CustomDialogController = controller as CustomDialogController
    if (DialogHost.nested.indexOf(c) < 0) {
      DialogHost.nested.push(c)
    }
    try {
      c.open()
    } catch (e) {
      console.error(`[DIALOG-HOST] openNested failed: ${JSON.stringify(e)}`)
      DialogHost.forgetNested(c)
    }
  }

  /** 关闭一个 nested 子弹窗并停止跟踪（对应 `openNested`） */
  static closeNested(controller: CustomDialogController | null | undefined): void {
    if (controller === null || controller === undefined) {
      return
    }
    const c: CustomDialogController = controller as CustomDialogController
    DialogHost.forgetNested(c)
    try {
      c.close()
    } catch (e) {
      console.error(`[DIALOG-HOST] closeNested failed: ${JSON.stringify(e)}`)
    }
  }

  private static forgetNested(c: CustomDialogController): void {
    const idx: number = DialogHost.nested.indexOf(c)
    if (idx >= 0) {
      DialogHost.nested.splice(idx, 1)
    }
  }

  /** 真关当前弹窗并释放（不保留实例，满足铁律 1/2）；连带关闭它的 nested 子弹窗 */
  static closeCurrent(): void {
    const c: CustomDialogController | null = DialogHost.current
    DialogHost.current = null
    // 先把叠在上面的子弹窗关掉（父没了子不能留），再关父
    const kids: CustomDialogController[] = DialogHost.nested.slice(0)
    DialogHost.nested = []
    for (const k of kids) {
      try {
        k.close()
      } catch (e) {
        console.error(`[DIALOG-HOST] closeNested(on closeCurrent) failed: ${JSON.stringify(e)}`)
      }
    }
    if (c !== null) {
      try {
        c.close()
      } catch (e) {
        console.error(`[DIALOG-HOST] close failed: ${JSON.stringify(e)}`)
      }
    }
  }

  /**
   * 子退重建父：先真关当前，再由 `builder` **重新创建**父弹窗并打开。
   * 用法（P3 接线后）：
   *   DialogHost.reopen(() => new CustomDialogController({ builder: ParentDialog({...新参数}) }))
   */
  static reopen(builder: () => CustomDialogController): void {
    DialogHost.closeCurrent()
    const next: CustomDialogController = builder()
    DialogHost.current = next
    try {
      next.open()
    } catch (e) {
      console.error(`[DIALOG-HOST] reopen failed: ${JSON.stringify(e)}`)
      DialogHost.current = null
    }
  }
}
