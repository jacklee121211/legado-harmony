import BookGroupsDao from '../../database/dao/BookGroupsDao'
import { BookGroups } from '../../database/entities/BookGroups'
// ⚠️ 2026-10-20：`BookType` 已不再使用 —— 顶栏 chip 行整体换成官方 `SegmentButton`
//    （封装见 `componets/common/GlassSegment.ets`）。`BookType` 组件本身保留
//    （`GroupTypeSearch` 等其它地方仍在用）。
import { GroupManageDialog } from './GroupManageDialog'
import FolderInfoDialog from '../../pages/view/bookShelf/components/dialog/FolderInfoDialog'
import coverInfoDialog from '../../pages/view/bookShelf/components/dialog/coverInfoDialog'
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil'
// ⚠️ 2026-10-20：`runJellyClick` / `showMessage` / `Haptics` 在本文件已无调用点 ——
//   三横按钮搬去 `IndexShelf`、chip 行换成 `GlassSegment`（震动在它内部做）、
//   长按编辑弹窗的调用点随「显示分组」栏一起删除。保留 import 会触发 lint，故移除。
import UiMotion from '../../common/utils/UiMotion'
import { NightMode } from '../../common/utils/NightMode'
// ★ 2026-10-11：分组行三横图标跟随主题色（与 IndexShelf.trailingIconColor 同款语义）
import { ThemeItem } from '../../common/model/Theme'
import { ThemeStorageKey } from '../../common/constants/Theme'
import ShelfPrefs from '../../common/utils/ShelfPrefs'
// 顶栏分段控件（2026-10-20：官方 SegmentButton 封装，带沉浸光感材质）
import { GlassSegment } from '../common/GlassSegment'

/**
 * 分组管理弹窗「停在分组行下面」的位置修正量（vp，**唯一可调点**）。
 *
 * `offset.dy` 是按「弹窗可用区的顶边」算的（SDK `custom_dialog_controller.d.ts:105-115` 原文
 *   「Offset of the dialog box relative to the alignment position.」），
 * 而本行上报的 `shelfGroupRowBottom` 是**窗口坐标**（`units.d.ts:2110-2119`）。
 * 弹窗可用区按官方说明「excludes safe areas」（同文件 `:128`）⇒ 两者差一个顶部安全区，
 * 代码里已用 `AppStorage['topRectHeight']` 相减。
 *
 * ⚠️ 【待验证】这一处是**唯一无法在本机验证**的几何换算：真机上如果面板位置偏高/偏低，
 *   只改这个常量即可（正值往下、负值往上），不要改别的地方。
 */
const GROUP_PANEL_DY_FIX: number = 0

/**
 * 三个 chip 的**原始语义**顺序（下标即语义，永不变化）。
 *
 * 0 = 最近 · 1 = 全部 · 2 = 分组
 * ⚠️ 必须与 `componets/myset/ChipOrderSetting.ets` 里的 `SEM_RECENT/SEM_ALL/SEM_GROUP`
 *   以及 `CHIP_NAMES` **逐字一致**（两处都靠它做语义↔显示下标换算）。
 * 放在模块级而不是 struct 静态成员：`GroupType` 是 `export default struct`，
 * 组件实例内用 `CHIP_NAMES` 会报 `Cannot find name 'GroupType'`。
 */
const CHIP_NAMES: string[] = ['最近', '全部', '分组']

/**
 * 「最近」虚拟 chip 的**高亮哨兵值**（2026-10-19 二修）。
 *
 * ── 为什么必须是这样一个"怪值" ────────────────────────────────────────────
 * `BookType` 判高亮只有一条规则：`index === bookTypeNumber`。
 * 所有真实 chip 传的 `index` 都是**数据库 groupId**（`INTEGER PRIMARY KEY` 自增 ⇒ 恒为正）。
 * ⇒ 只要哨兵取一个**永不可能成为 groupId 的大负数**，就能做到：
 *    「最近」亮 · 所有真实分组灭，且不会误伤任何一格。
 *
 * ── 踩过的坑（务必别再复用 bookTypeNumber 的"口径值"做高亮）──────────────
 * 上一版点「最近」时写 `bookTypeNumber = 2`（那是 `BooksDao.buildWhereClause` 里
 * "不加分组条件 = 全部书"的 **bookGroup 口径**）。而 `BookGroupsDao.initGroupData`
 * 的插入顺序是 `['分组','全部','未分组','本地','书单']` ⇒ **「全部」的 groupId 恰好是 2**
 * ⇒ `2 === 2` ⇒ 点「最近」时「全部」也亮（用户反馈：
 *   「点击最近，进入最近，但是全部还是被选定的状态」）。
 *
 * ── 为什么单独开一个 @State 而不是直接写进 bookTypeNumber ─────────────────
 *   `bookTypeNumber` 在本工程里**身兼两职**：
 *     ① 分组筛选 id（`BooksDao.buildWhereClause` 的 `bookGroup`）；
 *     ② **多个分支判别值**（`=== 1` 分组 / `=== 5` 书单，见 `BookContentRefresh`、
 *        `BookManageDialog`、`BookManagePage` 共 30+ 处）。
 *   把 -9999 写进它会顺着路由流到管理页（`BookManagePage.routeParam.bookTypeNumber`），
 *   那些 `=== 1 / === 5` 的判断全部落空 ⇒ 管理页空白。
 * ⇒ 用独立的 `chipHighlightId` 专供高亮，只影响这一行的显色，零副作用。
 */
