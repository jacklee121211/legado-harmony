/**
 * @author 2008
 * @datetime 2024/6/28 22:43
 * @className: IconTitleVo
 * 图标标题
 *
 * ── 2026-10-22：新增 `symbol`（系统符号）字段（用户要求「全改成 symbol」）──────
 * 两个字段**二选一**，渲染优先级 `symbol` → `icon`：
 *   · `symbol`：`$r('sys.symbol.xxx')`，走 `SymbolGlyph`（**新代码一律用这个**）；
 *   · `icon`  ：`$r('app.media.xxx')`，走 `Image`（历史 SVG，仅兼容 `Header` 的旧调用点）。
 * ⚠️ 为什么不用联合类型 `Resource | MenuIcon`：ArkTS 里 `instanceof` 判断 + 联合类型
 *    在 `@Prop` 上会带来额外复杂度，而这里只是"有哪个用哪个"，两个可选字段最直白。
 */
export class IconTitleVo{
  icon?: Resource;
  symbol?: Resource;
  title: string;

  /**
   * @param icon   旧 SVG 资源（可选；不传则必须传 symbol）
   * @param title  文案
   * @param symbol 系统符号（推荐；传了它就会优先于 icon 渲染）
   */
  constructor(icon: Resource | undefined, title: string, symbol?: Resource) {
    this.icon = icon
    this.title = title
    this.symbol = symbol
  }
}
