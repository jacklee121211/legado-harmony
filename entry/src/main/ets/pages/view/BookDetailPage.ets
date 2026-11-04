import { GroupEvents, GroupChangedListener, GroupChangedPayload } from '../../common/group/GroupEvents'
import CommonConstants from '../../common/constants/CommonConstants'
import { Haptics } from '../../common/utils/Haptics';
// 2026-09-21 精简：`ReadRecordItem` / `TagIndex` / `NoteIndex` 三个组件随
// 「阅读记录」「分类标签」「笔记 Tab」一起移除，故不再 import；
// `SwipeRefresher` 随「书源 Tab」移除。
import AppRouter, { ReaderRouteParam } from '../../common/router/AppRouter'
import { ReaderEntry } from '../../common/reader/ReaderEntry'
import { Books } from '../../database/entities/Books'
import booksUtil from '../../common/utils/booksUtils'
import booksDao from '../../database/dao/BooksDao'
import { resolveBookCover, coverCorners } from '../../common/utils/CoverSource'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
import { ShelfColors } from '../../common/utils/NightMode'
import { bookParser } from '@kit.ReaderKit'

/**
 * 标题图片样式（返回箭头 / 标题栏图标）
 *
 * ⚠️ 2026-10-12：原为 `fillColor(Color.White)` —— 那是压在旧底色
 *    `$r('app.color.book_detail_background')`（日间 `#2a5d5d` 深青绿）上的白箭头。
 *    本页底色改为**主题渐变**后，日间档底色变浅 ⇒ 白箭头在白/浅橙渐变上几乎不可见。
 *    改用 `ShelfColors.icon()`（日间 `rgba(19,19,19,0.88)`／夜间白），与全应用
 *    图标配色同源。`@Extend` 不能读实例状态，故此处直接用静态方法取色。
 */
@Extend(Image)
function titleImageStyle() {
  .fillColor(ShelfColors.icon()).width(CommonConstants.TITLE_IMG_SIZE).height(CommonConstants.TITLE_IMG_SIZE)
}

// 迁 Navigation 第 2 期：去掉 `@Entry`，并**必须**补 `export default`
// —— 原来作为 `@Entry` 页面时不需要导出，现在被 `pages/Index.ets` import 进来就必须有默认导出，
//    否则编译报 `Module '…/BookDetailPage' has no default export` 并连带
//    `'BookDetailPage({...})' does not meet UI component syntax`。
@Component
export default struct BookDetailPage {
  /**
   * **入参**：由 `Index.appRoutes()` 的 NavDestination 构建器注入。
   *
   * ⚠️ 为什么不用 `@Prop`：`@Prop` 对对象会**深拷贝**（`Books` 还带 `source`/`sourceList` 嵌套），
   * 而本页的书籍参数还有一个来源是**普通对象字面量**（`SearchBookItem` 拼的那个），
   * 深拷贝+类型校验都可能出问题。用普通字段接住、再在 `aboutToAppear` 里**整体赋给 `@State`**，
   * 既保持了原来的对象引用语义（和 `router.getParams()` 一致），又能触发一次 UI 刷新。
   */
  initBook: Books = new Books()
  @State bookData: Books = new Books()
  @State CatalogList: bookParser.CatalogItem[] = []; //章节数据
  /**
   * 目录搜索关键词（2026-09-22）。
   *
   * 原来 `catalogPanel()` 里的 `Search` **没有 onChange/onSubmit**，纯装饰。
   * 现在由它驱动 `filteredCatalog()`。
   *
   * ⚠️ 待补：拼音 / 首字母匹配。全工程**没有任何拼音能力**（无工具函数、
   *    `@pura/harmony-utils` 也不导出）⇒ 需要自建映射表或引三方库，
   *    属独立改动，本步只做**文字直接匹配**（`includes`，大小写不敏感）。
   */
  @State catalogKeyword: string = '';
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /**
   * 书架公共刷新信号（自增广播）。本页订阅它做**返回重查**（见 onShelfBroadcast）。
   */
  @State @Watch('onShelfBroadcast') shelfBooksTick: number = 0
  /**
   * 2026-11-03（双轨收口）：由 `GroupEvents` 事件驱动刷新（替代 AppStorage 计数器 + @StorageLink）。
   * 语义不变：意图命中就把 tick 加一 ⇒ 上面的 `@Watch` 回调照旧触发重查。
   */
  private shelfListener: GroupChangedListener = (p: GroupChangedPayload): void => {
    if (p.refreshBooks) { this.shelfBooksTick++ }
  }