const RECENT_CHIP_ID: number = -9999

@Component
export default struct groupTypeComponent {
  @State globalPositionY: Length = 0
  /** 分组行尾部三横按钮的 Q弹缩放值（2026-09-25，`runJellyClick` 自驱 `.scale()`） */
  @State groupRowScale: number = 1

  /** 显示分组 chip 的**长按编辑**弹窗（2026-09-25 新增：与隐藏分组同款 FolderInfoDialog） */
  @State editChipGroup: BookGroups | null = null
  private chipEditDialog: CustomDialogController | null = null

  private openChipEditDialog(): void {
    if (this.editChipGroup === null) {
      return
    }
    this.chipEditDialog = new CustomDialogController({
      builder: FolderInfoDialog({
        itemData: this.editChipGroup,
        // 真开真关（2026-10-01 用户方案）：子弹窗关闭后由**创建者**重建父弹窗——
        // 全新实例=全新 @Prop 快照，天然刷新；不再复用旧实例（其快照不具备刷新能力）。
        reopen: (): void => { this.reopenChipEditDialog() },
        cancel: (): void => {
          // 2026-10-12：**先真的 close**（旧写法只置 null ⇒ 弹窗留在屏幕上）
          this.chipEditDialog?.close()
          this.chipEditDialog = null
          this.getGroupList()
        }
      }),
      autoCancel: true,
      width: '80%',
      alignment: DialogAlignment.Center,
      customStyle: false,
      cornerRadius: 20,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      // 2026-10-12：遮罩/返回键路径同样**必须真的 close**（子组件内自己 close 不可靠，
      // 真机两次验证见 `ReaderSaveSchemeDialog.ets:205-208`）
      cancel: (): void => {
        this.chipEditDialog?.close()
        this.chipEditDialog = null
        this.getGroupList()
      },
    })
    this.chipEditDialog?.open()
  }

  /** 真开真关：重查该分组 → 更新 editChipGroup → **新建 controller** 全新实例打开 */
  private async reopenChipEditDialog(): Promise<void> {
    const id = this.editChipGroup?.groupId
    if (id !== undefined) {
      const groups: BookGroups[] = await BookGroupsDao.search({ type: this.currentIndex })
      const fresh = groups.find((g: BookGroups) => g.groupId === id)
      if (fresh !== undefined) {
        this.editChipGroup = fresh
      }
    }
    this.openChipEditDialog()
  }

