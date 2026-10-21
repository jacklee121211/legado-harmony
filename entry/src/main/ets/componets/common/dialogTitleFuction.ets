/**
 * @author 2008
 * @datetime 2024/6/28 22:24
 * @className: dialogTitleFuction
 */
import CommonConstants from '../../common/constants/CommonConstants'
import FontConstants from '../../common/constants/FontConstants'
import ImageConstants from '../../common/constants/ImageConstants'
import PaddingConstants from '../../common/constants/PaddingConstants'
import TextConstants from '../../common/constants/TextConstants'

/**
 * 菜单行（图标 + 文字）。
 *
 * ── 2026-10-22 图标全部改为**系统符号**（用户要求「全改成 symbol」）──────────────
 * 用户原话：「原来都不是 symbol，怪不得，全改成 symbol」。
 *
 * ── 改造前的问题（真机观感不一致）─────────────────────────────────────────────
 * 旧实现是 `@Prop icon: Resource` + `Image(this.icon)` 加载 **SVG 位图**，
 * 而书架「⋯」菜单那三张 SVG 的源文件规格**互不一致**：
 *
 * | 菜单项 | 旧资源 | 画布 | `fill-opacity` |
 * |---|---|---|---|
 * | 书籍导入 | `import_svg.svg` | 20×20 | 0.88 |
 * | 批量管理 | `batch_svg.svg` | 16×16 | 0.88 |
 * | 分组管理 | `folder.svg` | 24×24 | **0.65** |
 *
 * `Image` 被写死 `.width(20).height(20)`（`ImageConstants.IMG_WIDTH_20`）⇒ 三张图被
 * 强行缩放进同一个 20×20 框，但**图形在各自画布里的留白比例不同** ⇒ 缩放后视觉大小
 * 不一致；且 `fill-opacity` 是**图形自身不透明度**，`.fillColor()` 只改 RGB、改不了它
 * ⇒ 0.65 那个明显更灰。这就是用户看到的「图标和字体不太一样」（字体三行其实完全一致，
 * 是图标拖累了整行观感）。
 *
 * ── 现在：`SymbolGlyph` + 系统符号 ────────────────────────────────────────────
 * 符号名**逐个核实自 SDK 真源** `sysResource.js`（317 KB 全表，不是那个 11 KB 的
 * `hms/ets/sysResource.js` 索引 —— 查索引会得出"符号不存在"的错误结论）：
 * ```
 * square_and_arrow_down: 125832677,   ← 书籍导入
 * list_checkmark:        125835983,   ← 批量管理
 * folder:                125831897,   ← 分组管理
 * ```
 * `SymbolGlyph` 正好解决上面两个问题：
 *   · **矢量 + 单色**（`.fontColor` 染色，不存在 `fill-opacity` 打架）；
 *   · 尺寸由 `.fontSize` 统一驱动 ⇒ 三行图标严格等大、等重。
 *
 * ── 向后兼容 ──────────────────────────────────────────────────────────────────
 * `icon`（旧 SVG）字段保留，`symbol`（新）优先。`Header.dialogRightData` 目前
 * 全工程**无任何调用方传值**（已 grep 确认）⇒ 兼容分支是保险，不是活路径。
 */
@Component
export default struct dialogTitleFuction{
  isBorder: boolean = true
  @Prop title:string
  /**
   * **系统符号**（推荐，新代码一律用它）：`$r('sys.symbol.xxx')` ⇒ 走 `SymbolGlyph`。
   * 传了它就**忽略** `icon`。
   *
   * ⚠️ 不能写成 `@Prop symbol?: Resource`：etsLint 会报
   *   「The '@Prop' property 'symbol' cannot be an optional parameter.」
   *   ⇒ 用「非可选 + 默认 `undefined`」表达同样的"可以没有"。
   */
  @Prop symbol: Resource | undefined = undefined
  /**
   * 旧 SVG 图标（仅兼容 `Header` 的旧调用点）；`symbol` 未传时才用，走 `Image`。
   * 同上：非可选 + 默认 `undefined`。
   */
  @Prop icon: Resource | undefined = undefined
  /**
   * 是否按**夜间浮层**上色。
   *
   * ⚠️ 为什么用 `@Prop` 而不是直接读 `NightMode.isDarkSurface()`：
   *   本组件被两处复用 —— 书架右上「⋯」菜单（`IndexShelf.MenuBuilder`，夜间是**深色**面板）
   *   和 `Header` 的菜单（用在搜索/管理页，那两页**不做**深色适配，永远是浅色）。
   *   若无条件读全局夜间开关，搜索/管理页的菜单文字也会变白 ⇒ 白字压白底。
   *   ⇒ 由**调用方**声明自己那层是不是深色；`Header` 侧不传 ⇒ 默认 false ⇒ 与改造前一致。
   */
  @Prop nightStyle: boolean = false

  /** 前景色：图标与文字**共用同一档**（日间黑 / 夜间白），保证图标不会比文字"重"或"轻" */
  private fgColor(): ResourceColor {
    return this.nightStyle ? 'rgba(248, 249, 250, 0.88)' : $r('app.string.color_black_88')
  }

  build() {
    Column() {
      Row({
        space:8
      }){
        // ① 优先系统符号（矢量、单色、尺寸严格由 fontSize 统一）
        if (this.symbol) {
          SymbolGlyph(this.symbol)
            // 与文字行高（22）协调：14 号字配 18 号图标，视觉重量相当
            .fontSize(18)
            // 与文字同色（日间黑 / 夜间白）—— 见 fgColor()
            .fontColor([this.fgColor()])
        } else if (this.icon) {
          // ② 兼容旧 SVG（`Header` 的旧调用点）
          Image(this.icon)
            .width(ImageConstants.IMG_WIDTH_20)
            .height(ImageConstants.IMG_HEIGHT_20)
            .fillColor(this.fgColor())
        }

        Text(this.title)
          .font({
            size:FontConstants.FONT_SIZE_14,
            weight:FontConstants.FONT_WEIGHT_400,
            family:CommonConstants.FAMILY_PingFANG
          })
          .fontColor(this.fgColor())
          .lineHeight(TextConstants.TEXT_LINE_HEIGHT_22)
      }
      .border({
        style: BorderStyle.Solid,
        width: { bottom: this.isBorder ? 1 : 0 },
        color: this.nightStyle ? 'rgba(248, 249, 250, 0.14)' : '#f5f5f5'
      })
      .padding({
        top:PaddingConstants.PADDING_12,
        bottom:PaddingConstants.PADDING_12})
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .padding({
      left:PaddingConstants.PADDING_20,
      right:PaddingConstants.PADDING_20,})
  }
}
