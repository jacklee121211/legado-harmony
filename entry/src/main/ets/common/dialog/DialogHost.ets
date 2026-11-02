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

  /** 真关当前弹窗并释放（不保留实例，满足铁律 1/2） */
  static closeCurrent(): void {
    const c: CustomDialogController | null = DialogHost.current
    DialogHost.current = null
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
