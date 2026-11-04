import { ReaderCustomBg } from '../../../common/utils/ReaderCustomBg'
import { ReaderBgPalette } from './ReaderBgPalette'
import { Haptics } from '../../../common/utils/Haptics'
import { HapticTick } from '../../../common/utils/HapticTick'
import UiMotion from '../../../common/utils/UiMotion'

/**
 * 阅读设置面板里的「自定义颜色」区块（2026-11-04 渲染侧 R-2-b：从
 * `ReaderPage3.ets` 的 `@Builder ReaderSettingContent()` 抽出）。
 *
 * ── 方案 i：**草稿真值留在页面**（这是取证后的结论，不是妥协）──────────────
 * 调色盘草稿 `customBgR/G/B` + `customFontR/G/B` 共有 **6 个页面级写入方**
 * （`setDraft()`、`enterFreeMode()`、应用已保存方案、`restorePrevBackground()`、
 * `restoreCustomBg()` 两条分支）与 **6 个页面级读取方**（`customBgHex()/customFontHex()`
 * 落盘、`customBgRecord()` 持久化、`applyFreeColor` 回退、`applyCustomBg` 生效），
 * 横跨「记录恢复 / 方案应用 / 落盘 / 引擎下发」四条链路。
 * 若把草稿搬进组件（方案 ii），这 12 处全要改造成"组件↔页面"双向管道，
 * 且 6 个播种点与 `ReaderBgRecord` 的解析顺序强耦合 —— 漂移的表现就是
 * "进书看到的颜色和上次保存的不是同一个"。⇒ 草稿用 `@Link` 双向共享，
 * **组件只负责画 + 把手指的值写进草稿**；生效/落盘/播种全在页面。
 *
 * ── 各参数的归属 ───────────────────────────────────────────────────────────
 * · `@Link`（双向，页面持有真值）：6 个 RGB 草稿 + `fontTarget`（背景/文字编辑目标）；
 * · 普通成员（组件内自管，离开本块就没有意义）：气泡显隐 `tipCh`、滑条轨道宽 `sliderW`；
 * · `onToggleCustom` / `onOpenVip` / `onCommit` / `onSliderFeedback`：回调（副作用在页面）；
 * · `@Prop`（单向只读）：`colorMode`（配色）、`editVisible`（显隐）、`focused`（保存后持圈）、
 *   `isVip`（会员才显示真开关）。
 *
 * ── 与抽前逐节点一致的验收方式 ────────────────────────────────────────────
 * 开关展开 → 拖 RGB 滑条（只改草稿不动屏幕）→ 按「保存」才生效 —— 四步真机路径
 * 见施工记录 §92.4；`customEditVisible()` 为 false 时本块第一行仍显示
 * （用户四轮反馈："自定义颜色关闭的时候，颜色预览以及保存按钮都没被隐藏"是指
 *   预览+保存跟着编辑态走，标签行永远在）。
 *
 * 回退：删本文件，把 `ReaderPage3` 里的 `ReaderCustomColorBlock({...})` 调用换回原来的内联
 * `Column`（原代码在该提交的 diff 里，`git revert` 即可）。
 */
@Component
export struct ReaderCustomColorBlock {
  // ── 草稿（@Link：页面持有真值，双向同步）──────────────────────────────────
  @Link customBgR: number
  @Link customBgG: number
  @Link customBgB: number
  @Link customFontR: number
  @Link customFontG: number
  @Link customFontB: number
  /** 编辑目标：false = 背景 / true = 文字（原 `this.fontTarget`，页面多处读它） */
  @Link fontTarget: boolean

  // ── 显示态（@Prop：单向只读）──────────────────────────────────────────────
  /** 面板配色基准：0 = 夜间 / 1 = 日间（原 `this.colorMode`） */
  @Prop colorMode: number = 1
  /** 是否显示调色盘/预览行（原 `this.customEditVisible()`，页面算好传进来） */
  @Prop editVisible: boolean = false
  /** 预览块是否持橙圈（原 `this.isCustomBgFocused()`） */
  @Prop focused: boolean = false
  /** 会员开关（免费用户显示锁定假开关，点击弹 VIP） */
  @Prop isVip: boolean = false

  // ── 回调（副作用一律回页面）───────────────────────────────────────────────
  /** 自定义颜色开关被拨动（原 `this.toggleCustomBg(value)`） */
  onToggleCustom: (on: boolean) => void = (_on: boolean): void => {}
  /** 免费用户点了锁定开关（原 `this.openVipDialog()`） */
  onOpenVip: () => void = (): void => {}
  /** 按「保存」（原 `this.commitCustomColor()`：应用 + 落盘 + 持焦，逻辑全在页面） */
  onCommit: () => void = (): void => {}

