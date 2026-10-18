import { ColumnModifier } from '../../../common/utils/ComponetModifier';
import { Haptics } from '../../../common/utils/Haptics';
import CommonConstants from '../../../common/constants/CommonConstants';
import { dataItem } from '../../../componets/dataList/dataItem';
import { readStatisticsDataList } from '../../../componets/myCenter/readStatisticsDataList';
import { readBookList } from '../../../componets/dataList/readBookList';
import { serviceDialog } from '../../../componets/webDavService/serviceDialog';
import BooksDao from '../../../database/dao/BooksDao';
import { Books } from '../../../database/entities/Books';
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil';
import AppRouter, { ReadStatisticsRouteParam } from '../../../common/router/AppRouter';
import { ShelfColors } from '../../../common/utils/NightMode';
import { resolveBookCover } from '../../../common/utils/CoverSource';
import { ThemeStorageKey } from '../../../common/constants/Theme';
import { ThemeItem } from '../../../common/model/Theme';

/**
 * 「读过 / 读完」两个统计的二级菜单（**同一个模板，两套数据源**）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 2026-10-13 第二次改造：**「书签」整档下架**
 * ══════════════════════════════════════════════════════════════════════════
 * 用户拍板：「我的」页原来那一行三格（读过/读完/书签）整行删除，
 * 读过/读完 的入口搬进 `ReadDataCard` 的两个胶囊，**书签统计入口整个不要了**。
 * ⇒ 本页现在只服务 `type = 0`（读过）/ `type = 1`（读完）。
 * · `type = 2`（书签）分支、书签列表、书签删除、`totalChapMap` 百分比全部删除；
 * · **书签功能本身不受影响** —— 阅读器里有独立的 `ReaderBookmarkDialog`
 *   （2026-10-13 从目录弹窗拆出的「书签」按钮），`BookmarksDao.list()` 仍被它使用。
 *
 * 两个数据源仍然**相互独立**（用户 2026-09-21 明确要求）：
 *  · 读过 = `Books.durChapterTime > 0`；删除只清阅读进度字段，**不动 finishedTime**
 *  · 读完 = `Books.finishedTime > 0`（曾经读到末章，只写一次）；删除只清 `finishedTime`
 *
 * 书名的显示口径见 `readStatisticsDataList`（统一走 `bookNameDisplay()`，跟随
 * 「显示文件拓展名」开关 —— 这里过去直接渲染原始书名，永远带 `.txt`）。
 */
@Component
export default struct readStatistics {

  /**
   * 由 `Index.appRoutes()` 注入（原为 `(router.getParams() as dataItem).value`）。
   *
   * ⚠️ 字段名**不能**叫 `initParam` —— 编译器原文告警：
   *    「Methods, properties and accessors in structures decorated by '@Component'
   *      and '@ComponentV2' cannot have name as 'initParam'.」
   * 所以新建的页面一律用 `routeParam`。
   */
  routeParam: ReadStatisticsRouteParam = { type: 0 }

  // ⚠️ 页面底色：ColumnModifier 默认写死浅灰 ⇒ 暗色下整页发白。
  // 链式传入 `ShelfColors.pageBg()`（本页是 NavDestination，每次入栈都是新实例）。
  //
  // ★★ `withoutBottomInset()`：**底部不再让出系统手势区** ★★
  // 根因就是本修饰器给**页面盒子**加了 `padding.bottom` ⇒ 滚动内容被截在屏幕底以上。
  // 工程结论见 `docs/底部手势区贯通-排查记录.md:47,94`：
  //   「滚动容器盒子自身的底部 margin/padding 会把内容截在屏幕底以上；
  //     底部让位一律用 contentEndOffset（只动内容末尾）或给内容加内边距」
  Column = new ColumnModifier().backgroundColor(ShelfColors.pageBg()).withoutBottomInset()
  /** 全局主题（外层 Column 底色改为跟随主题渐变） */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  @State type: number | string = 0
  /**
   * 顶部「读过 / 读完」两个统计项（本页自己的标题页签）。
   * 2026-10-13：索引 0/1 与原实现一致，书签（原索引 2）已整体删除。
   */
  @State title_list: dataItem[] = [
    new dataItem("读过", 0),
    new dataItem("读完", 0),
  ]
  @State read_index: number = 0
  @State translateNum: number = 0
  @State translateX: number = 120
  /**
   * 表头「YYYY年 读过/读完 N 本」的 `[年份, 本数]`。
   *
   * 初值刻意用**当前年、0 本**（历史教训：写死 `[2023, 36]` 会在首帧显示假年份，
   * `loadData()` 覆盖之前用户能看见）。年份本身是真实逻辑：`applyTypeFilter()` 里
   * `new Date().getFullYear()` 取当前年。
   */
  @State dateValue: number[] = [new Date().getFullYear(), 0]
  @Provide delStatus: boolean = false
  /** 底部安全区高度（vp）—— 删除浮条要避开手势条（`EntryAbility` 写入 AppStorage） */
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0

  @State delDialog: boolean = false
  /** 渲染用（读过/读完走缩略图网格） */
  @State bookList: readBookList[] = []
  /** 与 `bookList` **下标对齐**的原始 Books，删除时取 id */
  private rawBooks: Books[] = []

