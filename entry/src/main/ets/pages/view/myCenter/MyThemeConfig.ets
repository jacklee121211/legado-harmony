import { ThemeStorageKey } from '../../../common/constants/Theme'
import { ThemeItem } from '../../../common/model/Theme'
import { MyThemeConfigComp } from './MyThemeConfigComp'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
import { common } from '@kit.AbilityKit'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
import { TabHeader } from '../../../componets/common/TabHeader'
// 2026-10-20：亮暗色三档换成官方 SegmentButton（与书架顶栏同一组件、同一沉浸光感材质）
import { GlassSegment } from '../../../componets/common/GlassSegment'

// 迁 Navigation 第 4 期：去掉 `@Entry` + 补 `export default`（被 Index.ets import 当组件用）。
@Component
export default struct MyThemeConfig {
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  // 亮暗色重构（2026-09-23）：三档「亮色 / 自动 / 暗色」，持久化键见 NightMode.MODE_KEY。
  // （本页颜色全部走语义色资源/$r token，跟随 Ability 配色自动翻面，无需订阅派生键。）
  @State themeMode: string = NightMode.MODE_AUTO
  /**
   * 分段按钮的选中下标（2026-10-20 新增，**必须是独立 @State**）。
   *
   * ⚠️ 为什么不能直接传 `this.modeIndex()`：
   *   ArkUI 的 `@Prop` 只在**父组件 build 重跑**时重新取值，而 `modeIndex()` 是普通方法，
   *   框架**无法追踪它内部读了 `themeMode`**（不是状态变量读取）⇒ 传进去的值不会更新。
   *   这正是"功能生效但按钮不动"的第二个根因。
   * ⇒ 把下标提升成 `@State`：`pickMode()` 里显式同步，`@Prop` 才能收到变化。
   */
  @State modeSel: number = 1

  aboutToAppear(): void {
    this.themeMode = NightMode.getMode()
    // 初始化分段按钮下标（与 themeMode 同步，见 modeSel 的注释）
    this.modeSel = this.modeIndex()
  }

  /**
   * 三档之一被选中。
   * 2026-10-20：`Haptics.tap()` 已移入 `GlassSegment` 内部（分段控件统一震动），
   * 这里只做业务动作。
   *
   * ⚠️ 必须**同时**更新 `modeSel`（UI 选中态）与 `themeMode`（业务状态）：
   *   只改 `themeMode` 的话按钮不会动（@Prop 追踪不到方法返回值，见 modeSel 注释）。
   */
  private pickMode(mode: string): void {
    // ⚠️ 顺序很重要：**先算下标、再提交业务状态**。
    //   `NightMode.setMode()` 内部会 `ctx.setColorMode()`，该调用在真机上**同步重入**
    //   `onConfigurationUpdate`（`NightMode.sync` 的注释里有 JSCrash 实证），
    //   期间可能触发重渲染。若此时 `modeSel` 还没更新，UI 会先闪回旧选中态。
    //   ⇒ 先把两个状态一次算好，最后才做有副作用的 setMode。
    const next: number = (mode === NightMode.MODE_LIGHT) ? 0
      : (mode === NightMode.MODE_DARK ? 2 : 1)
    this.themeMode = mode
    this.modeSel = next
    NightMode.setMode(mode, this.getUIContext().getHostContext() as common.UIAbilityContext)
  }

  /** 「亮色 / 自动 / 暗色」的文案顺序（= 分段控件下标语义） */
  private modeLabels(): string[] {
    return ['亮色', '自动', '暗色']
  }

  /**
   * 当前模式 → 分段按钮下标。
   *
   * ⚠️⚠️ 2026-10-20 修一个**致命低级 bug**（真机现象：「主题一直卡在自动」）：
   *   旧实现写的是 `this.modeLabels().indexOf(this.themeMode)` —— 在**中文标签数组**
   *   `['亮色','自动','暗色']` 里找 **模式常量** `'light'/'auto'/'dark'`
   *   ⇒ 永远 `-1` ⇒ 兜底 `return 1` ⇒ **永远显示"自动"**。
   *   书架那边没这个 bug 是因为它用 `this.chipSel = index` 直接赋下标，不做字符串反查。
   * ⇒ 现在用显式 `switch` 映射，两个空间（中文标签 / 模式常量）彻底分开，
   *   与 `modeToValue()` 形成严格互逆的一对。
   */
  private modeIndex(): number {
    switch (this.themeMode) {
      case NightMode.MODE_LIGHT:
        return 0
      case NightMode.MODE_DARK:
        return 2
      default:
        return 1
    }
  }

