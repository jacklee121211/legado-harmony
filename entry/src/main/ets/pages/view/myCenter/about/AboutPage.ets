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
import AppGalleryUtil, { StorePage, CommentResult } from '../../../../common/utils/AppGalleryUtil'
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
        // ── 顶部避让写法统一（2026-10-28；**只是可读性/一致性改动，不是"整页居中"的修复**）──
        // 旧写法是 `Blank(this.topRectHeight)`。Blank 确实是弹性节点：
        //   SDK `ets/component/blank.d.ts:39-49`："When the **Blank** component is used within a Row,
        //     Column, or Flex container, it will automatically stretch or shrink along the main axis if it
        //     does not have a main axis size specified."
        //   官方文档 documentId `API参考/ArkUI_方舟UI框架/ArkTS组件/空白与分隔/Blank/ts-basic-components-blank`：
        //   「从API version 10开始：Blank在父容器Row、Column、Flex主轴方向上未设置大小时会自动拉伸、压缩，
        //     设置了大小或容器自适应子节点大小时不会自动拉伸、压缩。」
        // ⚠️ 但**本页真机 bounds 证明它当时并没有被拉伸**（Lead 提供的 V3.0.4 原包，1320×2848，暗色）：
        //   状态栏 132px + 页头 padding-top 12vp × 3.25 ≈ 39px ⇒ 标题 Text top 应 = 171px，
        //   实测正是 [51, 171, 1107, 234] ⇒ Blank 当时只占 min 那点高度；若它去抢剩余空间，页头会被推到屏幕中部。
        // ⇒ **「整页居中」与 Blank 无关**（此前那版注释的归因是错的，已按实测更正）。删除 Blank 的收益只有两个：
        //   ① 与同页签的 `MySetPage.ets:1412` 用同一种写法（`.padding({ top: this.topRectHeight })`），
        //      属于可读性/一致性改动；② 竖直方向少一个"理论上可伸缩"的节点，避免后人误判。
        //   因 Blank 未被拉伸时占用就是 min，所以把避让改成固定 padding **几何等价**（见本组件末尾），
        //   页头位置仍是 topRectHeight（状态栏高度，窗口监听下发），剩余高度照旧全归 Scroll（layoutWeight 1）。
        // 「整页居中」的真因与修法见下面 Scroll 上的 `.align(Alignment.Top)`（官方 documentId faqs-arkui-725）。
        // 同时核对过：本页只有这一处顶部避让，不存在 Blank + padding 重复避让（旧版没有 padding）。
        SetHead({ titleName: '关于我们' })

        Scroll() {
          Column({ space: 16 }) {
            // ── 第一组：检查更新 / 评分评价 / 更新日志 ──────────────────────
            Column() {
              // 2026-10-21：点击直接进应用市场详情页（不再先查更新），见 onCheckUpdate
              this.row('检查更新', (): void => {
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
        // ── 「整页居中」的**真因**修复（2026-10-28）────────────────────────────────
        // Scroll 被 layoutWeight(1) 限高后，子内容比视口矮时**默认居中排布**。官方原文
        // （documentId `FAQ/UI框架/组件使用/如何解决Scroll组件设置高度限制后_无法顶部对齐的问题/faqs-arkui-725`）：
        //   「Scroll组件：……同时，若子组件的布局尺寸小于Scroll组件的尺寸时，则Scroll组件不可滚动，
        //     且**默认居中排布**。」
        //   「Scroll设置layoutWeight时：此时相当于给了Scroll组件的高度限制……Scroll子组件的布局尺寸
        //     小于Scroll组件的尺寸时，其子组件默认居中排布」
        //   「**分析结论**：……当设置Scroll组件高度后，可以通过设置 `.align(Alignment.Top)` 属性实现
        //     Scroll子组件顶部排布效果。」
        //   「**方案一**：Scroll组件设置高度限制，同时增加 .align(Alignment.Top) 属性。」
        // SDK 依据 `ets/component/common.d.ts:20261-20310`（通用属性 align）：
        //   `align(value: Alignment): T;` —— "Sets the alignment mode for child elements within the
        //   container's drawing area."；生效组件列表**含 [Scroll]**（同文件 :20280）；
        //   "Default value: **Alignment.Center**"（:20297）⇒ 默认就是居中，与本页现象一一对应。
        //   `Alignment.Top` 存在且语义为"顶部、水平居中"（`ets/component/enums.d.ts:1537/1550/1559`）。
        // 本页实测（Lead 真机 bounds）：Scroll 视口 ≈ 2200px，子 Column 布局高 1029px ⇒ 内容被居中，
        // 用户看到的「整页居中」即此。加 `.align(Alignment.Top)` 后内容从 Scroll 顶部起排，
        // 页头之下紧跟卡片；内容超过视口时仍可正常滚动（align 只影响"放不下时"的排布）。
        .align(Alignment.Top)
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
      // 顶部避让：固定 padding（替代原 `Blank(this.topRectHeight)`，等价改动，原因见 build 开头注释）。
      // 实测原 Blank 当时并未被拉伸（标题 y=171 = 状态栏 132 + 12vp×3.25），Blank 占的就是 min，
      // ⇒ 换成同样的固定值，页头位置与改前完全一致；写法和 `MySetPage.ets:1412` 统一。
      // **注意：这里不负责"整页居中"**，那个是 Scroll 子内容默认居中造成的，修在 Scroll 的 `.align(Alignment.Top)`。
      // 渐变仍然画在**同一个**根 Column 上（尺寸没变），所以顶部色带观感与改前一致。
      .padding({ top: this.topRectHeight })
      // 显式钉住主轴对齐为"起点"。Column 默认值本来就是 Start
      // （证据：SDK `ets/component/column.d.ts:181-193` justifyContent:
      //   "Alignment mode of the child components in the vertical direction. Default value: **FlexAlign.Start**"），
      // 写出来只是让"整页顶部对齐"成为显式契约（防止后人给根 Column 加 Center 把页头推到中部）。
      // 本页「整页居中」的真因不在 Column，而在 Scroll（见上）。
      .justifyContent(FlexAlign.Start)
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

  /**
   * 「检查更新」（2026-10-21 用户简化：**直接进应用市场详情页**，不再先查后弹窗）。
   *
   * 为什么这么改（用户原话：「点击之后进入应用商店的应用界面」）：
   *   · 原来走 `updateManager.checkAppUpdate` → 有新版才 `showUpdateDialog`，
   *     未上架/网络抖动时只能给"暂时无法检查更新"，用户点了等于没反应；
   *   · 直接进详情页，用户自己就能看到版本与更新按钮，一次点击到位。
   *
   * 官方依据（documentId `FAQ/应用市场服务_AppGallery_Kit/如何拉起应用市场并跳转至应用详情/faqs-appgallery-31`）：
   *   构造 `store://appgallery.huawei.com/app/detail?id=<bundleName>`，
   *   以 `action: 'ohos.want.action.appdetail'` 调 `context.startAbility(want)`。
   *   实现在 `AppGalleryUtil.openStore()`（那里有完整取证与一键回退开关）。
   */
  private async onCheckUpdate(): Promise<void> {
    const opened: boolean = await AppGalleryUtil.openStore(this.hostContext(), StorePage.DETAIL)
    if (!opened) {
      // 拉不起来（应用市场被卸载 / 未上架找不到条目）⇒ 中性提示，不暴露错误码
      this.toast('请前往应用市场查看更新')
    }
  }

  /**
   * 「评分评价」入口：先软引导，愿意再去评分。
   *
   * 若本地已记录「这个账号评价过」（一年内），**不再弹软引导** ——
   * 因为系统必然返回 1021500009，弹了也只是让用户白点一次。
   * 直接给感谢提示，符合真机实证：改 versionName 后仍报 0009（按账号一年限制）。
   */
  private onRateEntry(): void {
    if (!AppGalleryUtil.canComment()) {
      // 设备不支持应用内评分 ⇒ 直接尝试跳应用市场写评论页
      this.openStoreWriteReview()
      return
    }
    if (AppGalleryUtil.shouldSkipPrompt(this.hostContext())) {
      hilog.info(0x0000, 'AboutPage', 'rating cooldown active, skip prompt dialog')
      this.toast('感谢你之前的评价')
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