  /**
   * 书架公共刷新信号（2026-10-07）：阅读器退出时广播 ⇒ 本页重拉数据。
   *
   * 为什么需要：本页可点进阅读器（`AppRouter.push(RouteName.READER)`），
   * 返回时本 NavDestination **未销毁**（官方 FAQ `faqs-arkui-404`：出栈才销毁，
   * 压栈不停留 ⇒ `aboutToAppear` 不会再跑），不订阅的话列表停在旧数据。
   */
  @StorageLink(CommonConstants.BOOK_IS_BOOK_REFRESHING) @Watch('onShelfBroadcast')
  isBookRefreshing: number = 0

  onShelfBroadcast(): void {
    this.loadData()
  }

  @Builder head() {
    Row() {
      Row() {
        // ── 返回键：SymbolGlyph（颜色完全由 fontColor 决定，日/夜随 ShelfColors 翻）
        // 原实现是 PNG 位图，`fillColor` 对 PNG 无效 ⇒ 暗色下仍是深色箭头。
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(CommonConstants.TITLE_IMG_SIZE)
          .fontColor([ShelfColors.icon()])
          .onClick(() => {
            Haptics.tap();
            // 本页是 NavDestination，`router.back()` 会把整个 Index 弹掉（直接回桌面）
            AppRouter.back()
          })
      }.width("33%")
      Row() {
        // 标题：统一走 `ShelfColors.textMain()`，与页面底色同源（不会出现"暗底黑字"）
        Text(this.title_list[this.readType()].title)
          .fontSize(16)
          .fontWeight(600)
          .lineHeight(24)
          .fontColor(ShelfColors.textMain())
      }.width("33%")
      .justifyContent(FlexAlign.Center)
      Row() {
        // 「管理 / 完成」：走 `ShelfColors.textSub()`，与列表副文本同款
        Text(this.delStatus ? "完成" : "管理")
          .fontSize(14)
          .fontWeight(500)
          .lineHeight(22)
          .fontColor(ShelfColors.textSub())
          .onClick(() => {
            Haptics.tap();
            this.delStatus = !this.delStatus
          })
      }.width("33%").justifyContent(FlexAlign.End)
    }.width("100%")
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({ top: 12, bottom: 12 })
  }

