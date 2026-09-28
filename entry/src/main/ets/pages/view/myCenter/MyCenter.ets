import { Attribute } from '../../../common/utils/Attribute'
import AppRouter, { RouteName, ReadStatisticsRouteParam } from '../../../common/router/AppRouter'
import { promptAction } from '@kit.ArkUI'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { common } from '@kit.AbilityKit'
import { PreferencesUtil } from '@pura/harmony-utils'
import ImmersiveMaterialUtil, { MaterialColumnModifier, MaterialButtonModifier } from '../../../common/utils/ImmersiveMaterialUtil'
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion'
import { dataItem } from '../../../componets/dataList/dataItem'
import BooksDao from '../../../database/dao/BooksDao'
import BookmarksDao from '../../../database/dao/BookmarksDao'
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
import { IapManager } from '../../../common/utils/IapManager'
import { VipDialog } from '../../../componets/myCenter/VipDialog'

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
   * 三个计数的**刷新钩子**（2026-09-21 落地，解决真机「数字不实时、要杀进程重启」）。
   *
   * 为什么必须有它：`MyCenter` 是 `pages/Index.ets` 的**子组件**（不是页面，见文件头注释），
   * `aboutToAppear` 只在**组件首次创建**时触发一次 —— 读完书回来数字还是旧的。
   *
   * 机制：监听一个共享的"心跳"计数器 `myCenterTick`，值一变就重拉。
   * 谁负责 +1：
   *   · `pages/Index.ets` 的 `Tabs.onAnimationStart` —— 切到「我的」（index 3）时；
   *   · `pages/view/myCenter/readStatistics.ets` 的 `onPageHide` —— 删完书签/记录返回时。
   */
  @StorageLink('myCenterTick') @Watch('onCountsTick') myCenterTick: number = 0

  onCountsTick(): void {
    this.loadHeadCounts()
  }

  /**
   * 进入「我的」页时拉取真实计数（读过 / 读完 / 书签）。
   * 后续刷新走上面的 `myCenterTick` 钩子。
   */
  aboutToAppear(): void {
    // VIP（2026-09-28）：Preferences → AppStorage（@StorageLink 驱动头部 UI，
    // 键为编译期字面量，与 VipManager 约定一致）。
    AppStorage.setOrCreate('vipUnlocked', VipManager.isVip())
    // VIP 事实源刷新（2026-09-28 阶段2）：以华为 IAP 服务器已购记录为准（异步，不阻塞）。
    // 卸载重装/换机场景：同一华为账号进「我的」页即自动恢复 VIP。
    // ⚠️ refreshVip 只升不降（沙盒查不到已发货订单，见 IapManager 注释）。
    IapManager.refreshVip(getContext(this) as common.UIAbilityContext)
    this.loadHeadCounts()
  }

  @State head_list: dataItem[] = [
    new dataItem("读过", 0),
    new dataItem("读完", 0),
    new dataItem("书签", 0),
    // 「勋章」已移除（2026-09-21）：原为硬编码的假数据，点进去是空分支（见 head_onclick），
    // 无数据源、无功能，属纯占位符。索引保持 0=读过 / 1=读完 / 2=书签 不变。
  ]
  // 2026-09-21 精简：原 4 项里「备份」「书源」「净化」已删 ——
  //   · 备份 → `cloudDisk.ets` 整页无任何 WebDAV 实现（假设备名/假备份列表，
  //     「立刻备份」只是转 720° + toast「备份成功」）；
  //   · 书源 / 净化 → `centerOnclick` 里本来就是 `case 3/4: break` **空分支**，点了没反应。
  @State center_list: dataItem[] = [
    new dataItem("主题", 2, $r("app.media.my_center_book_icon")),
  ]
  // 「关于我们」入口已于 2026-09-21 删除（用户决定），`end_list` 整块随之移除
  //（它原来也只承载这一个入口）。
  @StorageLink('topRectHeight') topRectHeight: number = 0
  Column = new ColumnModifier()
  // 主题颜色
  // 亮暗色重构（2026-09-23）：订阅派生深色键 —— 渐变背景（ShelfColors.gradientStart/End）
  // 需要在深浅翻转时重绘；不订阅的话"自动"档跟随系统时会滞后到下一次重建。
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  /** 设置图标的 Q弹缩放值（2026-09-25 二次调优，`runJellyClick` 自驱 `.scale()`） */
  @State setIconScale: number = 1

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
      //右上角模式图标
      Row({ space: 10 }) {
        // VIP 金标（2026-09-28 用户要求：已开通时放在设置按钮左侧旁边）
        if (this.vipOn) {
          Text('VIP')
            .fontSize(12)
            .fontWeight(700)
            .fontColor(Color.White)
            .backgroundColor('#F5A623')
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        }
        //设置图标（2026-09-25：换成 SymbolGlyph，用户要求与书架页同批换 symbol。
        //符号名 `gearshape` 在 SDK 符号表 `…\Sdk\23\previewer\common\resources\entry\resources.txt`
        //查得，不猜名字。点击 Q弹缩放由 `.scale()` + `runJellyClick` 驱动（2026-09-25 二次调优：
        //内置 ScaleSymbolEffect 节奏定死太慢，借参考工程同款实现）。
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(26)
          .fontColor([ShelfColors.icon()])
          .scale({ x: this.setIconScale, y: this.setIconScale })
          .onClick(() => {
            Haptics.tap();
            runJellyClick((v: number) => {
              this.setIconScale = v
            })
            this.toMySetPage()
          })
          .clickEffect(UiMotion.CLICK)
      //夜间模式图标（2026-09-21 删除）：`night_onclick()` 是**空函数体**，
      //点了什么都不发生；整片右上角区域还绑着同一个空回调。
      }.justifyContent(FlexAlign.End).width("100%")

      Scroll() {
        // 整页**向上对齐**（用户要求）：内层 Column 显式撑满高度 + Start 对齐，
        // 并去掉原来垫在最上面的 `Blank(24)`，内容直接从顶部开始排。
        Column() {

          // 统计数据
          Row() {
            ForEach(this.head_list, (item: dataItem, index: number) => {
              Column({ space: 5 }) {
                Text(item.value.toString())
                  .fontSize(20)
                  .fontWeight(600)
                  // 数字翻滚动效（2026-09-21）。依据（SDK 原文）：
                  //   `contentTransition(transition: Optional<ContentTransition>)`
                  //     （`…\ets\component\text.d.ts:1248`，`@since 20`）
                  //   `declare class NumericTextTransition extends ContentTransition`
                  //     （`…\ets\component\text_common.d.ts:1971`，`@since 20`）
                  //   官方对它的限制原文：「It applies **only to positive integers** (decimals and
                  //   negative numbers are **not supported**)… The flip animation **fails if the text
                  //   contains child components** or is set via a styled string.」
                  // ⇒ 恰好匹配这三个计数：纯正整数、纯字符串、无子组件。
                  //   `enableBlur` 打开后翻转过程带一点模糊，观感更"高级"（默认 false）。
                  // 不想要就删掉这一行（`contentTransition` 是纯增量的属性）。
                  .contentTransition(new NumericTextTransition({
                    flipDirection: FlipDirection.DOWN,
                    enableBlur: true
                  }))
                Text(item.title).fontSize(10).fontWeight(500)
              }.onClick(() => {
                Haptics.tap();
                this.head_onclick(index)
              })
              .clickEffect(UiMotion.CLICK)
            })
          }.justifyContent(FlexAlign.SpaceBetween).width("100%").padding({ left: 20, right: 20 })

          // 固定高度间隔（**绝对不能用 `Blank`**）：
          // 本 Column 是 `height('100%')`，而 `Blank` 的语义是**撑满剩余空间**，
          // ⇒ 真机表现就是「主题」卡片被顶到页面最底部、与上面三个统计数字之间空出一大片
          //   （用户截图反馈「主题不够靠上」）。改成定高占位即可。
          Row().width('100%').height(16)

          //云盘 书源 主题 净化设置
          // 2026-09-24（用户反馈）：列表精简到只剩「主题」一项后，`SpaceBetween` 会把它
          //   排到整张卡片的最左边，且只有图标那 80vp 宽的小块能点。
          // ⇒ ① `justifyContent(Center)`：图标在整张卡里居中；
          //   ② 每项 `layoutWeight(1)`：单项时占满整行 = **整张卡片可点**，
          //      将来加回第二项也自动均分、各自可点。
          Row() {
            ForEach(this.center_list, (item: dataItem) => {
              Column({ space: 4 }) {
                Image(item.icon).size({ width: 24, height: 24 })
                Text(item.title).fontSize(12)
              }
              .height(48)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .onClick(() => {
                Haptics.tap();
                this.centerOnclick(item.value)
              })
              .clickEffect(UiMotion.CLICK)
            })
          }
          .width("100%")
          .justifyContent(FlexAlign.Center)
          .padding({ top: 16, bottom: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(10)
          // 卡片层次（2026-09-21）：与封面投影同一套视觉语言，给白色卡片一点"浮起来"的层次。
          // 纯增量属性、不动尺寸/布局 ⇒ 零回归风险；不想要就删这一行。
          // 用很淡的 0.06 透明度，避免在浅色渐变背景上显脏。
          .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })

          // ── 开通 VIP 卡片（2026-09-28 用户设计：未开通时显示）────────────────
          // 主题卡下方、整页水平居中、宽 30%（够字宽即可）、高度与主题卡持平（80）。
          if (!this.vipOn) {
            Row() {
              Row() {
                Text('开通 VIP')
                  .fontSize(14)
                  .fontWeight(600)
                  .fontColor('#F5A623')
              }
              .width('100%')
              .height(80)
              .justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(10)
              // 与主题卡同一套浮起层次（同款淡阴影）
              .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
              .clickEffect(UiMotion.CLICK)
              .onClick(() => {
                Haptics.tap();
                this.openVipDialog()
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 16 })
          }

        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ bottom: 10 })
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

  /**
   * 拉取「读过 / 读完 / 书签」真实计数。
   *
   * 三项**相互独立**（2026-09-21 用户明确要求）：
   *  · 读过 = `Books.durChapterTime > 0` 的书数
   *  · 读完 = `Books.finishedTime > 0` 的书数（"曾经读到末章"，只写一次）
   *  · 书签 = `bookmarks` 表条数
   *
   * ⚠️ 书签在**书签功能落地之前恒为 0** —— 底座没有书签功能，
   * `bookmarks` 表是移植时带过来的遗留物、无任何写入端。
   * 这里刻意走**真实查询**而不是硬编码 0，等写入端做好后无需再改。
   */
  async loadHeadCounts(): Promise<void> {
    try {
      const read = await BooksDao.countRead()
      const finished = await BooksDao.countFinished()
      const marks = await BookmarksDao.count()
      this.head_list = [
        new dataItem("读过", read),
        new dataItem("读完", finished),
        new dataItem("书签", marks),
      ]
    } catch (e) {
      console.log('loadHeadCounts, Error, ', JSON.stringify(e))
    }
  }

  //读过/读完/书签点击事件（0=读过 1=读完 2=书签）
  //「勋章」已于 2026-09-21 移除，故不再需要 `value == 3` 的空分支。
  head_onclick(value: number) {
    console.log("点击了" + value)
    // 迁 Navigation 第 4 期：readStatistics 已改为 NavDestination，改走路由门面。
    // ⚠️ 字段名必须用 `type`：目标页读的是 `(router.getParams() as dataItem).value`
    //    （`dataItem` 的字段就叫 `value`），而它的 `initParam` 类型是
    //    `ReadStatisticsRouteParam { type: number }` —— 两边字段名不同，
    //    这里刻意用 `type` 与接口对齐，值仍是原来的 `value`。
    AppRouter.push(RouteName.READ_STATISTICS, { type: value } as ReadStatisticsRouteParam)
  }

  //主题点击事件（2026-09-21 精简：只剩「主题」一项；
  //原「备份」「书源」「净化」的 case 1/3/4 已删除）
  centerOnclick(value: number | string) {
    switch (value) {
    // 点击主题
      case 2:
        // 迁 Navigation 第 4 期：主题配置页已改为 NavDestination，改走路由门面。
        AppRouter.push(RouteName.THEME_CONFIG)
        break
    }
  }

  toMySetPage() {
    // 迁 Navigation 第 4 期：我的设置已改为 NavDestination，改走路由门面。
    AppRouter.push(RouteName.MY_SET)
  }
}
