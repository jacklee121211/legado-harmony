import { ThemeStorageKey } from '../../common/constants/Theme'
import { Haptics } from '../../common/utils/Haptics';
import { ThemeItem } from '../../common/model/Theme'
import bookGroupUtil from '../../common/utils/bookGroupUtils'
import BookGroupsDao from '../../database/dao/BookGroupsDao'
import { BookGroups } from '../../database/entities/BookGroups'
import FolderInfoDialog from '../../pages/view/bookShelf/components/dialog/FolderInfoDialog'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil'
import { NightMode } from '../../common/utils/NightMode'
import ShelfPrefs, { SortDir, SortKey } from '../../common/utils/ShelfPrefs'

/** 排序区块的一行（档位 + 显示名） */
interface SortOptionVo {
  key: SortKey
  label: string
}

/**
 * 五个系统基础单元（2026-10-01 用户定义，**位置锁定、顺序恒定**）：
 *   全部 → 本地 → 书单 → 分组 → 未分组
 * 2026-10-13 起本常量只用于**判定**（哪些 chip 点击无反馈 / 不画眼睛 / 不许隐藏），
 * 不改变渲染顺序 —— 顺序仍与父级 `GroupType.sortSystemChips` 一致（五要素在前）。
 */
const BASE_UNIT_NAMES: string[] = ['全部', '本地', '书单', '分组', '未分组']

/**
 * 需要在**渲染层屏蔽**的系统单元（2026-10-19 需求第 1/4/5 条）。
 *
 * · 「本地」——用户原话：「以前我们是有书源功能的，现在只有本地，所以这个功能意义
 *   就不大了，我们可以直接把入口屏蔽掉也行。筛选能力作为保留完全可以。」
 * · 「书单」——用户原话：「删除书单分组」「删除所有书单入口…只针对入口，
 *   具体功能暂时不引用了，屏蔽入口。」
 *
 * ⚠️ 只在渲染层跳过；底层数据（`book_groups` 行、`works_lists` 表）、
 *   `WorksBookLists` 组件、`worksListsDao`、以及 `BooksDao.buildWhereClause` 对
 *   `bookGroup = 4`（本地）的筛选能力**全部原样保留**。
 * 回退：把本数组清空（`= []`）即恢复这两个入口。
 */
const HIDDEN_UNIT_NAMES: string[] = ['本地', '书单']

/**
 * 书架 → 分组行尾部「三横」→ 本面板（`GroupManageDialog` 的内容层）。
 *
 * ══ 2026-10-13 用户改版（本次，只动弹窗，**书架那一行原封不动**）══════════════════
 * 用户原话：
 *  「点击更多按钮出现的弹窗中所有分组点击不再出现半屏弹窗，默认五要素点击之后不需要有
 *    任何反馈，所有自定义分组点击后，直接进入隐藏分组，隐藏分组点击后恢复正常分组。
 *    右上角管理按钮直接取消。」
 *  「所有自定义分组右上角的X改成symbol的eye，睁眼表示未隐藏，闭眼表示隐藏，也就是和防窥
 *    的图标一样。」
 *  「简单来说，这个管理页面，只负责一个功能，就是进行自定义分组的隐藏和释放，因为半屏
 *    弹窗我们实际上用不上。」
 *
 * ⇒ 结构（两栏）**保持原样**：显示分组 / 隐藏分组。删掉的东西与理由：
 *   ① **半屏弹窗**：点击 chip 不再"进入分组"（`bindSheet` + `BookManageDialog` 整块删除，
 *      连带 `clickGroup` / `isShowBookFolderInfoDialog` / `bookFolderInfoDialog()`）；
 *   ② **「管理 / 完成」开关**：用户「右上角管理按钮直接取消」。它同时是拖拽排序的开关，
 *      而拖拽落点 `changeIndex()` 一直是 TODO（只打日志、不写库）⇒ 一并删除，不留假功能；
 *   ③ **隐藏/恢复前的二次确认框**（`hideDialogExample`）：用户要「点击后**直接**进入隐藏
 *      分组」⇒ 点击即生效，中间不再夹"确定隐藏吗"。
 *
 * ── X → eye（符号已核实，不是猜的）────────────────────────────────────────
 * 用户要求「和防窥的图标一样」⇒ 沿用阅读页防窥那一对（`ReaderPage3.ets:1817`）：
 *   · `sys.symbol.eye`       = 睁眼 = **未隐藏**（在「显示分组」栏）
 *   · `sys.symbol.eye_slash` = 闭眼 = **已隐藏**（在「隐藏分组」栏）
 * 符号存在性证据（SDK 真源 `sysResource.js`，非打包快照）：
 *   `sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js`
 *     `eye: 125832271,`
 *     `eye_slash: 125832272,`
 *
 * ── 点击行为矩阵 ────────────────────────────────────────────────────────
 * | 位置              | 点击                     | 长按            |
 * | 显示分组·五要素   | **完全无反馈**（不挂 onClick） | 无            |
 * | 显示分组·自定义   | 隐藏（移入隐藏分组）      | 无              |
 * | 隐藏分组          | 恢复（移回显示分组）      | 编辑（FolderInfoDialog）|
 */
