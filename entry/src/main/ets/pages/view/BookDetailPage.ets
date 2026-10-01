import CommonConstants from '../../common/constants/CommonConstants'
import { Haptics } from '../../common/utils/Haptics';
// 2026-09-21 精简：`ReadRecordItem` / `TagIndex` / `NoteIndex` 三个组件随
// 「阅读记录」「分类标签」「笔记 Tab」一起移除，故不再 import；
// `SwipeRefresher` 随「书源 Tab」移除。
import { router } from '@kit.ArkUI'
import ImmersiveMaterialUtil, { MaterialButtonModifier } from '../../common/utils/ImmersiveMaterialUtil'
import AppRouter, { RouteName, ReaderRouteParam } from '../../common/router/AppRouter'
import { FileHandler } from '../../common/utils/FileHandler'
import { Books } from '../../database/entities/Books'
import { BookHistory } from '../../database/entities/BookHistory'
import bookHistoryUtils from '../../common/utils/BookHistoryUtils'
import booksUtil from '../../common/utils/booksUtils'
import booksDao from '../../database/dao/BooksDao'
import { resolveCoverSource } from '../../common/utils/CoverSource'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
import { bookParser } from '@kit.ReaderKit'

/**
 * 标题图片样式
 */
@Extend(Image)
function titleImageStyle() {
  .fillColor(Color.White).width(CommonConstants.TITLE_IMG_SIZE).height(CommonConstants.TITLE_IMG_SIZE)
}

/**
 * 分割线样式
 */
@Extend(Divider)
function recordDividerStyle() {
  .vertical(true).width(0.5).height(24).color('#40ffffff')
}

/**
 * 加入书架dialog
 */
@CustomDialog
struct AddBookShelfDialog {
  controller?: CustomDialogController;

  build() {
    Row() {
      Image($r('app.media.ic_public_confirm')).width(24).height(24).fillColor('#FFFFFF')
      Text('加入书架成功').fontSize(14).fontWeight(400).lineHeight(22).fontColor('#FFFFFF')
      Blank()
      Text('移入分组').fontSize(14).fontWeight(400).lineHeight(22).fontColor('#FF9500')
    }.height(56).width(CommonConstants.FULL_WIDTH).padding({
      left: 20,
      right: 20,
      top: 16,
      bottom: 16
    }).backgroundColor('#333333')
  }
}

// 迁 Navigation 第 2 期：去掉 `@Entry`，并**必须**补 `export default`
// —— 原来作为 `@Entry` 页面时不需要导出，现在被 `pages/Index.ets` import 进来就必须有默认导出，
//    否则编译报 `Module '…/BookDetailPage' has no default export` 并连带
//    `'BookDetailPage({...})' does not meet UI component syntax`。
@Component
export default struct BookDetailPage {
  @State isShow: boolean = true;
  @State currentIndex: number = 0;
  // 是否加入书架
  @State isAddBookShelf: boolean = false;
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
  // 加入书架dialog
  dialogController: CustomDialogController = new CustomDialogController({
    builder: AddBookShelfDialog(),
    cornerRadius: 8,
    offset: { dx: 0, dy: -100 },
    gridCount: 4,
    customStyle: false,
  })
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
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0

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

