import BookMark from '../../../componets/head/BookMark'
import AppRouter, { RouteName, BookManageRouteParam } from '../../../common/router/AppRouter'
import BookBodyContent from './components/BookBodyContent'
import { FileHandler } from '../../../common/utils/FileHandler'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
import Dialog from '../../../componets/common/Dialog'
import { showMessage } from '../../../componets/common/promptShow'
import { bookShelfImport } from '../../../database/entities/Books'
import { getPasteDataSync, isNetworkUrl, sleep } from '../../../common/utils/utils'
import booksUtil from '../../../common/utils/booksUtils'
import axios, { AxiosResponse } from '@ohos/axios'
import { ThemeItem } from '../../../common/model/Theme'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { IconTitleVo } from '../../../componetsmodel/IconTitleVo'
import dialogTitleFuction from '../../../componets/common/dialogTitleFuction'
import { ShelfSearchPanel } from './components/dialog/ShelfSearchPanel'
import { ImportBookListDialog } from './components/dialog/ImportBookListDialog'
import { LengthMetrics } from '@kit.ArkUI'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
// ── Symbol 点击动效令牌 + 全局震动反馈（2026-09-25 新增）──────────────────────
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion'
import { Haptics } from '../../../common/utils/Haptics'

@Component
export default struct IndexShelf {
  @State currentIndex: number = 0
  /**
   * 顶部分类页签。**2026-10-11 起只剩「书架」一个**（用户裁定：删掉漫画/有声书两个入口，
   * 并把「小说」字样改成「书架」）。
   *
   * 为什么删：这两个页签在实现上只是 `Books.bookType` 的 SQL 分区
   * （`BooksDao.ets:134-136` 的 `bookType = type`），**全工程没有任何按 `bookType`
   * 分流的渲染**（`ReaderPage3.ets` 里 grep `bookType` 零命中，点书一律进同一个
   * ReaderKit 文本阅读器）。而：
   *   · 导入白名单只有文本后缀（见 `pickLocalBooks()` 的注释）；
   *   · ReaderKit 的排版参数 `readerCore.ReaderSetting` 只有 13 个字段
   *     （字体/行高/背景/翻页/视口），**没有图片模式、也没有音频模式**
   *     （SDK `…\hms\ets\api\@hms.core.readerservice.readerComponent.d.ets:69-199`）；
   * ⇒ 漫画/有声书页签永远装不进对应内容，是**空入口**。
   *
   * ⚠️ `currentIndex` 仍保留：它就是 `bookType`（导入归类、自建分组的 `groupType` 都用它），
   *    现在恒为 0。
   * 老数据：曾落在 bookType = 1/2 的书与分组由 `BooksDao.migrateBookTypeToShelf()`
   *    一次性搬到 0（删入口不丢书）。
   */
  titleArray: Array<string> = ['书架']
  @State bookTypeNumber: number = 2
  @State EXHIBIT: string = '列表'
  @State @Watch('changeGroup') GROUP: string = '标签'
  /**
   * 右上角「更多」菜单（2026-09-21 精简）。
   * 「下载管理」已删：`DownloadManagementPage` 里是三组硬编码「斗破苍穹」假列表，
   * 全工程 grep `downloadFile|DownloadTask|@ohos.request.download` **零命中**，
   * 页面内的 `switch(index){case 5,6,7: break}` 与「全选」`onClick` 也都是空的。
   * ⚠️ 删掉后**索引整体前移一位**，`changeTheme()` 里的 case 必须同步。
   */
  private moreList: IconTitleVo[] = [
    new IconTitleVo($r('app.media.import_svg'), '书籍导入'),
    new IconTitleVo($r('app.media.import_book_svg'), '导入书单'),
    new IconTitleVo($r('app.media.batch_svg'), '批量管理'),
  ]
  changeGroup() {
    if (this.GROUP === '文件夹') {
      this.bookTypeNumber = 1
    } else {
      this.bookTypeNumber = 2
    }
  }