@Component
export default struct groupTypePanel {
  /**
   * ⚠️ 2026-09-23：原来这里是 `@Link groupCoverShow: boolean`（面板直接把它置 false 来关自己）。
   * 现在本面板是 `@CustomDialog` 的**内容**（见 `GroupManageDialog.ets`），关窗必须走
   * `controller.close()`，所以改成**回调**，由调用方去关。
   */
  onClose: () => void = (): void => {}
  /**
   * 底色兜底 + 材质分支让位（工程既有实现，说明见 `ImmersiveMaterialUtil.ets:390-459`）。
   * · 材质可用 ⇒ 本方法**什么都不做**，背景由弹窗层（`systemMaterial`）画；
   * · 材质不可用 / 总开关关闭 ⇒ 落回 **白色实底**，绝不会"透明露底"。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  /** 右上角 ✕ 的 Q弹缩放（规范第 1 节三件套：SymbolGlyph + Haptics + runJellyClick） */
  @State closeScale: number = 1
  /** 打开瞬间的快照（父级最近一次查询结果，已按"五要素在前"排过序）——只为让首帧成型 */
  @Prop showGroupList: BookGroups[] = []
  @Prop currentIndex: number = 0
  /**
   * 面板自持的全量分组（2026-10-13 新增）。
   * 为什么不能只用 `@Prop showGroupList`：@Prop 是**创建瞬间快照**，点一下隐藏之后它不会变
   * ⇒ 分组会"点了没反应、要关掉弹窗再开"（规范 4.4 表格同款坑）。
   */
  @State allGroups: BookGroups[] = []
  /** 长按编辑的分组（走 `FolderInfoDialog`） */
  @State dialogGroupData: BookGroups = new BookGroups()
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：只为触发重绘（取色走下面的 `fgMain/fgSub/chipBg`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /** 分组变更广播键（规范第 5 节：改完必须广播，书架分组行 `GroupType` 在听） */
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0