  /**
   * 「书单」（系统单元）长按 → **直达封面样式弹窗**（2026-10-01 用户定义）。
   * 封面会真实应用到所有书单内的书（见 coverInfoDialog.resolveTargetBooks 的书单聚合分支）。
   */
  private worksCoverDialog: CustomDialogController | null = null
  private openWorksCoverDialog(item: BookGroups): void {
    this.worksCoverDialog = new CustomDialogController({
      builder: coverInfoDialog({
        itemData: item,
        // 2026-10-12：必须真的 close（旧写法只置 null ⇒ 弹窗关不掉）
        cancel: (): void => {
          this.worksCoverDialog?.close()
          this.worksCoverDialog = null
        }
      }),
      autoCancel: true,
      width: '92%',
      alignment: DialogAlignment.Center,
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      // 遮罩/返回键：同一条收尾路径（2026-10-12）
      cancel: (): void => {
        this.worksCoverDialog?.close()
        this.worksCoverDialog = null
      }
    })
    this.worksCoverDialog?.open()
  }
  /** App 级夜间开关：只为触发重绘（取色走 `ShelfColors`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  // ★ 2026-10-11：主题颜色（与 IndexShelf.ets:164 同款），给"三横"图标跟随主题色用。
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  @Link @Watch('changeRefresh')currentIndex: number
  @Link groupCoverShow:boolean
  @Link GROUP:string
  @State groupList:BookGroups[] = []
  @Link bookTypeNumber:number
  /**
   * 「最近」虚拟 chip 状态（2026-10-19 需求第 3 条）。
   *
   * ── 为什么是 `@Link` 而不是 `@Prop` ────────────────────────────────────────
   * 本行要能**写回**它（点「最近」= 切到该 chip），@Prop 是单向副本写不生效
   * （`BookFolder.openGroup` 的注释里记过同款坑）。
   *
   * ── 「最近」为什么不进数据库 ──────────────────────────────────────────────
   * 用户：「新增的最近和全部的区别是，全部以后是默认排序，最近继承现有的点击之后
   *   所看书籍上移…最近只有一种排序就是最近↓」。
   * 若把它做成 `book_groups` 里的一行，会污染两处**硬编码白名单**：
   *   · `GroupType.sortSystemChips()` 的 `order = ['全部','本地','书单','分组','未分组']`
   *   · `isLockedUnit()` / `groupTypePanel.BASE_UNIT_NAMES`
   * 且「最近」的查询口径是"全部书 + 锁死排序"，与任何真实分组都不同。
   * ⇒ 做成**纯 UI 层虚拟 chip**，只存在于本行，零数据库迁移。
   */
  @StorageLink('SHELF_RECENT_CHIP') onRecentChip: boolean = true
  /**
   * 分组行**高亮基准**（2026-10-19 二修，专供 `BookType.index === chipHighlightId`）。
   *
   * 与 `bookTypeNumber` 分离的原因见 `RECENT_CHIP_ID` 的注释：
   * `bookTypeNumber` 身兼"筛选 id + 分支判别值"两职，塞哨兵值会污染管理页。
   * 取值：停在「最近」⇒ `RECENT_CHIP_ID`；否则 = 当前分组的真实 groupId。
   */
  @State chipHighlightId: number = -9999
  /**
   * 分段控件的选中下标（2026-10-20 新增，**必须是独立 `@State`**）。
   *
   * ⚠️ 为什么不能直接传 `this.chipSelectedIndex()`：
   *   `@Prop` 只在**父组件 build 重跑**时重新取值，而 `chipSelectedIndex()` 是普通方法，
   *   框架**追踪不到它内部读了 `onRecentChip` / `chipHighlightId`**（不是直接的状态读取）
   *   ⇒ 传进去的值永不更新 ⇒ "点击后功能生效但按钮不切换"。
   *   这与主题页 `modeSel` 是**同一个坑**，两处一起修。
   * ⇒ 下标提升成 `@State`：`onChipClicked()` / `aboutToAppear()` 里显式同步。
   */
  @State chipSel: number = 0
  /**
   * 排序变更信号（透传给 `BookContent`）。
   *
   * ⚠️ 2026-10-19：排序区块最终放在**分组管理面板**里（`groupTypePanel.SortSection`），
   * 因为需求原话是「在**隐藏分组下面**新建一个区域」——隐藏分组只存在于那个面板中。
   * 本组件保留这个 `@Link` 只为把同一份状态透传给 `BookContent`（书架列表），
   * 真正递增发生在 `groupTypePanel.selectSort()/resetSort()`（写 AppStorage）。
   */
  @StorageLink('SHELF_SORT_TICK') sortTick: number = 0
  /**
   * 内容区左右滑动请求切档（2026-10-21 新增）。
   *
   * `BookBodyContent` 在书籍区域上挂了 `PanGesture`，松手时把「+1 / -1」写进本键；
   * 本组件 `@Watch` 收到后按当前下标偏移一档。
   *
   * ⚠️ 为什么用 AppStorage 而不是回调：手势在 `BookBodyContent`（孙子层），
   *   而选中态由本组件持有，中间还隔着 `@BuilderParam` 链路 ⇒ 走公共通道最可靠
   *   （与 `SHELF_RECENT_CHIP` / `SHELF_SORT_TICK` 同一套做法）。
   */
  @StorageLink('SHELF_CHIP_STEP') @Watch('onChipStep') chipStep: number = 0
  /**
   * 「跳到指定 chip」请求（2026-10-21 新增）。
   *
   * 用途：分组页的「返回分组列表」悬浮按钮（`BookContentRefresh`）需要**直接跳到**
   * 「分组」chip（下标 2），而不是相对 ±1 偏移 ⇒ 单独一条通道。
   * 与 `chipStep` 同样用「处理完复位成 -1」保证可重复触发（`@Watch` 只在值变化时跑）。
   */
  @StorageLink('SHELF_CHIP_GOTO') @Watch('onChipGoto') chipGoto: number = -1
  /**
   * 顶栏三段按钮排列（2026-10-21 新增）。
   *
   * 设置页「首页三段按钮排序」写这个键（`ChipOrderSetting.applyOrder`），
   * 本组件 `@Watch` 收到后重算显示下标 —— 因为**排列变了，同一语义项的位置也变了**
   * （例如「分组」从第 3 格跑到第 1 格，`chipSel` 必须跟着改，否则高亮会跳错格）。
   */
  @StorageLink('SHELF_CHIP_ORDER') @Watch('onChipOrderChanged') chipOrderKey: string = '0,1,2'
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') @Watch('changeRefresh')BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  /**
   * 分组管理弹窗控制器。
   * ⚠️ **每次展开都新建**（`openGroupPanel()` 里 `new CustomDialogController`）：
   *   SDK `custom_dialog_controller.d.ts:756` NOTE 原文「Custom dialog box parameters
   *   **do not support dynamic updates**」⇒ 要传"当前大类 index / 当前分组列表 / 当前位置"
   *   就只能新建（同 `ReaderPage3.openCatalogDialog()`）。
   *   新建的代价是不能用 `$xxx`（`@Link` 语法在方法里会 `ReferenceError`），
   *   所以参数一律走普通 `@Prop` 的"打开瞬间快照" —— 这正好是本面板需要的语义。
   */
  private groupPanelDialog: CustomDialogController | null = null
  aboutToAppear(): void {
    // 高亮基准初始化（2026-10-19 二修）：与 `IndexShelf.aboutToAppear` 恢复出的状态对齐
    //   · 停在「最近」 ⇒ 哨兵；否则用当前分组 id。
    //   为什么不用 `onRecentChip` 直接推导 highlightId：它只是个布尔，推不出"停在哪个分组"；
    //   而 `bookTypeNumber` 在「最近」态下**保持上次的值不变**（我们不再写 2），
    //   所以这里只能按 `onRecentChip` 二选一。
    this.chipHighlightId = this.onRecentChip ? RECENT_CHIP_ID : this.bookTypeNumber
    // 分段控件下标同步（2026-10-20）：必须是 @State，见 chipSel 的注释
    this.chipSel = this.chipSelectedIndex()
    this.getGroupList()
  }
  changeRefresh(){
    this.getGroupList()
  }
  getGroupList(){
    BookGroupsDao.search({
      type:this.currentIndex
    }).then((val)=>{
      this.groupList = this.sortSystemChips(val)
      // 分组列表到位后重算一次下标（「全部」「分组」的 groupId 要靠 groupList 才能反查）
      this.chipSel = this.chipSelectedIndex()
      // 上报当前分组名（「返回分组列表」悬浮按钮显示用，2026-10-21）
      AppStorage.setOrCreate<string>('SHELF_CURRENT_GROUP_NAME', this.currentGroupName())
    })
  }

