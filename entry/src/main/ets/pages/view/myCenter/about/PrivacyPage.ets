import { webview } from '@kit.ArkWeb'
import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'
import { ShelfColors } from '../../../../common/utils/NightMode'
import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { ThemeItem } from '../../../../common/model/Theme'

// ── 用户隐私与协议（2026-09-30 回填，用户需求）──────────────────────────────
// 用户拍板：直接用应用内 Web 组件打开远程协议页（不再维护本地静态文案）。
// 协议地址：https://md.weizhoudao.cc/zh/miaoyue
// 权限：ohos.permission.INTERNET 已在 module.json5 声明（既有）。
@Component
export default struct PrivacyPage {
  /** Web 控制器：负责页面内前进/后退与加载生命周期 */
  private controller: webview.WebviewController = new webview.WebviewController()
  /** 协议页地址（用户指定） */
  private url: string = 'https://md.weizhoudao.cc/zh/miaoyue'
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  /** 全局主题（2026-10-12：页面底色跟随主题渐变） */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  build() {
    NavDestination() {
      Column() {
        Blank(this.topRectHeight)
        SetHead({ titleName: '用户隐私与协议' })
        // ⚠️ 长文页的处理（2026-10-12）：本页正文由 **Web 组件内的远程页面**绘制，
        //    而 `Web` 自身是不透明画布 ⇒ 在它**后面**铺渐变是看不见的。
        //    做法：把根部渐变留给**页头色带**（SetHead 与 Web 之间的那一段），
        //    再给 Web 套一层圆角卡片并留出外边距，让主题渐变从四周透出来 ——
        //    既与全局主题统一，又不牺牲长正文的可读性（正文仍是白底黑字）。
        Web({ src: this.url, controller: this.controller })
          .layoutWeight(1)
          .width('100%')
          .javaScriptAccess(true)
          .borderRadius(12)
          .clip(true)
          .margin({ left: 12, right: 12, bottom: 12 })
        Blank(this.bottomRectHeight)
      }
      .width('100%')
      .height('100%')
      // 页头色带（SetHead 之上）保持主题渐变；Web 卡片区透过圆角与外边距露出同一渐变
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: ShelfColors.pageGradient(this.theme.mainColor, this.theme.secondColor)
      })
    }
    .hideTitleBar(true)
    .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
  }
}