  // ── 组件内自管（离开本块无意义）───────────────────────────────────────────
  /** 正在拖动的滑条通道（0=R 1=G 2=B，-1=无）—— 气泡显隐 */
  @State tipCh: number = -1
  /** 轨道实测宽度（vp），气泡定位用（原 `this.bgSliderW`，只有 R 条测了宽度） */
  private sliderW: number = 0

  /** 当前编辑目标的草稿 R（原 `this.draftR()`） */
  private draftR(): number {
    return this.fontTarget ? this.customFontR : this.customBgR
  }

  private draftG(): number {
    return this.fontTarget ? this.customFontG : this.customBgG
  }

  private draftB(): number {
    return this.fontTarget ? this.customFontB : this.customBgB
  }

  /** 草稿写入收口（原 `this.setDraft()`，按 fontTarget 分流） */
  private setDraft(r: number, g: number, b: number): void {
    if (this.fontTarget) {
      this.customFontR = r
      this.customFontG = g
      this.customFontB = b
    } else {
      this.customBgR = r
      this.customBgG = g
      this.customBgB = b
    }
  }

  /** 草稿 → #RRGGBB（预览块与色值文本用；页面侧同名方法保留给落盘链路） */
  private draftHex(): string {
    return this.fontTarget
      ? ReaderCustomBg.hexOf(ReaderCustomBg.make(this.customFontR, this.customFontG, this.customFontB))
      : ReaderCustomBg.hexOf(ReaderCustomBg.make(this.customBgR, this.customBgG, this.customBgB))
  }

