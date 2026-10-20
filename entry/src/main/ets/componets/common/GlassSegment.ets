/**
 * 分段控件（2026-10-20 新增，同日三修：**放弃真沉浸光感，改用玻璃方案**）。
 *
 * ══ 结论先行：为什么必须放弃 `backgroundSystemMaterial` ═══════════════════════
 * 官方 FAQ（documentId `开发指南/…/沉浸光感/沉浸光感常见问题/arkts-immersive-light-sense-faq`）
 * 「为组件设置了沉浸式系统材质但看不到材质效果 → 组件不在沉浸光感生效范围」原文：
 *
 *   > 沉浸光感开启后，
 *   > · 指定弹窗类组件（AlertDialog、ActionSheet、CustomDialog、…）的沉浸光感效果可在全页面生效。
 *   > · 指定弹窗类接口（PromptAction、Popup控制、Tips控制、菜单控制、半模态转场）…可在全页面生效。
 *   > · **Slider、Toggle、Select** 的沉浸光感效果可在全页面生效。
 *   > · **其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中
 *   >   barPosition 为 BarPosition.End 的底部 TabBar 中生效。在其他区域中设置沉浸光感效果不生效。**
 *   >
 *   > 解决措施：…**若无法满足生效范围要求，可改用 backgroundColor 等通用属性替代材质效果。**
 *
 * ⚠️ 「全页面生效」白名单里**只有 Slider / Toggle / Select，没有 SegmentButton**。
 *    我们 dock 能成功，是因为 `HdsTabs` 用了 `barPosition: BarPosition.End` 的底部 TabBar
 *    —— 正好命中白名单。而书架顶栏 / 主题页三档开关都**不在**这个范围。
 *    真机日志也会打印：`Material inactive: out of scope. Use component in navigation
 *    title bar or Tabbar.`
 *
 * ⇒ 三修做法：**不再传 `backgroundSystemMaterial`**（传了也是白传，还会因为
 *   "材质与背景色互斥"把背景色让掉 ⇒ 组件变**全透明**，正是用户截图看到的现象）。
 *   改用官方推荐的替代方案：`backgroundEffect`（半径/染色都自己给，观感最接近光感）
 *   + 选中项独立胶囊。
 *
 * ══ 三修前两版为什么失败（留档，别重复试错）══════════════════════════════════
 * · 一版：只传 `backgroundSystemMaterial` + `backgroundBlurStyle` ⇒ 材质越界不生效，
 *   而 blur 又被"材质优先"规则压住 ⇒ 灰白无质感。
 * · 二版：为让材质透出来把 `backgroundColor` 设成 `Color.Transparent`
 *   ⇒ 材质仍然不生效（越界），背景又没了 ⇒ **全透明**（用户截图）。
 * · 三版（本版）：不依赖材质，自己画。
 *
 * ══ 观感配方（与书架三胶囊/底部 dock 同一套语言）════════════════════════════
 * · 整条底：`backgroundEffect(ImmersiveMaterialUtil.glassOptions())` —— 可调玻璃，
 *   配方唯一真源，与书架其它胶囊逐字一致；
 * · 选中项：独立胶囊（半透明白/黑 + 主题色文字），带 `UiMotion.CLICK` 按压反馈；
 * · 未选中：透明底、次级文字色。
 *
 * ══ 一键回退 ═══════════════════════════════════════════════════════════════
 * 若将来 ArkUI 把 SegmentButton 纳入全页面生效白名单（或我们把它放进 TabBar），
 * 把 `USE_SYSTEM_MATERIAL` 改回 `true` 即可恢复官方组件路径 —— 那段代码保留在下方。
 */
import { Haptics } from '../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil'
import { NightMode } from '../../common/utils/NightMode'