  /**
   * 按 `catalogKeyword` 过滤目录；关键词为空时返回全量。
   *
   * 用 `@Builder` 里的 `ForEach` 直接调用（ArkUI 会在 `@State` 变化时重新求值）。
   */
  filteredCatalog(): bookParser.CatalogItem[] {
    const kw = (this.catalogKeyword ?? '').trim().toLowerCase();
    if (kw === '') {
      return this.CatalogList;
    }
    return this.CatalogList.filter((it: bookParser.CatalogItem) => {
      const name = (it.catalogName ?? '').toLowerCase();
      return name.includes(kw);
    });
  }

  /**
   * 书架/阅读器广播 `BOOK_IS_BOOK_REFRESHING` ⇒ 重查本书（2026-10-07）。
   *
   * ⚠️ 这里**不能**用 `onPageShow`：本页迁成 NavDestination 后已去掉 `@Entry`，
   * 而 `onPageShow` 是 **`@Entry` 页面专属**生命周期 —— 非页面组件里"不会报错、
   * 但也不会再触发"（官方 FAQ `faqs-arkui-59` 原文：「onPageShow和onPageHide仅作为
   * 页面生命周期提供，@Entry修饰的自定义组件定义为页面」；本工程
   * `readStatistics.ets` 迁 Navigation 第 4 期注释同款结论）。
   * 2026-10-01 写在这里的"从阅读器返回时重查本书"因此一直是**死代码**（静默失效）。
   *
   * 现在的刷新时机：`ReaderPage3.aboutToDisappear` 在退出阅读、最终进度落库后
   * 自增本键 ⇒ 压在本页下面的场景（详情页 → 阅读器 → 返回）本页随之重查，
   * 「读到第X章」进度、封面等取到最新落库值（initBook 是路由快照，会过期）。
   */
  onShelfBroadcast(): void {
    this.refreshBook()
  }

  /** 按 id 重查本书并整体刷新 @State（封面/书名/简介等全部取最新落库值） */
  private async refreshBook(): Promise<void> {
    const id = this.bookData.id ?? this.initBook.id
    if (id === undefined) {
      return
    }
    const fresh = await booksDao.getBookByIds([id])
    if (fresh.length > 0) {
      this.bookData = fresh[0]
    }
  }

  async aboutToAppear() {
    GroupEvents.subscribe(this.shelfListener)
    // 迁移后参数由 NavDestination 构建器经 `initBook` 注入，这里不再需要 `router.getParams()`。
    // 整体赋给 `@State` ⇒ 触发一次刷新（等价于原来 `aboutToAppear` 里那次赋值）。
    this.bookData = this.initBook
    // 2026-10-01：路由快照可能是旧数据（换封面后从书架长按进入）⇒ 先按 id 重查最新
    if (this.bookData.id !== undefined) {
      await this.refreshBook()
    }
    if (!this.bookData.isJoin) {
      this.bookData.isJoin = await booksUtil.isExistBooks(this.bookData.bookUrl, this.bookData.bookName)
    }
    this.initUrlBook()
  }

  async initUrlBook() {
    let path = this.bookData.bookUrl
    let bookParserHandler: bookParser.BookParserHandler = await bookParser.getDefaultHandler(path);
    this.CatalogList = bookParserHandler.getCatalogList();
  }

