import { ColumnModifier } from '../../../common/utils/ComponetModifier';
import { Haptics } from '../../../common/utils/Haptics';
import CommonConstants from '../../../common/constants/CommonConstants';
import { dataItem } from '../../../componets/dataList/dataItem';
import { readStatisticsDataList } from '../../../componets/myCenter/readStatisticsDataList';
import { readBookList } from '../../../componets/dataList/readBookList';
// ⚠️ 2026-10-13：`readTabs`（那个只显示「书架」一个页签的分段控件）已不再使用 ——
// 分类模式只剩默认一种，页签恒为 1 项 ⇒ 纯冗余，按用户要求删掉。
// 组件文件 `componets/myCenter/readTabs.ets` **保留**（未引用即不打包，留着以备将来
// 真出现多分类）。要彻底删文件再说，本次不动，避免影响其它分支。
import { serviceDialog } from '../../../componets/webDavService/serviceDialog';
// （2026-10-13 顺手清掉未使用的 `PublicConstants` import —— 它只在下面那条注释里
//   被提到名字，代码里一次都没引用过。）
import BooksDao from '../../../database/dao/BooksDao';
import BookmarksDao, { BookmarkRow } from '../../../database/dao/BookmarksDao';
import { Books } from '../../../database/entities/Books';
import UiMotion from '../../../common/utils/UiMotion';
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil';
import AppRouter, { RouteName, ReaderRouteParam, ReadStatisticsRouteParam } from '../../../common/router/AppRouter';
import { ShelfColors } from '../../../common/utils/NightMode';
import { resolveBookCover } from '../../../common/utils/CoverSource';
import { ThemeStorageKey } from '../../../common/constants/Theme';
import { ThemeItem } from '../../../common/model/Theme';

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
  //
  // ★★ 2026-10-13 `withoutBottomInset()`：**底部不再让出系统手势区** ★★
  // 用户反馈「不够贯穿底部，还是有一条」。根因就是本修饰器给**页面盒子**加了
  // `padding.bottom = bottomRectHeight` ⇒ 滚动内容被截在屏幕底以上，剩下一条永远是
  // 页面底色。工程结论见 `docs/底部手势区贯通-排查记录.md:47,94`：
  //   「滚动容器盒子自身的底部 margin/padding 会把内容截在屏幕底以上；
  //     底部让位一律用 contentEndOffset（只动内容末尾）或给内容加内边距」。
  // ⇒ 盒子留边归零，让位职责交给 `readStatisticsDataList` 的**内容末尾内边距**
  //   （那里已按 `bottomRectHeight + 16/80` 补好，最后一项照样不会被手势条/删除浮条压住）。
  Column = new ColumnModifier().backgroundColor(ShelfColors.pageBg()).withoutBottomInset()
  /** 全局主题（2026-10-12：外层 Column 底色改为跟随主题渐变） */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  @State type: number | string = 0
  /**
   * 顶部「读过 / 读完 / 书签」三个统计项（本页自己的标题页签，**保留**）。
   * 2026-10-13：原来这里还有一份 `read_list`（分类页签「书架」）—— 分类模式只剩默认一种，
   * 那排只含一个「书架」的分段控件已按用户要求删除（见 `build()`）。
   */
  @State title_list: dataItem[] = [
    new dataItem("读过", 0),
    new dataItem("读完", 0),
    new dataItem("书签", 0),
  ]
  @State read_index: number = 0
  @State translateNum: number = 0
  @State translateX: number = 120
  /**
   * 表头「YYYY年 读过/读完 N 本」的 `[年份, 本数]`。
   *
   * ⚠️ 2026-10-13 修初值：原来写死 `[2023, 36]`（底座样例遗留）。它虽然是**占位值**、
   *    `loadData()` 一跑就会被真实值覆盖，但真机上存在"先渲染一帧占位再刷新"的窗口
   *    （`readStatisticsDataList.readHeader` 的注释就记着更早那次"表头永远停在 2023年36本"
   *    的事故）⇒ 初值改成**当前年、0 本**，任何时刻都不会显示出一个假的年份。
   * 年份本身是**真实逻辑**：`applyTypeFilter()` 里 `new Date().getFullYear()` 取当前年，
   *    统计时间戳落在本年度内的本数 ⇒ 2027 年读书会自动显示「2027年读过 N 本」。
   */
  @State dateValue: number[] = [new Date().getFullYear(), 0]
  @Provide delStatus: boolean = false
  /**
   * 底部安全区高度（vp）—— 删除浮条要避开手势条。
   * 与阅读器/书架同源：`EntryAbility` 启动时把 `bottomRectHeight` 写进 AppStorage
   * （`EntryAbility.ets` 的 `getWindowAvoidArea(TYPE_NAVIGATION_INDICATOR)` → `toVp`）。
   */
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0

  @State delDialog: boolean = false
  /** 渲染用（读过/读完走缩略图网格） */
  @State bookList: readBookList[] = []
  /** 与 `bookList` **下标对齐**的原始 Books，删除时取 id */
  private rawBooks: Books[] = []
  /**
   * 当前页类型（读过/读完）的**全量**记录 —— 渲染列表的数据源。
   * 2026-09-29（审核问题⑤）：页签过去只动 `readTabs` 内部的滑块、从不上报
   * ⇒ 列表恒为全量、"筛选无效果"。当时引入 `typeIndex` 按 `bookType` 过滤。
   * 2026-10-11：分类页签只剩「书架」一个（漫画/有声书入口已删）⇒ 不再按 `bookType`
   * 过滤，`typeIndex` 仅保留为 `readTabs` 回调的状态镜像。
   * ⚠️ `rawBooks` 必须与渲染列表**同源**（`applyTypeFilter()` 里一次产出），
   * 批量删除靠下标对齐（`bookList[i]` ↔ `rawBooks[i]`）。
   */
  private allTypeBooks: Books[] = []
  // （2026-10-13：`@State typeIndex` 已删 —— 它原本只是分类页签的状态镜像，
  //   页签条已按用户要求删除，`applyTypeFilter()` 也不再按 bookType 过滤。）
  /** 书签列表（文字两行） */
  @State markList: BookmarkRow[] = []
  /** 书签被选中待删的 time 集合 */
  @State markChecked: number[] = []
  /** bookName → 总章数，用于算书签的进度百分比 */
  private totalChapMap: Map<string, number> = new Map()
  /**
   * 书架公共刷新信号（2026-10-07）：阅读器退出时广播（`ReaderPage3
   * .flushReadProgressThenNotifyShelf`）⇒ 本页重拉数据。
   *
   * 为什么需要：本页可经书签跳进阅读器（`AppRouter.push(RouteName.READER)`），
   * 返回时本 NavDestination **未销毁**（官方 FAQ `faqs-arkui-404`：出栈才销毁，
   * 压栈不停留 ⇒ `aboutToAppear` 不会再跑），而阅读期间新增的书签、「读完」标记
   * 都落了库 ⇒ 不订阅广播的话，返回后列表停在旧数据。
   */
  @StorageLink(CommonConstants.BOOK_IS_BOOK_REFRESHING) @Watch('onShelfBroadcast')
  isBookRefreshing: number = 0

  onShelfBroadcast(): void {
    this.loadData()
  }

  @Builder head() {
    Row() {
      Row() {
        // ── 返回键（2026-10-13 改 SymbolGlyph）────────────────────────────────
        // 原实现是 `Image($r('app.media.return_left'))` —— **PNG 位图**（2354 B），
        // 位图的像素颜色烧死在文件里，`fillColor` 对 PNG 无效 ⇒ 暗色下仍是深色箭头，
        // 在深底上几乎看不见（正是用户反馈「左侧的返回<在暗色模式下缺少颜色适配」）。
        // 改用文字型 SymbolGlyph：颜色完全由 `fontColor` 决定，日/夜随 `ShelfColors.icon()` 翻。
        // 符号名已核真源 `sysResource.js`：`chevron_left: 125832663`。
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(CommonConstants.TITLE_IMG_SIZE)
          .fontColor([ShelfColors.icon()])
          .onClick(() => {
            Haptics.tap();
            // 迁 Navigation 第 4 期：本页现在是 NavDestination，
            // `router.back()` 会把整个 Index 弹掉（直接回桌面）⇒ 必须走门面。
            AppRouter.back()
          })
      }.width("33%")
      Row() {
        // 标题（2026-10-13）：原先**没写 fontColor**，用的是系统默认字色 token。
        // 那个 token 跟的是 Ability 配色（`setColorMode`），而本页底色跟的是
        // `ShelfColors.pageBg()` / `pageGradient()`（AppStorage 驱动）—— 两套机制
        // 在某些时序下会不同步（暗底 + 黑字）。统一走 `ShelfColors.textMain()`，
        // 与底色同源，任何时序都不会错配。
        Text(this.title_list[this.type].title)
          .fontSize(16)
          .fontWeight(600)
          .lineHeight(24)
          .fontColor(ShelfColors.textMain())
      }.width("33%")
      .justifyContent(FlexAlign.Center)
      Row() {
        // 「管理 / 完成」（2026-10-13）：原用 `$r('app.color.text_secondary')`。
        // 该资源**确实**有暗色变体（`resources/dark/element/color.json`：
        // 日 `#99606060` / 暗 `#9EF8F9FA`），但它生效的前提是 Ability 配色被切成 DARK
        // —— 而本页背景走的是 `ShelfColors`（AppStorage）。两套机制必须同源才不会
        // 出现"背景已暗、字还是暗字的灰"。这里改用 `ShelfColors.textSub()`
        // （日 rgba(96,96,96,0.6) / 暗 rgba(248,249,250,0.62)），与列表副文本同款。
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
   * 管理态底部「删除」浮条（2026-10-13 改版）。
   *
   * ── 改前 / 改后（用户原话）───────────────────────────────────────────────
   * 「管理，选择之后，底部删除按钮，不是精致的四圆角小弹窗（系统风格统一），
   *   而是一种撑满覆盖，优化一下。」
   * 改前：`overlay` 里一条 `width('100%')` + `height(50)` 的实心条，**左右贴边、
   *   直角、无投影** ⇒ 看起来像"被裁了一块的页面"，不像浮在页面上的控件；
   *   而且底边压在屏幕最底，手势条会盖住它。
   * 改后：**四圆角浮动 dock** —— 左右各留 16vp、圆角 24（= 高的一半，胶囊形）、
   *   `ShelfColors.card()` 实底 + 柔和投影、底部避开系统手势区
   *   （`bottomRectHeight` + 16vp）。整条与全应用"悬浮 dock"观感一致
   *   （书架 dock / 阅读器底栏都是这个语言）。
   *
   * ⚠️ 外层 Column 用 `width('100%')` + `padding` 而不是给内层 Row 设
   *    `width('100%')` + `margin` —— 后者在 ArkUI 里会**超出父容器宽度**
   *    （百分比宽按父宽算、margin 再外扩），表现就是"右侧被裁掉一截"。
   *    本页 `readStatisticsDataList` 也有同款注意点。
   *
   * ⚠️⚠️ **`.overlay()` 的 builder 根节点必须给显式高度**（2026-10-13 真机回归）⚠️⚠️
   *    第一版这里只有 `width('100%') + padding`、**没有 height**，真机现象：
   *      ① 「删除」跑到**整个屏幕最上方**并溢出；
   *      ② 整页无法点击其它内容。
   *    原因：`overlay` 会把 builder 的根节点撑到**父容器的整屏高度**，
   *    而 `Column` 默认 `justifyContent = FlexAlign.Start` ⇒ 内容贴顶；
   *    那块整屏高的 overlay 层同时吃掉了全部命中测试。
   *    本工程另一处 overlay（`componets/myCenter/readTabs.ets:79`）的 builder 根节点
   *    `Row` 写了 `.height(30)`；改造前的旧版这里也是 `Button.height(50)` —— 都有显式高度。
   *    ⇒ 这里必须写 `height = 药丸高(48) + 底部避让(bottomRectHeight + 16)`，
   *      与 `padding.bottom` 用**同一个表达式**，两处一起改，否则高度会打架。
   */
  @Builder delBottom() {
    Column() {
      Row() {
        // 删除用强调红（与全工程"危险操作"同色系；`ACCENT_RED` 在本工程已有先例）
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
      // 与「我的」页卡片同一套浮起层次（同款淡投影，见 MyCenter 的 VIP 卡片）
      .shadow({ radius: 16, color: 'rgba(0, 0, 0, 0.12)', offsetX: 0, offsetY: 4 })
      .onClick(() => {
        Haptics.tap();
        this.deleteList()
      })
    }
    .width('100%')
    // ★ 显式高度 —— overlay 根节点没它就会被撑满整屏（见上方 ⚠️⚠️）
    //   48（药丸高）+ bottomRectHeight + 16（离手势条的呼吸位）
    .height(48 + this.bottomRectHeight + 16)
    // 底部避让系统手势条：本页是 NavDestination，`overlay` 对齐的是**整页底边**，
    // 不留白的话浮条会被手势条压住一半。
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
          // ── 2026-10-13：删掉分类页签条（`readTabs`）────────────────────────
          // 那里原本只有「书架」一个选项 —— 分类模式已只剩默认一种，
          // 一个只含单项的分段控件既没有可选项、又白占一行高度（用户要求删除）。
          // 「读过 / 读完」的直接从表头「YYYY年 读过 N 本」开始。
          // ── 2026-10-13 修「底部被遮住一大块」────────────────────────────────
          // 原写法直接把 `readStatisticsDataList` 当兄弟节点摆进本 Column：
          // 它内部滚动区是 `.size({ height:"80%" })` + `.align(TopStart)`
          // ⇒ 只占剩余高度的 80%、贴顶 ⇒ 底部约 20% 整块空出（用户反馈的"遮罩"）。
          // 修法：外面套一层 `layoutWeight(1)` 的 Column，把**确定的剩余高度**交给它；
          //   子组件内部再把高度改成 `height('100%')` + 滚动区 `layoutWeight(1)`，
          //   就能像书架一样铺到页面底边。
          // ⚠️ 这层包裹是必需的：直接给子组件写 `height('100%')` 会按**整个页面内容区**
          //   解析（含上方 `head()` 占掉的位置）⇒ 头部 + 100% 溢出。
          Column() {
            readStatisticsDataList({
              dateValue: this.dateValue,
              headLabel: Number(this.type) === 0 ? '读过' : '读完',
              bookList: this.bookList
            })
          }
          .width(CommonConstants.FULL_WIDTH)
          .layoutWeight(1)
        }
      }.attributeModifier(this.Column)
      .height(CommonConstants.FULL_HEIGHT)
      .width(CommonConstants.FULL_WIDTH)
      // 2026-10-12 适配全局主题渐变（与书架/我的同源配色对与 stop）。
      // ⚠️ 注意层次：`attributeModifier(this.Column)` 在**内层** Column 上给了
      //    纯色 `ShelfColors.pageBg()`；渐变挂**外层** Column ⇒ 外层渐变铺满整页，
      //    内层纯色被其自身内容（列表）遮挡的部分不可见，两者不冲突；
      //    若把纯色留在最外层，渐变就永远被盖住 —— 这是本页必须挂外层的原因。
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: ShelfColors.pageGradient(this.theme.mainColor, this.theme.secondColor)
      })
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

  /** 书签进度百分比：章下标 / 总章数（电脑端书签 chapterIndex = -1，无手机端章号 ⇒ 0） */
  private markPercent(row: BookmarkRow): number {
    const total = this.totalChapMap.get(row.bookName ?? '') ?? 0
    const idx = row.chapterIndex ?? 0
    if (total <= 0 || idx < 0) {
      return 0
    }
    return Math.max(0, Math.min(100, Math.round((idx + 1) / total * 100)))
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
    this.allTypeBooks = list
    // 2026-10-13：分类页签条已删除 ⇒ 不再往 `read_list` 喂数字（该状态一并删除）。
    this.applyTypeFilter()
  }

  /**
   * 按选中页签过滤（2026-09-29，审核问题⑤）。
   *
   * `rawBooks` 必须与渲染列表**同一次过滤**产出 —— `onAccept()` 靠下标对齐
   * （`bookList[i]` ↔ `rawBooks[i]`）取删除 id，两处过滤口径不一致就会删错书。
   * 表头「YYYY年读过/读完 N 本」同步改为过滤后的口径，与列表一致。
   */
  private applyTypeFilter(): void {
    const t = Number(this.type)
    // 2026-10-11：分类页签只剩「书架」一个 ⇒ 不再按 `bookType` 过滤（原：
    //   `filter((b) => b.bookType === this.typeIndex)`）。保留本方法是因为它还要算
    //   「YYYY年 N 本」表头、算每本进度、并产出与渲染列表**下标对齐**的 `rawBooks`。
    const filtered: Books[] = this.allTypeBooks
    this.rawBooks = filtered
    const year = new Date().getFullYear()
    const yearStart = new Date(year, 0, 1, 0, 0, 0, 0).getTime()
    let inYear = 0
    for (const b of filtered) {
      const stamp = t === 0 ? (b.durChapterTime ?? 0) : (b.finishedTime ?? 0)
      if (stamp >= yearStart) {
        inYear++
      }
    }
    this.dateValue = [year, inYear]
    const out: readBookList[] = []
    for (const b of filtered) {
      const total = b.totalChapterNum ?? 0
      const cur = b.durChapterIndex ?? 0
      const pct = total > 0 ? Math.max(0, Math.min(100, Math.round((cur + 1) / total * 100))) : 0
      // 封面：直接交地址，空值由 `Image.alt` 兜底（与书架 `BookInfos.ets:62-64` 一致）。
      // 旧实现空值兜底用的是 `app.media.book_cover`，那是个样板图 ⇒ 真机上"缩略图不对"。
      // 2026-10-06：并补上 `customCoverUrl` 优先级（`CoverSource.ets` 头注释的唯一契约），
      // 否则书架换过封面的书在统计页仍是旧封面/默认封面（"封面不与全局同步"同类）。
      // 2026-10-13：统一走 `resolveBookCover`（自定义 > **自带** > 书源 > 默认），
      // 自带封面（导入时从 epub 等提取）在统计页同样生效。
      const cover: ResourceStr = resolveBookCover(b)
      out.push(new readBookList(b.bookName, cover, b.author ?? '',
        [0, 0], new Date(t === 0 ? (b.durChapterTime ?? 0) : (b.finishedTime ?? 0)), pct, 0))
    }
    this.bookList = out
  }
}
