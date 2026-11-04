/**
 * 「书架 chip 切换」的定向端口（2026-11-05）。
 *
 * ── 为什么不用 `@Watch(bookTypeNumber)` 全局同步（上一版做法，已废弃）──
 * chip 的选中态是 `GroupType` 自己的 `@State`（`chipHighlightId` / `chipSel`）。
 * 曾用「`bookTypeNumber` 一变就同步 chip」的全局 `@Watch`，结果是**任何**改变
 * `bookTypeNumber` 的路径都会动 chip：
 *   · 返回手势切「全部」⇒ chip 该跟着跳（本来要的）；
 *   · 但**进入某个分组**（自定义 id）也会触发 ⇒ 自定义 id 不在 chip 序列里，
 *     换算出来的下标落到了「最近」/「全部」⇒ 用户看到"进文件夹标签乱跳"。
 *
 * ⇒ 改成**定向**：`GroupType` 注册一个"按名字选中系统 chip"的回调，
 *   只有**明确需要**改 chip 的调用方（目前只有 `IndexShelf` 的返回手势）才调用它。
 *   其它路径（进分组、点书、刷新…）完全不碰 chip。
 *
 * 契约：
 *   · `selectSystemChip('全部')` → true = 已切（chip + 内容同步）；false = 未注册或没这枚 chip；
 *   · 未注册（书架没挂载）时恒 false ⇒ 调用方自行兜底。
 */
export class ShelfChipRouter {
  private static handler: ((name: string) => boolean) | null = null

  static register(fn: (name: string) => boolean): void {
    ShelfChipRouter.handler = fn
  }

  static unregister(): void {
    ShelfChipRouter.handler = null
  }

  /** 按**名字**选中系统 chip（目前只用 '全部'）；返回是否成功 */
  static selectSystemChip(name: string): boolean {
    const fn: ((name: string) => boolean) | null = ShelfChipRouter.handler
    if (fn === null) {
      return false
    }
    try {
      return fn(name)
    } catch (e) {
      return false
    }
  }
}