  @State isShowImport: boolean = false
  @State isShowCloudImport: boolean = false
  // 「导入书单」弹窗（2026-09-25 从贴底 bindSheet 升级为标准居中 @CustomDialog，
  //   见 components/dialog/ImportBookListDialog.ets；控制器每次打开新建）
  private importListDialog: CustomDialogController | null = null

  private openImportListDialog(): void {
    this.importListDialog = new CustomDialogController({
      builder: ImportBookListDialog({
        onPaste: (): void => {
          this.pasteBookImport()
        },
        onLocal: (): void => {
          this.pickBookListLocal()
        },
        onClose: (): void => {
          // 关闭权在页面侧（全工程 2026-09-25 统一约定）
          this.importListDialog?.close()
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
    })
    this.importListDialog?.open()
  }

  /**
   * 书单本地导入：选 JSON 文件 → 解析 → 批量入架。
   * （逻辑自原 `ImportClickBox` case 4 原样搬移，供新弹窗回调调用。）
   */
  private async pickBookListLocal(): Promise<void> {
    const res = await FileHandler.documentPickerFile(1, ['.json'])
    FileHandler.ReadJSONFile(res[0]).then(async result => {
      if (result.length > 0) {
        this.bookImport = JSON.parse(result) as bookShelfImport[]
        this.bookImport.length > 0 ? await booksUtil.batchAdd(this.bookImport, this.currentIndex) : ''
        showMessage(this.bookImport.length > 0 ? `相关书单书籍内容导入${this.bookImport.length}本` :
          '未找到相关书单书籍内容')
      }
    })
    setTimeout(() => {
      this.isBookRefreshing++
    }, 500)
  }
  /** 书架搜索浮窗（2026-09-22 新增，见搜索按钮处的说明） */
  @State isShowShelfSearch: boolean = false
  /** 顶部搜索/更多图标的 Q弹缩放值（2026-09-25，`runJellyClick` 自驱 `.scale()`） */
  @State searchScale: number = 1
  @State moreScale: number = 1
  /**
   * 书架搜索弹窗控制器（2026-09-22 从 `bindSheet` 改成 `@CustomDialog`）。
   *
   * `@CustomDialog` 由 `offset` 直接控制位置、不受 sheet 锚定行为限制，
   * 且能通过 `systemMaterial` 拿到**真沉浸光感材质**（sheet 拿不到）。
   * 配方与已验证的「长按书籍弹窗 / 加入书单 / 睡眠定时」完全一致。
   */
  shelfSearchDialog: CustomDialogController | null = new CustomDialogController({
    builder: ShelfSearchPanel({
      onClose: () => {
        this.shelfSearchDialog?.close()
      }
    }),
    cancel: () => {
      this.isShowShelfSearch = false
    },
    autoCancel: true,
    // 用户要求：放大镜浮窗**居中**
    alignment: DialogAlignment.Center,
    width: '92%',
    // ⚠️ 2026-09-22 用户真机反馈：放大镜弹窗**居中效果完美**，但「高度差点，增加 15%」
    //   432 x 1.15 ≈ **497**（取 500 便于阅读）
    height: 465,
    cornerRadius: 20,
    customStyle: false,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageProp('APP_INDEX_SCROLLABLE') APP_INDEX_SCROLLABLE: boolean = false
  /**
   * App 级夜间开关（只为**触发本组件的重绘**而订）。
   * 真正取色一律走 `ShelfColors.*()`（它内部读同一个开关）—— 若只订状态而颜色还是
   * 写死的浅色，夜间下本页不会重绘；若只靠函数而不订状态，值变了也不会重绘。
   * 两者必须同时存在。规则见 `common/utils/NightMode.ets`。
   */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @State bookImport: bookShelfImport[] = []
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  // 网址导入dialog
  dialogController: CustomDialogController = new CustomDialogController({
    builder: Dialog({
      title: '网址导入',
      child: () => {
        this.DialogInput("请输入书籍目录或详情页")
      }
    }),
    cornerRadius: 8,
    offset: { dx: 0, dy: 0 }
  })
  tabsController: TabsController = new TabsController();
  private scrollController: Scroller = new Scroller();

  build() {
    Column() {
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.End
      }) {
        Row() {
          List({ scroller: this.scrollController }) {
            ListItem() {
              BookMark({ title: '书架', index: 0, currentIndex: this.currentIndex }).onClick(() => {
                Haptics.tap();
                this.currentIndex = 0
                this.tabsController.changeIndex(0)
                console.log(this.currentIndex + '')
              })
            }
          }
          // .align(Alignment.TopStart)
          .height(40)
          .scrollBar(BarState.Off)
          .listDirection(Axis.Horizontal)
          // ⚠️ 2026-09-23：这里**试过**加"向沉浸光感看齐"的胶囊外观（半透明底+强模糊+圆角），
          //   用户真机看后反馈「不好看」⇒ **已按用户要求改回原样**（不加任何底色/模糊）。
          //   「最近阅读/浏览历史…」和「分组/全部/未分组…」那两处的胶囊保留（用户没反对）。
        }

        // ── 搜索 / 更多已下移（2026-09-29 用户裁定）────────────────────────────
        // 用户原话：摘掉「浏览历史」后「最近阅读这一行后面空了，和下面这一行不对齐，
        //   上面这一行还有一个搜索和一个更多的图标，放在下面是不是非常完美」。
        // ⇒ 两个图标挪进「最近阅读」行的尾部（本组件顶部只留「书架」一行），
        //   全部交互逻辑（搜索浮窗 / ⋯菜单 / Q弹动效）仍在 IndexShelf，
        //   经 `BookBodyContent.trailingActions`（@BuilderParam）注入渲染，
        //   与设置 sheet 复用页面 @Builder 是同一官方模式（faqs-arkui-826）。
        Row() {
          Flex() {
          }
          .width(0)
          .height(0)
          .bindSheet($$this.isShowCloudImport, this.CloudImportDialog(), {
            // 网盘导入弹窗绑定元素
            height: 240,
            showClose: false,
            dragBar: false,
            backgroundColor: ShelfColors.card(),
            blurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
            onDisappear: () => {
              // this.clickBookType = ''
            }
          })
        }
      }
      .padding({ top: this.topRectHeight === 0 ? 30 : this.topRectHeight, left: 20, right: 20 })

      Tabs({
        barPosition: BarPosition.Start,
        controller: this.tabsController,
        index: this.currentIndex
      }) {
        ForEach(this.titleArray, () => {
          TabContent() {
            Column() {
              BookBodyContent({
                currentIndex: this.currentIndex,
                EXHIBIT: this.EXHIBIT,
                GROUP: this.GROUP,
                bookTypeNumber: this.bookTypeNumber,
                // 搜索/更多图标：下移到「最近阅读」行尾（2026-09-29，见 build() 同日注释）
                trailingActions: (): void => {
                  this.ShelfTopActions()
                }
              })
            }
          }
        })
      }
      .layoutWeight(1)
      .barWidth(0)
      .barHeight(0)
      .onChange((index) => {
        this.tabsController.changeIndex(index)
        console.log('index:' + index)
        this.currentIndex = index
      })
      .backgroundColor(ShelfColors.pageBg())
      .scrollable(this.APP_INDEX_SCROLLABLE)
    }
    .height('100%')
    // ── 页面主题渐变（书架整页的底色）────────────────────────────────────────
    // 日间：主题 mainColor → secondColor（用户可选 5 套浅色主题）。
    // 夜间：换成中性深灰渐变 —— `themeManager` 那 5 套**全是浅色**
    // （`common/constants/Theme.ets:5-9`，如 `#ffece0`），直接沿用会让整页发白。
    // 取值与规则见 `ShelfColors.gradientStart/End()`。
    .linearGradient({
      direction: GradientDirection.Bottom, // 渐变方向
      colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0],
        [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]] // 数组末尾元素占比小于1时满足重复着色效果
    })
    .borderRadius({ bottomRight: 5, bottomLeft: 5 })
  }

  /**
   * 右上角「⋯」的 `bindMenu` 内容。
   *
   * ⚠️ **夜间必须自己铺一层不透明深底**（2026-09-23 用户真机截图红圈反馈）。
   *
   * 根因：`bindMenu` 的**菜单面板底色是浮层自带的**，`MenuOptions` 只有
   *   `title?` / `showInSubWindow?` 两个字段（SDK `component/common.d.ts`），
   *   **没有任何颜色/材质开关**；而官方对 `MaterialState.DEFAULT` 的原文
   *   （documentId `API参考/…/ohos_arkui_uiMaterial_系统材质_/arkts-apis-uimaterial`）说
   *   「弹出框Dialog…**在组件本身未设置背景颜色、模糊参数和阴影参数时**默认开启沉浸式系统材质」
   *   —— 沉浸材质不认应用配色（`ImmersiveOptions` 六个字段里没有 colorMode，
   *   SDK `…\ets\api\@ohos.arkui.uiMaterial.d.ts:306-429`）⇒ 夜里那层还是浅色磨砂。
   *
   * 做法：给内容根节点上色 —— 内容会把菜单面板**绝大部分**盖住。
   *   · 日间：`Color.Transparent` ⇒ 与改造前**逐像素一致**（不改动原有观感）
   *   · 夜间：`#1F1F1F`（与各弹窗夜间面板同色）+ 圆角 12
   * 【待验证】菜单面板四周还有系统自带的少量内边距，夜间可能残留一圈浅色描边。
   *   真机若确实看得见，改法只有一条：把 `bindMenu` 换成 `bindPopup` +
   *   `CustomPopupOptions.popupColor`（SDK 该接口确有 `popupColor`/`radius`/`shadow` 字段，
   *   可完全接管底色），代价是 `bindMenu` → `bindPopup` 要自己维护显隐 `@State`。
   */
  /**
   * 「最近阅读」行尾部的 搜索 / 更多 两个图标（2026-09-29 自顶部行下移，见 build() 同日注释）。
   * 经 `BookBodyContent.trailingActions`（@BuilderParam）渲染在那一行的尾部空位；
   * `this` 绑定 IndexShelf（箭头函数闭包）⇒ 弹窗 / 菜单 / 动效状态全部还是本组件的。
   */
  @Builder
  ShelfTopActions() {
    Row({ space: 16 }) {
      // ── 搜索按钮（2026-09-25 换 SymbolGlyph；点击 Q弹缩放见 runJellyClick）────
      // 符号名 `magnifyingglass` 在 SDK 符号表
      //   `…\Sdk\23\previewer\common\resources\entry\resources.txt` 查得，不猜名字。
      // 颜色沿用 `ShelfColors.icon()`（日/夜双档，替代原 SVG 的显式染色；
      //   夜间不染色的坑见原注释，现在由 icon() 统一保证）。
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(24)
        .fontColor([ShelfColors.icon()])
        .scale({ x: this.searchScale, y: this.searchScale })
        .onClick(() => {
          Haptics.tap();
          runJellyClick((v: number) => {
            this.searchScale = v
          })
          // ★ 2026-09-22：改为**本地书架搜索浮窗**（用户要求）。
          //   用户原话：「书架顶部搜索是假的，进入之后是假的，直觉删除，保留搜索按钮，
          //   点击后直接出现浮窗搜索，可以搜索书名，支持拼音，首字母，汉字等多种搜索模式」。
          //   原来这里 `AppRouter.push(RouteName.SEARCH)` 去的是 `SearchBook.ets`，
          //   而那一页是**搜网络书源**的（`taskSearchBook` 在线搜索），
          //   对"找我自己书架上的书"来说是假的（`SearchBook` 页面本身保留 ——
          //   它的在线搜书能力另有用途，本次只是不再从书架入口进它）。
          this.isShowShelfSearch = true
          this.shelfSearchDialog?.open()
        })
        .clickEffect(UiMotion.CLICK)
        // ★★ 2026-09-22 改为 @CustomDialog（用户拍板「既然能统一，那就全 @CustomDialog」）★★
        //   原因：sheet 的 `preferType: SheetType.CENTER` 真机**毫无变化**
        //   （试过 detents / height / preferType 四种组合都不居中），
        //   而 `@CustomDialog` 由 `offset` **直接控制位置**，不受 sheet 锚定行为限制；
        //   这条路已在本工程验证成功三次（长按弹窗 / 加入书单 / 睡眠定时）。
        //   而且 `@CustomDialog` 还能拿到**真沉浸光感材质**（sheet 拿不到）。

      // ── 更多按钮（2026-09-25 换 SymbolGlyph；点击 Q弹缩放见 runJellyClick）────
      // 符号名 `more`（横向三点）同表查得；`more_fill` 也在表里（未用）。
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize(24)
        .fontColor([ShelfColors.icon()])
        .scale({ x: this.moreScale, y: this.moreScale })
        .bindMenu(this.MenuBuilder())
        .bindSheet($$this.isShowImport, this.ImportDialog(), {
          // 书籍导入弹窗绑定元素
          height: 200,
          showClose: false,
          dragBar: false,
          backgroundColor: ShelfColors.surface(),
          blurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
        })
        .onClick(() => {
          Haptics.tap();
          runJellyClick((v: number) => {
            this.moreScale = v
          })
        })
        .clickEffect(UiMotion.CLICK)
    }
  }

  @Builder
  MenuBuilder() {
    Column() {
      ForEach(this.moreList, (item: IconTitleVo, index) => {
        dialogTitleFuction({
          title: item.title,
          icon: item.icon,
          isBorder: this.moreList.length !== index + 1,
          // 菜单内容已铺半透明深底（见本 @Builder 的注释）⇒ 文字/图标同步转浅
          nightStyle: NightMode.isDarkSurface()
        })
          .onClick(() => {
            Haptics.tap();
            this.changeTheme(index)
          })
      })
    }
    // 材质与「最近阅读」小气泡对齐（2026-09-23 用户反馈）：同一个配方 =
    // 半透明面底 + COMPONENT_ULTRA_THICK 超厚模糊 + 圆角 20（取值见 BookBodyContent 同款注释）。
    // 原来日间 Transparent / 夜间死色 #1F1F1F，两种模式都和最近阅读的观感对不上。
    .backgroundColor(ShelfColors.surface())
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .borderRadius(20)
  }
  @Builder
  // 书籍导入UI盒子
  ImportClickBox(index: number, image: string, text: string) {
    Column({ space: 8 }) {
      Flex() {
        Image($r(`${image}`))
          .width(24)
      }
      .width(48)
      .height(48)
      .borderRadius(24)
      .borderColor(ShelfColors.line())
      .backgroundColor(ShelfColors.solidChip())
      .borderWidth(1)
      .padding(12)

      Text(text)
        .lineHeight(20)
        .font({
          size: 12,
          weight: 400
        })
    }
    .padding({
      top: 16,
      bottom: 12,
      left: 21,
      right: 21
    })
    .onClick(async () => {
      Haptics.tap();
      switch (index) {
        case 3:
          // 书单粘贴导入
          this.pasteBookImport()
          break
        case 4:
          //书单本地导入
          let res = await FileHandler.documentPickerFile(1, ['.json'])
          FileHandler.ReadJSONFile(res[0]).then(async result => {
            if (result.length > 0) {
              this.bookImport = JSON.parse(result) as bookShelfImport[]
              this.bookImport.length > 0 ? await booksUtil.batchAdd(this.bookImport, this.currentIndex) : ''
              showMessage(this.bookImport.length > 0 ? `相关书单书籍内容导入${this.bookImport.length}本` :
                '未找到相关书单书籍内容')
            }
          })
          setTimeout(() => {
            this.isBookRefreshing++
          }, 500)
          break
      }
    })
  }

  @Builder
  // 书籍导入弹窗
  ImportDialog() {
    Column() {
      GridRow({
        columns: 3
      }) {
        GridCol() {
          this.ImportClickBox(0, "app.media.my_center_file_icon", "本地导入")
        }

        GridCol() {
          this.ImportClickBox(1, "app.media.my_center_cloud_icon", "网盘导入")
        }

        GridCol() {
          this.ImportClickBox(2, "app.media.official_website", "网址导入")
        }
      }
      .height("60%")

      Divider()

      Column() {
        Text('取消').fontSize(16).fontWeight(400)
          .lineHeight(24)
      }
      .onClick(() => {
        Haptics.tap();
        this.isShowImport = false
      })
      .alignItems(HorizontalAlign.Center)
      .padding({
        top: 16
      })
    }
  }

  @Builder
  DialogInput(placeholder: string, maxlength?: number) {
    Row() {
      TextInput({ placeholder: placeholder })// .maxLength(maxlength)
        // .showCounter(true)
        .cancelButton({
          icon: {
            src: $r('app.media.close')
          }
        })
    }
    .margin({
      top: 16,
      bottom: 16
    })
  }

  @Builder
  // 书籍导入-网盘导入弹窗
  CloudImportDialog() {
    Column() {
      Row() {
        Text("网盘导入")
          .lineHeight(24)
          .font({
            size: 16,
            weight: 500
          })
      }
      .padding({
        top: 12,
        bottom: 12,
      })

      Divider()

      Row({ space: 16 }) {
        Flex({
          wrap: FlexWrap.Wrap,
          alignContent: FlexAlign.Center,
          justifyContent: FlexAlign.Center
        }) {
          Text("坚")
            .lineHeight(24)
            .font({
              size: 16,
              weight: 500
            })
            .opacity(0.45)
        }
        .backgroundColor(ShelfColors.chip())
        .width(40)
        .height(40)

        Text("坚果云")
          .lineHeight(22)
          .font({
            size: 14,
            weight: 500
          })
          .opacity(0.88)
      }
      .padding({
        top: 12,
        bottom: 12,
      })
      .width("100%")
      .onClick(() => {

      })

      Row({ space: 16 }) {
        Flex({
          wrap: FlexWrap.Wrap,
          alignContent: FlexAlign.Center,
          justifyContent: FlexAlign.Center
        }) {
          Image($r('app.media.add')).width(24)

        }
        .backgroundColor(ShelfColors.chip())
        .width(40)
        .height(40)

        Text("添加webdav网盘")
          .lineHeight(22)
          .font({
            size: 14,
            weight: 500
          })
          .opacity(0.88)
      }
      .padding({
        top: 12,
        bottom: 12,
      })
      .width("100%")
      .onClick(() => {

      })

      Divider()

      Column() {
        Text('取消').fontSize(16).fontWeight(400)
          .lineHeight(24)
      }
      .onClick(() => {
        Haptics.tap();
        this.isShowCloudImport = false
      })
      .alignItems(HorizontalAlign.Center)
      .padding({
        top: 16
      })
    }
    .padding({
      left: 20,
      right: 20
    })
  }

  @Builder
  // 书架搜索浮窗（2026-09-22 新增）：按书名/作者在**本地库**里过滤
  ShelfSearchDialog() {
    Column() {
      ShelfSearchPanel({
        onClose: () => {
          this.isShowShelfSearch = false
        }
      })
    }
    // ── 独立四圆角悬浮（2026-09-22 用户要求）──────────────────────────────
    // 用户原话：「书架放大镜的 sheet **底部粘连**，并且太高了，缩短 40%」。
    // sheet 侧已设为 `backgroundColor: Color.Transparent`，
    // 所以这里必须由**内容层**提供「留白 + 圆角 + 实底」：
    //   · `margin` 左右 16 / 底 12 ⇒ 面板与屏幕边缘的视觉留白（**去掉底部粘连**）
    //   · `padding` 16 ⇒ 圆角保护（内容不被 r=20 的圆弧压住）
    .backgroundColor(ShelfColors.card())
    .borderRadius(20)
    .padding(16)
    .margin({ left: 16, right: 16, bottom: 12 })
    .height('100%')
  }


  changeTheme(themeNum: number) {
    // 右上角更多（索引与 moreList 对齐，见其注释）
    switch (themeNum) {
      case 0:
        // 书籍导入 → **直接衔接本地导入**（用户要求：去掉二级菜单，化繁为简）。
        // 原来这里 `isShowImport = true` 弹出一个「本地导入/网盘导入/网址导入」二级菜单，
        // 而其中「网盘导入」是空壳、「网址导入」的 `ConfirmCallback` 从未赋值
        // （输完网址点确定只关弹窗）⇒ 只剩本地导入是真功能，直接做掉。
        this.pickLocalBooks()
        break
      case 1:
        // 导入书单弹窗（2026-09-25：标准居中 @CustomDialog）
        Haptics.tap();
        this.openImportListDialog()
        break
      case 2:
        // 迁 Navigation 第 4 期：管理页已改为 NavDestination，改走路由门面。
        AppRouter.push(RouteName.BOOK_MANAGE, {
          currentIndex: this.currentIndex,
          EXHIBIT: this.EXHIBIT,
          bookTypeNumber: this.bookTypeNumber
        } as BookManageRouteParam)
        break
    }
  }

  /**
   * 本地导入：拉起文件选择器 → 拷贝进沙箱 → 刷新书架。
   *
   * 为什么抽成方法：「书籍导入」现在**直接**走这里（用户要求去掉二级菜单），
   * 不再经过「本地导入 / 网盘导入 / 网址导入」那一层。
   *
   * 支持的后缀与 ReaderKit 官方支持列表一致：`txt / epub / mobi / azw / azw3`
   * （官方文档 documentId：`开发指南/Reader_Kit_阅读服务/Reader_Kit简介/reader-introduction`）。
   */
  private async pickLocalBooks(): Promise<void> {
    try {
      const fileResult = await FileHandler.documentPickerFile(undefined,
        ['.txt', '.epub', '.mobi', '.azw', '.azw3'])
      this.isShowImport = false
      if (fileResult.length === 0) {
        return
      }
      // ⚠️ 2026-09-24 导入竞态修复：必须**逐本 await** 到"拷贝+写库"真正完成，
      // 全部结束后再刷书架。旧实现 forEach 不等待 + 固定 500ms 定时器盲刷，
      // 批量导入时写库还没跑完就查了库 ⇒ 书架只出现一部分，重启才恢复。
      let okCount = 0
      for (const item of fileResult) {
        const ok = await FileHandler.CopyFile(item, this.currentIndex)
        if (ok) {
          okCount++
        }
      }
      if (okCount > 0) {
        showMessage(`已导入 ${okCount} 本书籍`)
        // 写库已在上面 await 完成，这里可以**立即**刷新，不再需要延时。
        this.isBookRefreshing++
      }
    } catch (e) {
      showMessage('导入失败：' + (e instanceof Error ? e.message : String(e)))
    }
  }

  //书单粘贴导入
  async pasteBookImport() {
    try {
      let url = getPasteDataSync()
      if (!url) {
        showMessage('未获取到粘贴信息，请求默认数据')
        await sleep()
        return
      }
      if (!isNetworkUrl(url ?? '')) {
        showMessage('复制的链接不正确')
        await sleep()
        url = undefined
        return
      }
      const res: AxiosResponse = await axios
        .get(url);
      this.bookImport = res.data as bookShelfImport[]
      showMessage(this.bookImport.length > 0 ? `相关书单书籍内容导入${this.bookImport.length}本` :
        '未找到相关书单书籍内容')
      this.bookImport.length > 0 ? booksUtil.batchAdd(this.bookImport, this.currentIndex) : ''
    } catch (err) {
      console.error('错误 ' + err);
    }
  }
}