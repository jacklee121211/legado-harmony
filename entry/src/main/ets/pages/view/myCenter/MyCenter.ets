import { Attribute } from '../../../common/utils/Attribute'
import AppRouter, { RouteName, ReadStatisticsRouteParam, ReadStatsRouteParam, ReaderRouteParam, BookManageRouteParam } from '../../../common/router/AppRouter'
import { promptAction } from '@kit.ArkUI'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { common } from '@kit.AbilityKit'
import { PreferencesUtil } from '@pura/harmony-utils'
import ImmersiveMaterialUtil, { MaterialColumnModifier, MaterialButtonModifier } from '../../../common/utils/ImmersiveMaterialUtil'
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion'
import { TabHeader } from '../../../componets/common/TabHeader'
// 阅读数据模块（2026-10-13）：卡1 阅读数据 / 卡2 阅读榜
import { ReadDataCard } from '../../../componets/myCenter/ReadDataCard'
import { ReadRankCard } from '../../../componets/myCenter/ReadRankCard'
import { Books } from '../../../database/entities/Books'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
import { ColumnModifier } from '../../../common/utils/ComponetModifier'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { ThemeItem } from '../../../common/model/Theme'
import { image } from '@kit.ImageKit'
import { resourceManager } from '@kit.LocalizationKit'
import { BusinessError } from '@kit.BasicServicesKit'
// ── 全局震动反馈（2026-09-25 新增）+ 会员（2026-09-28 会员化改造）─────────────
import { Haptics } from '../../../common/utils/Haptics'
import { VipManager } from '../../../common/utils/VipManager'
// ── 离线模式（2026-10-13 新增）：离线时整卡隐藏 Web服务 ──
import { STORAGE_KEY_OFFLINE_MODE } from '../../../common/utils/OfflineMode'
import { IapManager } from '../../../common/utils/IapManager'
import { VipDialog } from '../../../componets/myCenter/VipDialog'
import { WifiTransferDialog } from '../../../componets/myCenter/WifiTransferDialog'
// ── 个性化插件屏（2026-10-10 新增）───────────────────────────────────────────
import { PlugboardZone } from '../../../componets/plugboard/PlugboardZone'
import { PlugZone } from '../../../componets/plugboard/PlugboardTypes'
import { PlugboardPrefs } from '../../../componets/plugboard/PlugboardPrefs'

// T29-③（Round 40）：去掉 `@Entry`。
// 编译器原文：`It's not a recommended way to export struct with '@Entry' decorator,
//   which may cause ACE Engine error in component preview mode.`
// 实测依据：① `main_pages.json`（32 个页面）**没有** `pages/view/myCenter/MyCenter` ⇒ 它不是页面；
//          ② 它是被 `pages/Index.ets:8` **作为组件** import 的；
//          ③ 全文无 `onPageShow`/`onPageHide`/`onBackPress` 等 `@Entry` 专属生命周期。
// ⇒ 去掉 `@Entry` 后仍是被父组件渲染的普通组件，行为不变；保留 `export default`（父组件要用）。
@Component
export default struct MyCenter {
  /**
   * `myCenterTick` 心跳键的订阅点（2026-09-21 落地，2026-10-13 起**不再由本页自己算计数**）。
   *
   * 历史：本页原来有一行「读过 / 读完 / 书签」三格，数字由 `loadHeadCounts()` 拉。
   * 2026-10-13 用户拍板把那一行**整行删掉**，读过/读完 的入口搬进 `ReadDataCard`，
   * 书签整个去掉 ⇒ 本页不再需要任何计数查询。
   *
   * 但**键还要继续订阅**：`readStatistics` 删记录后靠 `AppStorage['myCenterTick']` 通知本页刷新，
   * 而两张卡内部也各自订阅了这个键（`ReadDataCard` / `ReadRankCard` 的 `@Watch('onDataTick')`），
   * 本页这次订阅只负责"顺手把整页重绘一次"，值一变即触发。
   */
  @StorageLink('myCenterTick') myCenterTick: number = 0