  /**
   * 管理态底部「删除」浮条（四圆角浮动 dock）。
   *
   * ⚠️⚠️ **`.overlay()` 的 builder 根节点必须给显式高度**（2026-10-13 真机回归）：
   * 不给 height 时 `overlay` 会把根节点撑到**整屏高**，内容贴顶 + 吃掉全部命中测试
   * （现象：「删除」跑到屏幕最上方、整页无法点击）。
   * ⇒ 高度 = 药丸高(48) + bottomRectHeight + 16，与 `padding.bottom` 用**同一个表达式**。
   */
  @Builder delBottom() {
    Column() {
      Row() {
        // 删除用强调红（与全工程"危险操作"同色系）
        Text("删除")
          .fontSize(15)
          .fontWeight(500)
          .fontColor('#E84026')
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(48)
      .borderRadius(24)
      .backgroundColor(ShelfColors.card())
      .shadow({ radius: 16, color: 'rgba(0, 0, 0, 0.12)', offsetX: 0, offsetY: 4 })
      .onClick(() => {
        Haptics.tap();
        this.deleteList()
      })
    }
    .width('100%')
    .height(48 + this.bottomRectHeight + 16)
    .padding({ left: 16, right: 16, bottom: this.bottomRectHeight + 16 })
    .visibility(this.delStatus ? Visibility.Visible : Visibility.None)
    .transition(
      TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 500 }).combine(
          TransitionEffect.translate({ y: 50 }).animation({ duration: 500 }))
        ,
        TransitionEffect.OPACITY.animation({ duration: 500 }).combine(
          TransitionEffect.translate({ y: 0 }).animation({ duration: 500 }))
      )
    )
  }

  build() {
    Column() {
      Column() {
        this.head()
        // 读过/读完 走缩略图网格（书签档已下架，不再有文字列表分支）
        // ── 2026-10-13：外层套 `layoutWeight(1)` 的 Column，把**确定的剩余高度**交给列表；
        //    直接给子组件写 `height('100%')` 会按整页内容区解析（含 head 占位）⇒ 溢出。
        Column() {
          readStatisticsDataList({
            dateValue: this.dateValue,
            headLabel: this.readType() === 0 ? '读过' : '读完',
            bookList: this.bookList
          })
        }
        .width(CommonConstants.FULL_WIDTH)
        .layoutWeight(1)
      }.attributeModifier(this.Column)
      .height(CommonConstants.FULL_HEIGHT)
      .width(CommonConstants.FULL_WIDTH)
      // 2026-10-12 适配全局主题渐变：纯色挂内层、渐变挂外层（外层渐变才能铺满整页）
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: ShelfColors.pageGradient(this.theme.mainColor, this.theme.secondColor)
      })
    }.overlay(this.delBottom(), {
      align: Alignment.Bottom,
      offset: { x: 0, y: 0 }
    })
  }

  /**
   * 归一化后的数据源类型：**只可能是 0（读过）或 1（读完）**。
   *
   * 历史：路由参数里可能带着 2（书签）—— 老调用点、旧深链、或用户从旧版本升级上来。
   * 书签档已删除，一律按"读过"兜底，绝不让 `title_list[2]` 越界（那会在渲染期抛异常）。
   */
  private readType(): number {
    const t: number = Number(this.type)
    return t === 1 ? 1 : 0
  }

  //删除列表
  deleteList() {
    this.clearInfoDel?.open()
  }

  onCancel() {
  }

  /** 确认删除 —— 只清当前档位对应的字段（读过/读完 互不影响） */
  async onAccept(): Promise<void> {
    const t: number = this.readType()
    for (let i = 0; i < this.bookList.length; i++) {
      if (this.bookList[i].status && i < this.rawBooks.length) {
        const id = this.rawBooks[i].id ?? 0
        if (t === 0) {
          await BooksDao.clearReadRecord(id)
        } else {
          await BooksDao.clearFinishRecord(id)
        }
      }
    }
    this.delStatus = false
    await this.loadData()
  }

  exitApp() {
    this.delDialog = false
  }

  clearInfoDel: CustomDialogController | null = new CustomDialogController({
    builder: serviceDialog({
      title: "确认删除吗？",
      value: "",
      cancel: () => { this.onCancel() },
      confirm: () => { this.onAccept() }
    }),
    cancel: this.exitApp,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    offset: { dx: 0, dy: 20 },
    customStyle: true,
    // 确认弹窗的材质走官方 options 渠道；配套的 `serviceDialog` 内已把内容层设为透明。
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })

  aboutToAppear(): void {
    // 迁 Navigation 第 4 期：注入参数 + loadData 合并到这里
    // （NavDestination 出栈即销毁 ⇒ 每次入栈都是新实例，`aboutToAppear` ≡ 原 `onPageShow`）
    this.type = this.routeParam.type
    this.loadData()
  }

  /**
   * 离开本页时通知「我的」刷新。
   * 为什么用 AppStorage 计数器：`MyCenter` 是 `pages/Index.ets` 的子组件、拿不到引用，
   * 且它也不是 `@Entry` ⇒ 只能靠共享状态单向通知。
   * 2026-10-13 起两张阅读数据卡也订阅了这个键（`@Watch('onDataTick')`）。
   */
  aboutToDisappear(): void {
    AppStorage.setOrCreate('myCenterTick', Date.now())
  }

  /** 拉取真实数据 */
  private async loadData(): Promise<void> {
    const t: number = this.readType()
    try {
      this.title_list = [
        new dataItem("读过", await BooksDao.countRead()),
        new dataItem("读完", await BooksDao.countFinished()),
      ]
    } catch (e) {
      console.log('readStatistics loadData head, Error, ', JSON.stringify(e))
    }

    let list: Books[] = []
    try {
      list = t === 0 ? await BooksDao.listRead() : await BooksDao.listFinished()
    } catch (e) {
      console.log('readStatistics loadData list, Error, ', JSON.stringify(e))
      list = []
    }
    this.rawBooks = list
    this.applyTypeFilter()
  }

  /**
   * 产出渲染列表 + 表头。
   *
   * `rawBooks` 必须与渲染列表**同一次过滤**产出 —— `onAccept()` 靠下标对齐
   * （`bookList[i]` ↔ `rawBooks[i]`）取删除 id，两处口径不一致就会删错书。
   * 表头「YYYY年读过/读完 N 本」同步改为过滤后的口径。
   */
  private applyTypeFilter(): void {
    const t: number = this.readType()
    const year = new Date().getFullYear()
    const yearStart = new Date(year, 0, 1, 0, 0, 0, 0).getTime()
    let inYear = 0
    for (const b of this.rawBooks) {
      const stamp = t === 0 ? (b.durChapterTime ?? 0) : (b.finishedTime ?? 0)
      if (stamp >= yearStart) {
        inYear++
      }
    }
    this.dateValue = [year, inYear]
    const out: readBookList[] = []
    for (const b of this.rawBooks) {
      const total = b.totalChapterNum ?? 0
      const cur = b.durChapterIndex ?? 0
      const pct = total > 0 ? Math.max(0, Math.min(100, Math.round((cur + 1) / total * 100))) : 0
      // 封面：统一走 `resolveBookCover`（自定义 > **自带** > 书源 > 默认），
      // 空值由 `Image.alt` 兜底（与书架 `BookInfos.ets` 一致）。
      const cover: ResourceStr = resolveBookCover(b)
      // 书名：**不在这里拼**。`readStatisticsDataList` 统一走 `bookNameDisplay()`，
      // 跟随「显示文件拓展名」开关（2026-10-13 修：过去这里直接传原始书名，永远带 `.txt`）。
      out.push(new readBookList(b.bookName, cover, b.author ?? '',
        [0, 0], new Date(t === 0 ? (b.durChapterTime ?? 0) : (b.finishedTime ?? 0)), pct, 0))
    }
    this.bookList = out
  }
}