  /**
   * 五个系统基础单元（2026-10-01 用户定义，**位置锁定**，顺序恒为）：
   *   全部 → 本地 → 书单 → 分组 → 未分组
   * 用户自建分组/书单按原相对顺序排在后面。
   * ⚠️ 实现必须是"按 isSystem+名字识别后**重建整个数组**"：上一版在 filter 出的子集里
   * `rest.indexOf(all)`（all 已被滤掉 ⇒ -1 ⇒ splice 位置错乱 + 全部丢失）——真机 18:2x
   * 复现"全部没了、书单改名后才出现全部"（改名后名字不再等于'书单'、works 找不到 ⇒ 走了
   * 原序分支）。这版对缺名系统行做兜底（找到几个排几个），customs 永远不会吞掉系统行。
   *
   * ══ 2026-10-20「终极简化」：本行**只留三个系统 chip，且不再显示自定义分组** ══
   * 用户原话：
   *   · 「所有的自定义分组创建后都不会在未分组后面进行显示了，只展示在分组里面」
   *   · 「其实未分组也可以删除，因为在分组中有未分组的置顶目录」
   * ⇒ 顶栏固定为：**最近 / 全部 / 分组**（「最近」由调用方单独渲染，见 build()）。
   *   · 「未分组」——删除（它的内容在「分组」页里有置顶目录）；
   *   · 「书单」「本地」——2026-10-19 已屏蔽，本次维持；
   *   · **自定义分组一律不进本行**（只在「分组」页的分组卡片列表里出现）。
   *
   * 恢复方法：把 `TOP_CHIP_NAMES` 加回 '未分组' 即可；要恢复自定义分组在顶栏，
   * 把下面 `customs` 那段重新 push 进 `result`（原实现见 git 历史）。
   */
  private sortSystemChips(list: BookGroups[]): BookGroups[] {
    const order: string[] = ['全部', '本地', '书单', '分组', '未分组']
    const systems: BookGroups[] = []
    for (const name of order) {
      // ── 2026-10-19 需求第 1/5 条：「书单」入口屏蔽 ──────────────────────────
      // 用户原话：「删除书单分组」「删除所有书单入口…只针对入口，具体功能暂时不引用了，屏蔽入口。」
      // ⇒ 与「本地」同一手法：只在**渲染层**跳过，`book_groups` 那一行数据、`works_lists`
      //   表、`WorksBookLists` 组件、`worksListsDao` 全部保留，随时可恢复。
      // 回退：删掉下面这行 continue 即恢复入口。
      if (name === '书单') {
        continue
      }
      // ── 2026-10-19 需求第 4 条：「本地」入口屏蔽 ──────────────────────────
      // 用户原话：「以前我们是有书源功能的，现在只有本地，所以这个功能意义就不大了，
      //   我们可以直接把入口屏蔽掉也行。筛选能力作为保留完全可以。」
      // ⇒ 只在**渲染层**跳过它；`BooksDao.buildWhereClause` 对 `bookGroup = 4` 的
      //   `bookGroup = 4 or isLocalBook = true` 筛选逻辑**原样保留**，
      //   将来做筛选器/恢复入口时可一键复用（不改数据库、不删行）。
      // 回退：删掉下面这个 continue 即恢复入口。
      if (name === '本地') {
        continue
      }
      // ── 2026-10-20：删除「未分组」chip ─────────────────────────────────────
      // 用户原话：「其实未分组也可以删除，因为在分组中有未分组的置顶目录」。
      // ⇒ 只删**顶栏入口**；`bookGroup = 3`（未分组）的筛选口径与
      //   `BookFolder` 里那张置顶的「未分组」卡片**都不动**，随时可恢复。
      if (name === '未分组') {
        continue
      }
      const hit = list.find((g: BookGroups) => g.isSystem && g.groupName === name)
      if (hit !== undefined) {
        systems.push(hit)
      }
    }
    // ── 2026-10-20：自定义分组**不再拼进顶栏** ─────────────────────────────────
    // 用户原话：「所有的自定义分组创建后都不会在未分组后面进行显示了，只展示在分组里面」。
    // ⇒ 这里只返回 systems（最近 / 全部 / 分组），customs 一律丢弃。
    //   （`customs` 的过滤逻辑仍保留在上面注释里作参考，实际不再参与结果。）
    return systems
  }

