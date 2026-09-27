import { ColumnModifier } from '../../../common/utils/ComponetModifier';
import { Haptics } from '../../../common/utils/Haptics';
import CommonConstants from '../../../common/constants/CommonConstants';
import { dataItem } from '../../../componets/dataList/dataItem';
import { readStatisticsDataList } from '../../../componets/myCenter/readStatisticsDataList';
import { readBookList } from '../../../componets/dataList/readBookList';
import { readTabs } from '../../../componets/myCenter/readTabs';
import { serviceDialog } from '../../../componets/webDavService/serviceDialog';
import { PublicConstants } from '../../../common/constants/PublicConstants';
import BooksDao from '../../../database/dao/BooksDao';
import BookmarksDao, { BookmarkRow } from '../../../database/dao/BookmarksDao';
import { Books } from '../../../database/entities/Books';
import UiMotion from '../../../common/utils/UiMotion';
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil';
import AppRouter, { RouteName, ReaderRouteParam, ReadStatisticsRouteParam } from '../../../common/router/AppRouter';
import { ShelfColors } from '../../../common/utils/NightMode';

/**
 * 「读过 / 读完 / 书签」三个统计的二级菜单（**同一个模板，三套数据源**）。
 *
 * 2026-09-21 改造：原来整页都是硬编码样例（8 条全是「夜的命名术」），
 * 现在接真实数据。三个数据源**相互独立**（用户明确要求）：
 *  · 0 读过 = `Books.durChapterTime > 0`；删除只清阅读进度字段，**不动 finishedTime**
 *  · 1 读完 = `Books.finishedTime > 0`（曾经读到末章，只写一次）；删除只清 `finishedTime`
 *  · 2 书签 = `bookmarks` 表；删除只删书签行
 * 三者互不影响。
 *
 * 书签用**文字两行列表**（用户口径）：①书名 + 进度百分比 ②存书签那页首行前 10 字
 * （后者在写入时就截好了，存在 `bookmarks.bookText`）。
 */
@Component
export default struct readStatistics {

  /**
   * 由 `Index.appRoutes()` 注入（原为 `(router.getParams() as dataItem).value`）。
   *
   * ⚠️ 字段名**不能**叫 `initParam` —— 编译器原文告警：
   *    「Methods, properties and accessors in structures decorated by '@Component'
   *      and '@ComponentV2' cannot have name as 'initParam'.」
   * 所以新建的页面一律用 `routeParam`。（`ReaderPage3` 里那个同名的 `initParam`
   * 是第 3 期留的、已在真机验证通过，本次**不动它**以免引入回归。）
   */
  routeParam: ReadStatisticsRouteParam = { type: 0 }

  // ⚠️ 页面底色：ColumnModifier 默认写死浅灰（PublicConstants.WINDOW_BACKGROUND_COLOR）
  // ⇒ 暗色下整页发白。链式传入 ShelfColors.pageBg()（本页是 NavDestination，每次入栈
  // 都是新实例 ⇒ 构造时取色即为当次正确的深浅档）。
  Column = new ColumnModifier().backgroundColor(ShelfColors.pageBg())
  @State type: number | string = 0
  /** 小说/漫画/有声书 三个小标签的数量（按 `Books.bookType` 真实统计） */
  @State read_list: dataItem[] = [
    new dataItem("小说", 0),
    new dataItem("漫画", 0),
    new dataItem("有声书", 0),
  ]
  @State title_list: dataItem[] = [
    new dataItem("读过", 0),
    new dataItem("读完", 0),
    new dataItem("书签", 0),
  ]
  @State read_index: number = 0
  @State translateNum: number = 0
  @State translateX: number = 120
  @State dateValue: number[] = [2023, 36]
  @Provide delStatus: boolean = false

  @State delDialog: boolean = false
  /** 渲染用（读过/读完走缩略图网格） */
  @State bookList: readBookList[] = []
  /** 与 `bookList` **下标对齐**的原始 Books，删除时取 id */
  private rawBooks: Books[] = []
  /** 书签列表（文字两行） */
  @State markList: BookmarkRow[] = []
  /** 书签被选中待删的 time 集合 */
  @State markChecked: number[] = []
  /** bookName → 总章数，用于算书签的进度百分比 */
  private totalChapMap: Map<string, number> = new Map()

