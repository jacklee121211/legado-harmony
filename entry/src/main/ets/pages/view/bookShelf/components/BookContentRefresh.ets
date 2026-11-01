/**
 * @author 2008
 * @datetime 2024/7/23 12:18
 * @className: BookContentRefresh
 */
import { showMessage } from '../../../../componets/common/promptShow'
import RefreshComponent from '../../../../componets/common/RefreshComponent'
import BookFolder from '../BookFolder'
// 2026-10-25：书单功能整体删除（用户口径「书单功能早就没了，能删就删了吧」）
//   ⇒ 原来的 `import WorksBookLists from '../Shelf/WorksBookLists'` 一并移除。
import BookContent from './BookContent'
// 「返回分组列表」悬浮按钮（2026-10-21）：震动 + Q弹 + 玻璃材质
import { Haptics } from '../../../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../../../common/utils/UiMotion'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import { NightMode } from '../../../../common/utils/NightMode'
import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { ThemeItem } from '../../../../common/model/Theme'
// ── 2026-11-01 多级文件夹：左下角常驻「新建分组」按钮（复用现有弹窗与动效）──────────
import addBookTypeDialog, { AddGroupChannel } from '../../../../componets/common/addBookTypeDialog'
import { BookGroups } from '../../../../database/entities/BookGroups'
import BookGroupsDao from '../../../../database/dao/BookGroupsDao'
import bookGroupUtils from '../../../../common/utils/bookGroupUtils'
import { GroupTree } from '../../../../common/group/GroupTree'
import { resolveCoverSource } from '../../../../common/utils/CoverSource'

/** 路径条上的一格（2026-11-01）：id=1 的「分组」是虚拟根，其余是真实分组 */
interface PathChip {
  id: number
  name: string
}

@Component
export default struct BookContentRefresh {
  @State @Watch('changeRefreshing')isRefreshing: boolean = false
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') isGroupRefreshing: number = 0
  // 2026-10-25：`BOOK_IS_BOOK_WORKS_BOOK_LIST`（书单刷新键）随书单功能删除
  /** 「分组 / 全部 / 未分组 / 本地」那一栏的**实测高度**（`GroupType` 上报）——用于给列表让位 */
  @StorageLink('shelfGroupRowH') shelfGroupRowH: number = 0
  @State counter: number = 0
  @State RefreshingTitle: string = '松开刷新'
  @Prop currentIndex: number = 0
  @Link EXHIBIT: string
  @Link GROUP: string
  @Prop searchValue: string
  @Link @Watch('onFolderChanged') bookTypeNumber:number
  /**
   * 「最近」chip 状态（2026-10-19 四修新增）。
   *
   * 用 `@StorageLink` 直连而不是 @Prop 逐层透传：它的真实载体是 AppStorage
   * （`SHELF_RECENT_CHIP`），排序面板（在分组管理弹窗里）也会改它，
   * 那条链路不经过本组件 ⇒ 只有 AppStorage 能保证三处看到同一个值。
   */
  @StorageLink('SHELF_RECENT_CHIP') onRecentChip: boolean = true
  /**
   * 当前所在分组的名字（2026-10-21 新增）。
   *
   * 用于「返回分组列表」悬浮按钮上显示"我在哪个分组"。
   * 由 `GroupType` 在切档 / 查完分组列表后写入 AppStorage；
   * 空串 = 不在任何具体分组内（最近 / 全部 / 分组列表页）。
   */
  @StorageLink('SHELF_CURRENT_GROUP_NAME') currentGroupName: string = ''
  /** 「返回分组列表」按钮的 Q弹缩放（规范 §1 三件套） */
  @State backScale: number = 1
  // ── 2026-11-01 多级文件夹：左下角「新建分组」按钮 ──────────────────────────
  /** 「+」按钮 Q弹缩放 */
  @State addScale: number = 1
  /** 新建分组的输入通道（与 `addBookTypeDialog` 共用 AppStorage key） */
  @StorageLink(AddGroupChannel.KEY_TEXT) newGroupName: string = ''
  // ── 2026-11-01 多级文件夹：路径条 + 子文件夹行 ─────────────────────────────
  /** 当前路径（首格是虚拟根「分组」id=1，后面是真实分组，根 → 当前） */
  @State pathChips: PathChip[] = []
  /** 当前分组的直属子文件夹（进入父组后以横滑卡片行展示） */
  @State childGroups: BookGroups[] = []
  /** 新建分组时的父级（0 = 根级；分组内新建 = 当前分组 id） */
  private newGroupParentId: number = 0
  @State checkGroup:Record<number, boolean> = {}
  /** 主题主色（悬浮按钮实底用） */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** 底部安全区实测高（悬浮按钮让位用，见 dockContentEndOffset） */
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0

