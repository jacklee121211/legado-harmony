import { display } from '@kit.ArkUI'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { TtsPrefs } from '../../../tts/TtsPrefs'
import { TtsState } from '../../../tts/TtsEngine'
import { TtsControlPanel } from '../../../components/tts/TtsControlPanel'
import { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../../common/utils/Haptics'

/**
 * 听书面板弹窗（2026-09-23 从 `bindSheet` 改成 `@CustomDialog`）。
 *
 * ── 为什么改 ──────────────────────────────────────────────────────────────
 * 与目录弹窗同一套理由：
 * · `CustomDialog` 的几何完全可控（`alignment` + `offset` + `width` + `radius`）⇒
 *   能做成"离底边留一掌的悬浮胶囊"；而 `SheetOptions` 全部 36 个字段里**没有 offset /
 *   底部留白字段**（字段表见 `component/common.d.ts:11753-12155`）⇒ sheet 永远贴底。
 * · 材质只有弹窗类组件能拿：官方「开启沉浸光感」原文把 `CustomDialog` 列在弹窗类里；
 *   前提是 `customStyle: false`（`custom_dialog_controller.d.ts:130-134`：
 *   「When this parameter is set to true: 1. The rounded corner radius is 0, and
 *     the background color is transparent.」）且内容层让出背景。
 *
 * ── ⚠️ 上次翻车的根因 · 这次必须守住的铁律 ────────────────────────────────
 * 2026-09-22 曾把听书面板改成 CustomDialog，结果「点击就全屏 + 播放按钮 UI 不更新 +
 * 暂停失效」，已回退（`git revert 29153a3`）。根因是**跨两级 `@Link` 传不进
 * `TtsControlPanel`**，而 SDK 对 `builder` 字段的 NOTE 写得很明确
 * （`component/custom_dialog_controller.d.ts:59-60`）：
 *   「To listen for data changes in the builder, use the **@Link or @Consume** decorator;
 *     other decorators, such as **@Prop and @ObjectLink, do not apply**.」
 * ⇒ **会变的数据一律用 `@Link` 传进本弹窗**（`ttsState` / `chapterTitle` / `segIndex` /
 *   `segTotal` / `segText` / `prefs` / `isShowListen`），再由本弹窗用**普通子组件传参**
 *   喂给 `TtsControlPanel`（这一层不是 builder 边界，`@Prop` 能正常更新）。
 *   调用侧写法见 `ReaderPage3.openListenDialog()`：值是 `$xxx`。
 *
 * ── 两段高度（原 sheet 的 `detents: ['42%','92%']`）──────────────────────
 * 高度由**内容层**决定（弹窗 options 里不写 height ⇒ 弹窗高度 = 内容节点高度，
 * `custom_dialog_controller.d.ts:126` 原文：「If the width and height of the dialog box are
 * not set, the dialog box … adapts its height to the custom content node.」）
 * ⇒ 两段高度就是 `stageHeight()` 的两个值；换挡靠顶部那条很淡的把手上**点一下**或**上下拖**。
 */

/**
 * 收起档高度**上限**（占屏高比例，安全阀）。
 * 收起档高度本身是内容自适应的（探针实测 317vp），这个 52% 平时碰不到。
 * 展开档的上限**不用比例**，改成"屏高 − 顶部安全区 − (底部安全区 + 离底留白)"，
 * 见 `stageMax()` 的注释（按真机探针数据定，不拍脑袋）。
 */
const STAGE_COLLAPSED_MAX: number = 0.52
/** 弹窗底边离系统底部安全区的留白（vp）—— 与底部页签条同口径；调用方设置的 `offset` 也用这个值 */
export const LISTEN_DIALOG_BOTTOM_GAP: number = 10

@CustomDialog
export struct ReaderListenDialog {
  /** 由 `CustomDialogController` 注入（`@CustomDialog` 必需字段） */
  controller?: CustomDialogController

  // ── 会变的数据：**必须 @Link**（理由见文件头 NOTE 原文）──────────────────
  /** 面板会把它置 false（"停止朗读" / "完成"两条路径）⇒ 由 `@Watch` 关掉弹窗 */
  @Link @Watch('onListenFlagChanged') isShowListen: boolean
  /** 听书偏好：面板直接改这个对象（自己会 `saveTtsPrefs` + `TtsEngine.updateConfig`） */
  @Link prefs: TtsPrefs
  @Link ttsState: TtsState
  @Link chapterTitle: string
  @Link segIndex: number
  @Link segTotal: number
  @Link segText: string

  // ── 这两个值**直接读 AppStorage**（页面本来就存在这两个 key）─────────────
  // `ReaderPage3`：`@StorageLink('readerColorMode')` / `@StorageLink('bottomRectHeight')`。
  // 为什么不从页面用 @Prop 传：控制器现在是"建一次的成员字段"（`$` 语法只能在组件构造
  // 上下文里用，见 `ReaderPage3.listenDialog` 的注释），@Prop 只能在构造时取一次值
  // ⇒ 日夜模式切换后会过期。走 AppStorage 就一直是最新的，且不用传参。
  // ⚠️ 亮暗色重构（2026-09-23）：键从 'colorMode'（已还给系统深浅色）改为专用键
  // 'readerColorMode' —— 跟随阅读器的日/夜间，而不是系统。
  /** 日/夜模式（**0 = 夜间**，1 = 日间；与父页面 `colorMode` 同义） */
  @StorageLink('readerColorMode') colorMode: number = 1
  /** 系统底部安全区高度（vp）—— 决定弹窗离屏幕底边的留白 */
  @StorageLink('bottomRectHeight') bottomInset: number = 0
  /**
   * 系统**顶部**安全区高度（vp，= 状态栏/摄像头那一带）—— 2026-09-23 新增。
   * 展开档的高度上限不再拍"92%"这种比例，而是**按可用高度算**：
   *   `屏高 − 顶部安全区 − (底部安全区 + 离底留白)`
   * 依据（真机探针实测，日志 `ttsLayout`）：展开档面板自然内容 = 234.59 + 483.19 = 717.78vp，
   * 加上内容层内边距 40 ⇒ 需要 757.78vp；而旧上限 92% 换算出来只有 738.49vp
   * ⇒ 差 19vp（滚动区 464.20 < 内容 483.19，正好差 19）⇒ 最后一行被切、要上划。
   */
  @StorageLink('topRectHeight') topInset: number = 0

  onStart: () => void = (): void => {
  }
  onSeekChapter: (delta: number) => void = (_delta: number): void => {
  }
  onBackToReader: () => void = (): void => {
  }
  /** 弹窗销毁（任何关闭方式）时回调 —— 语义等同改造前 sheet 的 `onDisappear` */
  onClosed: () => void = (): void => {
  }

  /** 展开档 / 收起档 */
  @State expanded: boolean = false
  /** 材质背板：材质可用 ⇒ 内容层一个背景属性都不设；不可用 ⇒ 落回改造前的实底纯色 */
  private surface: MaterialColumnModifier = new MaterialColumnModifier('#1F1F1F', true)

  aboutToAppear(): void {
    this.surface = new MaterialColumnModifier(
      this.colorMode == 0 ? '#1F1F1F' : 'rgba(248, 249, 250, 1)', true)
  }

  aboutToDisappear(): void {
    // 任何关闭方式（点遮罩 / 返回键 / 面板里的"停止朗读""完成"）都会走到这里。
    // 与改造前 `bindSheet` 的 `onDisappear` 同语义：回跳到当前朗读处。
    this.onClosed()
  }

  /** 面板把 `isShowListen` 置 false ⇒ 关掉弹窗（面板侧代码一行都不用改） */
  onListenFlagChanged(): void {
    if (!this.isShowListen) {
      this.controller?.close()
    }
  }

  /** 屏幕高（vp）缓存 —— 只查一次（`display` 查询可能抛异常，etsLint 要求 try/catch） */
  private screenHvpCache: number = 0

  /** 屏幕高（vp）—— 两段高度按它折算，与原 sheet 的 `detents` 同口径 */
  private screenHeightVp(): number {
    if (this.screenHvpCache > 0) {
      return this.screenHvpCache
    }
    let h = 800
    try {
      // ⚠️ 全局 `px2vp()` **已废弃**（`component/common.d.ts:6043-6045` 原文
      //    「@deprecated since 18」「@useinstead ohos.arkui.UIContext.UIContext#px2vp」）
      //    ⇒ 走 `UIContext.px2vp`（`api/@ohos.arkui.UIContext.d.ts:5152`）。
      h = this.getUIContext().px2vp(display.getDefaultDisplaySync().height)
    } catch (e) {
      // 查不到就用兜底值：宁可高度差一点，也不能让面板变 0 高
      h = 800
    }
    this.screenHvpCache = h > 0 ? h : 800
    return this.screenHvpCache
  }

  /**
   * 当前档位的**高度上限**（vp）。
   *
   * 高度**不再是比例**，而是**内容自适应**（2026-09-23 用户设计定案）：
   *   「我们知道小比例下应该显示什么了…**直接定死，就是渲染这些内容**，
   *     并且这个弹窗的大小是**根据内容进行高低**的」
   * ⇒ 收起档只渲染核心行（方案 + 沉浸听读；播放中换成 本章 + 滑块），
   *   展开档渲染全部行；高度 = 内容高度，只有超过上限才滚动。
   *   这样就不会再出现"巨型空底边"，也不需要在小比例里上下滑动。
   */
  private stageMax(): number {
    const h = this.screenHeightVp()
    if (this.expanded) {
      // ★ 2026-09-23：**按可用高度算**，不再拍"92%"这种比例。
      //   真机探针实测（日志 `ttsLayout`）：展开档自然内容需要 757.78vp，
      //   而 0.92 折算出来只有 738.49vp ⇒ 差 19vp ⇒ 最后一行被切、要上划。
      //   现在 = 屏高 − 顶部安全区 − (底部安全区 + 离底留白)
      //   ⇒ 内容能完整显示，且顶边正好停在顶部安全区之下（不会压摄像头）。
      return h - this.topInset - (this.bottomInset + LISTEN_DIALOG_BOTTOM_GAP)
    }
    // 收起档：内容只有核心几行（探针实测 317vp），这个上限平时碰不到，只作安全阀
    return h * STAGE_COLLAPSED_MAX
  }

  /** 换挡（带过渡动效） */
  private setStage(expanded: boolean): void {
    if (this.expanded === expanded) {
      return
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.expanded = expanded
    })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 底色层：材质可用时**不设任何背景属性**（露出弹窗层材质），不可用时落回实底纯色。
      // ⚠️ `MaterialColumnModifier` 是 `AttributeModifier<ColumnAttribute>`（工程既有实现），
      //    所以必须挂在一个 **Column** 上 —— 根节点是 Stack 时类型不兼容（mcp check 报过）。
      Column() {
        TtsControlPanel({
          isShowListen: $isShowListen,
          prefs: $prefs,
          ttsState: this.ttsState,
          chapterTitle: this.chapterTitle,
          segIndex: this.segIndex,
          segTotal: this.segTotal,
          segText: this.segText,
          colorMode: this.colorMode,
          // ★ 隐藏「睡眠定时」段（2026-09-22 用户要求：「听书这个 sheet 再低一点，
          //   保留到播放下面没东西为止」）。
          showSleepTimer: false,
          // ★ 收起档只渲染"核心行"（方案 + 沉浸听读；播放中换成 本章 + 滑块）
          //   ⇒ 收起档的内容刚等于面板高度，**不再有巨型空底边、也不需要上下滑**
          //   （2026-09-23 用户设计：「直接定死，就是渲染这些内容」）。
          compactMode: !this.expanded,
          // ★ 高度上限（安全阀）：高度跟着内容走，超过上限才由面板内部 `Scroll` 滚动
          panelMinHeight: 0,
          panelMaxHeight: this.stageMax(),
          onStart: (): void => {
            this.onStart()
          },
          onSeekChapter: (delta: number): void => {
            this.onSeekChapter(delta)
          },
          onBackToReader: (): void => {
            this.onBackToReader()
          }
        })
      }
      .width('100%')
      // ⚠️ **不要写 height('100%')**（2026-09-23 真机修复）：外层 Stack 现在是"高度由内容决定"
      //   （只给了 maxHeight），子节点写 100% 会**按父容器的上限解析** ⇒ Stack 被撑到上限，
      //   收起档底部就多出一大片空边框（用户截图反馈「小比例底部还有极大边框」）。
      //   展开档仍需要"填满舞台"：用 `constraintSize.minHeight` 表达（它只在下限起作用，
      //   不会像 100% 那样把自适应高度按上限解析）。
      .constraintSize({ minHeight: this.expanded ? this.stageMax() : 0 })
      // ★ 内保护内边距：与原 sheet 内容层**逐字一致**（面板自己还有 20/12/16 的内边距，
      //   两者叠加才是最终留白；收起档的空间账就是按这套算的，不要单独改这里）。
      .padding({ left: 16, right: 16, top: 20, bottom: 20 })
      .attributeModifier(this.surface)

      // ── 两段换挡把手 ──────────────────────────────────────────────────
      // 覆盖在**上内边距那 20vp 里**（Stack 顶层对齐），**不占布局高度**
      // ⇒ 不会挤掉面板的内容高度。
      // 交互：点一下在收起档 ↔ 展开档之间切换；上下拖超过 16vp 也换挡（等价 sheet 的拖拽换挡）。
      Row() {
        Row()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor(this.colorMode == 0
            ? 'rgba(248, 249, 250, 0.35)'
            : 'rgba(19, 19, 19, 0.20)')
      }
      .width('100%')
      .height(20)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        Haptics.tap();
        this.setStage(!this.expanded)
      })
      .gesture(
        PanGesture({ direction: PanDirection.Vertical, distance: 8 })
          .onActionEnd((event: GestureEvent) => {
            if (event.offsetY < -16) {
              Haptics.tick();
              this.setStage(true)
            } else if (event.offsetY > 16) {
              Haptics.tick();
              this.setStage(false)
            }
          })
      )
    }
    // 悬浮外观（宽度/圆角/材质/位置）全在**弹窗 options** 里（见 `openListenDialog()`）；
    // 内容层只写 width('100%') + 高度区间 + 圆角，**不写左右 margin**
    //（同时写 width('100%') 与左右 margin 会超出容器 —— 本工程的老坑）。
    .width('100%')
    // ★ 高度**不写死**（options 里也没写 height ⇒ 弹窗高度 = 本节点高度）：
    //   本节点只给**上限**，实际高度由 `TtsControlPanel` 的内容决定 ⇒ 弹窗跟着内容走
    //   （用户 2026-09-23：「弹窗的大小是根据内容进行高低的」）。
    .constraintSize({ maxHeight: this.stageMax() })
    // 探针（2026-09-23 临时诊断，过滤 `ttsLayout`）：本层高度 + 舞台上限 + 当前档位
    .onAreaChange((_o: Area, n: Area) => {
      hilog.info(0x0000, 'ttsLayout',
        'dialogStack h=%{public}d expanded=%{public}s stageMax=%{public}d bottomInset=%{public}d',
        Number(n.height), String(this.expanded), this.stageMax(), this.bottomInset);
    })
    .borderRadius(20)
    // ★ `.clip(true)` 必须加（2026-09-22 用户反馈「听书你没弄圆角」）：
    //   `TtsControlPanel` 内部自绘了多处 `backgroundColor`（chip 等），会溢出圆角边界。
    .clip(true)
  }
}
