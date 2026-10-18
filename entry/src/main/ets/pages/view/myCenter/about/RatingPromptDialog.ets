import { MaterialColumnModifier } from '../../../../common/utils/ImmersiveMaterialUtil'
import { Haptics } from '../../../../common/utils/Haptics'
import { ThemeItem } from '../../../../common/model/Theme'

/**
 * 「喜欢喵阅吗？」评分引导弹窗 —— 应用内评分弹窗的**前置软引导**。
 *
 * ── 为什么需要这一层（而不是直接调 commentManager.showCommentDialog）─────────
 * 系统评分弹窗一旦被拉起，对用户是"无预期"的；官方还带频率硬限制
 * （`commentManager.d.ts` 错误码原文：1021500007 该版本已评论 / 1021500009 已评论不满一年 /
 *   1021500008 评论数达上限）⇒ 直接裸调有相当概率弹出来又被系统拒，用户什么也看不到。
 * 所以先问一句：愿意 → 走系统评分；不愿意 → 引导到"联系我们"反馈，不骚扰。
 *
 * ── 规范遵从（docs/标准-弹窗与按钮统一规范.md）──────────────────────────────
 * §2.1 必须是 @CustomDialog（普通 @Component 进 builder 字段初始化器真机必崩）；
 * §2.3 内容根节点**不设** .backgroundColor()，用 MaterialColumnModifier(..., true) 让出背景，
 *      让调用方 options 的 systemMaterial 透出来；
 * §2.4 本弹窗是**内容自适应的短弹窗**，调用方 options 不给 height（给了反而撑满）。
 *
 * ⚠️ 2026-10-12 教训（见 `RenameBookDialog.ets:26-33`）：`this.controller?.close()` 在
 * @CustomDialog **子组件内无效**（SDK：只能由创建 controller 的父组件关）⇒
 * 本弹窗**不自己关**，只做「回调请求关闭」，由调用方在回调里 close()。
 * 主按钮配色沿用工程惯例 `theme.mainColor`（与 RenameBookDialog 确定键同源），
 * 不使用不存在的资源名（`resources/base/element/color.json` 里**没有** brand_color）。
 */
@CustomDialog
export default struct RatingPromptDialog {
  controller?: CustomDialogController
  @Prop theme: ThemeItem = {} as ThemeItem
  /** 用户点了「去评分」；调用方负责 close() 并拉起系统评分弹窗 */
  onGoRating: () => void = (): void => {
  }
  /** 用户点了「以后再说」/ 遮罩取消；调用方负责 close() 并记录一次"已拒绝" */
  onLater: () => void = (): void => {
  }
  /** 背板：调用方已通过 options 提供材质 ⇒ 传 `true` 让出背景（依据见类注释 §2.3） */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  build() {
    Column() {
      // ── 头部：标题 + 说明 ─────────────────────────────────────────────
      Column({ space: 8 }) {
        Text('喜欢喵阅吗？')
          .fontSize(18)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
        Text('如果喵阅帮到了你，去应用市场给个好评吧。\n你的每一颗星，都是我们继续更新的动力。')
          .fontSize(14)
          .lineHeight(21)
          .fontColor($r('app.color.text_primary'))
          .opacity(0.6)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 24 })

      // ── 主按钮：去评分 ───────────────────────────────────────────────
      Text('去评分')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(46)
        .borderRadius(23)
        .backgroundColor(this.theme.mainColor)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
        .onClick((): void => {
          Haptics.tap()
          // 只回调，不自己 close（见头部 ⚠️ 教训）
          this.onGoRating()
        })

      // ── 次按钮：以后再说 ─────────────────────────────────────────────
      Text('以后再说')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .opacity(0.5)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(44)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
        .onClick((): void => {
          Haptics.tap()
          this.onLater()
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 4 })
    .borderRadius(20)
    // 兜底圆角 + 材质（材质不可用时自动回落白实底，不会变透明）
    .attributeModifier(this.surface)
  }
}
