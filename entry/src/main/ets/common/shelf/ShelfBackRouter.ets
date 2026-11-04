import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN: number = 0x0000
const TAG: string = 'ShelfBack'

/**
 * 「书架返回手势」的路由口（2026-11-05 新增）。
 *
 * ── 为什么需要这个类（而不是直接在 `Index.onBackPress` 里写逻辑）─────────────
 * 书架当前所在分组是 `IndexShelf.bookTypeNumber`（`@State`，私有）。
 * 它是 `Index` 的**子组件**，而 `onBackPress` 只有 `@Entry`（`Index`）才能收到
 * ⇒ `Index` 拿不到那个状态，`IndexShelf` 又收不到返回事件。
 * 两侧都不能直连，于是用一个**最小单向端口**：`IndexShelf` 注册一个处理函数，
 * `Index` 在返回时问一句"这次返回书架要不要消费"。
 *
 * ⚠️ 契约（改动前必读）：
 *   · `handle()` 返回 **true = 已消费**（`Index.onBackPress` 必须 `return true`，不再交给系统）；
 *   · 返回 **false = 不消费**（书架不在分组域，走系统默认：退出应用）；
 *   · 未注册（书架没挂载，例如在阅读页）时 `handle()` 恒 false ⇒ 不影响阅读页的返回逻辑。
 *   · 只做"分组域 → 上一级 / 根分组 → 全部"这一件事，其它页签一律不接管。
 */
export class ShelfBackRouter {
  private static handler: (() => boolean) | null = null

  /** `IndexShelf` 挂载时注册（重复注册直接覆盖，最后一个挂载的生效） */
  static register(fn: () => boolean): void {
    ShelfBackRouter.handler = fn
  }

  /** `IndexShelf` 卸载时注销 —— 防止持有已销毁组件的闭包 */
  static unregister(): void {
    ShelfBackRouter.handler = null
  }

  /** `Index.onBackPress` 调用：true = 本次返回已被书架消费 */
  static handle(): boolean {
    const fn: (() => boolean) | null = ShelfBackRouter.handler
    if (fn === null) {
      return false
    }
    try {
      return fn()
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'ShelfBackRouter handler failed: %{public}s', JSON.stringify(e))
      return false
    }
  }
}
