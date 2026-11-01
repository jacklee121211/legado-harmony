import { ThemeStorageKey } from "../../common/constants/Theme"
import { Haptics } from '../../common/utils/Haptics'
import { ThemeItem } from "../../common/model/Theme"
import { NightMode } from "../../common/utils/NightMode"

/**
 * 四选项确认弹窗（2026-11-02 新增）。
 *
 * ── 为什么需要第四个键 ────────────────────────────────────────────────────
 * 用户原话：「在**解散、删除、取消**之前，加一个**恢复显示**」。
 * 被隐藏的分组同时存在四种处置：恢复显示 / 解散 / 删除 / 取消；
 * 既有的 `ThreeActionDialog` 只有三个按钮位，硬塞第四个会把它们的布局改坏。
 * 按「新增能力不改造既有公共组件」的惯例，单独开一个四键组件，
 * 样式与 `ThreeActionDialog` **逐项对齐**（同一套标题 20/600、说明 14/400、
 * 圆角 15 胶囊按钮、主题色/次色/夜间文字色口径），保证观感一致。
 *
 * ── 按钮语义由调用方决定（本组件不猜业务）─────────────────────────────────
 * 渲染顺序固定为：option1 → option2 → option3 → 取消；
 * 宿主通过 `onOption1/2/3/onCancel` 接线，关闭权在本组件（先 `close()` 再回调）。
 *
 * ⚠️ 属于规范 §4.3 的「二级短确认框」：允许叠放在父弹窗之上。
 */
@CustomDialog
export default struct FourActionDialog {

  controller?: CustomDialogController

  /** 第一项（如「恢复显示」）—— 主题色实底白字，代表"推荐/正向"动作 */
  @Prop option1Text: string = '恢复显示'
  /** 第二项（如「解散」）—— 次色底主题字 */
  @Prop option2Text: string = '解散'
  /** 第三项（如「删除」）—— 次色底主题字（危险项放这里） */
  @Prop option3Text: string = '删除'
  /** 取消文案 */
  @Prop cancelText: string = '取消'

  @Prop title: string = ''
  /** true ⇒ 原样渲染标题（用于「「XX」要怎么处理？」这类问句） */
  @Prop rawTitle: boolean = false
  /** 说明第一行（空串 = 不渲染） */
  @Prop hintPrimary: string = ''
  /** 说明第二行（空串 = 不渲染） */
  @Prop hintSecondary: string = ''
  /** 说明第三行（空串 = 不渲染） */
  @Prop hintTertiary: string = ''

  onOption1: () => void = () => {
  }
  onOption2: () => void = () => {
  }
  onOption3: () => void = () => {
  }
  onCancel: () => void = () => {
  }

  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

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

      if (this.hintPrimary.length > 0 || this.hintSecondary.length > 0 || this.hintTertiary.length > 0) {
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
          if (this.hintTertiary.length > 0) {
            Text(this.hintTertiary)
              .fontColor(this.hintColor())
              .fontSize(14).fontWeight(400).lineHeight(22)
              .textAlign(TextAlign.Center)
          }
        }
        .padding({ left: 20, right: 20 })
      }

      // 四键一行：字号 15 + 左右内边距 12，保证 1320px 宽的设备上不折行
      Row({ space: 8 }) {
        Text(this.option1Text)
          .onClick(() => {
            Haptics.tap()
            this.controller?.close()
            this.onOption1()
          })
          .fontSize(15)
          .borderRadius(15)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .fontColor(Color.White)
          .backgroundColor(this.theme.mainColor)
        Text(this.option2Text)
          .onClick(() => {
            Haptics.tap()
            this.controller?.close()
            this.onOption2()
          })
          .fontSize(15)
          .borderRadius(15)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
        Text(this.option3Text)
          .onClick(() => {
            Haptics.tap()
            this.controller?.close()
            this.onOption3()
          })
          .fontSize(15)
          .borderRadius(15)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
        Text(this.cancelText)
          .onClick(() => {
            Haptics.tap()
            this.controller?.close()
            this.onCancel()
          })
          .fontSize(15)
          .borderRadius(15)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
      }.padding({ top: 20, bottom: 20 })
    }
  }
}