  /** 滑条轨道色（原 `this.sliderSelectedColor()`） */
  private sliderTrackColor(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.16)' : 'rgba(0, 0, 0, 0.04)'
  }

  /**
   * 气泡 x 定位（原 `this.bgTipX()`）。算法照抄官方 FAQ `faqs-arkui-1198` 的
   * `calculateExactPosition`：滑块中心 = 百分比 × (轨道宽 − 滑块宽) + 滑块宽 / 2；
   * 气泡 x = clamp(滑块中心 − 气泡宽/2, 0, 轨道宽 − 气泡宽)。
   */
  private tipX(value: number): number {
    const w = this.sliderW
    if (!(w > 0)) {
      return 0
    }
    const blockW = 22
    const tipW = 44
    const percent = ReaderCustomBg.clamp(value, 0, 255) / 255
    const center = percent * (w - blockW) + blockW / 2
    return Math.max(0, Math.min(center - tipW / 2, w - tipW))
  }

  /** 单条 RGB 滑条 + 气泡（R/G/B 三条同构，抽成 @Builder 消重） */
  @Builder
  private SliderRow(label: string, channel: number) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(12)
        .width(14)
        .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
      Stack() {
        Slider({
          value: channel === 0 ? this.draftR() : (channel === 1 ? this.draftG() : this.draftB()),
          min: 0,
          max: 255,
          step: 1,
          style: SliderStyle.InSet
        })
          .selectedColor(this.sliderTrackColor())
          .blockSize({ width: 22, height: 22 })
          .borderRadius(20)
          .padding({ left: 6, right: 6 })
          .width('100%')
          .showTips(false)
          // 取轨道实测宽度（vp）给气泡定位用；`Area.width` 的官方说明见
          // `…\ets\component\common.d.ts:20062`（`onAreaChange`）。只有 R 条需要测（气泡 x 共用）。
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            this.sliderW = Number(newArea.width)
          })
          .onChange((value: number, mode: SliderChangeMode) => {
            // 与抽前逐字一致：滑条上既有 `Haptics.tick()`（原内联）也有 `HapticTick.tick()`
            // （原 `onCustomBgSliderChange()` 末尾），两条都保留，不擅自"去重"。
            Haptics.tick()
            HapticTick.tick()
            const v = Math.round(value)
            if (channel === 0) {
              this.setDraft(v, this.draftG(), this.draftB())
            } else if (channel === 1) {
              this.setDraft(this.draftR(), v, this.draftB())
            } else {
              this.setDraft(this.draftR(), this.draftG(), v)
            }
            const dragging: boolean = mode === SliderChangeMode.Begin
              || mode === SliderChangeMode.Moving
              || mode === SliderChangeMode.Click
            this.tipCh = dragging ? channel : -1
          })
        if (this.tipCh === channel) {
          Text(`${channel === 0 ? this.draftR() : (channel === 1 ? this.draftG() : this.draftB())}`)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .backgroundColor('#007DFF')
            .borderRadius(6)
            .width(44)
            .textAlign(TextAlign.Center)
            .padding({ top: 3, bottom: 3 })
            .position({ x: this.tipX(channel === 0 ? this.draftR() : (channel === 1 ? this.draftG() : this.draftB())), y: -26 })
            // 气泡只负责显示，绝不能吃掉落手指（否则滑条拖不动）
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .layoutWeight(1)
      Text(`${channel === 0 ? this.draftR() : (channel === 1 ? this.draftG() : this.draftB())}`)
        .fontSize(12)
        .width(30)
        .textAlign(TextAlign.End)
        .fontColor('#007DFF')
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text('自定义颜色')
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        // ── 自定义颜色开关（进入/退出自定义颜色模式），紧贴标签（用户指定）────
        if (this.isVip) {
          Toggle({ type: ToggleType.Switch, isOn: this.editVisible })
            .selectedColor('#007DFF')
            .onChange((value: boolean) => {
              Haptics.tap();
              this.onToggleCustom(value)
            })
        } else {
          // 会员化（2026-09-28）：免费用户看到锁定样式的假开关，点击 → VIP 弹窗
          //（不用真 Toggle：避免"点了先弹开又弹回"的视觉回弹问题）
          Stack({ alignContent: Alignment.End }) {
            Row()
              .width(40)
              .height(22)
              .borderRadius(11)
              .backgroundColor('rgba(128, 128, 128, 0.45)')
            Row()
              .width(18)
              .height(18)
              .borderRadius(9)
              .backgroundColor(Color.White)
              .margin({ right: 2 })
          }
          .onClick(() => {
            Haptics.tap();
            this.onOpenVip()
          })
        }
        // 调色盘相关区块的显隐：**已应用**或**展开编辑中**都显示
        if (this.editVisible) {
          Blank()
          // ── "背景 / 文字"滑块：切调色盘的编辑目标（用户口中的"通过滑块切换"）────
          Text('背景')
            .fontSize(12)
            .fontColor(!this.fontTarget ? '#007DFF'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)'))
          Toggle({ type: ToggleType.Switch, isOn: this.fontTarget })
            .selectedColor('#007DFF')
            .onChange((value: boolean) => {
              Haptics.tap();
              this.fontTarget = value
            })
          Text('文字')
            .fontSize(12)
            .fontColor(this.fontTarget ? '#007DFF'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.editVisible) {
        Row({ space: 10 }) {
          // ── 预览块 = 当前编辑目标（背景/文字）的草稿色；「保存」确认后持橙圈 ──
          Column()
            .width(22)
            .height(22)
            .borderRadius(11)
            .backgroundColor(this.draftHex())
            .borderWidth(this.focused ? 2 : 1)
            .borderColor(this.focused
              ? '#ff6600'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.35)' : 'rgba(0, 0, 0, 0.25)'))
          Text(this.draftHex())
            .fontSize(12)
            .fontColor(this.focused
              ? '#ff6600'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)'))
          Blank()
          // ── 保存按钮（用户指定放右端）：确认草稿 = 应用 + 落盘 + 持焦 ─────────
          Button('保存')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#007DFF')
            .borderRadius(18)
            .height(34)
            .padding({ left: 14, right: 14 })
            .clickEffect(UiMotion.CLICK)
            .onClick(() => {
              Haptics.tap();
              this.onCommit()
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (this.editVisible) {
        // 左：无极调色盘（横向色相 × 纵向明暗的连续色域，任意点都能取到确定颜色）
        // 右：R / G / B 三条 0-255 滑块（与字号/行距同款 Slider，带气泡 + 线性震动）
        // ⚠️ 2026-09-25 保存键方案：调色盘/滑条**只写草稿**（按 fontTarget 分流），
        //    不碰引擎 —— 按「保存」才应用。草稿存哪（背景 or 文字）由 setDraft 收口。
        Row({ space: 14 }) {
          ReaderBgPalette({
            paletteR: this.draftR(),
            paletteG: this.draftG(),
            paletteB: this.draftB(),
            onPick: (r: number, g: number, b: number): void => {
              this.setDraft(r, g, b)
            },
            onCommit: (): void => {
              // 抬手不做任何"生效"—— 确认权在「保存」按钮（用户最终裁定）
            }
          })

          Column({ space: 4 }) {
            // ── 气泡：为什么**不用**系统 `Slider.showTips(true, …)` ────────────────
            // 官方 FAQ 原文（documentId `FAQ/UI框架/组件使用/Slider组件自定义气泡开发/faqs-arkui-1198`）：
            //   「**场景二**：动态内容更新需求。……**在滑块滑动过程中，Slider 气泡可动态更新 UI 内容**？」
            //   解决思路原文：「气泡实现方式：可使用 `showTips(false)` **关闭系统气泡**，
            //     选择系统 Popup 组件或自定义组件比如 Text 模拟气泡。」
            // ⇒ 官方把"滑动中气泡内容实时更新"明确归为**需要自己实现**的场景
            //   ⇒ 所以这里按官方方案自己画：`Stack` 层叠 + `Text` 模拟气泡 + `position` 定位。
            this.SliderRow('R', 0)
            this.SliderRow('G', 1)
            this.SliderRow('B', 2)
          }
          .layoutWeight(1)
          // 与左侧色盘同高（色盘 = 116vp），三行在高度内均分 ⇒ 视觉上对齐
          .height(116)
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
  }
}