  @Builder head() {
    Row() {
      Row() {
        Image($r("app.media.return_left"))
          .size({ width: CommonConstants.TITLE_IMG_SIZE, height: CommonConstants.TITLE_IMG_SIZE })
          .onClick(() => {
            Haptics.tap();
            // 迁 Navigation 第 4 期：本页现在是 NavDestination，
            // `router.back()` 会把整个 Index 弹掉（直接回桌面）⇒ 必须走门面。
            AppRouter.back()
          })
      }.width("33%")
      Row() {
        Text(this.title_list[this.type].title).fontSize(16).fontWeight(600).lineHeight(24)
      }.width("33%")
      .justifyContent(FlexAlign.Center)
      Row() {
        Text(this.delStatus ? "完成" : "管理")
          .fontSize(14)
          .fontWeight(500)
          .lineHeight(22)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => {
            Haptics.tap();
            this.delStatus = !this.delStatus
          })
      }.width("33%").justifyContent(FlexAlign.End)
    }.width("100%")
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({ top: 12, bottom: 12 })
  }

  @Builder delBottom() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row() {
        Text("删除").fontColor(Color.Red)
      }.height("100%")
    }.backgroundColor($r('app.color.card_bg'))
    .width("100%")
    .height(50)
    .borderColor($r('app.color.sub_btn_bg'))
    .borderWidth({
      top: 1
    })
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
    .onClick(() => {
      Haptics.tap();
      this.deleteList()
    })
  }

  /** 书签列表项：两行 —— ①书名 + 进度% ②存书签那页首行前 10 字 */
  @Builder markItem(row: BookmarkRow, idx: number) {
    Row({ space: 10 }) {
      if (this.delStatus) {
        SymbolGlyph($r(this.markChecked.indexOf(row.time) >= 0
          ? 'sys.symbol.checkmark_circle_fill' : 'sys.symbol.circle'))
          .fontSize(20)
          .fontColor([this.markChecked.indexOf(row.time) >= 0 ? '#007DFF' : $r('app.color.text_tertiary')])
          // 勾选时的符号形变动效（2026-09-21）。用 triggerValue 重载而不是 isActive
          // （isActive 默认 false = 不播放），依据见 ReaderPage3 书签图标处的 SDK 原文注释。
          .symbolEffect(new ReplaceSymbolEffect(), this.markChecked.indexOf(row.time) >= 0 ? 1 : 0)
      }
      Column({ space: 4 }) {
        Row() {
          Text(row.bookName ?? '')
            .fontSize(15)
            .fontWeight(500)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(`${this.markPercent(row)}%`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }.width('100%')
        // ⚠️ 必须逐字段兜底：真机崩溃栈
        //   `TypeError: Cannot read property length of undefined`
        //   at readStatistics.ets:138 (markItem) —— 数据库读回的 `bookText` 可能是 undefined
        //   （`queryForList` 的字段映射不保证每个列都有值）。
        Text(this.markLine2(row))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      Haptics.tap();
      if (this.delStatus) {
        // 管理态：勾选
        const at = this.markChecked.indexOf(row.time)
        if (at >= 0) {
          this.markChecked.splice(at, 1)
        } else {
          this.markChecked.push(row.time)
        }
        this.markChecked = this.markChecked.slice()
      } else {
        // 普通态：跳到该书阅读页的**书签所在页**
        this.openBookAt(row)
      }
    })
    // 点击按压反馈（2026-09-21），依据见 `UiMotion` 注释
    .clickEffect(UiMotion.CLICK)
  }

  @Builder markListBuilder() {
    List({ space: 0 }) {
      ForEach(this.markList, (row: BookmarkRow, idx: number) => {
        ListItem() {
          this.markItem(row, idx)
        }
      }, (row: BookmarkRow) => row.time.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .divider({ strokeWidth: 1, color: $r('app.color.sub_btn_bg') })
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      Column() {
        this.head()
        // 读过/读完走缩略图网格；书签走文字两行列表
        if (Number(this.type) === 2) {
          this.markListBuilder()
        } else {
          readTabs({
            read_list: this.read_list
          })
          readStatisticsDataList({
            dateValue: this.dateValue,
            headLabel: Number(this.type) === 0 ? '读过' : '读完',
            bookList: this.bookList
          })
        }
      }.attributeModifier(this.Column)
      .height(CommonConstants.FULL_HEIGHT)
      .width(CommonConstants.FULL_WIDTH)
    }.overlay(this.delBottom(), {
      align: Alignment.Bottom,
      offset: { x: 0, y: 0 }
    })
  }

  /** 书签第二行文案。
   *
   * 口径（用户明确要求）：**存书签那页首行的前 10 个字**。
   *
   * 2026-09-21 曾短暂改成"章节名优先"，原因是那时取不到正文 ——
   * `ReaderPage3.currentPageFirstLine()` 取自 `TtsEngine.currentNodeTexts()`，
   * 而引擎不朗读时该值为 null，于是 `bookText` 恒空、只能退回章节名
   * （真机表现为「第二行全是第一章名 preface」）。
   * 现在 `ReaderPage3` 已改为走旁路 `TtsEngine.previewNodeTexts()` 按需读章节正文
   * （复用同一个 `buildChapterNodes()` 块节点模型），**纯默读也能取到正文**，
   * 故恢复"前 10 字"优先；取不到时才退回章节名（老书签就是这种）。
   */
  private markLine2(row: BookmarkRow): string {
    const t = row.bookText ?? ''
    if (t.length > 0) {
      return t
    }
    const c = row.chapterName ?? ''
    return c.length > 0 ? c : '（无记录）'
  }

  /** 书签进度百分比：章下标 / 总章数 */
  private markPercent(row: BookmarkRow): number {
    const total = this.totalChapMap.get(row.bookName ?? '') ?? 0
    if (total <= 0) {
      return 0
    }
    return Math.max(0, Math.min(100, Math.round(((row.chapterIndex ?? 0) + 1) / total * 100)))
  }

  /**
   * 由书签跳到该书阅读页的**书签所在位置**（书签列表用；找不到就提示）。
   *
   * ⚠️ 2026-09-21 修复：旧实现只传了 `{ bookData: hit }` —— **只有"书"，没有"位置"**，
   * 所以点击书签只是"打开这本书"，落在书籍自身进度上，而不是书签那一页。
   * 现改为把 `bookmarks.chapterIndex`（目录号）与 `bookmarks.chapterPos`（页首块节点号）
   * 一起带过去，由 `ReaderPage3.tryBookmarkJump()` 复用 `requestLocate()` 精确回跳。
   */
  private async openBookAt(row: BookmarkRow): Promise<void> {
    const bookName = row.bookName ?? ''
    try {
      const all = await BooksDao.search({})
      const hit = all.find((b: Books) => b.bookName === bookName)
      if (hit === undefined) {
        this.getUIContext().getPromptAction().showToast({ message: '找不到这本书（可能已删除）' })
        return
      }
      // 迁 Navigation 第 3 期：阅读页已改为 NavDestination，改走路由门面
      const rp: ReaderRouteParam = {
        bookData: hit,
        bmChapterIndex: row.chapterIndex ?? 0,
        bmNode: row.chapterPos ?? 0
      };
      AppRouter.push(RouteName.READER, rp)
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '打开失败' })
    }
  }

  //删除列表
  deleteList() {
    this.clearInfoDel?.open()
  }

  onCancel() {
  }

  /**
   * 确认删除 —— **三套数据各删各的，互不影响**。
   */
  async onAccept(): Promise<void> {
    const t = Number(this.type)
    if (t === 2) {
      // 书签：只删书签行
      for (const time of this.markChecked) {
        await BookmarksDao.remove(time)
      }
      this.markChecked = []
    } else {
      // 读过 / 读完：按 id 清对应字段
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
    // 确认弹窗的材质走官方 options 渠道（说明见 BookInfos.ets 同处注释）；
    // 配套的 `serviceDialog` 内已用 `MaterialColumnModifier(..., true)` 把内容层设为透明。
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })

  aboutToAppear(): void {
    // 迁 Navigation 第 4 期：原来这里是"注入参数 + loadData()"分离在 aboutToAppear/onPageShow 两处，
    // 现在合并 —— 依据见下面 `aboutToDisappear` 上方的注释。
    this.type = this.routeParam.type
    this.loadData()
  }

  /**
   * 离开本页时通知「我的」刷新三个计数（`MyCenter.loadHeadCounts()`）。
   * 场景：本页删了书签 / 清了读过记录 ⇒ 返回「我的」后头像区数字要跟着变。
   * 为什么用 AppStorage 计数器而不是直接调用：`MyCenter` 是 `pages/Index.ets` 的
   * **子组件**、拿不到引用，且它也不是 `@Entry` ⇒ 只能靠共享状态单向通知。
   *
   * ── 迁 Navigation 第 4 期：`onPageShow`/`onPageHide` → 组件生命周期 ────────
   * `onPageShow`/`onPageHide` 是 **`@Entry` 页面专属**生命周期，去掉 `@Entry` 后
   * 它们**不会报错、但也不会再触发**（静默失效，很难发现）。
   *
   * 而 `NavDestination` 不需要它们，因为官方明确「**页面出栈后会被销毁**」
   * （documentId `FAQ/UI框架/组件使用/Navigation组件中_NavDestination页面是否可以缓存_
   * 下次入栈可以复用/faqs-arkui-404` 原文：「NavDestination 不支持缓存功能，
   * 页面出栈后会被销毁。」）⇒ 每次入栈都是全新实例：
   *   · `aboutToAppear` ≡ 原 `onPageShow`（每次进入都会触发）
   *   · `aboutToDisappear` ≡ 原 `onPageHide`
   */
  aboutToDisappear(): void {
    AppStorage.setOrCreate('myCenterTick', Date.now())
  }

  /** 拉取真实数据 */
  private async loadData(): Promise<void> {
    const t = Number(this.type)
    // 总章数映射（书签进度百分比用）
    try {
      const all = await BooksDao.search({})
      const m = new Map<string, number>()
      for (const b of all) {
        m.set(b.bookName, b.totalChapterNum ?? 0)
      }
      this.totalChapMap = m
      // 小说/漫画/有声书 三个小标签：按 bookType 真实统计
      let n0 = 0
      let n1 = 0
      let n2 = 0
      for (const b of all) {
        if (b.bookType === 0) { n0++ } else if (b.bookType === 1) { n1++ } else if (b.bookType === 2) { n2++ }
      }
      this.read_list = [new dataItem("小说", n0), new dataItem("漫画", n1), new dataItem("有声书", n2)]
      this.title_list = [
        new dataItem("读过", await BooksDao.countRead()),
        new dataItem("读完", await BooksDao.countFinished()),
        new dataItem("书签", await BookmarksDao.count()),
      ]
    } catch (e) {
      console.log('readStatistics loadData head, Error, ', JSON.stringify(e))
    }

    if (t === 2) {
      this.markList = await BookmarksDao.list()
      this.markChecked = []
      return
    }

    let list: Books[] = []
    try {
      list = t === 0 ? await BooksDao.listRead() : await BooksDao.listFinished()
    } catch (e) {
      console.log('readStatistics loadData list, Error, ', JSON.stringify(e))
      list = []
    }
    this.rawBooks = list
    // ★「YYYY年度过/读完 N 本」= **当前自然年**内有对应记录的书数。
    //   原值是底座样例遗留的硬编码 `[2023, 36]`（`@State dateValue` 初值），
    //   曾因为表头 @Builder 按值传参不刷新而在真机上一直显示「2023年读过36本」。
    const year = new Date().getFullYear()
    const yearStart = new Date(year, 0, 1, 0, 0, 0, 0).getTime()
    let inYear = 0
    for (const b of list) {
      const stamp = t === 0 ? (b.durChapterTime ?? 0) : (b.finishedTime ?? 0)
      if (stamp >= yearStart) {
        inYear++
      }
    }
    this.dateValue = [year, inYear]
    const out: readBookList[] = []
    for (const b of list) {
      const total = b.totalChapterNum ?? 0
      const cur = b.durChapterIndex ?? 0
      const pct = total > 0 ? Math.max(0, Math.min(100, Math.round((cur + 1) / total * 100))) : 0
      // 封面：直接交地址，空值由 `Image.alt` 兜底（与书架 `BookInfos.ets:62-64` 一致）。
      // 旧实现空值兜底用的是 `app.media.book_cover`，那是个样板图 ⇒ 真机上"缩略图不对"。
      const cover: ResourceStr = b.coverUrl ?? ''
      out.push(new readBookList(b.bookName, cover, b.author ?? '',
        [0, 0], new Date(t === 0 ? (b.durChapterTime ?? 0) : (b.finishedTime ?? 0)), pct, 0))
    }
    this.bookList = out
  }
}