  // ══════════════════════════════════════════════════════════════════════════
  // 书籍排序区块（2026-10-19 需求第 6 条）
  // ══════════════════════════════════════════════════════════════════════════
  /** 当前排序档位（本地可观察副本，与 ShelfPrefs 同步） */
  @State curSortKey: SortKey = SortKey.IMPORT_TIME
  /** 当前排序方向 */
  @State curSortDir: SortDir = SortDir.DESC
  /**
   * **进入本面板瞬间**的排序快照 —— 「重置」要回到的目标。
   *
   * 用户原话：「每次进入这个弹窗记录一个当前排序的快照，点击重置按钮恢复到这个快照」。
   * ⇒ 快照在 `aboutToAppear` 取一次；本面板每次打开都是**新实例**
   *   （调用方 `GroupType.openGroupPanel()` 每次 new CustomDialogController，
   *   理由见那里的注释）⇒ 「每次进入」天然等于「每次新实例」。
   *
   * ⚠️ 2026-10-22：初值由 `RECENT_READ` 改为 `IMPORT_TIME`，与
   *   `ShelfPrefs.getSortKey()` 的新默认值对齐（用户：「书籍排序默认是导入时间」）。
   *   这只是**首帧占位**，`aboutToAppear` 会立刻用持久化值覆盖 ⇒ 不会误导用户。
   */
  private snapSortKey: SortKey = SortKey.IMPORT_TIME
  private snapSortDir: SortDir = SortDir.DESC
  /** 排序变更信号：自增后 `BookContent`（书架）会重查并按新顺序渲染 */
  @StorageLink('SHELF_SORT_TICK') shelfSortTick: number = 0
  /**
   * 「最近」chip 状态（2026-10-19）。
   *
   * ⚠️ 这里是**排他**关系，理由与「最近阅读档可双向」并不矛盾：
   *   · 「最近」chip 的排序**写死在查询里**（`BookContent.buildQueryParams` 恒为最近↓），
   *     它根本不读 `ShelfPrefs`；
   *   · 用户在排序面板里选任何档，意图都是"按我选的排" ⇒ 必须切到会读 `ShelfPrefs`
   *     的那组 chip（「全部」等），否则"点了排序却毫无变化"。
   * ⇒ 详见 `applySort()` 的注释。
   */
  @StorageLink('SHELF_RECENT_CHIP') onRecentChip: boolean = true

  // ══════════════════════════════════════════════════════════════════════════
  // 列表 / 宫格（2026-10-20 从顶栏第一行搬进本弹窗）
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * 当前展示形态（`'列表'` / `'宫格'`）。
   *
   * 用 `@StorageLink` 直连 —— 顶栏那个切换按钮已被删除（用户：「喵阅字样取消，
   * 这一行全都取消」），现在**唯一入口就是本弹窗**。书架侧
   * （`IndexShelf.EXHIBIT`）也是 `@State` 初值读 `ShelfPrefs.isGrid()`，
   * 但两边不是父子关系（本弹窗挂在分组管理里）⇒ 必须靠 AppStorage 广播。
   */
  @StorageLink('SHELF_EXHIBIT_GRID') isGridMode: boolean = true

  /** 面板里的 5 个排序档（顺序与用户列举一致） */
  private readonly SORT_OPTIONS: SortOptionVo[] = [
    { key: SortKey.PINYIN, label: '首字母' },
    { key: SortKey.IMPORT_TIME, label: '导入时间' },
    { key: SortKey.RECENT_READ, label: '最近阅读' },
    { key: SortKey.FORMAT, label: '格式' },
    { key: SortKey.FILE_SIZE, label: '文件大小' }
  ]

  /** 排序是否已偏离快照（决定「重置」按钮的可用态文案） */
  private sortDirty(): boolean {
    return this.curSortKey !== this.snapSortKey || this.curSortDir !== this.snapSortDir
  }

  // ── 2026-10-19 三修：**取消「最近阅读」的锁定** ─────────────────────────────
  // 上一版这里有一个 `isSortLocked(key)`，把「最近阅读」档锁成"只能降序、不能翻转"，
  // 并在行尾显示「固定↓」。**那是概念混淆，用户已指出**：
  //
  //   用户原话：「在书籍排序中这个最近阅读是作用于**最近以外**的其他分组，
  //     和其他的排序是一样的，你是不是搞混了。」
  //
  // 两个概念必须分清：
  //   ① 「最近」**chip**（分组行里那个）——它才是"锁死最近↓"的：
  //      `BookContent.buildQueryParams()` 在 `onRecentChip === true` 时**写死**
  //      `sortKey: RECENT_READ, sortDir: DESC`，根本不读 `ShelfPrefs`。
  //   ② 排序**面板**里的「最近阅读」**档** —— 它和首字母/导入时间/格式/文件大小完全同级，
  //      只作用于「最近」以外的那组 chip（用户切到哪个分组就按这个档排）。
  //      ⇒ **必须和其它档一样支持 ↑/↓ 双向翻转**，不需要也不能锁。
  // ⇒ 本文件不再有任何锁定逻辑；锁定只存在于 ① 的查询口径里（那才是它的家）。