  build() {
    Column() { // todo 状态栏
      Row() {

      }.width(CommonConstants.FULL_WIDTH).height(40)

      // 标题栏
      Row() { // 返回与标题
        Row({ space: 12 }) {
          Image($r("app.media.ic_public_return_left")).titleImageStyle().onClick(() => {
            Haptics.tap();
            // 入栈/出栈必须成对：本页现在由 NavPathStack 推入（见 Index.appRoutes）
            AppRouter.pop()
          })
          Text('书籍详情').fontColor(ShelfColors.textMain()).fontSize(16)
        }.height(24)

        // 右侧「编辑 / 分享 / 更多」三个图标已于 2026-09-21 删除：
        //   · 编辑 → 跳 `/pages/view/BookEditor/BookEditorPage`，该页**不在 `main_pages.json`**
        //     （全工程 30 个 `@Entry` 里唯一一个不在清单却被人 push），路径还带前导斜杠
        //     ⇒ 点了必然路由失败；
        //   · 分享 / 更多 → **连 `.onClick` 都没有**，纯装饰。
      }.padding({
        left: 20,
        right: 20,
        top: 12,
        bottom: 12
      }).height(36).width(CommonConstants.FULL_WIDTH)

      // 小说标题
      Row({ space: CommonConstants.SPACE_20 }) {
        // 2026-10-13：走 `resolveBookCover`（四层：自定义 > 自带 > 书源 > 默认），
        // 自带封面（导入时从 epub 等提取）在详情页同样生效；无自带再回退原 coverUrl。
        Image(resolveBookCover(this.bookData))
          .alt($r('app.media.icon_book_default_cover_ten'))
          .width(CommonConstants.NOVEL_IMG_WIDTH)
          .height(CommonConstants.NOVEL_IMG_HEIGHT)
          // 2026-10-04：均匀 5 改为书脊式圆角（同内置封面 SVG，90 宽画布左 4 / 右 8 等比）。
          .borderRadius(coverCorners(CommonConstants.NOVEL_IMG_WIDTH))
          // 视觉升级（2026-09-21）：与书架封面统一加柔和投影。纯增量属性，不动布局。
          .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.22)', offsetX: 0, offsetY: 5 })
        Column({ space: 8 }) {
          Text(this.bookData.bookName.replace(new RegExp('\\..*', 'g'), ''))
            .width('75%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(ShelfColors.textMain())
            .fontSize(20)
          Blank()
          Row() {
            Text(this.bookData.author ?? '佚名')
              .fontSize(CommonConstants.FONT_NOVEL_DETAIL_AUTHOR_SIZE)
              .fontColor(ShelfColors.textSub())
            Image($r('app.media.ic_public_right'))
              .width(CommonConstants.NOVEL_DETAIL_AUTHOR_IMG_SIZE)
              .height(CommonConstants.FONT_NOVEL_DETAIL_AUTHOR_SIZE)
              .fillColor(ShelfColors.icon())
          }

          // 分类标签「幻想修仙 / 完本 / 300万字」已于 2026-09-21 删除 —— 全是写死的字符串，
          // 与这本书没有任何关系（底座样例数据）。
        }.height(CommonConstants.NOVEL_IMG_HEIGHT).alignItems(HorizontalAlign.Start)
      }.padding({
        left: 20,
        right: 20,
        top: 12,
        bottom: 12
      }).width(CommonConstants.FULL_WIDTH).height(116)

      // 「阅读记录」三格（阅读时长 243小时 / 阅读天数 16天 / N刷 3次）已于 2026-09-21 删除 ——
      // 三个数**全是写死的**（连 `ReadRecordItem` 的默认值 `243/'小时'` 都是假的），
      // 而真正的阅读时长数据源 `readRecord` 表**全工程零写入**。
      // 显示假数字比不显示更糟，故整块移除。

      // 书籍简介
      Flex() {
        // 简介兜底：原来是《大奉打更人》的整段原文（底座样例数据），现已去掉 ——
        // 没有简介就如实显示「暂无简介」，不要给用户看另一本书的内容。
        Text(this.bookData.intro ?? '暂无简介')
          .fontColor(ShelfColors.textSub())
          .fontSize(14)
          .fontWeight(400)
          .lineHeight(22)
      }.padding({
        left: 20,
        right: 20,
        top: 12,
        bottom: 12
      }).width(CommonConstants.FULL_WIDTH)

      // ★★ 目录内嵌（2026-09-22 按用户方案，取代原来的目录 sheet）★★
      //
      // 用户原话：「书籍详情的目录 sheet 也没变，但是这个我建议改一下，
      //   **直接把这个 sheet 的内容做到书籍详情里面**，现在书籍详情里面，
      //   在**暂无简介下面是空的**，正正好好，一个**四角矩形的目录**，
      //   然后底部两个独立的按钮，左面是**已加书架**，右面是**立即阅读**按钮」。
      //
      // ⇒ 目录不再走 sheet，直接作为页面内一块「四角矩形」区域：
      //   · 顶部：目录搜索框（复用 `catalogKeyword` + `filteredCatalog()`）
      //   · 中部：章节列表（`.layoutWeight(1)` 吃掉剩余高度）
      //   · 四角圆角 + 卡片底色
      //   「加入书架 / 立即阅读」两个底部按钮已于 2026-11-05 随死链删除
      //   （`catalogPanel()` 从未渲染，按钮实际一直不可见；进阅读走目录行点击，用户拍板）。
      Column() {
        // 目录搜索（真搜索：`filteredCatalog()` 按章节名过滤）
        Search({ placeholder: '搜索目录', value: this.catalogKeyword })
          .height(36)
          .onChange((v: string) => {
            this.catalogKeyword = v
          })
          .onSubmit((v: string) => {
            this.catalogKeyword = v
          })

        List() {
          ForEach(this.filteredCatalog(), (item: bookParser.CatalogItem) => {
            ListItem() {
              Text(`${item.catalogName}`.replace(new RegExp('\\s{1,}', 'g'), ' ').replaceAll('=', ''))
                .fontSize(14)
                .fontColor(ShelfColors.textMain())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({
                  left: item.catalogLevel ? item.catalogLevel * 20 + 12 : 12,
                  right: 12,
                  top: 10,
                  bottom: 10
                })
                .onClick(() => {
                  Haptics.tap();
                  // 跳转前无需再关 sheet（目录已内嵌）；
                  // 仍保留"进阅读页"这一行为，与原 sheet 里的点击一致。
                  const rp: ReaderRouteParam = {
                    bookData: this.bookData, clickBookCatalogId: item.catalogId
                  };
                  ReaderEntry.open(this.getUIContext(), rp.bookData, { param: rp })
                })
            }
          }, (item: bookParser.CatalogItem): string => `${item.catalogId}_${item.catalogName}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .divider({
          strokeWidth: 0.5,
          color: 'rgba(0, 0, 0, 0.06)',
          startMargin: 12,
          endMargin: 12
        })
      }
      // 四角矩形目录（用户明确要"四角矩形"）+ 内保护边距（避免内容被圆角压住，
      // 与听书/目录 sheet 同一处理）
      // 用户反馈：「书籍详情目录列表**不需要白色圆角 sheet 了**，没必要了，**直接用融入背景**就行」。
      // ⇒ 去掉白色卡片底与圆角，只保留内保护边距（防内容贴边）。
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .margin({ left: 16, right: 16, top: 4, bottom: 8 })
      .layoutWeight(1)

      // 章节目录Panel
      /*Panel(this.isValue) {
        Column() {

        }
      }
      .width(CommonConstants.FULL_WIDTH)
      .type(PanelType.Foldable)
      .halfHeight('50%')
      .backgroundColor('#FFFFFF')*/
    }
    .height(CommonConstants.FULL_HEIGHT)
    .width(CommonConstants.FULL_WIDTH)
    // 2026-10-12 适配全局主题渐变。
    // 此前是 `$r('app.color.book_detail_background')` —— 实测该资源在 **base（日间）**
    // 档写死为 `#2a5d5d`（青绿），与本应用主题色毫无关系；dark 档才是 `#1B1B1D`。
    // ⇒ 日间档下本页底色是固定的青绿，从书架点进来会"换了一套配色"。
    // 改为与书架/我的同源的配色对与 stop（0.0 → 0.2）。
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: ShelfColors.pageGradient(this.theme.mainColor, this.theme.secondColor)
    })
  }

}