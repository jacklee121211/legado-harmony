import { display } from '@kit.ArkUI'
/**
 * 阅读设置面板弹窗（2026-09-23 从"底栏胶囊内换内容"改成 `@CustomDialog`）。
 *
 * ── 为什么改 ──────────────────────────────────────────────────────────────
 * 用户真机反馈：「听书的效果不错，但是设置没有效果，点击就是正常出现」，并且
 * 「听书除了听书弹窗以外会有个**全局变暗的遮罩**，但是设置不会」。
 * 根因（代码定位）：设置原本**不是出入场**，只是同一个底栏胶囊里把"进度行"换成"设置行"
 *   （旧代码 `if (!this.isShowContentSetting) { 进度行 } else { 设置行 }`）
 * ⇒ ① 只能是硬切，没有可加转场的"出现/消失"；② 遮罩来自 `@CustomDialog` 的默认
 *   `maskColor`（SDK `component/custom_dialog_controller.d.ts:158-169` 原文
 *   「Custom mask color. Default value: **0x33000000**」），页内胶囊自然没有。
 * ⇒ 改成 `@CustomDialog` 后三项一次到位：**真材质 + 默认遮罩 + 弹簧出入场**，
 *   与「目录 / 书签」「听书」「睡眠定时」三个弹窗完全同款。
 *
 * ── 内容怎么进来的：`@BuilderParam`，**不是**搬代码 ─────────────────────────
 * 设置 UI（亮度/字号/行距/档位/标定/翻页…）仍写在 `ReaderPage3` 的 `@Builder
 * ReaderSettingContent()` 里，由本弹窗用 `@BuilderParam content` 接收。
 * 官方 FAQ（documentId `FAQ/UI框架/组件使用/BuilderParam如何接收父组件的状态变量/faqs-arkui-826`）原文：
 *   「使用 @BuilderParam 装饰器接收父组件传递过来的自定义构建函数，并且在子组件中调用
 *    `this.customView()` 就能看到父组件的自定义内容，**状态变量改变时也能更新**。」
 *   （父组件侧写法必须是箭头函数：`content: () => { this.ReaderSettingContent() }`）
 * ⇒ 字号/行距/亮度滑条的实时刷新由**页面自己**的状态驱动，不需要任何 `@Link` 透传。
 *
 * ⚠️ 这一层是本弹窗与「听书面板」的**关键结构差异**，不要照抄听书的做法：
 *   听书面板的 UI 在**独立组件** `TtsControlPanel` 里，属于弹窗 builder 的参数字段，
 *   受 SDK `custom_dialog_controller.d.ts:60-61` 约束
 *   「To listen for data changes in the builder, use the **@Link or @Consume** decorator;
 *     other decorators, such as **@Prop and @ObjectLink, do not apply**.」
 *   ⇒ 那份数据必须走 `@Link`。
 *   本弹窗的 UI 挂在**页面**的 `@Builder` 上（弹窗只负责"框 + 材质 + 遮罩 + 动画"），
 *   不经过 builder 参数字段 ⇒ 不受该约束。（同款先例：`componets/common/Dialog.ets`
 *   的 `@BuilderParam child`，`IndexShelf` 用它把「网址导入」输入框塞进弹窗。）
 */

/** 弹窗底边离系统底部安全区的留白（vp）—— 与听书/底部页签条同口径 */
export const SETTING_DIALOG_BOTTOM_GAP: number = 10


@CustomDialog
export struct ReaderSettingDialog {
  /** 由 `CustomDialogController` 注入（`@CustomDialog` 必需字段） */
  controller?: CustomDialogController

  /**
   * 设置面板内容（来自页面 `ReaderPage3.ReaderSettingContent()`）。
   * 传法必须用箭头函数闭包，见文件头 FAQ 依据。
   */
  @BuilderParam content: () => void

  /**
   * 弹窗内容最大高度（vp）＝ 屏幕高的 70%。
   * 2026-09-25 用户反馈：「底部这一行按钮**溢出弹窗了**，并且**没法上下拖拽**」
   *   （小屏/大字号设备内容总高超过屏幕）。⇒ 内容包进 Scroll：
   *   · 内容不足上限 ⇒ Scroll 高度=内容高度，观感与原来完全一致（"高度够的直接锁定"）；
   *   · 内容超出上限 ⇒ 上限封顶 + 内部上下滚动（"需要有上拉支持"）。
   */
  private maxContentH(): number {
    try {
      const d = display.getDefaultDisplaySync();
      const vpH = d.height / d.densityPixels;
      // 用户五轮反馈：「点击自定颜色后，最好是高度增加适配屏幕，而不是不变高度让用户上拉」
      // ⇒ 上限放宽到"屏高 − 顶部安全区 − 底部页签条/留白（约 180vp）"，
      //    弹窗随内容长高；只有真放不下才内部滚动（上拉是无奈之举）。
      const h = vpH - 180;
      return Math.max(400, Math.round(h));
    } catch (e) {
      return 640;
    }
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          if (this.content) {
            this.content()
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: this.maxContentH() })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    // 高度**由内容决定**（与听书面板同款）：弹窗 options 里不写 height ⇒ 高度 = 内容节点高度，
    // 但被上面 Scroll 的 maxHeight 封顶（超出即内部滚动）。
    // SDK `custom_dialog_controller.d.ts:126` 原文：「If the width and height of the dialog box are
    // not set, the dialog box … adapts its height to the custom content node.」
    // ⚠️ 刻意**不写 `height('100%')`**：那会按父容器上限解析（听书面板踩过这个坑）。
  }
}