  /**
   * 点某个排序档：同档 ⇒ 翻转方向；换档 ⇒ 切过去并取默认降序。
   * ⚠️ 全程**不关弹窗**（用户明确要求，否则重置逻辑不成立）。
   */
  private selectSort(key: SortKey): void {
    Haptics.tap()
    if (this.curSortKey === key) {
      // 同档 ⇒ 翻转（含「最近阅读」档，与其它档一致）
      this.curSortDir = this.curSortDir === SortDir.DESC ? SortDir.ASC : SortDir.DESC
    } else {
      // 换档 ⇒ 默认降序
      this.curSortKey = key
      this.curSortDir = SortDir.DESC
    }
    this.applySort()
  }

  /** 重置 = 回到**进入本面板时**的快照 */
  private resetSort(): void {
    Haptics.tap()
    this.curSortKey = this.snapSortKey
    this.curSortDir = this.snapSortDir
    this.applySort()
  }

  /**
   * 把当前排序落到三处（顺序很重要）：
   *   ① `ShelfPrefs` 持久化（下次启动仍在）；
   *   ② 退出「最近」chip —— 见下方说明；
   *   ③ 递增 `SHELF_SORT_TICK` 让书架重查。
   * ⚠️ **不关弹窗**（用户明确要求），这样「重置」才有意义。
   */
  private applySort(): void {
    ShelfPrefs.setSort(this.curSortKey, this.curSortDir)
    // ── ② 退出「最近」chip（2026-10-19，三修时复核过仍然成立）────────────────
    // 用户口径：「最近只有一种排序就是最近↓，然后其他的标签包括后续用户自定义的
    //   标签分组都会随着排序进行排序」。
    // ⇒ 「最近」chip 的排序是**写死在查询里**的（`BookContent.buildQueryParams`），
    //   不读 `ShelfPrefs`；用户一旦在排序面板里选了任何档，意图显然是
    //   "按我选的这个排" ⇒ 必须切到会读 `ShelfPrefs` 的那组 chip（「全部」），
    //   否则"点了排序但看不见任何变化"（因为还停在锁死的「最近」上）。
    this.onRecentChip = false
    this.shelfSortTick++
  }

  /** 某档的箭头：当前档按真实方向，非当前档给中性 ↑ */
  private sortArrow(option: SortOptionVo): Resource {
    if (this.curSortKey !== option.key) {
      return $r('sys.symbol.arrow_up')
    }
    return this.curSortDir === SortDir.ASC ? $r('sys.symbol.arrow_up') : $r('sys.symbol.arrow_down')
  }


