import AppRouter, { RouteName, BookManageRouteParam } from '../../../common/router/AppRouter'
import BookBodyContent from './components/BookBodyContent'
import { FileHandler } from '../../../common/utils/FileHandler'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil'
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
import ShelfPrefs from '../../../common/utils/ShelfPrefs'
// 三横面板（排序 + 列表/宫格）：2026-10-20 三横从 GroupType 搬到本组件后由这里打开
import { GroupManageDialog } from '../../../componets/group/GroupManageDialog'
// 分组管理弹窗（2026-10-22 新增）：复用「移动至分组」组件 + 打开前预取分组
import BookSelectGroupDialog from './components/dialog/BookSelectGroupDialog'
import bookGroupUtils from '../../../common/utils/bookGroupUtils'
import { BookGroups } from '../../../database/entities/BookGroups'
import { LengthMetrics } from '@kit.ArkUI'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
// ── Symbol 点击动效令牌 + 全局震动反馈（2026-09-25 新增）──────────────────────
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion'
import { Haptics } from '../../../common/utils/Haptics'
import { importableExts } from '../../../common/format/FormatFlags'
// ── 个性化插件屏（2026-10-10 新增）───────────────────────────────────────────
import { PlugboardZone } from '../../../componets/plugboard/PlugboardZone'
import { PlugZone } from '../../../componets/plugboard/PlugboardTypes'

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
  /**
   * 展示形态（列表 / 宫格）。
   *
   * ── 2026-10-19 需求第 2 条 ────────────────────────────────────────────────
   * 用户原话：「默认进入是宫格显示，而不再是列表，并且切换做好持久化，
   *   而不是每次都重置为列表」。
   * ⇒ ① 初值从 `ShelfPrefs` 读（默认宫格，见 `ShelfPrefs.isGrid()`）；
   *   ② 切换时写回 `ShelfPrefs`。
   * 回退：`ShelfPrefs.ENABLED = false` ⇒ 恒返回宫格默认，不读不写持久化。
   *
   * ⚠️ 2026-10-20：切换按钮已从顶栏第一行**搬进三横弹窗**
   *   （`groupTypePanel.ExhibitSection`，用户：「把列表/宫格挪进三横的弹窗里面」）。
   *   弹窗与书架不是父子关系 ⇒ 改走 AppStorage 广播：
   *   弹窗写 `SHELF_EXHIBIT_GRID`，这里 `@Watch` 同步到 `EXHIBIT`。
   */
  @StorageLink('SHELF_EXHIBIT_GRID') @Watch('onGridModeChanged') gridMode: boolean = ShelfPrefs.isGrid()
  /** 由 `gridMode` 驱动的展示形态（唯一渲染源） */
  @State EXHIBIT: string = ShelfPrefs.isGrid() ? '宫格' : '列表'

  /** AppStorage 的宫格开关变了 ⇒ 同步本页的展示形态（弹窗里点「列表/宫格」时触发） */
  onGridModeChanged(): void {
    const next: string = this.gridMode ? '宫格' : '列表'
    if (this.EXHIBIT !== next) {
      this.EXHIBIT = next
    }
  }
  @State @Watch('changeGroup') GROUP: string = '标签'
  /**
   * 右上角「更多」菜单（2026-09-21 精简）。
   * 「下载管理」已删：`DownloadManagementPage` 里是三组硬编码「斗破苍穹」假列表，
   * 全工程 grep `downloadFile|DownloadTask|@ohos.request.download` **零命中**，
   * 页面内的 `switch(index){case 5,6,7: break}` 与「全选」`onClick` 也都是空的。
   *
   * ── 2026-10-19：删掉「导入书单」入口（用户需求第 2 条）──────────────────────
   * 用户原话：「删除导入书单」。
   * ⚠️ 被删掉的实现**保留在文件里**（`openImportListDialog` / `pickBookListLocal` /
   *    `pasteBookImport` / `ImportBookListDialog` 组件），只是没有入口调用它们 ——
   *    按用户要求「只针对入口，具体功能暂时不引用了，屏蔽入口」。
   *    想恢复入口：把 `new IconTitleVo($r('app.media.import_book_svg'), '导入书单')`
   *    加回本数组即可。
   *
   * ⚠️ **2026-10-22 起分发改成按标题匹配**（`changeTheme(title)`）：因为「分组管理」
   *    只在分组状态下出现（`visibleMoreList()`），项数会变 ⇒ 下标不再稳定，
   *    写 `case 0 / case 1` 迟早错位（这正是本节历史上的三次踩坑来源）。
   */
  /**
   * 右上角「更多」菜单项。
   *
   * ── 2026-10-22：图标全部改为**系统符号**（用户要求「全改成 symbol」）────────────
   * 原来三项都是 `Image` 加载的 SVG 位图，而三张源文件规格互不一致
   * （20×20/0.88、16×16/0.88、24×24/**0.65**）⇒ 被 `Image` 强行缩进 20×20 框后
   * 视觉大小与灰度都对不上（`fillColor` 改不了图形自身的 `fill-opacity`）。
   * 详见 `dialogTitleFuction` 文件头的对照表。
   *
   * 符号名**逐个核实自 SDK 真源** `sysResource.js`（317 KB 全表）：
   * ```
   * square_and_arrow_down: 125832677,   ← 书籍导入（方框 + 下箭头 = 导入语义）
   * list_checkmark:        125835983,   ← 批量管理（清单 + 勾选 = 批量勾选语义）
   * folder:                125831897,   ← 分组管理（文件夹）
   * ```
   * ⇒ 三项同源（同一套 symbol 字体）、同字号（`dialogTitleFuction` 统一 18）、
   *   同色（与文字共用 `fgColor()`）⇒ 不会再出现"这一项偏大偏灰"。
   *
   * 构造参数：`new IconTitleVo(旧SVG, 文案, 系统符号)` —— 第 1 个传 `undefined`
   * 表示"不再需要旧位图"，渲染时走 `SymbolGlyph` 分支。
   */
  private moreList: IconTitleVo[] = [
    new IconTitleVo(undefined, '书籍导入', $r('sys.symbol.square_and_arrow_down')),
    new IconTitleVo(undefined, '批量管理', $r('sys.symbol.list_checkmark')),
    // ── 2026-10-22 新增「分组管理」（用户需求第 1 条）──────────────────────────
    // 用户原话：「用户在分组状态下，也就是三段开关的分组开关下，点击更多，在书籍导入/
    //   批量管理之下应该增加一个分组管理，点击之后进入移动至分组的弹窗，虽然我们复用
    //   移动至分组的弹窗，但是和移动至分组不一样，我们的弹窗是分组管理…」
    // ⚠️ 本项**只在「分组」状态下出现**（见 `visibleMoreList()`）⇒ 数组下标与
    //   `changeTheme()` 的 case 不再一一对应，所以分发改成**按标题**匹配。
    new IconTitleVo(undefined, '分组管理', $r('sys.symbol.folder')),
  ]

  /**
   * 「分组」状态判定（2026-10-22）：三段开关停在「分组」上。
   *
   * `bookTypeNumber === 1` 就是「分组」这个系统单元的 groupId ——
   * 依据 `BookGroupsDao.initGroupData()` 的插入顺序 `['分组','全部','未分组','本地','书单']`
   * （`BookGroupsDao.ets:221`）⇒ 分组=1 / 全部=2 / 未分组=3 / 本地=4 / 书单=5，
   * 与 `BookContentRefresh` 里 `bookTypeNumber === 1` 判「分组页」的口径**完全一致**。
   * 「最近」态下 `bookTypeNumber` 保持上次的值 ⇒ 必须同时排除 `onRecentChip`。
   */
  private inGroupState(): boolean {
    return !this.onRecentChip && this.bookTypeNumber === 1
  }

  /** 当前实际渲染的「更多」菜单项（分组管理只在分组状态下出现） */
  private visibleMoreList(): IconTitleVo[] {
    if (this.inGroupState()) {
      return this.moreList
    }
    return this.moreList.filter((it: IconTitleVo): boolean => it.title !== '分组管理')
  }
  /**
   * 「⋯」菜单的内容层材质修饰器（2026-10-19）。
   *
   * 第二参数 `true` = **调用方已在 options 里给了 `systemMaterial`** ⇒ 材质生效时
   * 内容层一个背景属性都不设（官方：「主动设置的背景色、背景模糊…不生效」）；
   * 夜间 / 设备不支持材质时自动落回 `ShelfColors.surface()` 实底，不会透明露底。
   * 语义与全局弹窗（`BookInfoDialogs` 等）完全一致 —— 这就是"统一风格"的落点。
   */
  private menuSurface: MaterialColumnModifier =
    new MaterialColumnModifier(ShelfColors.surface(), true)
  changeGroup() {
    if (this.GROUP === '文件夹') {
      this.bookTypeNumber = 1
    } else {
      this.bookTypeNumber = 2
    }
  }

  @State isShowImport: boolean = false
  @State isShowCloudImport: boolean = false

  // ══════════════════════════════════════════════════════════════════════════
  // 排序（2026-10-19，需求第 3 / 6 条）
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * 当前是否停在「最近」这个**虚拟 chip** 上。
   *
   * ── 「最近」是什么（与用户逐条敲定）──────────────────────────────────────
   * 用户原话：「新增的最近和全部的区别是，全部以后是默认排序，最近继承现有的
   *   点击之后所看书籍上移…最近只有一种排序就是最近↓，然后其他的标签包括后续用户
   *   自定义的标签分组都会随着排序进行排序。」
   * ⇒ · 「最近」**不是数据库里的分组**，它不落 `book_groups` 表（避免污染既有
   *      `sortSystemChips` 五要素白名单与 `isLockedUnit` 判定）；
   *    · 它是一个**虚拟 chip**：选中时把查询口径置成「全部书（bookGroup=2）」
   *      且排序**锁死**为「最近阅读降序」；
   *    · 其余 chip（全部 / 自定义分组…）走 `ShelfPrefs` 里的排序档。
   *
   * 初值：需求「首次安装默认都是在最近」⇒ `ShelfPrefs.isRecentChip()`（默认 true）。
   *
   * ⚠️ 2026-10-19：改用 `@StorageLink('SHELF_RECENT_CHIP')` 而不是纯 `@State`。
   *   原因：排序面板挂在**分组管理弹窗**（`groupTypePanel`）里，它与本页不是父子关系，
   *   一旦用户在里面排序就必须同时把「最近」退掉 —— 只有 AppStorage 这条公共通道能做到。
   *   `@StorageLink` 的初值就是首次创建该 key 时的值 ⇒ 从持久化恢复。
   */
  @StorageLink('SHELF_RECENT_CHIP') onRecentChip: boolean = ShelfPrefs.isRecentChip()
  /**
   * 排序变更信号（自增触发子组件重查）。
   *
   * 为什么不直接用 `BOOK_IS_BOOK_REFRESHING`：那个信号是"**数据**变了"，
   * 会连带重取 `bookCount` 等；排序变化只是"**顺序**变了"，用独立信号更精确。
   * `BookContent` 已加同名 `@StorageLink`，见那边的注释。
   */
  @StorageLink('SHELF_SORT_TICK') sortTick: number = 0
  /** 三横（≡）按钮的 Q弹缩放（2026-10-20 从 `GroupType` 搬到本组件） */
  @State sortScale: number = 1
  /** 排序/显示设置面板控制器（每次打开新建，理由见 GroupType 同款注释） */
  private sortPanelDialog: CustomDialogController | null = null

  /**
   * 打开「显示设置」面板（排序 + 列表/宫格）。
   *
   * ⚠️ 2026-10-20：三横已移到本组件，所以这里自己 new 控制器。
   *   每次都新建：SDK `custom_dialog_controller.d.ts:756` NOTE
   *   「Custom dialog box parameters **do not support dynamic updates**」，
   *   而且"每次进入记录一个排序快照"正是靠新实例的 `aboutToAppear` 实现
   *   （见 `groupTypePanel.aboutToAppear` 的快照逻辑）。
   */
  private openSortPanel(): void {
    this.sortPanelDialog = new CustomDialogController({
      builder: GroupManageDialog({
        // 分组列表已不再在面板里渲染（用户：「显示分组和隐藏分组也不在需要了」），
        // 传空数组即可 —— 面板只读 `curSortKey/curSortDir/isGridMode` 这些全局态。
        showGroupList: [],
        currentIndex: this.currentIndex,
        onClose: (): void => {
          this.sortPanelDialog?.close()
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '90%',
      customStyle: false,
      cornerRadius: 20,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        // 遮罩/返回键：同样必须真的 close（工程既有约定，见 GroupType 同款注释）
        this.sortPanelDialog?.close()
      },
    })
    this.sortPanelDialog?.open()
  }

  /**
   * 冷启动时从持久化恢复「当前选中的 chip」（2026-10-19 需求第 3 条）。
   *
   * ── 为什么必须在 aboutToAppear 里显式恢复，而不是靠 @StorageLink 的初值 ────
   * `@StorageLink(key) x: T = init` 的 `init` **只在 AppStorage 中该 key 尚不存在时**
   * 用于创建它；页面重建（切 tab、返回书架）时 key 已存在，初值表达式**不会再求值**。
   * 而 `ShelfPrefs` 是磁盘持久化 —— 两者不是一个东西：
   *   冷启动 ⇒ AppStorage 是空的 ⇒ 会走初值 ✓
   *   但若用户上次停在「某分组」而这次冷启动，`isRecentChip()` 只能推出 true/false，
   *   **推不出具体的 groupId** ⇒ 必须从 `ShelfPrefs.getCurrentChipId()` 显式还原。
   * 官方依据（`@StorageLink` 语义）：documentId
   *   `API参考/ArkUI_方舟UI框架/ArkTS组件/状态管理与渲染控制/状态管理V1装饰器/
   *    StorageLink_AppStorage双向数据同步/ts-state-management-storagelink`，原文：
   *   「若AppStorage中**已存在**该键名对应的属性，则@StorageLink装饰变量的本地初始值
   *     将被AppStorage中对应属性的值**覆盖**；若AppStorage中不存在该键名对应的属性，
   *     则以@StorageLink装饰变量的本地初始值在AppStorage中创建对应属性。」
   * ⇒ 与上面分析一致：已存在时不会用我们的初值。
   */
  aboutToAppear(): void {
    const savedChip: number | undefined = ShelfPrefs.getCurrentChipId()
    if (savedChip === undefined) {
      // 上次停在「最近」（或首次安装）⇒ 保持默认
      this.onRecentChip = true
    } else {
      this.onRecentChip = false
      this.bookTypeNumber = savedChip
    }
  }

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

  /**
   * 书架顶部**三个图标**（🔍 搜索 / ≡ 排序 / ⋯ 更多）的颜色。
   *
   * ── 2026-10-22 改回**中性色**（用户要求）────────────────────────────────────
   * 用户原话：「我需要优化的是书架顶部的三个图标，搜索，排序，更多这三个」+
   *   「正常日间黑色，夜间白色就行」。
   *
   * ── 改造前为什么"顺色、看不清"（实测数字）───────────────────────────────────
   * 旧实现日间返回 `this.theme.mainColor`（2026-10-11 那版的"跟随主题色"），
   * 而这三个图标压在**玻璃胶囊**上：`ImmersiveMaterialUtil.glassOptions()` 的
   * `color: 'rgba(255, 255, 255, 0.35)'` 叠在页面顶部**主题渐变**（起点就是 `mainColor`）上
   * ⇒ 底色本身就被主题色染过一遍，再拿同一个 `mainColor` 画图标，等于**同色压同色**。
   *
   * 按 WCAG 2.x 公式实算（玻璃层先与主题色 alpha 合成，再算对比度）：
   *
   * | 主题 | 胶囊实际底色 | 旧（主题色） | 改为黑色 |
   * |---|---|---|---|
   * | 粉 | `#FFBAC6` | **1.30:1** | **13.10:1** |
   * | 红 | `#F58585` | **1.54:1** | **8.59:1** |
   * | 黄 | `#FFBA59` | **1.30:1** | **12.43:1** |
   * | 蓝 | `#69B4FF` | **1.54:1** | **9.54:1** |
   * | 绿 | `#71CDA7` | **1.42:1** | **10.98:1** |
   *
   * 图标门槛 3:1 —— 旧实现**五套主题全部不达标**（最低 1.30:1），这就是用户说的"顺色"。
   *
   * ── 现在 ──────────────────────────────────────────────────────────────────
   * 日间近黑 / 夜间近白，与 `ShelfColors.icon()` 同一档（该方法是全工程图标的既有基准，
   * 其注释已记录"夜间不给色会画成黑色 ⇒ 深色底上完全看不见"这个真机教训）：
   *   · 日间 `rgba(19, 19, 19, 0.88)` —— 与主题色的色相无关，任何主题下都 ≥ 8.5:1；
   *   · 夜间 `rgba(248, 249, 250, 0.88)` —— 深色渐变上 14:1 级别。
   *
   * ⚠️ 这里**不再跟随主题色**。想要"主题感"，主题色已经通过整页渐变 + 三段开关的选中态
   *   表达了；顶部功能图标属于"工具"，用中性色换取可读性是正确的取舍。
   *
   * 回退：把方法体改回 `return NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : this.theme.mainColor`
   *   即恢复 2026-10-11 那版"跟随主题色"的行为。
   */
  private trailingIconColor(): string {
    return ShelfColors.icon()
  }

  build() {
    Column() {
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.End
      }) {
        // ── 2026-10-13 用户要求：**删掉「喵阅」标题行，让下方内容整体上提** ──────────
        // 真机实测（Mate 80 Pro Max，1320×2848 @3.35）：
        //   · 「喵阅」文字本身占 y=132~232（30vp）；
        //   · 它所在的那个 `List` 写了 `.height(40)` ⇒ **这 40vp（134px）才是标题行的真实占高**；
        //   · 下一行「最近阅读」胶囊在 y=344。
        // ⚠️ 关键结论：**只删那两个汉字不会让内容上提** —— `.height(40)` 还在，
        //    下面会留一条 40vp 的空白带。必须把这个 List 一起删掉，Tabs 才会整体上移 40vp。
        // 为什么可以整个删：`titleArray` 只有一项 `['书架']`、页签栏 `barWidth/barHeight = 0`
        //   ⇒ 这个标题除了"点一下回到 0 号页签"没有任何作用（点到它也只是原地不动）。
        //
        // ⚠️ 但下面这个 **0 尺寸的 Row 必须留着**：它是 `bindSheet`（网盘导入 / 云盘导入）
        //    的绑定锚点，删掉它「网盘导入」弹窗就再也弹不出来（`bindSheet` 需要一个可见节点）。
        Row() {
          Flex() {
          }
          .width(0)
          .height(0)
          .bindSheet($$this.isShowCloudImport, this.CloudImportDialog(), {
            height: 240,
            showClose: false,
            dragBar: false,
            backgroundColor: ShelfColors.card(),
            blurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
            onDisappear: () => {
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
                // ── 2026-10-19：「最近」虚拟 chip 状态 + 排序信号 ──────────────
                // 「最近」= 全部书 + 锁死最近阅读降序；其余 chip 走 ShelfPrefs 的排序档。
                onRecentChip: this.onRecentChip,
                sortTick: this.sortTick,
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
      // ★★ 2026-10-11 二修：**撤掉 pageBg 兜底白底**（上一版把它当成"白条"的修法，判断错了）★★
      //
      // 上一版（HEAD 5a770c3）写道：「去掉 pageBg 兜底 ⇒ 底部手势条出现白条蒙版（渐变 0.2 后
      // 重复着色）」——真凶不是这个，证据两条：
      //   ① 官方对 `linearGradient.colors` 的原文（documentId
      //      `API参考/…/通用属性/视效与模糊/颜色渐变/ts-universal-attributes-gradient-color`）：
      //      「repeating7+ | boolean | 设置渐变颜色是否在组件范围内循环重复填充。**默认值：false**。
      //        false：渐变效果**仅在指定范围内显示一次**。」
      //      本组件**没有**设 `repeating: true` ⇒ 0.2 之后一路是 `secondColor`，**不存在重复着色段**。
      //   ② 真机截图逐行采样（`screenshot_20261010_210433`，橙主题）：y=660 到 y=2460 恒为
      //      (254,236,224)=#ffece0，2000+px 无任何周期性变化 ⇒ 实测与官方默认值一致。
      //
      // 真凶在 HDS 页签那一侧：悬浮页签**自带一层底部渐变蒙层**（`gradientMask`，浅色模式默认
      // `#CCF1F3F5` 铺满屏幕最底 72vp），已在 `Index.ets` 的 `hdsFloatingStyle()` 里关掉
      // （那里有完整证据链与像素验算）。所以这里恢复"渐变贯通"的观感 —— 也就是
      // 35ee995 那一版（= 用户截图那一版）的样子，与"我的"页同款。
      .scrollable(this.APP_INDEX_SCROLLABLE)
    }
    .height('100%')
    // ★ 恢复（35ee995 那一版原本就有；上一版连带删掉时记的是"多余"）：让整页渐变（含底部
    //   手势条区）一并铺进系统安全区。35ee995 之后它是与"无兜底底色"配套存在的 ⇒ 一起恢复。
    .expandSafeArea([SafeAreaType.SYSTEM])
    // ── 页面主题渐变（书架整页的底色）────────────────────────────────────────
    // 日间：主题 mainColor → secondColor（用户可选 5 套浅色主题）。
    // 夜间：换成中性深灰渐变 —— `themeManager` 那 5 套**全是浅色**
    // （`common/constants/Theme.ets:5-9`，如 `#ffece0`），直接沿用会让整页发白。
    // 取值与规则见 `ShelfColors.gradientStart/End()`。
    .linearGradient({
      direction: GradientDirection.Bottom, // 渐变方向
      // ⚠️ 这里**不是**重复着色（旧注释抄自官方示例片段，那段示例同时设了 `repeating: true`）：
      //    官方原文「repeating7+ … 默认值：false。false：渐变效果只在指定范围内显示一次」
      //    ⇒ 0 → 0.2 之间是 mainColor → secondColor 的渐变，0.2 以下**恒为 secondColor**。
      //    真机实测吻合（截图 y=660 起恒为 #ffece0，见上方"二修"注释的采样数字）。
      colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0],
        [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]]
    })
    // ★ 底部圆角（35ee995 那一版起就有，与上面的 expandSafeArea 配套）
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
        .fontSize(20)        // ★ 2026-10-11：24→20，与下面"全部/本地"那行三横字号统一
        .fontColor([this.trailingIconColor()])
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

      // ══ 三横（≡）：只用来排序 + 列表/宫格 ═══════════════════════════════════
      // 2026-10-20「终极简化」：从 `GroupType` 尾部搬到这里。
      // 用户原话：「…下面一行的未分组后面接着搜索，搜索之后是三横…三横之后是更多」。
      // ⇒ 本行的图标顺序固定为：🔍 → ≡ → ⋯（与用户指定一致）。
      SymbolGlyph($r('sys.symbol.line_3_horizontal'))
        .fontSize(20)
        .fontColor([this.trailingIconColor()])
        .scale({ x: this.sortScale, y: this.sortScale })
        .onClick(() => {
          Haptics.tap();
          runJellyClick((v: number) => {
            this.sortScale = v
          })
          this.openSortPanel()
        })
        .clickEffect(UiMotion.CLICK)

      // ── 更多按钮（2026-09-25 换 SymbolGlyph；点击 Q弹缩放见 runJellyClick）────
      // 符号名 `more`（横向三点）同表查得；`more_fill` 也在表里（未用）。
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize(20)        // ★ 2026-10-11：24→20，与下面"全部/本地"那行三横字号统一
        .fontColor([this.trailingIconColor()])
        .scale({ x: this.moreScale, y: this.moreScale })
        .bindMenu(this.MenuBuilder(), {
          // ★ 2026-10-19：**菜单的系统材质**——全局统一的材质来源。
          // 官方：「菜单支持通过 ContextMenuOptions 中的 systemMaterial 字段设置沉浸光感效果」
          // （documentId `开发指南/…/组件适配沉浸光感/arkts-immersive-light-sense-component-adaptation`）。
          // `feedbackMaterial()` 就是工程里给「即时反馈类（Toast / 菜单）」准备的那一档（THICK /
          // 按算力收敛），与全局弹窗走同一套决策点 ⇒ 观感对齐。
          // 一键回退：把 `ImmersiveMaterialUtil.ENABLED` 改 false ⇒ 这里返回 undefined
          //   ⇒ 组件回落到内容层 `menuSurface` 的实底色，与改造前一致。
          systemMaterial: ImmersiveMaterialUtil.feedbackMaterial(),
          // 圆角与内容层一致（官方默认 20vp，这里显式写死，避免不同设备/版本漂移）
          borderRadius: 20,
        })
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
      ForEach(this.visibleMoreList(), (item: IconTitleVo, index) => {
        dialogTitleFuction({
          title: item.title,
          // 2026-10-22：改传**系统符号**（`symbol` 优先于旧 `icon`，见 dialogTitleFuction）
          symbol: item.symbol,
          // 2026-10-22：分隔线按**实际渲染条数**判最后一项（分组状态下多一项「分组管理」）
          isBorder: this.visibleMoreList().length !== index + 1,
          // 菜单内容已铺半透明深底（见本 @Builder 的注释）⇒ 文字/图标同步转浅
          nightStyle: NightMode.isDarkSurface()
        })
          .onClick(() => {
            Haptics.tap();
            // 2026-10-22：改传**标题**而非下标 —— 项数随状态变化，下标会错位
            this.changeTheme(item.title)
          })
      }, (item: IconTitleVo): string => item.title)
    }
    // ── 2026-10-19：材质改走**官方的菜单系统材质**，不再自己手画底 ──────────────
    // 用户原话：「更多点击之后出现的这个菜单弹窗…不是和我们全局一样的风格…应该就是换个材质的问题」。
    // 根因：全局弹窗（@CustomDialog）走的是 `systemMaterial`（沉浸光感），而这里是自己拼的
    //   「半透明面底 + COMPONENT_ULTRA_THICK」，所以观感对不上。
    // 官方两条原文：
    //   ① 「菜单支持通过 ContextMenuOptions 中的 systemMaterial 字段设置沉浸光感效果」
    //      （documentId `开发指南/…/组件适配沉浸光感/arkts-immersive-light-sense-component-adaptation`）；
    //   ② 同一篇：「沉浸光感开启后，**主动设置的背景色、背景模糊等自定义样式属性不生效**」
    //      ⇒ 想拿到材质就必须把 `backgroundColor` / `backgroundBlurStyle` 让出来，不能并存。
    //   `MenuOptions extends ContextMenuOptions`（SDK `common.d.ts:15637`），
    //   而 `systemMaterial?: SystemUiMaterial;` @since 26.0.0（同文件 `:15594`）。
    // ⇒ 内容层交给 `MaterialColumnModifier`：材质生效时**一个背景属性都不设**；
    //   夜间/材质不可用时自动落回实底色，绝不会透明露底（见该修饰器 `applyNormalAttribute`）。
    .borderRadius(20)
    .attributeModifier(this.menuSurface)
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


  changeTheme(title: string) {
    // 右上角更多（**按标题分发**，2026-10-22 起；项数会随状态变化，下标不可靠）
    switch (title) {
      case '书籍导入':
        // 书籍导入 → **直接衔接本地导入**（用户要求：去掉二级菜单，化繁为简）。
        // 原来这里 `isShowImport = true` 弹出一个「本地导入/网盘导入/网址导入」二级菜单，
        // 而其中「网盘导入」是空壳、「网址导入」的 `ConfirmCallback` 从未赋值
        // （输完网址点确定只关弹窗）⇒ 只剩本地导入是真功能，直接做掉。
        this.pickLocalBooks()
        break
      case '批量管理':
        // ── 2026-10-19：原 case 2「批量管理」前移到 case 1 ────────────────────
        // 因为「导入书单」（原 case 1）的入口已按用户需求删除，索引整体前移一位。
        // 迁 Navigation 第 4 期：管理页已改为 NavDestination，改走路由门面。
        AppRouter.push(RouteName.BOOK_MANAGE, {
          currentIndex: this.currentIndex,
          EXHIBIT: this.EXHIBIT,
          bookTypeNumber: this.bookTypeNumber
        } as BookManageRouteParam)
        break
      case '分组管理':
        // 2026-10-22 新增（用户需求第 1 条）：复用「移动至分组」弹窗，进**分组管理模式**
        this.openGroupManageDialog().catch((e: Error): void => {
          console.error('openGroupManageDialog failed: ' + e.message)
        })
        break
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 「分组管理」弹窗（2026-10-22 新增，用户需求第 1 条）
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * 打开分组管理：**复用 `BookSelectGroupDialog`**，只把 `isManageMode` 置 true。
   *
   * ── 为什么与 `BookInfoDialogs.openMoveGroupDialog()` 一样"打开瞬间新建 controller"──
   * SDK `custom_dialog_controller.d.ts:756` NOTE 原文「Custom dialog box parameters
   * **do not support dynamic updates**」⇒ 参数（含 `isManageMode`）只在创建时固化；
   * 而且每次打开都重新预取分组（`prefetchGroups`）⇒ 首帧就有完整列表、且是当次最新。
   *
   * ── 三条关闭路径（与工程统一口径一致）────────────────────────────────────────
   *   · 「取消」按钮 ⇒ 弹窗回调 `onClose` ⇒ 本方法 close 它（关闭权归持有 controller 的一侧）；
   *   · 遮罩 / 返回键 ⇒ options 的 `cancel` ⇒ 同样 close；
   *   · 新建分组成功后 ⇒ `onGroupCreated` ⇒ close 旧实例 → 重新预取 → new → open
   *     （与 `openMoveGroupDialog` 的「真开真关」完全同款，理由见那边注释）。
   *   · 删除/解散成功后 ⇒ `BookSelectGroupDialog.afterGroupChanged()` 也走 `onGroupCreated`
   *     这条通道重开（分组列表已变，必须重建实例才看得到）。
   */
  private groupManageDialog: CustomDialogController | null = null

  private async openGroupManageDialog(): Promise<void> {
    const groups: BookGroups[] = await bookGroupUtils.prefetchGroups(this.currentIndex)
    const dlg = new CustomDialogController({
      builder: BookSelectGroupDialog({
        // 本模式下点「未分组」无反馈、点其它分组弹三选一（见组件内 isManageMode 注释）
        isManageMode: true,
        // 没有选定书籍 ⇒ 不传 Ids / oldGroupId（保持默认 0，两个分支都不会用到）
        currentIndex: this.currentIndex,
        // 分组管理不"移动"，`moveGroup` 不会被调用；给空实现保持签名完整
        moveGroup: (): void => {},
        onClose: (): void => {
          this.groupManageDialog?.close()
          this.groupManageDialog = null
        },
        // 新建分组 / 删除 / 解散成功后：真开真关（重新预取分组再开）
        onGroupCreated: (): void => {
          this.groupManageDialog?.close()
          this.groupManageDialog = null
          this.openGroupManageDialog().catch((e: Error): void => {
            console.error('openGroupManageDialog after change failed: ' + e.message)
          })
        },
        presetGroups: groups
      }),
      height: 400,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      customStyle: false,
      cornerRadius: 25,
      // 材质与「移动至分组」弹窗完全同款（内容层已让出背景，见 BookSelectGroupDialog 的 surface）
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.groupManageDialog?.close()
        this.groupManageDialog = null
      }
    })
    this.groupManageDialog = dlg
    dlg.open()
  }

  /**
   * 本地导入：拉起文件选择器 → 拷贝进沙箱 → 刷新书架。
   *
   * 为什么抽成方法：「书籍导入」现在**直接**走这里（用户要求去掉二级菜单），
   * 不再经过「本地导入 / 网盘导入 / 网址导入」那一层。
   *
   * 支持的后缀由 `FormatFlags.importableExts()` 统一给出：默认仍与 ReaderKit 官方列表一致
   * （`txt / epub / mobi / azw / azw3`，官方 documentId
   * `开发指南/Reader_Kit_阅读服务/Reader_Kit简介/reader-introduction`）；
   * 2026-10-19 起可含 `pdf / docx / doc`（受 `FMT_MASTER_ENABLED` 等开关控制，关掉即回退）。
   */
  private async pickLocalBooks(): Promise<void> {
    try {
      const fileResult = await FileHandler.documentPickerFile(undefined, importableExts())
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