  /**
   * 进入「我的」页：VIP 状态回填 / 事实源刷新。
   * （阅读数据的加载在两张卡各自的 `aboutToAppear` 里，本页不再代劳。）
   */
  aboutToAppear(): void {
    // VIP（2026-09-28）：Preferences → AppStorage（@StorageLink 驱动头部 UI，
    // 键为编译期字面量，与 VipManager 约定一致）。
    AppStorage.setOrCreate('vipUnlocked', VipManager.isVip())
    // VIP 事实源刷新（2026-09-28 阶段2）：以华为 IAP 服务器已购记录为准（异步，不阻塞）。
    // 卸载重装/换机场景：同一华为账号进「我的」页即自动恢复 VIP。
    // ⚠️ refreshVip 只升不降（沙盒查不到已发货订单，见 IapManager 注释）。
    IapManager.refreshVip(getContext(this) as common.UIAbilityContext)
  }
  // 「主题」卡片入口已删（2026-09-30 v3.12）：功能迁至顶部 symbol 主题按钮。

  // 「关于我们」入口已于 2026-09-21 删除（用户决定），`end_list` 整块随之移除
  //（它原来也只承载这一个入口）。
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  Column = new ColumnModifier()
  // 主题颜色
  // 亮暗色重构（2026-09-23）：订阅派生深色键 —— 渐变背景（ShelfColors.gradientStart/End）
  // 需要在深浅翻转时重绘；不订阅的话"自动"档跟随系统时会滞后到下一次重建。
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /**
   * 离线模式（2026-10-13 新增）：true = 隐藏 Web服务整卡（用户要求「整个 web 服务直接隐藏」）。
   * 绑 OfflineMode 的广播键，切模式后本页立即重渲染。
   */
  @StorageLink(STORAGE_KEY_OFFLINE_MODE) offlineOn: boolean = false
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  // （2026-10-01 已删除 setIconScale/themeIconScale 两个 Q弹状态：顶部主题/设置按钮
  //   移入底部 dock，见 Index.ets nav。）

  // ── Web服务（2026-09-30 回填）────────────────────────────────────────────
  /** 传书对话框控制器（wifi传书/电脑阅读共用） */
  private wifiDialog: CustomDialogController | null = null
  /** 三个服务项各自的 Q弹缩放值（runJellyClick 自驱） */
  @State wifiScale: number = 1
  @State readScale: number = 1
  @State airScale: number = 1

  // ── 会员（2026-09-28 会员化改造·二版：登录下线，VIP 跟系统华为账号）────────
  /** VIP 解锁缓存位（事实源在 IAP，见 VipManager；进本页自动 refreshVip 核对） */
  @StorageLink('vipUnlocked') vipOn: boolean = false
  /** VIP 购买弹窗控制器 */
  private vipDialog: CustomDialogController | null = null

