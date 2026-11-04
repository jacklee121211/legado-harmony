import UiMotion from '../../../common/utils/UiMotion'

/**
 * 阅读设置面板里的**三个入口按钮行**（2026-11-04 渲染侧 R-2-a：从 `ReaderPage3` 的
 * `@Builder ReaderSettingContent()` 抽出，原区间 `:9194-9262`，共 69 行）。
 *
 * 三个入口：`字体管理` / `更多材质` / `更多方案`。
 *
 * ── 为什么抽这一块（判据，逐条）────────────────────────────────────────────
 * ① **纯视图**：本组件不持有可写状态、不读写 `@State`、不做落盘或下发；
 * ② **依赖单向**：页面 → 组件（3 个入参 + 4 个回调），组件拿不到
 *    `openFontDialog/openTexDialog/openSchemeDialog/openVipDialog` 的实现；
 * ③ **业务门禁仍在页面**：
 *    · `OfflineMode.showReadingEnhancements()`（"精简模式是否显示这三项"）留在页面；
 *    · `VipManager.isVip()`（免费用户点材质/方案 ⇒ 弹 VIP）也留在页面回调里 ——
 *      它属于**业务规则**而不是渲染，且组件不应依赖 `VipManager`；
 * ④ **时序不变**：原来每个 `onClick` 第一句都是 `Haptics.tap()`，本轮由页面侧
 *    `onBeforeAct` 承担，仍是"触感 → 打开弹窗"的同一顺序。
 *
 * ── 为什么根节点是 `Row` 而不是再套一层 Column ──────────────────────────────
 * 原代码就是 `if (…) { Row { 三个 Button } .width('100%')… }`。
 * 组件 build() 的根直接写成那个 `Row`，因此**不会多出布局节点** ⇒
 * 严格 A/B（同一本书、同一阅读方式、同一面板态）的节点树差异必须为 **0**。
 *
 * ── 焦点规则（原注释，随代码一起搬）────────────────────────────────────────
 * · 当前选中材质不在主页前 8 个预览里 ⇒ 材质格圈不到它，橙圈改框在「更多材质」上；
 * · 应用中的方案都住在弹窗里 ⇒ 橙圈框在「更多方案」上。
 *   ⇒ 所以两个按钮各吃一个 `@Prop` 焦点布尔，页面负责算（`isTexOverflowFocused()` / `bgFocus === 'scheme'`）。
 *
 * 回退：删本文件，把 `ReaderPage3` 里的 `ReaderEntryButtonsBlock({...})` 换回原来那段内联 `Row`
 * （原文在本次提交的 diff 里，`git revert` 即可）。
 */
@Component
export struct ReaderEntryButtonsBlock {
  /** 面板配色基准：0 = 夜间 / 1 = 日间（原 `this.colorMode`） */
  @Prop colorMode: number = 1

  /** 「更多材质」橙圈（原 `this.isTexOverflowFocused()`） */
  @Prop texFocused: boolean = false

  /** 「更多方案」橙圈（原 `this.bgFocus === 'scheme'`） */
  @Prop schemeFocused: boolean = false

  /** 触感（原各按钮第一句 `Haptics.tap()`；依赖留在页面，组件不引 Haptics） */
  onBeforeAct: () => void = (): void => {}

  /** 字体管理（原 `this.openFontDialog()`） */
  onFont: () => void = (): void => {}

  /** 更多材质（原 `Haptics.tap(); if (!VipManager.isVip()) { openVipDialog() ; return } openTexDialog()`） */
  onTex: () => void = (): void => {}

  /** 更多方案（原同上，末句 `openSchemeDialog()`） */
  onScheme: () => void = (): void => {}

  build() {
    Row({ space: 16 }) {
      Button('字体管理')
        .fontSize(13)
        .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        .backgroundColor(this.colorMode == 0
          ? 'rgba(248, 249, 250, 0.16)'
          : 'rgba(19, 19, 19, 0.06)')
        .borderRadius(18)
        .height(34)
        .padding({ left: 14, right: 14 })
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          this.onBeforeAct()
          this.onFont()
        })

      Button('更多材质')
        .fontSize(13)
        .fontColor(this.texFocused ? '#ff6600'
          : (this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'))
        .backgroundColor(this.colorMode == 0
          ? 'rgba(248, 249, 250, 0.16)'
          : 'rgba(19, 19, 19, 0.06)')
        // ── 焦点规则（2026-09-25 用户二轮反馈）：当前选中的材质不在主页前 8 个
        //    预览里 ⇒ 材质格圈不到它，橙圈改框在「更多材质」按钮上。
        .borderWidth(this.texFocused ? 1.5 : 0)
        .borderColor('#ff6600')
        .borderRadius(18)
        .height(34)
        .padding({ left: 14, right: 14 })
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          this.onBeforeAct()
          this.onTex()
        })

      Button('更多方案')
        .fontSize(13)
        .fontColor(this.schemeFocused ? '#ff6600'
          : (this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'))
        .backgroundColor(this.colorMode == 0
          ? 'rgba(248, 249, 250, 0.16)'
          : 'rgba(19, 19, 19, 0.06)')
        // ── 焦点规则（2026-09-25 用户三轮反馈）：应用中的方案在这批已存方案里
        //    （方案全部住在弹窗里）⇒ 橙圈框在「更多方案」按钮上。
        .borderWidth(this.schemeFocused ? 1.5 : 0)
        .borderColor('#ff6600')
        .borderRadius(18)
        .height(34)
        .padding({ left: 14, right: 14 })
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          this.onBeforeAct()
          this.onScheme()
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }
}
