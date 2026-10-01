import { ThemeStorageKey } from '../../../common/constants/Theme'
import { Haptics } from '../../../common/utils/Haptics';
import { ThemeItem } from '../../../common/model/Theme'
import { MyThemeConfigComp } from './MyThemeConfigComp'
import { NightMode } from '../../../common/utils/NightMode'
import { common } from '@kit.AbilityKit'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
import { TabHeader } from '../../../componets/common/TabHeader'

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

  aboutToAppear(): void {
    this.themeMode = NightMode.getMode()
  }

  /** 三档之一被选中 */
  private pickMode(mode: string): void {
    this.themeMode = mode
    NightMode.setMode(mode, this.getUIContext().getHostContext() as common.UIAbilityContext)
  }

  /** 三段滑动开关的单段 */
  @Builder
  modeSegment(label: string, mode: string) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.themeMode === mode ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.themeMode === mode ? this.theme.mainColor : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.themeMode === mode ? $r('app.color.card_bg') : Color.Transparent)
      .onClick(() => {
        Haptics.tap();
        this.pickMode(mode)
      })
  }

  build() {
    Column() {
      // 头部标题栏（2026-10-01 统一页签头 TabHeader：居中标题、无返回箭头——
      // 本页是常驻页签，原返回箭头会弹空 Navigation 栈，已删）
      TabHeader({ title: '主题' })

      // ── 三段滑动开关（2026-09-23 亮暗色重构）────────────────────────────────
      // 「亮色 / 自动 / 暗色」：自动 = 跟随系统深浅色（系统切换即时重涂）。
      // 决策与持久化全部收口在 NightMode（MODE_KEY 持久化 + sync 下发）。
      Row({ space: 4 }) {
        this.modeSegment('亮色', NightMode.MODE_LIGHT)
        this.modeSegment('自动', NightMode.MODE_AUTO)
        this.modeSegment('暗色', NightMode.MODE_DARK)
      }
      // 2026-09-25 用户要求：宽度缩到 90%
      .width('90%')
      .padding(4)
      .borderRadius(21)
      .backgroundColor($r('app.color.chip_bg'))
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
    .backgroundColor($r('app.color.page_bg_alt'))

  }
}