  /** 打开 VIP 弹窗（未登录也能直接买：IAP 跟系统华为账号走） */
  private openVipDialog(): void {
    this.vipDialog = new CustomDialogController({
      builder: VipDialog({
        dark: this.nightOn,
        vipOwned: VipManager.isVip(),
        onClose: (): void => {
          this.vipDialog?.close()
          this.vipDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.vipDialog = null
      }
    })
    this.vipDialog.open()
  }

  build() {
    Column() {
      // Blank(this.topRectHeight-20)
      // ── 页签标题头（2026-10-01 用户需求）：与主题/设置两页同一标准 TabHeader ──
      TabHeader({ title: '我的' })

      // ── 顶部 Row（2026-10-13 已清空 VIP 标记）────────────────────────────
      // VIP 金标原在此行右端（2026-09-28，真机实测 高 67px），2026-10-13 按用户要求
      // 搬进「Web服务」标题行。本行**保留为空壳**并收窄到 8vp。
      // 目的：消掉「我的 ↔ 设置」两页切换的**顶端撕裂感**（用户 2026-10-13 反馈）。
      //   实测依据（Mate 80 Pro Max，屏宽 1320px，scale 3.35）：
      //     设置页首行「显示文件拓展名」文字上沿 y = 461
      //     我的页首行「Web服务」   文字上沿 y = 495  ⇒ 差 34px
      //   本行原高 67px（=20vp 内容撑开），收窄至 8vp：
      //     实测 10vp 时 Web服务 上沿 = 468；再收 2vp(6.7px) ⇒ 461.3，与设置页 461 对齐（残差 0.3px）。
      //   ⚠️ 残差 0.3px 属**结构差异**（设置行 `SetListView.ets:87` 自带 padding 12 且内容垂直居中，
      //      本页是卡片 padding 16 + 顶部起排），不再继续追平，避免破坏本页卡片设计。
      //   ⚠️ 若删除本空壳行，Web服务 会上移 67px 直接贴住页头 ⇒ 必须保留。
      Row({ space: 10 }) {
      }.justifyContent(FlexAlign.End).width("100%")
      .height(8)

      Scroll() {
        // 整页**向上对齐**（用户要求）：内层 Column 显式撑满高度 + Start 对齐，
        // 并去掉原来垫在最上面的 `Blank(24)`，内容直接从顶部开始排。
        Column() {

          // ── 阅读数据（2026-10-13 架构升级：**替代原来那一行「读过/读完/书签」三格**）──
          // 用户拍板的改法：三格整行删除 —— 「读过 / 读完」的**入口**搬进卡 1
          // （卡内那两个胶囊就是原来的入口，点进去还是 `readStatistics` 的 0/1 明细页），
          // 「书签」整个不要了（阅读器里仍有独立的 `ReaderBookmarkDialog` 可用）。
          // 时间口径：时长只统计**前台停留**，见 `common/utils/ReadTimeRecorder.ets`。
          Column() {
            ReadDataCard({
              onOpenDetail: (mode: string, anchor: number): void => {
                AppRouter.push(RouteName.READ_STATS,
                  { mode: mode, anchorMs: anchor } as ReadStatsRouteParam)
              },
              onOpenReadList: (type: number): void => {
                AppRouter.push(RouteName.READ_STATISTICS, { type: type } as ReadStatisticsRouteParam)
              }
            })
          }
          .width('100%')
          // ⚠️ 不能在这里再套 `padding({left:20,right:20})`：页面最外层 Column 的
          //    `ColumnModifier` 已经给了 20 左右内边距（ComponetModifier 默认值），
          //    再套一层会比「Web服务」卡窄 40vp（用户 2026-10-13 反馈"宽度对不上"）。
          .margin({ top: 24 })

          // ── 阅读榜（2026-10-13）：按时段内的阅读时长排序，5 档筛选在卡内右上角 ──
          Column() {
            ReadRankCard({
              onOpenDetail: (mode: string, anchor: number): void => {
                AppRouter.push(RouteName.READ_STATS,
                  { mode: mode, anchorMs: anchor } as ReadStatsRouteParam)
              },
              onOpenBook: (book: Books): void => {
                AppRouter.push(RouteName.READER, { bookData: book } as ReaderRouteParam)
              }
            })
          }
          .width('100%')
          // ⚠️ 不能在这里再套 `padding({left:20,right:20})`：页面最外层 Column 的
          //    `ColumnModifier` 已经给了 20 左右内边距（ComponetModifier 默认值），
          //    再套一层会比「Web服务」卡窄 40vp（用户 2026-10-13 反馈"宽度对不上"）。
          .margin({ top: 16 })

          // ── Web服务卡片（2026-09-30 回填，用户需求）────────────────────────
          // wifi传书 / 电脑阅读 / 隔空传送（替代基座的"电脑写源"——书源体系已整体移除）。
          // 基座考古结论：基座的 Web 服务是**纯空壳**（假开关 + 写死的假地址 192.168.41.12:1122，
          // 无任何 HTTP/Socket 服务端实现，见基座 WebdavService.ets）⇒ 服务端为全新开发
          //（方案与范围待用户确认，本轮先落入口与样式）。图标用 symbol、点按走
          // clickEffect + Haptics（全 app 现有机制）。
          //
          // ⚠️ 2026-10-13 离线模式：整卡隐藏（用户要求「web服务，整个web服务直接隐藏」）。
          //    包**整卡**而不是只包下面那两个条目 —— 否则会剩一个孤零零的「Web服务」标题行
          //    （它还带 VIP 金标，单独留着更奇怪）。
          if (!this.offlineOn) {
          Column({ space: 12 }) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.display'))
                .fontSize(16)
                .fontColor([this.theme.mainColor])
              Text('Web服务')
                .fontSize(14).fontWeight(600)
                .fontColor($r('app.color.text_primary'))
              // ── VIP 入口（2026-10-13 用户重设计：**取消原来那张 80 高的大卡片**）──────
              // 这个位置就是 VIP 的唯一入口，两种形态同尺寸同色系：
              //   · 已开通 → 金色「VIP」标识
              //   · 未开通 → 金色「开通 VIP」按钮
              // 「上下对齐」由 Row 的垂直对齐保证 —— SDK 原文（`row.d.ts:156-165`）：
              // `alignItems` "Alignment mode of child components in the vertical direction."
              // **Default value: VerticalAlign.Center** ⇒ 与「Web服务」文字自动居中，无需显式设置。
              // 离线模式（Web 服务整卡隐藏）的入口见下方独立的 `offlineVipRow`。
              if (this.vipOn) {
                Row() {
                  Text('VIP')
                    .fontSize(12)
                    .fontWeight(700)
                    .fontColor(Color.White)
                    .backgroundColor('#F5A623')
                    .borderRadius(8)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                }
                .clickEffect(UiMotion.CLICK)
                .onClick(() => {
                  Haptics.tap();
                  this.openVipDialog()
                })
              } else {
                Row({ space: 3 }) {
                  SymbolGlyph($r('sys.symbol.crown'))
                    .fontSize(11)
                    .fontColor([Color.White])
                  Text('开通 VIP')
                    .fontSize(12)
                    .fontWeight(700)
                    .fontColor(Color.White)
                }
                .backgroundColor('#F5A623')
                .borderRadius(8)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .clickEffect(UiMotion.CLICK)
                .onClick(() => {
                  Haptics.tap();
                  this.openVipDialog()
                })
              }
            }
            .width('100%')

            Row({ space: 10 }) {
              this.webServiceItem($r('sys.symbol.wifi'), 'wifi传书', (): void => {
                this.openWifiDialog()
              })
              this.webServiceItem($r('sys.symbol.computer'), '电脑阅读', (): void => {
                this.openWifiDialog()
              })
              // 2026-10-01（用户）：「隔空传送」更名「书籍分享」；点击进**全部书籍**管理页。
              // ⚠️ bookTypeNumber 必须传 2（系统"全部"分组）：BooksDao.searchPage 对
              // bookGroup===2 **跳过分组过滤**（BooksDao.ets:141）⇒ 列出全库书籍；
              // 原来传 0（不存在组 0）⇒ 管理页为空（用户实测"进入的是空的管理页"）。
              this.webServiceItem($r('sys.symbol.dot_radiowaves_left_and_right'), '书籍分享', (): void => {
                AppRouter.push(RouteName.BOOK_MANAGE,
                  { currentIndex: 0, EXHIBIT: '', bookTypeNumber: 2 } as BookManageRouteParam)
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(10)
          .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
          // 2026-10-13 顺序调换后：本卡作为**第二个**元素，与上方统计行之间取 16
          // （原「统计行 margin top 16」的同一间距，只是方向反过来）。
          .margin({ top: 16 })
          }

          // ── 离线模式的 VIP 入口（2026-10-13 用户设计）────────────────────────
          // 全量模式：VIP 入口在「Web服务」标题行那个金标位置（未开通=「开通 VIP」按钮）。
          // 离线模式：Web 服务**整卡隐藏** ⇒ 那个位置跟着没了，所以在卡片流末尾补一个
          //           **紧凑入口**（56 高，与其它卡同宽同圆角），只有未开通时才出现；
          //           已开通时什么都不显示（没有"要看状态"的必要，不占地方）。
          // ⚠️ 已经**取消**原来那张 80 高、只有一个字的「开通 VIP」大卡片（用户："太大了，太占地方"）。
          if (this.offlineOn && !this.vipOn) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.crown'))
                .fontSize(18)
                .fontColor(['#F5A623'])
              Text('开通 VIP')
                .fontSize(14).fontWeight(600)
                .fontColor('#F5A623')
              Text('自定义字体 · 背景材质 · 主题 · 防窥等')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
              Blank()
              SymbolGlyph($r('sys.symbol.chevron_forward'))
                .fontSize(14)
                .fontColor([$r('app.color.text_primary')])
                .opacity(0.35)
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(10)
            .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
            .margin({ top: 16 })
            .clickEffect(UiMotion.CLICK)
            .onClick(() => {
              Haptics.tap();
              this.openVipDialog()
            })
          }

          // （2026-10-13 用户要求：「关于我们」入口**迁到设置页最底部** ——
          //   本页原来的 `Blank()` + 关于我们卡片已删除，
          //   新位置见 `MySetPage.ets` 的「关于我们」设置组。)

          // ── 个性化插件屏 · 方块区（2026-10-10 新增）───────────────────────────
          // 【已隐藏 2026-10-11】效果待优化，暂时隐藏入口
          // 2026-10-11：宽度对齐"读过"列左边到"书签"列右边（屏宽/3 = 屏宽 33%）
          // 居中显示。无内容时不渲染卡片背景（避免空白块）
          // if (PlugboardPrefs.hasContent(PlugZone.MY_BLOCK)) {
          //   Row() {
          //     PlugboardZone({ zone: PlugZone.MY_BLOCK, zoneLabel: '2区·方块' })
          //       .width('33.33%')
          //       .borderRadius(10)
          //       .backgroundColor($r('app.color.card_bg'))
          //       .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
          //   }
          //   .width('100%')
          //   .justifyContent(FlexAlign.Center)
          //   .margin({ top: 16 })
          // }

          // 弹性占位：内容不足一屏时把最后一块往上顶（原「关于我们」贴底的那段已随入口迁走，
          // 这里保留 Blank 让内容从顶部起排、不居中）。
          Blank()

        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
        // ── 底部 dock 让位（2026-10-01 用户反馈"关于我们与书架/我的这一行重叠"）────
        // 底部 dock 是**悬浮 Tabs 条**（barOverlap，Index.ets barFloatingStyle），
        // 会盖住 TabContent 的内容 —— 必须给滚动内容末尾垫出 dock 的实际覆盖高度。
        // 自适应依据：条高 56（ImmersiveMaterialUtil.TAB_BAR_HEIGHT）+ 条底边距
        // （bottomRectHeight 系统安全区实测值 + 8）+ 12 呼吸位 —— 不同屏幕比例下
        // bottomRectHeight 由系统 avoid-area 实时下发，天然适配。材质关闭时 dock
        // 走常规布局（不悬浮），只留 12 呼吸位。
        .padding({ bottom: this.pageBottomInset() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .attributeModifier(this.Column)
    .linearGradient({
      direction: GradientDirection.Bottom, // 渐变方向
      // 亮暗色重构（2026-09-23，用户拍板"深色底+主题色点缀"）：深色档换成中性深灰渐变，
      // 主题色只保留在图标/按钮等点缀处；日间档与原来逐字一致。
      colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0.0],
        [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]]
    })
    .height('100%')
    // 改名半模态（2026-09-28 移除）：登录下线后头像/昵称一并移除，改名半模态随之删除。
  }

  /** 底部 dock 让位量（自适应：安全区实测值参与计算，统一收口 ImmersiveMaterialUtil） */
  private pageBottomInset(): number {
    return ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight)
  }

  // （2026-10-13 已删除 `loadHeadCounts()` 与 `head_onclick()`：
  //   它们只服务原来那一行「读过/读完/书签」三格。
  //   三格按用户要求整行删除后 —— 读过/读完 的入口搬进 `ReadDataCard` 的胶囊
  //   （点击走 `onOpenReadList` → 同一个 `readStatistics` 明细页），计数改由新表
  //   `readDaily` + `books.finishedTime` 按周期统计，本页不再需要任何计数查询。
  //   书签整个下架：阅读器内仍有独立的 `ReaderBookmarkDialog`。）

  //主题点击事件（2026-09-21 精简：只剩「主题」一项；
  //原「备份」「书源」「净化」的 case 1/3/4 已删除）
  /**
   * Web服务三宫格单项（2026-09-30 回填）：symbol 图标 + 标签 + **Q弹**（runJellyClick
   * 自驱 scale，与书架顶部按钮同款配方）+ 统一震动（Haptics.tap）。
   * 动作由调用方注入：wifi传书/电脑阅读 → WifiTransferDialog；隔空传送 → 管理页。
   */
  @Builder
  webServiceItem(icon: Resource, label: string, onTap: () => void) {
    Column({ space: 6 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.theme.mainColor])
        .scale({ x: this.wifiScaleOn(label), y: this.wifiScaleOn(label) })
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor(ShelfColors.card())
    .clickEffect(UiMotion.CLICK)
    .onClick(() => {
      Haptics.tap()
      this.jellyByLabel(label)
      onTap()
    })
  }

  /** 三宫格各自的 Q弹 scale 取值（label → state 的桥接，避免数组下标更新不刷 UI） */
  private wifiScaleOn(label: string): number {
    if (label === 'wifi传书') {
      return this.wifiScale
    }
    if (label === '电脑阅读') {
      return this.readScale
    }
    return this.airScale
  }

  private jellyByLabel(label: string): void {
    if (label === 'wifi传书') {
      runJellyClick((v: number) => {
        this.wifiScale = v
      })
    } else if (label === '电脑阅读') {
      runJellyClick((v: number) => {
        this.readScale = v
      })
    } else {
      runJellyClick((v: number) => {
        this.airScale = v
      })
    }
  }

  /** 打开 WiFi 传书/电脑阅读对话框（同一个服务的两个入口） */
  private openWifiDialog(): void {
    this.wifiDialog = new CustomDialogController({
      builder: WifiTransferDialog({
        dark: this.nightOn,
        onClose: (): void => {
          this.wifiDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '86%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.wifiDialog = null
      }
    })
    this.wifiDialog.open()
  }
}