  /**
   * 是否应该显示「返回分组列表」按钮（2026-10-21 新增）。
   *
   * 用户原话：「在分组中点击一个分组进入这个分组，此时我该如何返回上一级呢？貌似没有什么办法？
   *   并且我们也不知道我所在分组是什么名字…底部 minibar 上方多一个按钮，
   *   叫做返回分组列表，点击后返回分组列表。」
   *
   * 判定条件（三条同时满足）：
   *   ① 不在「最近」态（`onRecentChip === false`）；
   *   ② 不在「分组列表页」本身（`bookTypeNumber !== 1`，1 = 「分组」系统单元）；
   *   ③ 不是「书单」页（`bookTypeNumber !== 5`，虽已屏蔽入口，防御性判断）；
   *   ④ 能查到分组名（`currentGroupName` 非空 ⇒ 确实在某个具体分组里）。
   */
  private shouldShowBackToGroups(): boolean {
    if (this.onRecentChip) {
      return false
    }
    if (this.bookTypeNumber === 1 || this.bookTypeNumber === 5) {
      return false
    }
    return this.currentGroupName.length > 0
  }

  /**
   * 返回分组列表。
   *
   * 语义 = 回到「分组」系统单元那一页（`bookTypeNumber = 1`），
   * 与点顶栏「分组」chip **完全等价**（走 `SHELF_CHIP_STEP` 不行，那是±1 偏移；
   * 这里直接广播一个"跳到分组页"的请求，由 `GroupType` 落到 `onChipClicked(2)`）。
   */
  private backToGroupList(): void {
    Haptics.tap()
    runJellyClick((v: number) => {
      this.backScale = v
    })
    // 2 = 「分组」chip 的下标（`chipLabels()` = ['最近','全部','分组']）
    AppStorage.setOrCreate<number>('SHELF_CHIP_GOTO', 2)
  }
  changeRefreshing(){
    if (this.isRefreshing) {
      switch (this.bookTypeNumber){
        case 1:
          this.isGroupRefreshing++
          break;
        // 2026-10-25：`case 5`（书单）随书单功能一起删除
        default:
          this.isBookRefreshing++
          break
      }
    }
  }
  /**
   * 左下角常驻「新建分组」按钮（2026-11-01）。
   * 只在分组卡片页显示（`bookTypeNumber === 1` 且不在「最近」态）。
   * 风格与「返回分组列表」胶囊完全同源：主题主色实底 + 圆角 18 + Q弹 + `clickEffect`。
   */
  @Builder
  addGroupButton() {
    Row() {
      SymbolGlyph($r('sys.symbol.plus_circle'))
        .fontSize(20)
        .fontColor([NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : '#FFFFFF'])
    }
    .padding({ left: 12, right: 14, top: 8, bottom: 8 })
    .borderRadius(18)
    .backgroundColor(this.theme.mainColor)
    .scale({ x: this.addScale, y: this.addScale })
    .clickEffect(UiMotion.CLICK)
    .onClick(() => {
      this.openAddGroupDialog(0)
    })
  }

