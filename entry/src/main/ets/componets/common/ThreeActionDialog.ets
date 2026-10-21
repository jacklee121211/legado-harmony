import { ThemeStorageKey } from "../../common/constants/Theme"
import { Haptics } from '../../common/utils/Haptics'
import { ThemeItem } from "../../common/model/Theme"
import { NightMode } from "../../common/utils/NightMode"

/**
 * 三选项确认弹窗（2026-10-22 新增）。
 *
 * ── 为什么要新开一个组件（而不是复用 `confirmDialog` / `TitleContentDialog`）─────
 * 需求（用户原话）：「我们点击除了未分组以外的其他分组，都是弹窗询问是否删除或者解散
 *   该分组，该弹窗有**三个选项，删除，解散，取消**」。
 * 而工程既有的两个确认框都是**两键**（取消 / 确认）：
 *   · `componets/common/confirmDialog.ets`（`confirmDialogExample`）
 *   · `componets/common/TitleContentDialog.ets`
 * ⇒ 硬塞第三个键只能改它们的布局，会波及全工程十几处调用点。按「新增能力不改造既有
 *   公共组件」的惯例，单独开一个三键组件；样式与上面两个**逐项对齐**（同样的
 *   `Column` + 标题 20/600 + 内容 14/400 + `Row({space:24})` 按钮行 + 圆角 15 胶囊 +
 *   主题色/次色），保证观感与全局一致。
 *
 * ── 按钮语义由**调用方**决定（本组件不猜业务）────────────────────────────────
 * 三个回调 `onPrimary` / `onSecondary` / `onCancel` 由宿主接线；
 * 本组件只负责"点哪个键就关自己 + 回调哪个"，关闭权与既有两个确认框一致
 * （先 `this.controller.close()` 再回调 —— 与 `confirmDialogExample` 同款）。
 *
 * ⚠️ 属于规范 §4.3 的「二级短确认框」：**允许叠放在父弹窗之上**，不执行"父退子进"。
 */
@CustomDialog
export default struct ThreeActionDialog {

  controller?: CustomDialogController

  /** 主操作文案（危险操作，如「删除」）—— 主题色实底白字 */
  @Prop primaryText: string = '删除'
  /** 次操作文案（如「解散」）—— 次色底主题色字 */
  @Prop secondaryText: string = '解散'
  /** 取消文案 */
  @Prop cancelText: string = '取消'
  /**
   * 标题。
   * `rawTitle === false`（默认）⇒ 渲染成「确定{title}吗？」（与工程既有确认框同句式）；
   * `rawTitle === true` ⇒ **原样**渲染（用于「「开心」要怎么处理？」这类问句）。
   */
  @Prop title: string = ''
  @Prop rawTitle: boolean = false
  /**
   * 补充说明的**两行**（空串 = 该行不渲染）。
   *
   * ⚠️ 为什么拆成两个 `@Prop` 而不是一个带 `\n` 的字符串：
   *   两行在视觉上需要不同的强调（第一行是"危险"、第二行是"温和"），
   *   拆开后各自可以用不同颜色，且不依赖 `Text` 对 `\n` 的换行行为。
   */
  @Prop hintPrimary: string = ''
  @Prop hintSecondary: string = ''

  onPrimary: () => void = () => {
  }
  onSecondary: () => void = () => {
  }
  onCancel: () => void = () => {
  }

  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  /** 内容说明的文字色（夜间必须自己翻 —— 沉浸光感材质上黑字不可读，与 TitleContentDialog 同口径） */
  private hintColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.65)' : 'rgba(0, 0, 0, 0.45)'
  }

  build() {
    Column() {
      Text(this.rawTitle ? this.title : `确定${this.title}吗？`)
        .fontWeight(600).fontSize(20).maxLines(2)
        .textAlign(TextAlign.Center)
        .margin({ top: 20, bottom: 10 })
        .padding({ left: 20, right: 20 })

      if (this.hintPrimary.length > 0 || this.hintSecondary.length > 0) {
        Column({ space: 4 }) {
          if (this.hintPrimary.length > 0) {
            Text(this.hintPrimary)
              .fontColor(this.hintColor())
              .fontSize(14).fontWeight(400).lineHeight(22)
              .textAlign(TextAlign.Center)
          }
          if (this.hintSecondary.length > 0) {
            Text(this.hintSecondary)
              .fontColor(this.hintColor())
              .fontSize(14).fontWeight(400).lineHeight(22)
              .textAlign(TextAlign.Center)
          }
        }
        .padding({ left: 20, right: 20 })
      }

      // ── 按钮排列（2026-10-22 二修，用户明确指定顺序）─────────────────────────
      // 用户原话：「点击分组之后的弹窗，现在是取消，解散，删除，这个排序不对，
      //   应该是**解散、删除、取消**」。
      // ⇒ 渲染顺序固定为：次操作（解散）→ 主操作（删除，主题色强调）→ 取消。
      //   ⚠️ 与工程既有两键确认框（`取消 / 确认`）的顺序**不同**，这是本弹窗的特例：
      //     三个动作里"取消"是唯一"什么都不做"的，放最右（远离最危险的"删除"）。
      Row({ space: 12 }) {
        Text(this.secondaryText)
          .onClick(() => {
            Haptics.tap()
            this.controller?.close()
            this.onSecondary()
          })
          .fontSize(16)
          .borderRadius(15)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
        Text(this.primaryText)
          .onClick(() => {
            Haptics.tap()
            this.controller?.close()
            this.onPrimary()
          })
          .fontSize(16)
          .borderRadius(15)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .fontColor(Color.White)
          .backgroundColor(this.theme.mainColor)
        Text(this.cancelText)
          .onClick(() => {
            Haptics.tap()
            this.controller?.close()
            this.onCancel()
          })
          .fontSize(16)
          .borderRadius(15)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
      }.padding({ top: 20, bottom: 20 })
    }
  }
}