/**
 * 是否走官方 `SegmentButton` + `backgroundSystemMaterial` 路径。
 *
 * ⚠️ 当前**刻意不用**：官方 FAQ 明确 SegmentButton 不在"全页面生效"白名单内，
 *   在书架顶栏传材质只会导致组件变透明（已真机验证两次：一版灰白、二版全透明）。
 *   只有在把它放进 `Navigation` 标题栏 / `Tabs` 底部 TabBar 时才应启用。
 *
 * 启用方式（保留的官方路径，二版实现要点，供将来搬位置时复用）：
 * ```ts
 * SegmentButtonOptions.capsule({
 *   buttons: items, multiply: false,
 *   backgroundColor: Color.Transparent,        // 让材质透出来
 *   selectedBackgroundColor: 'rgba(255,255,255,0.62)', // 不设会变系统蓝
 *   fontColor, selectedFontColor,
 *   backgroundSystemMaterial: ImmersiveMaterialUtil.segmentMaterial(),
 *   // ⚠️ 不要同时设 backgroundBlurStyle —— 会盖住材质
 * })
 * ```
 * 另注意：`selectedIndexes` 是 `@Link number[]`，`options` 重建会重挂节点导致
 * "点了有反应但按钮不跟手"（日志 `Find customNode by self: SegmentButtonItemArrayComponent`
 * 高频刷屏即此）⇒ 必须按文案内容签名判重，不能每帧重建。
 */
// const USE_SYSTEM_MATERIAL: boolean = false

@Component
export struct GlassSegment {
  /** 文案数组（顺序即显示顺序） */
  @Prop @Watch('onLabelsChanged') labels: string[] = []
  /**
   * 当前选中下标（0 起）。父组件用 `@State` 持有，本组件只回调 `onChange`。
   *
   * ⚠️⚠️ 2026-10-20 关键修复（真机 bug：「点击后功能有效，但按钮不切换」）：
   *   根因是**两个问题叠加**，都已修：
   *   ① `@Prop selected` **没有挂 `@Watch`** ⇒ `onSelectedChanged()` 从不被调用
   *      ⇒ `@State curIndex` 永远停在 `aboutToAppear` 的初值（"卡在自动"就是这么来的）。
   *   ② `@Builder` 内部直接读 `@Prop` 不建立可靠的刷新依赖
   *      （`@Builder` 不是独立组件，表达式只在宿主 build 时求值）
   *      ⇒ 必须复制到 `@State`，由 `@State` 驱动样式。
   *   ⇒ 现在：`@Prop @Watch('onSelectedChanged') selected` + `@State curIndex` 双保险。
   */
  @Prop @Watch('onSelectedChanged') selected: number = 0
  /** 选中下标的本地副本（`@State` ⇒ 保证 UI 一定跟着变） */
  @State private curIndex: number = 0
  /** 选中项变化回调（父组件在回调里更新自己的 @State） */
  onChange: (index: number) => void = (_i: number): void => {}
  /** 未选中文字色 */
  @Prop fontColor: ResourceColor = $r('app.color.text_secondary')
  /** 选中文字色 */
  @Prop selectedFontColor: ResourceColor = $r('app.color.text_primary')

  /** 每个按钮独立的 Q弹缩放（规范 §1：每键独立状态，不能用下标驱动） */
  @State private scales: number[] = []

  // ── 2026-10-21：滑动手势相关状态已移除 ──────────────────────────────────
  // 用户澄清：「滑动**书籍区域**，而不是那个开关」。手势改由内容区承载
  // （`BookBodyContent` 的 PanGesture），本组件回归纯点击控件。
  aboutToAppear(): void {
    this.curIndex = this.normalize(this.selected)
    this.resetScales()
  }

  /**
   * `@Prop selected` 变了 ⇒ 同步到 `@State curIndex`（驱动 UI）。
   * 这是"父组件改选中态 → 按钮高亮跟着动"的**唯一可靠链路**，理由见 `selected` 的注释。
   */
  onSelectedChanged(): void {
    const next: number = this.normalize(this.selected)
    if (this.curIndex !== next) {
      this.curIndex = next
    }
  }

  /** `@Prop labels` 变了 ⇒ 重置每键缩放数组（长度要对齐） */
  onLabelsChanged(): void {
    this.resetScales()
  }

  private resetScales(): void {
    const next: number[] = []
    for (let i = 0; i < this.labels.length; i++) {
      next.push(1)
    }
    this.scales = next
  }

  /** 把外部传进来的下标收敛到合法范围（防越界导致高亮全灭） */
  private normalize(index: number): number {
    if (this.labels.length === 0) {
      return 0
    }
    return (index >= 0 && index < this.labels.length) ? index : 0
  }