  /**
   * 下标 → NightMode 模式常量。
   *
   * ⚠️ 为什么用下标映射而不是直接 `indexOf(模式常量)`：`SegmentButton` 只回传下标，
   *   而三个常量（`NightMode.MODE_LIGHT/AUTO/DARK`）的值与下标顺序**不保证一致**
   *   （见 `NightMode` 里的定义），必须显式映射，不能靠巧合。
   */
  private modeToValue(index: number): string {
    switch (index) {
      case 0:
        return NightMode.MODE_LIGHT
      case 2:
        return NightMode.MODE_DARK
      default:
        return NightMode.MODE_AUTO
    }
  }

  build() {
    Column() {
      // 头部标题栏（2026-10-01 统一页签头 TabHeader：居中标题、无返回箭头——
      // 本页是常驻页签，原返回箭头会弹空 Navigation 栈，已删）
      TabHeader({ title: '主题' })

      // ── 三段滑动开关（2026-09-23 亮暗色重构）────────────────────────────────
      // 「亮色 / 自动 / 暗色」：自动 = 跟随系统深浅色（系统切换即时重涂）。
      // 决策与持久化全部收口在 NightMode（MODE_KEY 持久化 + sync 下发）。
      //
      // ★ 2026-10-20：换成官方 **SegmentButton（胶囊类）**，与书架顶栏同一组件、同一材质。
      //   用户原话：「连主题那个按钮一并换成这个效果好的」。
      //   旧实现是手写 `Row` + `modeSegment()`（每段自己 `.backgroundColor`），
      //   换成 `GlassSegment` 后：选中胶囊 + 沉浸光感材质 + 跟手拖拽都由官方组件负责。
      GlassSegment({
        labels: this.modeLabels(),
        // ★ 2026-10-20：传 **@State 变量** `modeSel`，不再传方法调用 `this.modeIndex()`
        //   （方法返回值框架追踪不到 ⇒ 按钮永远停在初值，这是"卡在自动"的根因之一）
        selected: this.modeSel,
        // 与书架顶栏同一套文字色策略（见 GroupType.chipFontColor 的注释）：
        // 选中 = 主题主色，未选中 = 次级黑/白。不传就会落到系统蓝黑。
        fontColor: NightMode.isDarkSurface()
          ? 'rgba(248, 249, 250, 0.72)'
          : 'rgba(0, 0, 0, 0.62)',
        selectedFontColor: this.theme.mainColor,
        onChange: (index: number): void => {
          const labels: string[] = this.modeLabels()
          if (index >= 0 && index < labels.length) {
            this.pickMode(this.modeToValue(index))
          }
        }
      })
      // 2026-09-25 用户要求：宽度缩到 90%
      .width('90%')
      .margin({ bottom: 12 })

      // ── 内容区（2026-09-23：**去掉原来那层 Tabs**）────────────────────────────
      // 原页签有三项「个性主题 / 桌面图标 / 启动页」，后两项的 TabContent **都是空的**（样子货）：
      //   · 「启动页」随启动动画页一起删除（用户：「直接去掉启动动画页，毫无意义」）
      //   · 「桌面图标」经用户确认也删除
      // ⇒ 只剩一项，再套一层页签没有意义 ⇒ 直接渲染内容，并移除 navList / activeNavIndex /
      //   `tabBarBuilder()`（否则就是死代码）。
      Column() {
        MyThemeConfigComp()
      }
      .padding({
        left: 20,
        right: 20,
        top: 24,
        // 底部 dock 让位（2026-10-01）：主题格子滚到底要停在悬浮 dock 之上（自适应）
        bottom: ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight)
      })
      .borderRadius({
        topLeft: 12,
        topRight: 12
      })
      // 2026-09-25 用户反馈：主题格子下面还有个白色蒙版 ⇒ 去掉卡片底色，背景一色
      .width('100%')
      .layoutWeight(1)
    }
    .height('100%')
    .width('100%')
    .padding({top: this.topRectHeight})
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0],
        [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]]
    })

  }
}
