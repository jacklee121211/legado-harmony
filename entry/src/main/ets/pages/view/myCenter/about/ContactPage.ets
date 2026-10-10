import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'

// ── 联系我们（2026-10-07 新增 / 2026-10-08 修复"加 QQ 群跳不出去"）──────────
// 1. 主体仍是应用内 Web 组件打开远程 md 联系页（与「用户隐私与协议」同源策略）。
// 2. 加 `onLoadIntercept`：当 Web 内点「点击加入 QQ 群」等外链（host ≠
//    md.weizhoudao.cc）且是主帧且来自用户手势时，拦截并通过
//    `UIAbilityContext.openLink` 让系统按 scheme 决定调起 QQ App / 浏览器
//    —— 这是为什么「浏览器能跳转出去、应用内跳不出去」的根因。
//    · SDK 依据：
//      - `WebAttribute.onLoadIntercept(callback)` `@since 10`（@kit.ArkWeb，
//        证据：sdk\default\openharmony\ets\component\web.d.ts:7202）。
//      - `WebResourceRequest.getRequestUrl()` `@since 8`（同上 :2777）。
//      - `WebResourceRequest.isMainFrame()` `@since 8`（同上 :2789 附近）。
//      - `WebResourceRequest.isRequestGesture()` `@since 8`（同上 :2787）。
//        该字段用于过滤 window.location / meta refresh 等非用户主动跳转，
//        避免误拦截 md 页内的脚本导航。
//      - `UIAbilityContext.openLink(link, options?, callback?)` `@since 12`
//        （证据：sdk\default\openharmony\ets\api\application\UIAbilityContext.d.ts:300）。
// 3. URL 守门：只放行/拦截 host 完全等于本站的导航，**不**做通配后缀匹配。
// 4. 失败兜底：openLink 抛错时降级为继续在 WebView 内打开（返回 false），
//    保证至少 md 页本身始终可读。
//
// ⚠️ 一键回退（若真机上 openLink 调起 QQ App 行为不符合预期）：
//   把下方 `BLOCK_OUTSIDE_LINKS` 设为 `false` 即可恢复「只在 WebView 内
//   打开一切外链」的旧行为（与原版一致，问题会复现但不报错）。
const BLOCK_OUTSIDE_LINKS: boolean = true
const SITE_HOST: string = 'md.weizhoudao.cc'

@Component
export default struct ContactPage {
  /** Web 控制器：负责页面内前进/后退与加载生命周期 */
  private controller: webview.WebviewController = new webview.WebviewController()
  /** 联系页地址（用户指定，按用户原样保留 percent-encoded 形式） */
  private url: string = 'https://md.weizhoudao.cc/s/%E5%96%B5%E9%98%85%E8%BD%AF%E4%BB%B6%E8%81%94%E7%B3%BB%E9%A1%B5'
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0

  build() {
    NavDestination() {
      Column() {
        Blank(this.topRectHeight)
        SetHead({ titleName: '联系我们' })
        // Web 组件：占满余下空间；加载失败/无网时展示 Web 自身的错误页
        Web({ src: this.url, controller: this.controller })
          .layoutWeight(1)
          .width('100%')
          .javaScriptAccess(true)
          // 拦截外链：让"加 QQ 群"等跳转走系统，而不是死在 WebView 内。
          .onLoadIntercept((event) => {
            if (!BLOCK_OUTSIDE_LINKS) {
              // 一键回退开关：直接放行所有导航。
              return false
            }
            const req = event?.data
            if (!req) {
              return false
            }
            // 仅主帧 + 仅用户手势 —— 放过图片/iframe/meta refresh。
            if (!req.isMainFrame() || !req.isRequestGesture()) {
              return false
            }
            const target: string = req.getRequestUrl()
            if (!target) {
              return false
            }
            // 同源放行（md 页内的锚点/引用页/同站点其它页）
            if (this.isSameSite(target)) {
              return false
            }
            // 外链：拦截并交给系统按 scheme 决定 QQ App / 浏览器。
            // 失败兜底：openLink 抛错时返回 false 让 Web 自己处理。
            try {
              const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext
              if (ctx) {
                ctx.openLink(target)
                return true // 拦截 —— 否则 Web 仍会尝试自己加载
              }
            } catch (e) {
              // 静默降级：return false 让 Web 自己处理（用户至少能看到错误页）
            }
            return false
          })
        Blank(this.bottomRectHeight)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.White)
    }
    .hideTitleBar(true)
    .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
  }

  /**
   * 守门：判断 URL 是否仍属于本站（`md.weizhoudao.cc`）。
   * 只匹配 host 完全相等，**不**做后缀通配 —— 避免被 `*.weizhoudao.cc`
   * 之类的子域劫持（虽然 md.weizhoudao.cc 目前没有子域，但写严一点没坏处）。
   */
  private isSameSite(rawUrl: string): boolean {
    try {
      // strip protocol + path → 只留 host
      const head: string = rawUrl.startsWith('http://') ? rawUrl.substring(7)
        : rawUrl.startsWith('https://') ? rawUrl.substring(8)
          : rawUrl
      const slashIdx: number = head.indexOf('/')
      const host: string = slashIdx === -1 ? head : head.substring(0, slashIdx)
      // 去掉可能的端口
      const colonIdx: number = host.indexOf(':')
      const pureHost: string = colonIdx === -1 ? host : host.substring(0, colonIdx)
      return pureHost === SITE_HOST
    } catch (e) {
      return false
    }
  }
}