  /** 五个系统基础单元识别（锁定改名/删除/长按编辑，见各入口守卫） */
  private isLockedUnit(item: BookGroups): boolean {
    return item.isSystem && ['全部', '本地', '书单', '分组', '未分组'].includes(item.groupName ?? '')
  }

  /**
   * 打开「分组管理」面板（`@CustomDialog`）。
   *
   * ⚠️ 2026-10-20：由 `private` 改为 **public** —— 三横（≡）按钮已移到 `IndexShelf` 的
   *   右侧动作区（用户要求「搜索之后是三横…三横之后是更多」），入口不再在本组件内。
   *   调用方式：`IndexShelf` 通过 `@BuilderParam` 传进来的 builder 无法直接拿到子组件实例，
   *   所以改用**回调注入**：`IndexShelf` 把 `openSortPanel` 这类动作作为参数传进来
   *   （见 `BookBodyContent` 的 `onOpenSortPanel`）。本方法仍保留，供分组行内部复用。
   */
  openGroupPanel(): void {
    this.groupCoverShow = true
    this.groupPanelDialog = new CustomDialogController({
      builder: GroupManageDialog({
        showGroupList: this.groupList,
        currentIndex: this.currentIndex,
        onClose: (): void => {
          this.closeGroupPanel()
        }
      }),
      autoCancel: true,
      // 2026-09-25 用户改版：不再顶到分组行下面（旧"整宽下拉面板"观感 —— 左右顶满屏幕、
      // 只有下两角圆），改成与全工程统一的**标准居中弹窗**：四圆角 20 + 90% 宽
      // （用户原话：「不是四圆角，左右太宽，顶屏幕了，宽度百分之90就行」）。
      alignment: DialogAlignment.Center,
      width: '90%',
      // 只有 `customStyle: false` 时弹窗层才有背景 ⇒ 材质才有处可附。
      // SDK `custom_dialog_controller.d.ts:130-134` 原文：`customStyle: true` 时
      // 「the rounded corner radius is 0, and **the background color is transparent**」
      // ⇒ 材质无处附着（本工程 2026-09-22 真机踩过：弹窗整个变透明）。
      customStyle: false,
      cornerRadius: 20,
      // 真沉浸光感材质（官方「开启沉浸光感」把 CustomDialog 列在弹窗类里）
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      // ── 展开动画（用户点名「其次没有展开动画」）────────────────────────────
      // SDK `custom_dialog_controller.d.ts:205/226`：`openAnimation?` / `closeAnimation?: AnimateParam`
      // ⚠️ 官方 NOTE（同文件 `:37-38`）原文：「During animation playback, the page **does not
      //   respond to touch, swipe, or click interactions**」⇒ 弹窗动效要短 ⇒ 用 `SPRING_FAST`。
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        // 点遮罩 / 返回手势关掉：同步标志位（本行不依赖它渲染，只作状态镜像）
        this.groupCoverShow = false
      },
    })
    this.groupPanelDialog.open()
  }

  /**
   * 顶栏 chip 的文字色（2026-10-20 二修）。
   *
   * 为什么不用 `$r('sys.color.font_primary')`：那是系统蓝黑色，
   * `SegmentButton` 的默认值就是它 —— 真机上表现为"黑字 + 蓝色选中块"，
   * 与我们的主题渐变完全不搭（用户截图反馈"效果很差"的直接原因之一）。
   * ⇒ 选中态用**主题主色**（与改造前 `BookType` 的选中态一致），
   *   未选中态用次级黑/白（保证在橙底上可读）。
   */
  private chipFontColor(selected: boolean): ResourceColor {
    if (selected) {
      return this.theme.mainColor
    }
    return NightMode.isDarkSurface()
      ? 'rgba(248, 249, 250, 0.72)'
      : 'rgba(0, 0, 0, 0.62)'
  }

  /**
   * 内容区滑动请求切档（2026-10-21）。
   *
   * `chipStep` 是「+1 / -1」的**请求值**（不是累计计数）——
   * `BookBodyContent` 每次滑动都写同一个 ±1，所以这里用 `@Watch` 触发即可。
   * ⚠️ 不能把 `chipStep` 当计数器自增：`@Watch` 只在**值变化**时触发，
   *   连续两次左滑都是 +1 ⇒ 第二次不会触发。修法：每次处理完把值**复位成 0**，
   *   这样下一次 ±1 又构成"值变化"。
   */
  onChipStep(): void {
    const step: number = this.chipStep
    if (step === 0) {
      return
    }
    // 先复位，保证下一次同样方向的滑动也能触发（见上面注释）
    this.chipStep = 0
    const next: number = this.chipSel + step
    const max: number = this.chipLabels().length - 1
    if (next < 0 || next > max) {
      return
    }
    this.onChipClicked(next)
  }

  /**
   * 排列变化时的处理（2026-10-21 新增）。
   *
   * 只做一件事：**重算显示下标**。
   * 因为 `chipSel` 是"选中项在 `SegmentButton` 里的位置"，
   * 而位置由排列决定 ⇒ 排列一改，同一个选中项就换了位置。
   * 不重算的话，用户改完排序回到书架会看到"高亮跳到了别的格子上"。
   */
  onChipOrderChanged(): void {
    this.chipSel = this.chipSelectedIndex()
  }

  /**
   * 处理「跳到指定 chip」请求（2026-10-21）。
   * 与 `onChipStep` 同一套复位策略：处理完置回 -1，下一次写同样的值也能触发。
   *
   * ⚠️ 2026-10-21：**入参改语义** —— `BookContentRefresh` 的「返回分组列表」按钮
   *   传的是**语义下标** 2（=分组），不是显示位置。因为用户可在设置页任意排列，
   *   「分组」可能在任意一格 ⇒ 必须先换算成显示下标再走 `onChipClicked`。
   */
  onChipGoto(): void {
    const semantic: number = this.chipGoto
    if (semantic < 0) {
      return
    }
    this.chipGoto = -1
    if (semantic > 2) {
      return
    }
    this.onChipClicked(this.chipDisplayIndexOf(semantic))
  }
  /**
   * 当前所在**真实分组**的名字（2026-10-21 新增，同日二修）。
   *
   * 供「返回分组列表」悬浮按钮显示"我在哪个分组"（如 `< 开心  返回分组列表`）。
   *
   * ── 二修：必须排除系统单元 ────────────────────────────────────────────────
   * 用户反馈：「在全部里面，也有这个显示，这不需要，只在进入分组列表下面的**子分组**中
   *   才有显示，而且显示的文字，< 后面应该是打开的子分组名称，比如 `< 开心 返回分组列表`。」
   * 根因：`groupList` 里同时含系统单元（全部/分组）和真实分组（未分组/开心/快乐…），
   *   旧实现只按 groupId 反查 ⇒ 停在「全部」时也能查到名字「全部」⇒ 按钮误显示。
   * ⇒ 现在**额外排除系统单元**（`isSystem === true`）：只有用户自建的子分组才返回名字。
   *   这样「全部」「分组」都不显示按钮，「未分组」「开心」「快乐」才显示。
   *
   * ⚠️ 「未分组」在库里是 `isSystem = true`（见 `BookGroupsDao.initGroupData`），
   *   但它**确实是"装书的子分组"**（分组页里那张置顶卡片），用户点进去也该能返回
   *   ⇒ 单独放行它（白名单 `ALLOW_SYSTEM_AS_SUBGROUP`）。
   */
  private currentGroupName(): string {
    if (this.onRecentChip || this.chipHighlightId === RECENT_CHIP_ID) {
      return ''
    }
    const hit = this.groupList.find((g: BookGroups) => g.groupId === this.chipHighlightId)
    if (hit === undefined) {
      return ''
    }
    const name: string = hit.groupName ?? ''
    // 系统单元里只有「未分组」算"可进入的子分组"（分组页里有它的置顶卡片）
    if (hit.isSystem && name !== '未分组') {
      return ''
    }
    return name
  }

  /** 关面板（面板里的 ✕ 按钮走这里） */
  private closeGroupPanel(): void {
    this.groupCoverShow = false
    this.groupPanelDialog?.close()
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SegmentButton 的「文案 / 选中下标 / 点击」三件套（2026-10-20 新增）
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 顶栏三个 chip 的文案，**按用户配置的排列返回**（2026-10-21 新增）。
   *
   * 用户原话：「首页三段按钮排序…调整三个按钮的排序…六种组合…
   *   并且用户应用后，这个开关下面会显示当前的排列。」
   *
   * ── 关键：语义下标 ≠ 显示下标 ──────────────────────────────────────────────
   * · **语义下标**（`CHIP_NAMES` 的索引）：0=最近 / 1=全部 / 2=分组 —— 恒定不变，
   *   `onChipClicked()`、`chipSelectedIndex()` 全部按它工作。
   * · **显示下标**：用户在设置页排出来的顺序，只影响渲染位置。
   * ⇒ 本方法把语义顺序按 `ShelfPrefs.getChipOrder()` 重排后返回；
   *   点击时再用 `chipSemanticIndexAt(显示下标)` 反查回语义下标。
   *
   * ⚠️ 只含**系统单元**：用户已定「所有的自定义分组创建后都不会在未分组后面进行显示了，
   *   只展示在分组里面」⇒ 自定义分组不参与本数组。
   */
  private chipLabels(): string[] {
    const order: number[] = ShelfPrefs.getChipOrder()
    const out: string[] = []
    for (const semantic of order) {
      out.push(CHIP_NAMES[semantic])
    }
    return out
  }

  /**
   * 显示下标 → 语义下标（2026-10-21 新增）。
   *
   * `SegmentButton` 回传的是**显示位置**；而所有业务逻辑都按语义下标工作
   * （0=最近 / 1=全部 / 2=分组）⇒ 必须在这里换算。
   * 例：用户排成「分组·最近·全部」，则点第 0 格 → 语义 2（分组）。
   */
  private chipSemanticIndexAt(displayIndex: number): number {
    const order: number[] = ShelfPrefs.getChipOrder()
    if (displayIndex < 0 || displayIndex >= order.length) {
      return -1
    }
    return order[displayIndex]
  }

  /**
   * 语义下标 → 显示下标（2026-10-21 新增）。
   * 用于把"当前选中哪一格"换算成 `SegmentButton` 认的显示位置。
   */
  private chipDisplayIndexOf(semanticIndex: number): number {
    const order: number[] = ShelfPrefs.getChipOrder()
    const i: number = order.indexOf(semanticIndex)
    return i >= 0 ? i : 0
  }

  /**
   * 当前选中项在 `SegmentButton` 里的**显示下标**（2026-10-21 改写）。
   *
   * 映射规则：
   *   · `onRecentChip === true` 或 `chipHighlightId === RECENT_CHIP_ID` ⇒ 语义 0（最近）
   *   · 否则按 groupList 里「全部」「分组」的 groupId 匹配 ⇒ 语义 1 / 2
   *   · 都对不上（例如停在某个自定义分组）⇒ 兜底语义 0
   * 得到**语义下标**后再用 `chipDisplayIndexOf()` 换算成显示位置
   * （因为用户可在设置页任意排列，语义 ≠ 显示）。
   */
  private chipSelectedIndex(): number {
    if (this.onRecentChip || this.chipHighlightId === RECENT_CHIP_ID) {
      return this.chipDisplayIndexOf(0)
    }
    // 语义 1 = 全部 / 语义 2 = 分组
    for (let semantic = 1; semantic <= 2; semantic++) {
      const name: string = CHIP_NAMES[semantic]
      const hit = this.groupList.find((g: BookGroups) =>
        g.isSystem && g.groupName === name)
      if (hit !== undefined && hit.groupId === this.chipHighlightId) {
        return this.chipDisplayIndexOf(semantic)
      }
    }
    return this.chipDisplayIndexOf(0)
  }

  /**
   * 点了第 `index` 个 chip（`index` 是**显示位置**，2026-10-21 起可变）。
   *
   * ⚠️ 关键：入参是 `SegmentButton` 的显示下标，必须先换算成**语义下标**
   *   （0=最近 / 1=全部 / 2=分组）再分发，否则用户一改排列就点错功能。
   *
   * 语义与改造前**逐条对齐**：
   *   0 最近 ⇒ `onRecentChip = true` + 高亮基准置哨兵 + 持久化 undefined
   *   1 全部 ⇒ 退出最近 + `bookTypeNumber = 全部.groupId` + 持久化
   *   2 分组 ⇒ 退出最近 + `GROUP='文件夹'` + `bookTypeNumber = 分组.groupId` + 持久化
   */
  private onChipClicked(displayIndex: number): void {
    const semantic: number = this.chipSemanticIndexAt(displayIndex)
    if (semantic < 0) {
      return
    }
    if (semantic === 0) {
      // 2026-10-20：`chipSel` 必须**无条件**更新 —— 早先这里 `if (this.onRecentChip) return`
      // 会跳过赋值，导致"已经是最近时再点最近"不刷新（虽无视觉变化，但保持状态一致）
      this.onRecentChip = true
      this.chipHighlightId = RECENT_CHIP_ID
      this.chipSel = this.chipDisplayIndexOf(0)
      // ★ 2026-10-21：清空分组名 —— 「最近」不是子分组，不应显示「返回分组列表」按钮
      AppStorage.setOrCreate<string>('SHELF_CURRENT_GROUP_NAME', '')
      ShelfPrefs.setCurrentChipId(undefined)
      return
    }
    // 真实系统单元（全部 / 分组）
    const name: string = CHIP_NAMES[semantic]
    const hit = this.groupList.find((g: BookGroups) => g.isSystem && g.groupName === name)
    if (hit === undefined || hit.groupId === undefined) {
      return
    }
    this.onRecentChip = false
    this.GROUP = (name === '分组') ? '文件夹' : '标签'
    this.bookTypeNumber = hit.groupId
    this.chipHighlightId = hit.groupId
    // ★ 2026-10-20：同步分段控件下标（缺这句 = "功能生效但按钮不动"）
    // ★ 2026-10-21：用 `chipDisplayIndexOf` 换算成**显示位置**
    this.chipSel = this.chipDisplayIndexOf(semantic)
    // 上报当前分组名（2026-10-21：供「返回分组列表」按钮显示）
    AppStorage.setOrCreate<string>('SHELF_CURRENT_GROUP_NAME', this.currentGroupName())
    ShelfPrefs.setCurrentChipId(hit.groupId)
  }

  /**
   * 分组行尾部"三横"图标颜色。
   *
   * ⚠️ 2026-10-22：本方法**当前没有任何调用点**（三横按钮已搬到 `IndexShelf` 右侧动作区，
   *   见 `IndexShelf.ShelfTopActions()`），属遗留死代码，保留只为"想恢复时不用重写"。
   *
   * ⚠️ 它与 `IndexShelf.trailingIconColor()` **已不再同款**：那一处 2026-10-22 按用户要求
   *   改成了**中性色**（`ShelfColors.icon()`，日间黑/夜间白），因为"跟随主题色"在玻璃胶囊上
   *   实测只有 1.30~1.54:1（远低于图标门槛 3:1，用户反馈"顺色、看不清"）。
   *   若将来把三横搬回本组件，**请直接用 `ShelfColors.icon()`**，不要用本方法。
   */
  private groupIconColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : this.theme.mainColor
  }

  build() {
    // ── 2026-09-23 结构简化（用户：「点击展开分组管理…首先这个模块没有沉浸光感材质，
    //    也就是 CustomDialog，其次没有展开动画」）────────────────────────────────
    // 原来这里是 `if (this.groupCoverShow) { Stack{ 面板 + 手画 Rect 遮罩 } } else { 本行 }`：
    //   · 遮罩是手画的 `Rect().fill('rgba(0, 0, 0, 0.45)')`，材质一点没有（面板根节点写死白底）；
    //   · 展开是纯 `if`，**没有任何 `.transition()`** ⇒ 硬切。
    // ⇒ 现在展开的面板搬进 `@CustomDialog`（`GroupManageDialog`），三样一块到位：
    //   真材质（弹窗 options 的 `systemMaterial`）+ 默认遮罩（`0x33000000`）+ 弹簧展开动画。
    //   本行**始终渲染**（不再被面板顶掉），`groupCoverShow` 退化为"面板是否打开"的镜像标志。
    Flex(
      {
        alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.SpaceBetween
      }
    ) {
      // ══ 2026-10-20：chip 行整体换成官方 **SegmentButton（胶囊类）** ══════════
      // 用户原话：「顶部这三个，最近，全部，分组，可不可以换个组件？…我发现了一个组件，
      //   很好…这个也是沉浸光感的，和我们的dock很像，你去找找呗，官方应该有实例。」
      // ⇒ 组件 = `SegmentButton`（封装在 `componets/common/GlassSegment.ets`），
      //   材质 = `ImmersiveMaterialUtil.segmentMaterial()`（真沉浸光感）。
      //
      // ── 为什么不再用 ForEach + BookType ──────────────────────────────────────
      // `SegmentButton` 自己管"选中项胶囊 + 跟手拖拽动效 + 等分宽度"，比我们手画的
      // `BookType`（每个 chip 各自 `.backgroundColor`）更接近系统观感，且支持光感。
      // ⚠️ 代价：**不支持横向滚动、宽度等分**（官方：「不支持通用属性…根据按钮个数
      //   平均分配每个按钮宽度」）。当前只有 3 项（最近/全部/分组），用户已确认可接受。
      //
      // ── 选中态怎么映射（关键）───────────────────────────────────────────────
      // 旧实现用 `chipHighlightId`（哨兵 -9999 = 最近 / 真实 groupId）判亮。
      // `SegmentButton` 只认**下标**，所以这里换算：
      //   · `chipItems` 的顺序 = [最近, 全部, 分组]（系统单元，自定义分组已不进顶栏）；
      //   · `chipSelectedIndex()` 把 `chipHighlightId` 反查成下标。
      GlassSegment({
        labels: this.chipLabels(),
        // ★ 2026-10-20：传 **@State 变量** `chipSel`，不再传方法调用 `this.chipSelectedIndex()`
        //   （方法返回值框架追踪不到 ⇒ 按钮永远停在初值，与主题页 `modeSel` 同一个坑）
        selected: this.chipSel,
        // 文字色必须显式给主题色：`SegmentButton` 默认用 `sys.color.font_primary`（系统蓝黑），
        // 压在主题渐变彩带上既不像截图也压不住底色（2026-10-20 二修，见 GlassSegment 头注释）。
        fontColor: this.chipFontColor(false),
        selectedFontColor: this.chipFontColor(true),
        onChange: (index: number): void => {
          this.onChipClicked(index)
        }
      })
      .layoutWeight(1)
      // ★ 2026-10-21：**去掉左右内边距**（原来是 `left:15, right:8`）。
      //   用户反馈：「三段开关距离左屏幕远，但是三图标又距离右屏幕近…建议整体往左一点，
      //   两边距离一样」。
      //   根因：外层 `BookBodyContent` 已有 `.padding({left:15, right:15})`，
      //   这里再叠加 `left:15` ⇒ 左侧实际间距 **30vp**，而右侧只有外层 15vp ⇒ 明显不对称。
      //   ⇒ 本层不再加任何水平内边距，左右都只由外层 15vp 决定 ⇒ 两边严格相等。
      //   （`right:8` 那个"给三横图标让位"的旧用意已不存在：三横已搬到外层右侧动作区。）
      // ══ 高度上报（保留）══════════════════════════════════════════════════════
      // 旧实现把这一串挂在"胶囊 Column"上，换成 `SegmentButton` 后材质由组件自己管，
      // 但**实测高度上报必须保留** —— `BookContentRefresh` 靠 `shelfGroupRowH` 给列表让位，
      // 删了会导致第一行书被顶栏压住（2026-09-23 真机踩过）。
      .onAreaChange((_o: Area, n: Area) => {
        AppStorage.setOrCreate('shelfGroupRowH', Number(n.height))
        // 把本行的**窗口坐标底边**也上报 —— 三横弹窗要停在它下面。
        //   `Area.globalPosition` 依据（SDK `component/units.d.ts:2110-2119`）原文：
        //     「Position of the top-left corner of the target element in the **current window
        //       coordinate system**.」（单位 vp）
        AppStorage.setOrCreate('shelfGroupRowBottom', Number(n.globalPosition.y) + Number(n.height))
      })
    }
  }
}