  /**
   * 主文字色 / 次级文字色 / 淡色块底 —— 夜间必须自己翻，否则是**黑字压深底**。
   *
   * 为什么不能靠 `$r('app.string.color_black_*')` 的 dark 限定词：本面板这两处用的是
   * **字面量** `rgba(0,0,0,…)`（不是资源），限定词目录管不到。
   * 本面板唯一的宿主是 `GroupManageDialog`（书架 → 分组管理）⇒ 恒属"书架深色档"，
   * 直接读全局夜间开关是安全的。
   */
  private fgMain(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)';
  }

  private fgSub(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.45)' : 'rgba(0, 0, 0, 0.45)';
  }

  private chipBg(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.10)' : 'rgba(0, 0, 0, 0.04)';
  }

  aboutToAppear(): void {
    // ① 先用父级快照成型（避免"打开瞬间列表是空的，过一会儿才刷出来"——工程老问题）
    this.allGroups = this.showGroupList.slice()
    // ② 再以库为准重查（父级快照可能是几分钟前的）
    this.reload()
    // ③ 排序：取当前值，并把它记为**本次进入的快照**（重置目标）
    this.curSortKey = ShelfPrefs.getSortKey()
    this.curSortDir = ShelfPrefs.getSortDir()
    this.snapSortKey = this.curSortKey
    this.snapSortDir = this.curSortDir
  }

  /**
   * 重查本大类的全部分组（含隐藏），写入 `allGroups`。
   * 排序用 `sortChips()`，与父级 `GroupType.sortSystemChips()` **同一条规则**
   * （五要素在前、其余按库里的相对顺序），保证本面板与书架那一行的 chip 顺序一致。
   */
  private reload(): void {
    BookGroupsDao.search({
      type: this.currentIndex
    }).then((val: BookGroups[]) => {
      this.allGroups = this.sortChips(val)
    })
  }

  private sortChips(list: BookGroups[]): BookGroups[] {
    const systems: BookGroups[] = []
    for (const name of BASE_UNIT_NAMES) {
      const hit = list.find((g: BookGroups) => g.isSystem && g.groupName === name)
      if (hit !== undefined) {
        systems.push(hit)
      }
    }
    const result: BookGroups[] = []
    for (const g of systems) {
      result.push(g)
    }
    for (const g of list) {
      // 与 `GroupType.sortSystemChips` 同一口径：被屏蔽的单元也不能落到自定义段，
      // 否则「屏蔽」只在排序数组里生效、渲染时又冒出来。
      if (!systems.includes(g) && !(g.isSystem && HIDDEN_UNIT_NAMES.includes(g.groupName))) {
        result.push(g)
      }
    }
    return result
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ⚠️ 2026-10-20「终极简化」：以下 5 个方法**当前没有调用点**（刻意保留）
  // ══════════════════════════════════════════════════════════════════════════
  // 用户要求：「三横里面的显示分组和隐藏分组也不在需要了，只剩下排序了」，
  //   并在被问到「隐藏自定义分组能力怎么办」时明确选择「连功能一起不要」。
  // ⇒ 「显示分组 / 隐藏分组」两栏的 UI 已从 build() 删除，
  //   但**数据能力一行未删**：`toggleShow()`（写 `book_groups.show`）、
  //   `editGroup()`（长按编辑）、以及下面的分组筛选/归类方法都还在。
  // 想恢复隐藏能力：把两栏 ForEach 加回 build()，chip 挂回 `toggleShow` / `editGroup` 即可。
  // （因此 lint 会报 unusedSymbol 警告 —— 这是**预期状态**，不是遗漏。）

  /** 是不是五个系统基础单元（`isSystem` + 名字在白名单里）⇒ 点击无反馈 / 不画眼睛 / 不许隐藏 */
  private isBaseUnit(item: BookGroups): boolean {
    return item.isSystem && BASE_UNIT_NAMES.includes(item.groupName)
  }

  /** 「显示分组」栏 = 所有 `show = true` 的分组（五要素 + 自定义），顺序与原实现一致 */
  private visibleGroups(): BookGroups[] {
    return this.allGroups.filter((g: BookGroups) => g.show)
      .filter((g: BookGroups) => !(g.isSystem && HIDDEN_UNIT_NAMES.includes(g.groupName)))
  }

  /** 「隐藏分组」栏 = 所有 `show = false` 的分组 */
  private hiddenGroups(): BookGroups[] {
    return this.allGroups.filter((g: BookGroups) => !g.show)
  }

  /**
   * 点击分组 = 隐藏 ⇄ 恢复（本面板唯一功能）。
   *
   * 顺序很关键（规范第 5 节第 2 条「广播必须发生在 DB 提交之后」）：
   *   ① 面板内**先**乐观更新 ⇒ 手指抬起就能看到它跳到另一栏（不等异步写库）；
   *   ② `await` 落库 ⇒ 然后才重查 + 广播。
   *   反例（本次一并修掉）：`bookGroupUtil.updateGroupShow` 原实现是 `forEach` 裸调 DAO
   *   （不 await），调用方立刻重查会读到**旧** `show` ⇒ "点了没反应，重开弹窗才对"。
   */
  private toggleShow(item: BookGroups): void {
    const id: number | undefined = item.groupId
    if (id === undefined) {
      return
    }
    Haptics.tap()
    const next: boolean = !item.show
    // ① 乐观更新：改对象 + **换数组引用**（只改对象属性不会触发本次 build）
    item.show = next
    this.allGroups = this.allGroups.slice()
    // ② 落库 → 重查 → 广播
    bookGroupUtil.updateGroupShow(id, next).then(() => {
      this.reload()
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
    })
  }

  /** 长按隐藏分组 → 编辑（改名 / 删除；隐藏中的分组**只有**这里能编辑） */
  private editGroup(item: BookGroups): void {
    Haptics.tap()
    this.dialogGroupData = item
    this.groupInfoDialog?.open()
  }

  groupInfoDialog: CustomDialogController | null = new CustomDialogController({
    builder: FolderInfoDialog({
      itemData: this.dialogGroupData,
      // 真开真关（2026-10-01 用户方案）：子关闭→重查→open，全新实例=全新快照
      reopen: (): void => { this.reopenGroupInfoDialog() },
      // ⚠️ 必须用箭头包一层：旧写法 `cancel: this.exitDialog` 把方法**脱绑**传出去，
      //   回调里 `this` 不再指向本组件（工程内同类坑见规范 4.4 表格）
      cancel: (): void => {
        this.exitDialog()
      }
    }),
    cancel: (): void => {
      this.exitDialog()
    },
    autoCancel: true,
    // 2026-09-25 用户反馈：长按编辑弹窗与全局统一 —— 居中 + 四圆角 + 标准宽
    // （原 Bottom/100%/customStyle:true 是贴底老款式）。customStyle:false 时弹窗层
    // 才有背景，systemMaterial 才有处附着（工程 2026-09-22 真机结论）。
    width: '80%',
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 20,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),

  })

  //退出弹框
  exitDialog(): void {
    this.groupInfoDialog?.close()
    // 改名 / 删除 / 改隐藏态都会影响两栏归属 ⇒ 关子弹窗后重查
    this.dialogGroupData = new BookGroups()
    this.reload()
    this.BOOK_IS_BOOK_GROUPS_REFRESHING++
  }

  /** 真开真关（2026-10-01 用户方案）：重查该分组 → 更新 dialogGroupData → open。 */
  private async reopenGroupInfoDialog(): Promise<void> {
    const id = this.dialogGroupData.groupId
    if (id !== undefined) {
      const groups: BookGroups[] = await BookGroupsDao.search({ type: this.currentIndex })
      const fresh = groups.find((g: BookGroups) => g.groupId === id)
      if (fresh !== undefined) {
        this.dialogGroupData = fresh
      }
    }
    this.groupInfoDialog?.open()
  }

  build() {
    Column({
      space: 15
    }) {
      // ══════════════════════════════════════════════════════════════════════════
      // ★★ 2026-10-20「终极简化」：本面板**只剩排序 + 列表/宫格** ★★
      // ══════════════════════════════════════════════════════════════════════════
      // 用户原话：「三横里面的显示分组和隐藏分组也不在需要了，只剩下排序了，
      //   把列表/宫格挪进三横的弹窗里面…三横只用来排序了，可以优化一下弹窗」。
      // 并且明确：「三横弹窗只剩排序后，「隐藏自定义分组」这个能力怎么办？」→「连功能一起不要」。
      //
      // ⇒ 删除的东西（都在本文件里，git 历史可查）：
      //   · 「显示分组」标题 + `visibleGroups()` 的 chip 网格（点一下 = 隐藏）
      //   · 「隐藏分组」标题 + `hiddenGroups()` 的 chip 网格（点一下 = 恢复、长按 = 编辑）
      //   · `toggleShow()` 的**调用点**（方法本身保留，`updateGroupShow` 数据能力不删）
      //   · `editGroup()` 的**调用点**（长按编辑入口随之消失）
      //
      // ⇒ 现在的结构（从上到下）：
      //   ① 标题「显示设置」+ ✕
      //   ② 列表 / 宫格 分段（用户：「把列表/宫格挪进三横的弹窗里面」）
      //   ③ 书籍排序 5 档 + 重置（`SortSection`）
      //
      // ⚠️ 分组**永远全部显示**了（`show` 字段仍在库里，但已无 UI 可改）。
      //    想恢复隐藏能力：把 `visibleGroups()` / `hiddenGroups()` 两段 ForEach 加回来，
      //    并给 chip 挂回 `toggleShow` / `editGroup` —— 方法都还在，只是没人调。
      // ══════════════════════════════════════════════════════════════════════════
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.Center
      }) {
        Text('显示设置').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgMain())

        Row({ space: 12 }) {
          // v3.20：关闭 X 换 SymbolGlyph + 主题色——原 `app.media.close` 位图为固定深色，
          // 深色模式下不可观测（用户反馈）。`xmark` 经 SDK 符号表核实存在。
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor([this.theme.mainColor])
            .scale({ x: this.closeScale, y: this.closeScale })
            .clickEffect(UiMotion.CLICK)
            .onClick(() => {
              Haptics.tap();
              runJellyClick((v: number) => {
                this.closeScale = v
              })
              this.onClose()
            })
        }
      }

      // ── 列表 / 宫格（2026-10-20 从顶栏第一行搬进来）──────────────────────────
      this.ExhibitSection()

      // ── 书籍排序（5 档双向 + 重置）──────────────────────────────────────────
      this.SortSection()
    }
    .borderRadius({ bottomLeft: 20, bottomRight: 20 })
    .padding({
      left: 15,
      right: 15,
      top: 12,
      bottom: 20
    })
    .width('100%')
    // ⚠️ 2026-09-23：原来这里是 `.backgroundColor(Color.White)` —— **写死纯白**，
    //   这就是用户说的「这个模块没有沉浸光感材质」的直接原因：
    //   ① 它原本只是 Stack 里的一个自绘 Column，**不在沉浸光感的生效范围内**；
    //   ② 而且写死的背景色会把材质层整个盖住（官方 FAQ「背景色或背景模糊遮挡材质效果」原文：
    //      「沉浸光感的视觉层级位于组件的 backgroundColor、backgroundBlurStyle 等属性**之下**。
    //        如果同时设置了不透明的背景色或背景模糊样式，这些属性会覆盖在材质层之上」）。
    //   ⇒ 现在材质由弹窗层 options 提供（`GroupManageDialog` 的 `systemMaterial`），
    //     本层交给 `MaterialColumnModifier`：材质可用时不设任何背景，不可用时回落白色实底。
    .attributeModifier(this.surface)
  }

  /**
   * 列表 / 宫格分段控件（2026-10-20 从 `BookBodyContent.ExhibitBuilder` 搬来）。
   *
   * 用户原话：「把列表/宫格挪进三横的弹窗里面」。
   * 行为与搬来前**完全一致**：切换后写 `ShelfPrefs.setGrid()` 持久化
   * （需求：「切换做好持久化，而不是每次都重置为列表」），并同步到 AppStorage
   * 让书架立即换形态（**弹窗不关**，与排序同一交互契约）。
   */
  @Builder
  ExhibitSection() {
    Column({ space: 8 }) {
      Text('展示方式').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgMain())
        .width('100%')

      Row({ space: 8 }) {
        this.ExhibitChip('列表', false)
        this.ExhibitChip('宫格', true)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  ExhibitChip(label: string, grid: boolean) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.isGridMode === grid ? 600 : 400)
      .fontColor(this.isGridMode === grid ? this.theme.mainColor : this.fgMain())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(8)
      .backgroundColor(this.isGridMode === grid
        ? (NightMode.isDarkSurface() ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.06)')
        : Color.Transparent)
      .clickEffect(UiMotion.CLICK)
      .onClick(() => {
        Haptics.tap()
        this.isGridMode = grid
        ShelfPrefs.setGrid(grid)
        // 让书架立即换形态（弹窗不关，与排序面板同一契约）
        this.shelfSortTick++
      })
  }

  /**
   * 书籍排序区块（2026-10-19 需求第 6 条）。
   *
   * 行为契约（用户逐条敲定）：
   *   · 5 个档位，每档**双向**：点当前档翻转 ↑/↓；
   *   · 「最近阅读」锁死降序（「最近只有一种排序就是最近↓」）；
   *   · 每次操作都写 `ShelfPrefs`（持久化）+ 递增 `SHELF_SORT_TICK`（底层书架实时重排）；
   *   · **不关弹窗** —— 否则「重置回进入时快照」就没有意义了；
   *   · 「重置」写回 `aboutToAppear` 记下的快照。
   */
  @Builder
  SortSection() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('书籍排序').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgMain())
        Text(this.sortDirty() ? '点击切换方向' : '当前为进入时排序')
          .fontSize(12).fontWeight(400).lineHeight(20).fontColor(this.fgSub())
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Column({ space: 2 }) {
        ForEach(this.SORT_OPTIONS, (option: SortOptionVo) => {
          Row() {
            Text(option.label)
              .fontSize(13)
              .fontWeight(this.curSortKey === option.key ? 600 : 400)
              .fontColor(this.curSortKey === option.key ? this.theme.mainColor : this.fgMain())
              .layoutWeight(1)

            // （2026-10-19 三修）这里原来有条件显示「固定↓」——已删除。
            //  「最近阅读」档与其它四档完全同级、同样支持 ↑/↓ 双向，见 selectSort 上方的注释。
            SymbolGlyph(this.sortArrow(option))
              .fontSize(14)
              .fontColor([this.curSortKey === option.key ? this.theme.mainColor : this.fgSub()])
          }
          .width('100%')
          .height(34)
          .padding({ left: 10, right: 10 })
          .borderRadius(8)
          .backgroundColor(this.curSortKey === option.key
            ? (NightMode.isDarkSurface() ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.06)')
            : Color.Transparent)
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            this.selectSort(option.key)
          })
        }, (option: SortOptionVo): string => 's' + option.key)
      }
      .width('100%')

      Row() {
        Text('重置')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.sortDirty() ? this.theme.mainColor : this.fgSub())
      }
      .width('100%')
      .height(34)
      .justifyContent(FlexAlign.Center)
      .borderRadius(8)
      .backgroundColor(this.chipBg())
      .clickEffect(UiMotion.CLICK)
      .onClick(() => {
        this.resetSort()
      })
    }
    .width('100%')
  }

  // ── 以下两个 chip 绘制与 2026-10-13 之前**完全一致**（只换了右上角图标）──────
  @Builder
  GroupTypeColor(title: string) {
    Column() {
      Row() {
        Text(title)
          .fontWeight(500)
          .fontSize(12)
          .textOverflow({
            overflow: TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(1)
          .fontColor(this.theme.mainColor)
          .textAlign(TextAlign.Center)
      }
      .margin({ right: 16, bottom: 16 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width(68)
      .backgroundColor(this.theme.secondColor)
      .padding({
        left: 16,
        right: 16,
        top: 6,
        bottom: 6
      })
    }
  }

  @Builder
  GroupType(title: string) {
    Column() {
      Row() {
        Text(title)
          .fontWeight(500)
          .fontSize(12)
          .textOverflow({
            overflow: TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(1)
          .fontColor(this.fgMain())
          .textAlign(TextAlign.Center)
      }
      .margin({ right: 16, bottom: 16 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width(68)
      .backgroundColor(this.chipBg())
      .padding({
        left: 16,
        right: 16,
        top: 6,
        bottom: 6
      })
    }
  }
}
