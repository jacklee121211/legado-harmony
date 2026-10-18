import AppRouter from '../../../../common/router/AppRouter'
import { RouteName } from '../../../../common/router/AppRouter'
import { SetHead } from '../../../../componets/myset/SetHead'
import { Haptics } from '../../../../common/utils/Haptics'
import UiMotion from '../../../../common/utils/UiMotion'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'
import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { ThemeItem } from '../../../../common/model/Theme'
import { bundleManager } from '@kit.AbilityKit'
import type { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
// 版本兜底常量与更新日志同源（都由 `scripts/sync-version.ps1` 从 git 提交备注生成）
import { APP_VERSION_FALLBACK } from './VersionLogData'
import AppGalleryUtil, { UpdateCheckState, StorePage, CommentResult } from '../../../../common/utils/AppGalleryUtil'
import RatingPromptDialog from './RatingPromptDialog'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'

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
  /** 检查更新进行中（防重复点击） */
  @State checkingUpdate: boolean = false

  /**
   * 评分引导弹窗（2026-10-13 新增）。
   * 规范 §2.2 options 标准配方：customStyle:false + cornerRadius:20 + systemMaterial + SPRING_FAST。
   * §2.4：内容自适应的短弹窗 ⇒ **不给 height**。
   * §4.1：关闭归调用方（弹窗内 `this.controller?.close()` 无效，见 RenameBookDialog 教训）。
   */
  ratingPromptDialog: CustomDialogController | null = new CustomDialogController({
    builder: RatingPromptDialog({
      theme: this.theme,
      onGoRating: (): void => {
        this.closeRatingDialogAndRate()
      },
      onLater: (): void => {
        this.ratingPromptDialog?.close()
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    width: '80%',
    cornerRadius: 20,
    customStyle: false,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    cancel: (): void => {
      // 遮罩/返回键关闭：同样算一次"以后再说"
    }
  })

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
            // ── 第一组：检查更新 / 评分评价 / 更新日志 ──────────────────────
            Column() {
              this.row(this.checkingUpdate ? '检查中…' : '检查更新', (): void => {
                this.onCheckUpdate()
              }, this.versionName)
              Divider().color(this.nightOn ? '#2A2A2C' : '#F0F0F0')
                .margin({ left: 20, right: 20 })
              this.row('评分评价', (): void => {
                this.onRateEntry()
              })
              Divider().color(this.nightOn ? '#2A2A2C' : '#F0F0F0')
                .margin({ left: 20, right: 20 })
              this.row('更新日志', (): void => {
                AppRouter.push(RouteName.VERSION_LOG)
              })
            }
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(10)
            .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })

            // ── 第二组：用户隐私与协议 / 开源许可 / 联系我们 ─────────────────
            Column() {
              this.row('开源许可', (): void => {
                AppRouter.push(RouteName.LICENSE)
              })
              Divider().color(this.nightOn ? '#2A2A2C' : '#F0F0F0')
                .margin({ left: 20, right: 20 })
              this.row('联系我们', (): void => {
                AppRouter.push(RouteName.CONTACT)
              })
              this.row('用户隐私与协议', (): void => {
                AppRouter.push(RouteName.PRIVACY)
              })
              Divider().color(this.nightOn ? '#2A2A2C' : '#F0F0F0')
                .margin({ left: 20, right: 20 })
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
      // 2026-10-12 适配全局主题渐变（此前是本页唯一的纯色 `ShelfColors.pageBg()`
      // ⇒ 从书架/我的点进来会"突然换底色"）。配色对与书架、我的**同源**
      // （`ShelfColors.pageGradient`），stop 同为 0.0 → 0.2。
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: ShelfColors.pageGradient(this.theme.mainColor, this.theme.secondColor)
      })
    }
    .hideTitleBar(true)
    .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
  }

  // ── 应用市场相关动作（2026-10-13 新增）──────────────────────────────────
  //
  // 全部走 AppGalleryUtil（那里有 SDK 取证与回退开关）。本页只负责"用户提示"。
  // 官方约束：「应用已在应用市场上架」（开发指南 store-update）⇒ 未上架时
  // 这些接口会失败，统一降级成中性提示，**不弹错误码**。

  /** 取 UIAbilityContext（与官方示例同款：getHostContext() as common.UIAbilityContext） */
  private hostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext
  }

  /** 统一 toast（showToast 可能抛异常，此处吞掉：提示失败不该影响主流程） */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch (err) {
      hilog.warn(0x0000, 'AboutPage', `showToast failed: ${JSON.stringify(err)}`)
    }
  }

  /**
   * 延迟 toast —— **专用于紧接着系统评分弹窗之后**。
   *
   * ══ 为什么必须延迟（2026-10-18 真机日志实证，`docs/日志.md` 原文）═══════════
   *   11:19:25.756  AppGalleryUtil  showCommentDialog failed, code=1021500007 ...
   *   11:19:25.756  AceOverlay  Toast node mount to root node
   *   11:19:25.756  Ace        W  Current Node(id: 1) is prohibited add child(tag Toast, id: 614),
   *                              Current modalUiextension count is : 1
   *   11:19:25.761  ModalPage node remove from parent node      ← 系统弹窗这时才真正销毁
   *   11:19:27.370  AceOverlay  pop toast enter                 ← toast 1.6s 后才被弹出
   *
   * 说明：`showCommentDialog` 的 Promise **在系统 UIExtension 销毁之前**就 reject 了
   * （25.756 < 25.761）。此时宿主根节点受「有 modal UIExtension 挂载」限制，
   * ArkUI 直接拒收 Toast 节点（`is prohibited add child`）⇒ 用户什么也看不到。
   * ⇒ 必须等 UIExtension 摘除后再弹。300ms 取的是实测销毁耗时的量级（约 5ms）的保守值。
   */
  private toastAfterComment(delayMs: number, message: string): void {
    setTimeout((): void => {
      this.toast(message)
    }, delayMs)
  }

  /** 「检查更新」 */
  private async onCheckUpdate(): Promise<void> {
    if (this.checkingUpdate) {
      return
    }
    this.checkingUpdate = true
    const state: UpdateCheckState = await AppGalleryUtil.checkAndPromptUpdate(this.hostContext())
    this.checkingUpdate = false
    if (state === UpdateCheckState.HAS_UPDATE) {
      // showUpdateDialog 成功时系统弹窗已接管；失败则由 AppGalleryUtil 内部记录，
      // 这里再兜一层：直接跳应用详情页让用户手动更新。
      const opened: boolean = await AppGalleryUtil.openStore(this.hostContext(), StorePage.DETAIL)
      if (!opened) {
        this.toast('请前往应用市场更新')
      }
      return
    }
    if (state === UpdateCheckState.LATEST) {
      this.toast('已是最新版本')
      return
    }
    // 未上架 / 无网络 / 服务不可用 ⇒ 中性提示（这里**不**暴露错误码）
    this.toast('暂时无法检查更新')
  }

  /** 「评分评价」入口：先软引导，愿意再去评分 */
  private onRateEntry(): void {
    if (!AppGalleryUtil.canComment()) {
      // 设备不支持应用内评分 ⇒ 直接尝试跳应用市场写评论页
      this.openStoreWriteReview()
      return
    }
    this.ratingPromptDialog?.open()
  }

  /**
   * 弹窗点「去评分」：先关弹窗（关闭归调用方），再拉起系统评分。
   *
   * 按业务结局分支处理（2026-10-18 真机日志修正）：
   *   已评价过（1021500007/0009）/ 达上限（0008）**绝不能**跳商店 ——
   *   用户明明评价过却被丢进应用市场，是体验事故。
   *   只有真不可用（0001/0002/0003/0005）才降级跳写评论页。
   *
   * ⚠️ 这里的提示一律用 `toastAfterComment`（延迟），原因见该方法头的日志实证：
   *   系统 UIExtension 未销毁前，ArkUI 会拒收 Toast 节点 ⇒ 用户看不到任何东西。
   */
  private async closeRatingDialogAndRate(): Promise<void> {
    this.ratingPromptDialog?.close()
    const result: CommentResult = await AppGalleryUtil.showCommentDialog(this.hostContext())
    if (result === CommentResult.SHOWN) {
      // 系统弹窗已接管，什么都不做
      return
    }
    if (result === CommentResult.ALREADY_REVIEWED_CURRENT || result === CommentResult.REVIEWED_WITHIN_YEAR) {
      this.toastAfterComment(300, '感谢你之前的评价')
      return
    }
    if (result === CommentResult.LIMIT_REACHED) {
      this.toastAfterComment(300, '感谢支持')
      return
    }
    if (result === CommentResult.NOT_LOGGED_IN) {
      this.toastAfterComment(300, '请先登录华为账号再评价')
      return
    }
    // CommentResult.UNAVAILABLE ⇒ 真不可用，退回应用市场写评论页
    this.openStoreWriteReview()
  }

  /** 跳应用市场写评论页（Deep Linking，官方原文见 AppGalleryUtil.buildStoreUri） */
  private async openStoreWriteReview(): Promise<void> {
    const opened: boolean = await AppGalleryUtil.openStore(this.hostContext(), StorePage.WRITE_REVIEW)
    if (!opened) {
      // 紧跟系统评分弹窗之后，同样要走延迟（见 toastAfterComment 的日志实证）
      this.toastAfterComment(300, '请前往应用市场评价')
    }
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
