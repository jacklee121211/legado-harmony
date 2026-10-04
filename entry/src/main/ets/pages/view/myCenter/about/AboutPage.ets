import AppRouter from '../../../../common/router/AppRouter'
import { RouteName } from '../../../../common/router/AppRouter'
import { SetHead } from '../../../../componets/myset/SetHead'
import { Haptics } from '../../../../common/utils/Haptics'
import UiMotion from '../../../../common/utils/UiMotion'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'
import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { ThemeItem } from '../../../../common/model/Theme'
import { bundleManager } from '@kit.AbilityKit'
// 版本兜底常量与更新日志同源（都由 `scripts/sync-version.ps1` 从 git 提交备注生成）
import { APP_VERSION_FALLBACK } from './VersionLogData'

// ── 关于我们（2026-09-30 回填，用户需求清单）────────────────────────────────
// 基座（legado-harmony）的 aboutUsPage 为空壳参考：本页按喵阅现状全部重写。
// 保留：检查更新（预留，未上架）/ 更新日志 / 用户隐私与协议 / 开源许可。
// 删除：开发人员、官网、公众号、QQ频道、QQ群、崩溃日志、免责声明（用户拍板）。
@Component
export default struct AboutPage {
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  /** 版本名（来自 AppScope/app.json5 的 versionName，运行时读取，不硬编码） */
  @State versionName: string = ''

  aboutToAppear(): void {
    // bundleManager.getBundleInfoForSelfSync：SDK @kit.AbilityKit → @ohos.bundle.bundleManager
    // （@since 10）；BundleFlag.GET_BUNDLE_INFO_DEFAULT 即含 versionName/versionCode。
    // 同步接口在 aboutToAppear 一次性读取即可。
    // "检查更新"行与页脚显示的都是本字段，而它的权威源是 `AppScope/app.json5`
    // ⇒ 与更新日志、与生成器同源（2026-10-05 起由 commit-msg 钩子同步）。
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      this.versionName = `V${info.versionName}`
    } catch (err) {
      // 兜底也读生成常量（原来是硬编码 'V2.0.0'，会与真实版本脱节）
      this.versionName = APP_VERSION_FALLBACK
    }
  }

  build() {
    NavDestination() {
      Column() {
        // 顶部避让（与 MyCenter 同款：顶部安全区高度由窗口监听下发）
        Blank(this.topRectHeight)
        SetHead({ titleName: '关于我们' })

        Scroll() {
          Column({ space: 16 }) {
            // ── 第一组：检查更新 / 更新日志 ────────────────────────────────
            Column() {
              this.row('检查更新', (): void => {
                // 未上架预留（用户拍板）：后续填入自己的商店/链接后改此分支
                this.getUIContext().getPromptAction().showToast({ message: '暂未上架，敬请期待' })
              }, this.versionName)
              Divider().color(this.nightOn ? '#2A2A2C' : '#F0F0F0')
                .margin({ left: 20, right: 20 })
              this.row('更新日志', (): void => {
                AppRouter.push(RouteName.VERSION_LOG)
              })
            }
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(10)
            .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })

            // ── 第二组：用户隐私与协议 / 开源许可 ──────────────────────────
            Column() {
              this.row('用户隐私与协议', (): void => {
                AppRouter.push(RouteName.PRIVACY)
              })
              Divider().color(this.nightOn ? '#2A2A2C' : '#F0F0F0')
                .margin({ left: 20, right: 20 })
              this.row('开源许可', (): void => {
                AppRouter.push(RouteName.LICENSE)
              })
            }
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(10)
            .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
          }
          .width('100%')
          .padding({ left: 20, right: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // ── 页脚：应用名 + 版本（**固定在页面底部**，不随卡片列表滚动）──────
        // v3.7 布局调整（用户需求："顶部标题向上对齐，喵阅以及版本字样在底部"）：
        // 旧版页脚在 Scroll 内容末尾，卡片少时悬在半空；改为 Scroll 之外的
        // 常驻底栏，layoutWeight 让卡片列表吃掉全部中间空间。
        Column({ space: 4 }) {
          Text('喵阅')
            .fontSize(16).fontWeight(600)
            .fontColor($r('app.color.text_primary'))
          Text(`${this.versionName}`)
            .fontSize(12)
            .opacity(0.45)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: this.bottomRectHeight + 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ShelfColors.pageBg())
    }
    .hideTitleBar(true)
    .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
  }

  /** 统一行样式：标题 + 右侧可选版本号 + 雪佛龙（与全 app 行视觉一致） */
  @Builder
  row(title: string, onTap: () => void, tail?: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
      Blank(12)
      if (tail !== undefined && tail !== '') {
        Text(tail)
          .fontSize(12)
          .opacity(0.45)
          .margin({ right: 4 })
      }
      SymbolGlyph($r('sys.symbol.chevron_forward'))
        .fontSize(16)
        .fontColor([$r('app.color.text_primary')])
        .opacity(0.35)
    }
    .width('100%')
    .height(48)
    .padding({ left: 20, right: 20 })
    .clickEffect(UiMotion.CLICK)
    .onClick(() => {
      Haptics.tap()
      onTap()
    })
  }
}
