import { webview } from '@kit.ArkWeb'
import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'

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

  build() {
    NavDestination() {
      Column() {
        Blank(this.topRectHeight)
        SetHead({ titleName: '用户隐私与协议' })
        // Web 组件：占满余下空间；加载失败/无网时展示 Web 自身的错误页
        Web({ src: this.url, controller: this.controller })
          .layoutWeight(1)
          .width('100%')
          .javaScriptAccess(true)
        Blank(this.bottomRectHeight)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.White)
    }
    .hideTitleBar(true)
    .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
  }
}