  onPageShow() {
    this.isShow = true
    // 2026-10-01：从阅读器/其它页返回时重查本书——换封面等修改要实时反映（用户反馈
    // "书籍详情没有同步更新最新的封面"）。initBook 是进入页面瞬间的路由快照，会过期。
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

  // 加入书架函数
  addBookShelf() {
    booksUtil.addBooks(this.bookData)
    this.dialogController.open();
    this.isAddBookShelf = true; // 1s后关闭dialog
    setTimeout(() => {
      this.isBookRefreshing++
      this.dialogController.close();
    }, 1000);
  }

  /**
   * Panel
   */
  @Builder
  catalogPanel() {
    Column() {
      // ★ 目录搜索（2026-09-22 从"假搜索"改成真搜索）。
      //   原来只有一个 `Search({placeholder:'搜索目录'})`，**没有 onChange / onSubmit**
      //   ⇒ 输入什么都不筛，是纯装饰。
      //   `catalogKeyword` 过滤 `filteredCatalog()`；清空即恢复全量。
      Search({ placeholder: '搜索目录', value: this.catalogKeyword })
        .height(34)
        .padding({ top: 8, bottom: 8 })
        .onChange((v: string) => {
          this.catalogKeyword = v
        })
        .onSubmit((v: string) => {
          this.catalogKeyword = v
        })
      Tabs({ index: this.currentIndex, barPosition: BarPosition.Start }) {
        TabContent() {
          Column() {
            List() {
              ForEach(this.filteredCatalog(), (item: bookParser.CatalogItem, index: number) => {
                ListItem() {
                  Button({ type: ButtonType.Normal }) {
                    Row() {
                      Text(`${item.catalogName}`.replace(new RegExp('\\s{1,}', 'g'), ' ').replaceAll('=', ''))
                        .layoutWeight(1)
                    }.width('100%').padding({
                      left: 20,
                      right: 20,
                      top: 12,
                      bottom: 12
                    })
                  }.borderRadius(10).width('100%').backgroundColor($r('app.color.card_bg')).onClick(() => { // 跳转到阅读器
                    // 迁 Navigation 第 3 期：阅读页已改为 NavDestination，改走路由门面
                    const rp: ReaderRouteParam = {
                      bookData: this.bookData, clickBookCatalogId: item.catalogId
                    };
                    // ★ 跳转前**必须先关掉本 sheet**（2026-09-22 用户反馈修复）。
                    //   用户原话：「点击某个章节进入阅读器后，这个 sheet 不会自动关闭，
                    //   还是存在，这个不对，应该点击后立刻消失了」。
                    //   原因：这里原来只有 `AppRouter.push(...)`，`isShow` 一直是 `true`
                    //   ⇒ 进入阅读页后目录 sheet 仍盖在上面。
                    //   先置 `false` 再 push：sheet 开始收起、阅读页随后入栈。
                    this.isShow = false
                    AppRouter.push(RouteName.READER, rp)
                  })
                }
                // 补 keyGenerator（T10-1 / D-11）：目录可达数千条，默认键是
                // `index + '_' + JSON.stringify(item)` ⇒ 每次都 stringify 整个 CatalogItem。
                // 用业务唯一键（`catalogId`）取代；官方规则 `foreach-args-check`「滑动丢帧场景下优先修改」。
              }, (item: bookParser.CatalogItem): string => `${item.catalogId}_${item.catalogName}`)
            }.chainAnimation(true).edgeEffect(EdgeEffect.Fade).divider({
              strokeWidth: 0.8,
              color: $r('app.color.divider'),
              startMargin: 12,
              endMargin: 12
            })
          }
        }.tabBar(this.catalogTab(0, '目录', this.CatalogList.length))

        // 「书源」与「笔记」两个 Tab 已于 2026-09-21 删除：
        //   · 书源 → `SwipeRefresher({ content:'书源加载中...', isLoading:true })` 是**永久加载中**，
        //     背后没有任何数据源（书源表零种子数据、解析还外包给第三方服务器）；
        //   · 笔记 → `NoteIndex` 里是 4 条硬编码的《大奉打更人》假笔记，全工程无笔记表，
        //     编辑只写内存对象不落库。
        // 详情页现在只剩「目录」一个 Tab（目录是真数据，来自 ReaderKit 的 getCatalogList）。
      }.layoutWeight(1).onChange((index: number) => {
        this.currentIndex = index;
      })

      Row({ space: 20 }) {
        Button(this.bookData.isJoin ? '已加书架' : '加入书架')
          .padding({
            left: 32,
            right: 32,
            top: 8,
            bottom: 8
          })
          .width(150)
          .height(40)
          .borderRadius(200)
          .onClick(() => {
            Haptics.tap();
            !this.bookData.isJoin ? this.addBookShelf() : ''
          })
          // 主题色沉浸光感材质（2026-09-21 用户拍板「愿意牺牲主题色实底换材质」）。
          // 主次层次用**不同透明度**保留：次按钮用较淡的主题色材质（0.35），
          // 主按钮用较浓的（0.75，见下一个按钮）。依据与取舍见 `MaterialButtonModifier` 注释。
          .attributeModifier(new MaterialButtonModifier(this.theme.secondColor, this.theme.mainColor,
            ImmersiveMaterialUtil.tint(this.theme.mainColor, 0.35)))
        Button('立即阅读')
          .padding({
            left: 32,
            right: 32,
            top: 8,
            bottom: 8
          })
          .width(150)
          .height(40)
          .borderRadius(200)
          .onClick(() => { // 跳转到阅读器
            // 迁 Navigation 第 3 期：阅读页已改为 NavDestination，改走路由门面
            const rp: ReaderRouteParam = { bookData: this.bookData };
            AppRouter.push(RouteName.READER, rp) // this.jumpReadPage(``, 0)
          })
          .attributeModifier(new MaterialButtonModifier(this.theme.mainColor, '#FFFFFF',
            ImmersiveMaterialUtil.tint(this.theme.mainColor, 0.75)))
      }.padding({ top: 12, bottom: 12 }).justifyContent(FlexAlign.Center).width(CommonConstants.FULL_WIDTH).height(64)
    }
    .padding({ left: 20, right: 20, bottom: 12 })
    .width(CommonConstants.FULL_WIDTH)
    .height(CommonConstants.FULL_HEIGHT)
    .borderRadius(16)
  }

  /**
   * tab页签
   */
  @Builder
  catalogTab(index: number, name: string, count: number) {
    Column() {
      Row() {
        Text(name)
          .fontSize(16)
          .fontColor(this.currentIndex === index ? '#e0000000' : '#73000000')
          .fontWeight(500)
          .lineHeight(24)
        Text(count.toString())
          .fontSize(12)
          .lineHeight(20)
          .fontColor(this.currentIndex === index ? '#e0000000' : '#73000000')
          .fontWeight(500)
      }

      Divider()
        .width(10)
        .strokeWidth(3)
        .lineCap(LineCapStyle.Round)
        .color(this.theme.mainColor)
        .opacity(this.currentIndex === index ? 1 : 0)
    }.padding({ top: 8, bottom: 8 }).width(59).height(40)
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
          Text('书籍详情').fontColor(Color.White).fontSize(16)
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
        // 2026-10-01：封面走 customCoverUrl 优先（resolveCoverSource 处理 default:// 协议），
        // 与书架渲染同一契约；无自定义封面回退原 coverUrl。
        Image(resolveCoverSource(this.bookData.customCoverUrl ?? '') ?? this.bookData.coverUrl)
          .alt($r('app.media.icon_book_default_cover_ten'))
          .width(CommonConstants.NOVEL_IMG_WIDTH)
          .height(CommonConstants.NOVEL_IMG_HEIGHT)
          .borderRadius(5)
          // 视觉升级（2026-09-21）：与书架封面统一加柔和投影。纯增量属性，不动布局。
          .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.22)', offsetX: 0, offsetY: 5 })
        Column({ space: 8 }) {
          Text(this.bookData.bookName.replace(new RegExp('\\..*', 'g'), ''))
            .width('75%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(Color.White)
            .fontSize(20)
          Blank()
          Row() {
            Text(this.bookData.author ?? '佚名')
              .fontSize(CommonConstants.FONT_NOVEL_DETAIL_AUTHOR_SIZE)
              .fontColor('#FFF')
              .opacity(0.45)
            Image($r('app.media.ic_public_right'))
              .width(CommonConstants.NOVEL_DETAIL_AUTHOR_IMG_SIZE)
              .height(CommonConstants.FONT_NOVEL_DETAIL_AUTHOR_SIZE)
              .fillColor('#FFF')
              .opacity(0.45)
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
          .fontColor('#FFFFFF')
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
      //   页面底部原有的「加入书架 / 立即阅读」两个按钮**保持不变**，
      //   正好构成用户要的"目录 + 底部两个独立按钮"。
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
                .fontColor('#333333')
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
                  AppRouter.push(RouteName.READER, rp)
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
    .backgroundColor($r('app.color.book_detail_background'))
  }

  // @StorageLink('BOOK_IS_BOOK_HISTORY_REFRESHING') isBookHistoryRefreshing: number = 0
  //跳转阅读界面更新或者添加阅读历史记录方法
  async jumpReadPage(durChapterTitle: string, durChapterIndex: number) {
    let bookHistory = new BookHistory()
    bookHistory.id = this.bookData.id
    bookHistory.bookName = this.bookData.bookName
    bookHistory.author = this.bookData.author
    bookHistory.durChapterTime = Date.now()
    bookHistory.bookType = this.bookData.bookType
    bookHistory.bookUrl = this.bookData.bookUrl ?? ''
    bookHistory.coverUrl = this.bookData.coverUrl ?? ''
    bookHistory.originBookId = this.bookData.id
    bookHistory.durChapterTitle = durChapterTitle
    bookHistory.durChapterIndex = durChapterIndex
    bookHistoryUtils.addBooks(bookHistory)
  }
}