import { CapsuleSegmentButtonV2, SegmentButtonV2Items } from '@kit.ArkUI'

/**
 * 阅读设置面板里的「背景模糊」区块（2026-11-04 渲染侧 R-1：从
 * `ReaderPage3.ets` 的 `@Builder ReaderSettingContent()` 抽出）。
 *
 * ── 为什么抽这一块（判据，逐条）────────────────────────────────────────────
 * ① **纯视图**：本组件不持有任何可写状态，也不做任何副作用（无 `applyTextureBg` /
 *    无 `saveCustomBg` / 无落盘 / 无 `setPageConfig`）—— 只把「开关被拨动」「选了第几档」
 *    两个事实用回调抛回页面；
 * ② **依赖单向**：页面 → 组件（4 个入参 + 2 个回调），组件**从不**回调页面的状态；
 * ③ **时序不变**：原内联 `onChange` 的语句顺序（触感 → 写状态 → 条件换图 → 落盘）
 *    原样搬进页面的回调里，一行未改。
 *
 * ── 为什么状态不进来（关键）─────────────────────────────────────────────────
 * `bgBlurOn` / `bgBlurRadius` 是页面的 `@State`，且**写入后还要触发页面自己的两件事**
 * （`applyTextureBg()` 换图、`saveCustomBg()` 落盘）。若用 `@Link` 把状态搬进组件，
 * 这两件事就得跟着搬 —— 那就变成"状态两个家"。故本组件**只读**（`@Prop`），
 * 写入与副作用一律回页面执行（与 `ReaderSession` 的入参口径同源）。
 *
 * ── `items` 为什么是普通成员而不是 `@Prop` ──────────────────────────────────
 * `SegmentButtonV2Items` 是 `@ObservedV2` 对象，`CapsuleSegmentButtonV2` 收的是它的
 * **引用**。`@Prop` 会深拷贝 ⇒ 每次父组件刷新都会 new 一个等价对象 ⇒ 选中态丢失
 * （页面 `:1942` 注释已记："创建一次挂成员，反复 new 会丢选中态"）。
 * ⇒ 用普通成员（构造期赋值一次、之后不再同步），页面侧 `bgBlurSegItems` 本来就只建一次。
 *
 * ── 视觉与布局必须与抽前逐节点一致 ──────────────────────────────────────────
 * 根节点就是抽前那个 `Column({ space: 8 })`（`.width('100%')` + `HorizontalAlign.Start`），
 * 标签字色三元、Toggle `selectedColor('#007DFF')`、`CapsuleSegmentButtonV2.layoutWeight(1)`
 * 全部照抄。验收方式：同一操作状态下 `uitest dumpLayout` 节点树结构化比对，差异必须为 0
 * （见 `docs/阅读器-设置面板测绘-2026-11-04.md` §4 的基线）。
 *
 * 回退：删本文件，把 `ReaderPage3` 里的 `ReaderBlurBlock({...})` 调用换回原来的内联
 * `Column`（原代码在本次提交的 diff 里，`git revert` 即可）。
 */
@Component
export struct ReaderBlurBlock {
  /** 面板配色基准：0 = 夜间 / 1 = 日间（原 `this.colorMode`） */
  @Prop colorMode: number = 1

  /** 模糊开关当前值（原 `this.bgBlurOn`）；组件只读，写入走 `onToggle` */
  @Prop bgBlurOn: boolean = false

  /**
   * 档位选项（原 `this.bgBlurSegItems`）。
   * ⚠️ 普通成员，**不要**加 `@Prop`（理由见文件头）。
   */
  items: SegmentButtonV2Items = new SegmentButtonV2Items([])

  /** 当前档位下标（原 `this.bgBlurTierIndex()`） */
  @Prop selectedIndex: number = -1

  /** 开关被拨动（原内联 `onChange` 里的整段逻辑，现在在页面执行） */
  onToggle: (on: boolean) => void = (_on: boolean): void => {}

  /** 选了第几档（原内联 `$selectedIndex` 里的整段逻辑，现在在页面执行） */
  onPickTier: (index: number) => void = (_index: number): void => {}

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text('背景模糊')
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        Toggle({ type: ToggleType.Switch, isOn: this.bgBlurOn })
          .selectedColor('#007DFF')
          .onChange((value: boolean) => {
            this.onToggle(value)
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.bgBlurOn) {
        Row({ space: 10 }) {
          Text('强度')
            .fontSize(12)
            .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
          CapsuleSegmentButtonV2({
            items: this.items,
            selectedIndex: this.selectedIndex,
            $selectedIndex: (index: number): void => {
              this.onPickTier(index)
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