  private isActive(index: number): boolean {
    // 用 `@State curIndex` 判活，不用 `@Prop selected`（理由见 selected 的注释）
    return this.curIndex === index
  }

  /** 选中胶囊底色：半透明白/黑（压在主题渐变上呈现"玻璃选中块"） */
  private pillBg(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.22)' : 'rgba(255, 255, 255, 0.66)'
  }

  @Builder
  Chip(label: string, index: number) {
    Text(label)
      .fontSize(15)
      .fontWeight(this.isActive(index) ? 600 : 400)
      .fontColor(this.isActive(index) ? this.selectedFontColor : this.fontColor)
      .textAlign(TextAlign.Center)
      // ★ 2026-10-21：**恢复 `layoutWeight(1)`**。
      //   上一版我给死 `width(88)`，导致整条 = 88*3+4+8 = 276vp，
      //   而可用宽度只有约 214vp ⇒ 把右侧图标胶囊**挤出屏幕**（用户截图实证）。
      //   ⇒ 回到 `layoutWeight(1)`：三格**等分父容器给它的宽度**，
      //     父容器宽度由 `BookBodyContent` 的 `layoutWeight(1)` + 右 padding 决定
      //     ⇒ 自适应任何屏宽，且绝不溢出。
      .layoutWeight(1)
      .height(34)
      .borderRadius(17)
      // 选中项：独立胶囊；未选中：完全透明（让整条玻璃透上来）
      .backgroundColor(this.isActive(index) ? this.pillBg() : Color.Transparent)
      .scale({
        x: this.scales.length > index ? this.scales[index] : 1,
        y: this.scales.length > index ? this.scales[index] : 1
      })
      .clickEffect(UiMotion.CLICK)
      .onClick(() => {
        Haptics.tap()
        runJellyClick((v: number) => {
          const next: number[] = this.scales.slice()
          if (index < next.length) {
            next[index] = v
            this.scales = next
          }
        })
        // 只回调，选中态由父组件持有（@Prop 单向，改了也不生效）
        this.onChange(index)
      })
  }

  build() {
    // 整条背板：与书架三胶囊/底部 dock 同一款可调玻璃（配方唯一真源）
    Row({ space: 2 }) {
      ForEach(this.labels, (label: string, index: number) => {
        this.Chip(label, index)
      }, (label: string, index: number): string => 'seg_' + index + '_' + label)
    }
    // ★ 2026-10-21：**必须 `width('100%')`**，占满父容器给的宽度。
    //   上一版改成 `constraintSize({maxWidth:320})` + chip 固定宽 ⇒ 整条 276vp 超宽，
    //   把右侧图标胶囊挤出屏幕（用户截图实证）。
    //   ⇒ 恢复 100%：父容器（`BookBodyContent` 的左侧 Column）用 `layoutWeight(1)`
    //     分配宽度，本组件跟着它走 ⇒ 屏宽自适应、绝不溢出。
    //   "让开关变窄"的正确手段在**父层**：给右侧图标胶囊留出固定宽度 +
    //     给中间留一个 `Blank()` 间隙（见 `BookBodyContent`），而不是在这里写死宽度。
    .width('100%')
    .padding(4)
    .borderRadius(21)
    .backgroundEffect(ImmersiveMaterialUtil.glassOptions())
    // ★ 2026-10-20：**固定总高 42vp**，供右侧图标胶囊对齐（见 BookBodyContent 同款注释）。
    //   构成：外层 padding 4×2 + 内部 chip 34 = 42。
    //   ⚠️ 不要靠 padding 凑高度 —— 会随字体缩放漂移；固定值才能保证两行严格等高。
    .height(42)
    // ── 2026-10-21：**滑动手势已撤掉** ──────────────────────────────────────
    // 用户原话：「滑动切换你理解错了，你先恢复之前的，我的意思是**滑动书籍区域**，
    //   而不是那个开关，做到自然切换。」
    // ⇒ 滑动切换改由 `BookBodyContent` 的**内容区**承载（见那边的 PanGesture），
    //   本组件回归纯点击控件。这样在书籍列表/宫格上左右滑才生效，且不干扰开关本身。
  }
}