  /** 新建分组弹窗（复用 `addBookTypeDialog`：拒空名/重名，与「移动至」同款材质与动效） */
  addGroupDialog: CustomDialogController | null = new CustomDialogController({
    builder: addBookTypeDialog({
      cancel: (): void => {
        this.addGroupDialog?.close()
      },
      confirm: (): void => {
        this.createGroupFromDialog()
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 20,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST)
  })

  private openAddGroupDialog(parentId: number = 0): void {
    this.newGroupParentId = parentId
    Haptics.tap()
    runJellyClick((v: number) => {
      this.addScale = v
    })
    this.newGroupName = ''
    this.addGroupDialog?.open()
  }

  /** 确认新建：空名/同级重名拦截 → `addGroup(parentId)` → 广播刷新 + 重算路径 */
  private async createGroupFromDialog(): Promise<void> {
    const name: string = (this.newGroupName ?? '').trim()
    if (name === '') {
      showMessage('分组名称不能为空')
      return
    }
    const parentId: number = this.newGroupParentId
    const groups: BookGroups[] = await BookGroupsDao.search({ type: this.currentIndex })
    for (const g of groups) {
      if (!g.isSystem && (g.parentId ?? 0) === parentId && (g.groupName ?? '').trim() === name) {
        showMessage(`已存${name}分组`)
        return
      }
    }
    const ng: BookGroups = new BookGroups()
    ng.groupName = name
    ng.groupType = this.currentIndex
    ng.parentId = parentId
    await bookGroupUtils.addGroup(ng)
    this.newGroupName = ''
    this.isGroupRefreshing++
    await this.onFolderChanged()
    showMessage(`已添加${name}分组`)
  }

  // ── 2026-11-01 多级文件夹：路径条 / 子文件夹行 ──────────────────────────────
  aboutToAppear(): void {
    this.onFolderChanged()
  }

  /**
   * 层级变化：重算路径条 + 直属子文件夹。
   * 触发：① `bookTypeNumber` 变化（@Watch）；② 新建分组后手动调用。
   * 口径：`bookTypeNumber <= 1`（分组根 / 全部）或「最近」态 ⇒ 清空。
   */
  private async onFolderChanged(): Promise<void> {
    const id: number = this.bookTypeNumber
    if (id <= 1 || this.onRecentChip) {
      this.pathChips = []
      this.childGroups = []
      return
    }
    try {
      const all: BookGroups[] = await BookGroupsDao.search({ type: this.currentIndex })
      const tree: GroupTree = GroupTree.build(all)
      const path: BookGroups[] = tree.pathOf(id)
      const chips: PathChip[] = [{ id: 1, name: '分组' }]
      for (const g of path) {
        if (g.groupId !== undefined) {
          chips.push({ id: g.groupId, name: g.groupName })
        }
      }
      this.pathChips = chips
      this.childGroups = tree.childrenOf(id).filter((g: BookGroups): boolean => g.show)
      // 兼容既有字段（「返回分组列表」胶囊已被路径条取代，但该键仍被其它地方读写）
      AppStorage.setOrCreate<string>('SHELF_CURRENT_GROUP_NAME',
        path.length > 0 ? path[path.length - 1].groupName : '')
    } catch (e) {
      this.pathChips = []
      this.childGroups = []
      console.error('onFolderChanged failed: ' + JSON.stringify(e))
    }
  }

  /** 跳到某个分组（路径条 / 子文件夹行共用）；只改 bookTypeNumber，不动 GROUP */
  private jumpToFolder(id: number): void {
    if (id <= 0 || id === this.bookTypeNumber) {
      return
    }
    Haptics.tap()
    this.bookTypeNumber = id
  }

  /** 面包屑文案：`分组/父组/子组`（首段是虚拟根「分组」） */
  private pathText(): string {
    const names: string[] = []
    for (const p of this.pathChips) {
      names.push(p.name)
    }
    return names.join('/')
  }

  /** 面包屑点击：回上一级；已在根级分组时回分组列表 */
  private backOneLevel(): void {
    const n: number = this.pathChips.length
    if (n <= 2) {
      this.backToGroupList()
      return
    }
    const target: PathChip = this.pathChips[n - 2]
    Haptics.tap()
    this.bookTypeNumber = target.id
  }

  /** 路径条左侧「+」：在当前分组下新建子分组 */
  private openAddSubGroup(): void {
    this.openAddGroupDialog(this.bookTypeNumber)
  }

  build() {
    // ★★ 2026-10-21 三修：**「返回分组列表」按钮移出 `Refresh`** ★★
    // 用户反馈：「我下划刷新，这个按钮也会跟着被下滑，能固定吗」。
    // 根因：按钮原来在 `Refresh` 的**内容区**里（Refresh{ Stack{ 列表 + 按钮 } }），
    //   而 `Refresh` 下拉时会把整个内容区往下平移 ⇒ 按钮跟着走。
    // ⇒ 结构对调：`Stack{ Refresh{ 列表 } + 按钮 }`
    //   按钮成为 Refresh 的**兄弟节点**、叠在上层 ⇒ 下拉刷新时纹丝不动。
    //   `alignContent: BottomEnd` 仍让按钮贴右下；`Refresh` 自己撑满。
    Stack({ alignContent: Alignment.BottomEnd }) {
      Refresh({ refreshing: $$this.isRefreshing, builder: this.refreshComponent }) {
      // ★★ 2026-10-19 四修：**「最近」chip 必须无视 bookTypeNumber 的分流** ★★
      //
      // 用户反馈：「依次点击全部、分组、最近，最近显示的还是**分组这一页**…
      //   最近代表的是**全部书籍**的最近阅读排序。所以无论从哪里回到最近，
      //   最近里面都是全部书籍的按照最近阅读排序的。」
      //
      // 根因：这里的分流**只看 `bookTypeNumber`**：
      //   · 点「分组」⇒ `bookTypeNumber = 分组.groupId`（=1）；
      //   · 再点「最近」⇒ 只把 `onRecentChip` 置 true，而 **`bookTypeNumber` 仍是 1**
      //     （正确，因为我们特意不让它被哨兵值污染，见 `GroupType.RECENT_CHIP_ID` 注释）；
      //   ⇒ `bookTypeNumber === 1` 命中 ⇒ 渲染 `BookFolder`（分组卡片页）⇒ 用户看到"分组这一页"。
      //
      // 修法：把「最近」态**优先于**所有 `bookTypeNumber` 分支判断 ——
      //   「最近」的定义就是"全部书 + 最近阅读排序"，与当前停在哪个分组无关。
      // ══ 主体内容（用 Stack 包住，以便叠加「返回分组列表」悬浮按钮）════════════
      // ★ 2026-10-21 二修：按钮改到**右侧**（用户：「显示效果非常好，但是应该放在右侧」）
      //   ⇒ Stack 对齐改成 `BottomEnd`，按钮只给 `right` 外边距。
        Column() {
          // ── 2026-11-01 多级文件夹：进入父组后先显示直属子文件夹（横滑行）────────
          if (!this.onRecentChip && this.bookTypeNumber > 1 && this.childGroups.length > 0) {
            Scroll() {
              Row({ space: 12 }) {
                ForEach(this.childGroups, (g: BookGroups) => {
                  Column({ space: 4 }) {
                    Image(resolveCoverSource(g.coverUrl ?? '') ?? $rawfile('cover_defaults/c1.svg'))
                      .width(56)
                      .height(76)
                      .borderRadius(6)
                      .draggable(false)
                    Text(g.groupName)
                      .fontSize(11)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width(56)
                  }
                  .onClick(() => {
                    if (g.groupId !== undefined) {
                      this.jumpToFolder(g.groupId)
                    }
                  })
                }, (g: BookGroups) => 'cf' + (g.groupId ?? 0))
              }
              .padding({ left: 10, right: 10 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .padding({ top: 8, bottom: 6 })
          }

          if (this.onRecentChip) {
            BookContent({
              currentIndex: this.currentIndex,
              // 「最近」恒查全部书（bookGroup=2 = 不加分组条件）。
              // `BookContent.buildQueryParams()` 内部对 onRecentChip 也会再兜一次，
              // 这里显式传 2 是为了让**本层判断**也自洽，不依赖子组件的二次兜底。
              bookTypeNumber: 2,
              EXHIBIT: this.EXHIBIT,
              searchValue: this.searchValue
            })
          } else if (this.bookTypeNumber !== 5 && this.bookTypeNumber !== 1){
            BookContent({
              currentIndex:this.currentIndex,
              bookTypeNumber:this.bookTypeNumber,
              EXHIBIT: this.EXHIBIT,
              searchValue: this.searchValue
            })
          } else {
            Scroll() {
              Column() {
                // 2026-10-25：书单（`bookTypeNumber === 5`）分支整块删除 —— 书单功能下线，
                //   这里只剩「分组卡片页」一种。
                BookFolder({
                  EXHIBIT: this.EXHIBIT,
                  currentIndex:this.currentIndex,
                  // 2026-10-13：分组卡片改成"点了**直接切到该分组**"（用户不再要半屏 sheet）
                  // ⇒ 子组件必须能写回这两个状态，故传 @Link（链尾 @Prop 是单向副本，写不生效）。
                  GROUP: this.GROUP,
                  bookTypeNumber: this.bookTypeNumber
                })
              }
              .padding({ left: 10, right: 10, bottom: 30 })
            }
            .scrollBar(BarState.Off)
            // ★ 2026-10-25 官方 UX 自检 2.1.5.3.3「滑动过界反馈动效一致性」修复：
            //   `scroll.d.ts`「Default value: **EdgeEffect.None**」⇒ 分组卡片页的滚动容器
            //   是 `Scroll`（书架主列表才是 `List`，默认 Spring），不写就没有越界反馈。
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          }
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      // ⚠️ 2026-10-21：这两个回调属于 `Refresh`（`onStateChange`/`onRefreshing` 是
      //   RefreshAttribute 的方法），**必须挂在 Refresh 的修饰链上**，
      //   不能跟着按钮一起留在外层（挂到 Stack 上会报
      //   `Property 'onStateChange' does not exist on type 'StackAttribute'`）。
      //   下面这段原来在文件末尾、紧跟 `.margin({top:0})`，本次结构对调时一并搬回这里。
      .onStateChange((refreshStatus: RefreshStatus) => {
        if (refreshStatus === 1 || refreshStatus === 2) {
          this.RefreshingTitle = '松开刷新'
        } else {
          this.RefreshingTitle = '刷新中...'
        }
      })
      .onRefreshing(() => {
        setTimeout(() => {
          this.counter++
          this.isRefreshing = false
        }, 1000)
        showMessage('刷新成功')
      })

      // ── 多级面包屑（2026-11-01 用户定稿）────────────────────────────────────
      //  · **一个按钮**、**右侧对齐**（与旧「返回分组列表」胶囊同位置、同尺寸风格）；
      //  · 左侧保留返回 symbol（`chevron_left`），用户第一眼就知道"这是返回"；
      //  · 路径用 `/` 分隔（Windows 地址栏观感），超长省略；
      //  · 点击 = 回上一级；已经在根级分组（如 `分组/开心`）时 = 回分组列表。
      //  · 左侧「+」仍是"在当前分组下新建子分组"（与面包屑分离，避免多按钮语义混淆）。
      if (this.bookTypeNumber > 1 && !this.onRecentChip) {
        Row({ space: 8 }) {
          Row() {
            SymbolGlyph($r('sys.symbol.plus_circle'))
              .fontSize(18)
              .fontColor([NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : '#FFFFFF'])
          }
          .padding({ left: 10, right: 12, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor(this.theme.mainColor)
          .scale({ x: this.addScale, y: this.addScale })
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            this.openAddSubGroup()
          })

          Blank()

          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(16)
              .fontColor([NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : '#FFFFFF'])
            Text(this.pathText())
              .fontSize(13)
              .fontWeight(500)
              .fontColor(NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : '#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .constraintSize({ maxWidth: '70%' })
          .padding({ left: 12, right: 14, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor(this.theme.mainColor)
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            this.backOneLevel()
          })
          .margin({ right: 20 })
        }
        .width('100%')
        .padding({ left: 20 })
        .margin({ bottom: ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight) })
      }
      // ── 2026-11-01：分组卡片页左下角常驻「新建分组」─────────────────────────
      //  与外层 Stack 的 `BottomEnd` 对齐协作：整行铺满 + 左对齐 ⇒ 按钮贴左下；
      //  `HitTestMode.Transparent` 让空白区域的触摸仍能落到下面的列表上。
      if (this.bookTypeNumber === 1 && !this.onRecentChip) {
        Row() {
          this.addGroupButton()
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ left: 20 })
        .margin({ bottom: ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight) })
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    // ── 给「分组 / 全部 / 未分组 / 本地」那一栏让位（2026-09-23）──────────────────
    // ★ 2026-10-11：groupTypeComponent 改文档流（不再浮在 Tabs 上），不再需要让位
    //   ⇒ top 固定 0（让本组件内容紧贴 groupTypeComponent 之下）。
    .margin({
      top: 0
    })
  }
  @Builder
  refreshComponent() {
    RefreshComponent({
      RefreshingTitle: this.RefreshingTitle,
    })
  }
}
