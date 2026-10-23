import { it } from '@ohos/hypium'
import { Haptics } from '../../../common/utils/Haptics';
import BookOverlay from '../../../componets/bookDetail/BookOverlay'
import { showMessage } from '../../../componets/common/promptShow'
import { folderList } from '../../../componets/dataList/folderList'
import BookGroupsDao from '../../../database/dao/BookGroupsDao'
import bookGroupUtil from '../../../common/utils/bookGroupUtils'
import { BookGroups } from '../../../database/entities/BookGroups'
import FolderInfoDialog from './components/dialog/FolderInfoDialog'
import coverInfoDialog from './components/dialog/coverInfoDialog'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../common/utils/UiMotion'
import { shelfEntrance } from '../../../common/utils/EntranceWave'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
import { resolveCoverSource, coverCorners } from '../../../common/utils/CoverSource'
// 宫格列数（2026-10-23 多端适配）：与书籍宫格**同源同一份取值**
import ShelfPrefs from '../../../common/utils/ShelfPrefs'

/**
 * 文件夹
 */
@Component
export default struct BookFolder {
  @Prop EXHIBIT: string
  // ── 宫格列数的两个输入源（2026-10-23 多端适配）────────────────────────────
  // 用户原话：「最近和全部都没问题，随着调节就可以变化，但是分组没变化啊，
  //   我建议分组跟着变化，也没必要单独给分组弄一个调节器，
  //   因为分组其实和单本书宽度相仿。」
  // ⇒ 分组视图**不单独设滑块**，直接复用书籍宫格那一份列数
  //   （`ShelfPrefs.effectiveColumns`：自动档跟随断点 / 手动档用设置页滑块的值）。
  //   分组卡片的视觉宽度与单本书封面同量级，列数一致才对齐得好看。
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE) userGridColumns: number = 0
  /** App 级夜间开关：只为触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  currentIndex: number = 0
  /**
   * 2026-10-13 新增（用户：「在分组这个列表里，点击哪个分组，直接切换到对应分组去，
   * 这样也算是天然适配」）：
   * 点分组卡片不再开半屏 sheet，而是**直接切到那个分组** ⇒ 本组件必须能写回父级
   * （`IndexShelf`）的这两个状态，故用 `@Link`（`@Prop` 是单向副本，写了不生效）。
   * 上游链路（全部是既有 @Link 链，本组件只是接到链尾）：
   *   `IndexShelf` `@State @Watch('changeGroup') GROUP` / `@State bookTypeNumber`
   *   → `BookBodyContent`（@Link）→ `BookContentRefresh`（@Link）→ 本组件（@Link）。
   */
  @Link GROUP: string
  @Link bookTypeNumber: number
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') @Watch('getGroupList') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  /**
   * 书籍数据变更（删书 / 移入移出分组 / 导入）→ **只重算"共N本"**（2026-10-06）。
   *
   * 为什么需要它：分组卡片上的"共N本"过去读 `book_groups.bookIds`（陈旧冗余列），
   * 现已改为按 `books.bookGroup` 现算（见 `bookGroupUtil.fillRealBookIds`）；而
   * 「删书 / 移动书籍」只广播 `BOOK_IS_BOOK_REFRESHING`（在分组 sheet 内删书就是这条路），
   * 分组卡片若不监听就还停在旧数字 ⇒ 不算"实时"。
   * 走 `refreshGroupCounts`（**不**走 `getGroupList`）：后者会 `replayEntrance()` 重播
   * 整屏入场动画，删一本书就翻一次牌是噪音（同 `BookContent.animateOnNextLoad` 的取舍）。
   */
  @StorageLink('BOOK_IS_BOOK_REFRESHING') @Watch('refreshGroupCounts') BOOK_IS_BOOK_REFRESHING: number = 0

  // ── 渐次入场（2026-09-24 新增，需求第 5 / 7 点）──────────────────────────────
  /**
   * 每项的"已入场"标记。用数组而不是把项抽成子组件 —— 本文件的两套卡片都是
   * `@Builder` 内联出来的，抽组件会牵动布局；而 `@State` 对 Array 的**数组项赋值**
   * 是可观察的（官方状态管理 V1 文档：`@State` 装饰 Array 时「可以观察到数组本身的
   * 赋值和数组项的增删改」）⇒ 数组方案同样能逐项驱动动画。
   */
  @State enteredFlags: boolean[] = []
  /** 未到期的入场定时器句柄，`aboutToDisappear` 里统一清掉 */
  private enterTimers: number[] = []

  /**
   * 读取某一项是否已入场。
   * ⚠️ **必须容错**：`enteredFlags` 是按"上一次的数据条数"建的，若因任何原因越界
   * （父组件直接注入数据、条数变化早于 flags 重建），`undefined` 会被当成 falsy
   * ⇒ 整项永久透明。所以这里把 `undefined` 显式判成"已入场"。
   */
  private isEntered(index: number): boolean {
    const v: boolean | undefined = this.enteredFlags[index]
    return v === undefined ? true : v
  }

  /**
   * 开一波并重建标记数组。
   *
   * ⚠️ 调用顺序必须严格是 `replayEntrance(...)` → `this.groupList = val`：
   *    两行在同一同步块里，渲染只会发生一次，彼时 flags 已与数据等长，
   *    不会出现"数据已到、flags 还没建"的那一帧（那就是前面说的永久透明隐患）。
   */
  private replayEntrance(count: number): void {
    this.clearEnterTimers()
    shelfEntrance.begin()
    const flags: boolean[] = []
    for (let i = 0; i < count; i++) {
      const d: number = shelfEntrance.delayFor(i)
      if (d < 0) {
        // 波次已结束 ⇒ 直接终态，不播动画（需求第 7 点）
        flags.push(true)
      } else {
        flags.push(false)
        this.enterTimers.push(setTimeout(() => {
          this.enteredFlags[i] = true
        }, d))
      }
    }
    this.enteredFlags = flags
  }

  private clearEnterTimers(): void {
    for (const t of this.enterTimers) {
      clearTimeout(t)
    }
    this.enterTimers = []
  }

  aboutToDisappear(): void {
    this.clearEnterTimers()
  }

  aboutToAppear(): void {
    this.getGroupList()
  }

  @State groupList: BookGroups[] = []

  /**
   * 拉分组列表（2026-09-29 修审核问题④「未分组的书未存放在未分组组别」）。
   *
   * 「未分组」是系统分组（isSystem=true），而 build() 过去把系统分组**全部**过滤掉
   * ⇒ 文件夹视图里根本没有"未分组"这个文件夹，默认 bookGroup=3（未分组）的书
   * 在文件夹视图里无家可归（「全部 / 未分组」两个页签能看到，文件夹视图看不到）。
   * ① 放行名为「未分组」的系统分组（按名字认，不按 groupId 认 —— 系统分组由
   *    `initGroupData` 按固定顺序插入，老库 groupId 可能漂移，名字才是稳定标识）；
   * ② 它的 `bookIds` 库里恒空（默认入架的书从不走 updateAddBookIds）。
   *
   * ⚠️ 2026-10-06 修「自建分组恒显示共0本」：当年只给「未分组」现算了 bookIds，
   *    自建分组仍读 `book_groups.bookIds` 这个陈旧冗余列（真机实测为空串，且被
   *    `DbUtil.parseResultSet` 读成 undefined）⇒ 一律显示"共0本"。
   *    现在**所有**分组统一走 `bookGroupUtil.fillRealBookIds`（按 books.bookGroup 现算，
   *    口径与点进分组后的列表查询同源）—— 「点进分组」现在是**切到该分组**
   *    （`openGroup()` ⇒ `bookTypeNumber = groupId`），列表查询口径仍是 `bookGroup = groupId`，
   *    天然一致。
   */
  async getGroupList() {
    try {
      const val = await this.loadGroupList()
      this.replayEntrance(val.length)
      this.groupList = val
    } catch (e) {
      console.log('BookFolder getGroupList, Error, ', JSON.stringify(e))
    }
  }

  /** 只刷新卡片上的"共N本"（书数据变更）：重查 → 重算 → 整体赋值触发重绘；不复播入场波 */
  async refreshGroupCounts() {
    try {
      this.groupList = await this.loadGroupList()
    } catch (e) {
      console.log('BookFolder refreshGroupCounts, Error, ', JSON.stringify(e))
    }
  }

  /** 查分组 + 现算每个分组的真实书籍数（两条刷新路径共用） */
  private async loadGroupList(): Promise<BookGroups[]> {
    const val: BookGroups[] = await BookGroupsDao.search({
      type: this.currentIndex
    })
    await bookGroupUtil.fillRealBookIds(val, this.currentIndex)
    return val
  }

  /**
   * 点分组卡片 = **直接切到该分组**（2026-10-13 用户改版）。
   *
   * 用户原话：「我发现现在点击分组之后，点击里面的未分组，出现的还是半屏弹窗，不需要
   *   这个了，在分组这个列表里，点击哪个分组，直接切换到对应分组去，这样也算是天然适配」。
   *
   * 走的**就是分组行 chip 那条老路径**（`componets/group/GroupType.ets` 的
   * `selectGroup()`）：`GROUP = '标签'` + `bookTypeNumber = 该分组 id`
   * ⇒ `BookContentRefresh` 依据 `bookTypeNumber` 渲染 `BookContent`，
   *   而 `BookContent` 的查询口径正是 `bookGroup = bookTypeNumber` ——
   *   与分组卡片的"共N本"（`fillRealBookIds` 按 `books.bookGroup` 现算）同源，
   *   所以点进去的数字与列表条数天然一致。
   *
   * ⚠️ 语句顺序**不能反**：`IndexShelf` 有 `@Watch('changeGroup')`，`GROUP` 变成
   *   `'标签'` 时它会把 `bookTypeNumber` 兜底置成 2（全部）。官方文档
   *   `开发指南/…/状态管理_V1/管理组件拥有的状态/Watch装饰器_状态变量更改通知/arkts-watch`
   *   原文两句：
   *     「@Watch触发时机：回调触发时间是变量真正变化、**被赋值的时间**」
   *     「@Watch方法在自定义组件的属性变更之后**同步执行**」
   *   ⇒ 兜底发生在 `this.GROUP = '标签'` **这一行当场**，紧跟其后的
   *   `this.bookTypeNumber = id` 必然覆盖它；
   *   反过来写（先 id 后 GROUP）就会被兜底改成"全部"，表现为"点了没反应"。
   *   该顺序与 `GroupType.selectGroup()` 逐字一致（那条路径在真机上已验证）。
   */
  private openGroup(item: BookGroups): void {
    const id: number | undefined = item.groupId
    if (id === undefined) {
      return
    }
    Haptics.tap()
    this.GROUP = '标签'
    this.bookTypeNumber = id
    // ★ 2026-10-21：上报当前子分组名 —— 「返回分组列表」悬浮按钮靠它显示
    //   `< 开心  返回分组列表`。
    //   ⚠️ 这条路径（分组页点卡片进入）**不经过** `GroupType.onChipClicked`，
    //     所以必须在这里单独写一次，否则从分组页进去时按钮不显示名字。
    //   ⚠️ 同时要清掉「最近」态：`BookContentRefresh` 的按钮显示条件是
    //     `!onRecentChip && bookTypeNumber !== 1 && 名字非空`，
    //     若残留 `onRecentChip === true`，进来会被「最近」分支接管（显示全部书）。
    AppStorage.setOrCreate<boolean>('SHELF_RECENT_CHIP', false)
    AppStorage.setOrCreate<string>('SHELF_CURRENT_GROUP_NAME', item.groupName ?? '')
  }

  build() {
    GridRow({
      // 旧实现写死 3 列（与书籍宫格旧值同款）⇒ 平板横屏下列数与书籍不一致。
      // 现在与 `BookContent` 的 `List.lanes()` **同源同一个函数**：
      //   自动档 sm=3 / md=4 / lg=5 / xl=6；手动档 = 设置页滑块值。
      // ⚠️ 手机端恒为 3（sm 档），与旧值完全一致 ⇒ 零回归。
      columns: this.EXHIBIT === '宫格'
        ? ShelfPrefs.effectiveColumns(this.userGridColumns, this.currentBreakpoint) : 1
    }) {
      ForEach(this.groupList, (item: BookGroups, index: number) => {
        // ⚠️ 放行「未分组」系统分组（2026-09-29，审核问题④）：其余系统分组
        // （分组/全部/本地/书单）不是"装书的地方"，维持排除。
        if (item.show && (!item.isSystem || item.groupName === '未分组')) {
          GridCol() {
            Column() {
              if (this.EXHIBIT === '宫格') {
                this.bookInfoGrid(item)
              } else {
                this.bookFolderInfo(item)
              }
            }
          }
          .gesture(
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction((event: GestureEvent) => {
                Haptics.tap();
                // 五个系统单元锁定（2026-10-01 用户定义）：全部/本地/分组/未分组不提供
                // 长按弹窗；书单长按**直达封面样式弹窗**；自建分组仍走原弹窗。
                if (item.isSystem) {
                  if (item.groupName === '书单') {
                    this.openWorksCoverDialog(item)
                  } else {
                    showMessage('「' + (item.groupName ?? '') + '」是系统单元，不支持编辑')
                  }
                  return
                }
                this.dialogGroupData = item
                this.groupInfoDialog?.open()
              }))
          .onClick(() => {
            // 2026-10-13 用户：「点击哪个分组，直接切换到对应分组去」⇒ 不再开半屏 sheet
            this.openGroup(item)
          })
          // ── 渐次入场（2026-09-24，需求第 5 / 7 点）
          // 只动图形变换属性，不触发重新布局。`.animation()` 放最后。
          .opacity(this.isEntered(index) ? 1 : 0)
          .scale({
            x: this.isEntered(index) ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM,
            y: this.isEntered(index) ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM
          })
          .translate({ y: this.isEntered(index) ? 0 : UiMotion.ITEM_ENTER_TRANSLATE_Y })
          .animation(UiMotion.itemEnterParam())
        }
      }, (item: BookGroups, index: number): string => {
        // ── 键值必须并入**所有影响显示**的字段（2026-10-06）────────────────────
        // 官方《ForEach：循环渲染》非首次渲染原文：「它会检查新生成的键值是否在上次渲染中
        //   已经存在。如果键值不存在，则会创建一个新的组件；**如果键值存在，则不会创建新的
        //   组件，而是直接渲染该键值所对应的组件**。」（documentId：
        //   `开发指南/…/ForEach_循环渲染/arkts-rendering-control-foreach`）
        // 本项目规范同步要求（`docs/标准-弹窗与按钮统一规范.md:212`）：「LazyForEach/ForEach
        //   键值必须包含影响显示的字段：键值相同的项复用旧组件、不重绑数据 ⇒ 广播了也不重渲染」。
        // 卡片上会变且影响显示的有：分组名 / 置顶角标 / 显示开关 / 封面（含 coverType 书页叠层）
        //   / "共N本"。少任何一个，改完都停在旧画面（"共0本"就是这么来的）。
        // ⚠️ 第三个参数**必须声明 index**（即使不用）：官方 FAQ `faqs-arkui-219` 原文
        //   「如果keyGenerator未缺省，且包含index，无论itemGenerator中是否包含index，
        //     生成的键值规则都由开发者自定义，框架不会拼接index」——itemGenerator 里用了
        //     index（入场错峰），不声明的话框架会把 index 拼到键值尾部，等于键值里带下标。
        return (item.groupId !== undefined ? 'g' + item.groupId : item.groupName)
          + '|' + (item.groupName ?? '')
          + '|' + (item.isTop ? 'T' : 'F')
          + '|' + (item.show ? '1' : '0')
          + '|' + (item.coverUrl ?? '')
          + '|' + item.coverType
          + '|' + (item.bookIds?.length ?? 0)
      })
    }
    // ── 2026-10-13：`bindSheet($$isShowBookFolderInfoDialog, BookManageDialog)` 整块删除 ──
    // 用户：「点击里面的未分组，出现的还是半屏弹窗，不需要这个了…点击哪个分组，直接切换到
    //   对应分组去」。分组内容现在由书架列表本身呈现（`bookTypeNumber = 该分组 id`
    //   ⇒ `BookContent` 按 `bookGroup` 查），与点分组行 chip 完全同一条路径、同一套口径。
  }

  // ── 2026-10-13：`@State clickGroup` + `bookFolderInfoDialog()`（BookManageDialog 的
  //    sheet 内容）一并删除。历史上这里要 `clickGroup` 只是为了把"点了哪个分组"传给
  //    sheet（当时还专门论证过它为什么必须是 @State 而非 @ObjectLink —— 因为它被本地
  //    整体赋值）。现在点击直接切分组（`openGroup()`），不再需要中间态。

  /**
   * 分组卡片封面的「多本叠加」装饰层（2026-10-21 新增）。
   *
   * 用户原话：「最近和全部里面的单本书籍看起来要比分组的书籍要宽厚一些，我建议给分组
   *   里面的书籍封页增加一下宽度，不是正常的加宽，而是在下面增加一层或者两层，
   *   像是两三本书叠加在一起，更符合分组的效果，建议是**右侧以及底部**进行多出来叠加效果。」
   *
   * ── 设计要点 ─────────────────────────────────────────────────────────────
   * · **不改变封面本身尺寸**（仍是 88×120）—— 加宽会破坏与单本书封面的视觉一致性；
   * · 在封面**右下方**错位叠 2 层"书页"，形成"一摞书"的观感；
   * · 层次：最底层最大最淡 → 中间层 → 封面（最上、最亮）；
   * · 用 `ShelfColors.skeleton()` 系列半透明白/黑，日夜自动跟随（与工程其它占位块同源）；
   * · `HitTestMode.None` 让装饰层不抢触摸（否则会挡住卡片的点击/长按）。
   *
   * ── 为什么错位方向是"右下"而不是"左上"
   * 封面左上角有「置顶」角标（`item.isTop`），左上叠层会压住它；
   * 右下是空区，且符合"书叠在下面"的直觉（后放的书压在下面、露出来的是右下边）。
   */
  @Builder
  FolderStackDecor() {
    // 第 2 层（最底、偏移最大、最淡）
    Row()
      .width(88)
      .height(120)
      .borderRadius(coverCorners(88))
      .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.05)')
      .translate({ x: 10, y: 8 })
      .zIndex(0)
      .hitTestBehavior(HitTestMode.None)
    // 第 1 层（中间、偏移中等）
    Row()
      .width(88)
      .height(120)
      .borderRadius(coverCorners(88))
      .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.16)' : 'rgba(0,0,0,0.08)')
      .translate({ x: 5, y: 4 })
      .zIndex(1)
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  bookInfoGrid(item: BookGroups) {
    Column({
      space: 5
    }) {
      Column() {
        Column() {
          Stack() {
            // ── 2026-10-21：先画叠加装饰层（在封面**下面**）──────────────────
            this.FolderStackDecor()

            Stack() {
              Stack() {
                if (item.isTop) {
                  Text('置顶')
                    .fontColor(Color.White)
                    .fontWeight(300)
                    .fontSize(8)
                    .padding(3)
                    .borderRadius(5)
                    .backgroundColor('rgba(0, 0, 0, 0.45)')
                    .zIndex(1)
                }
                // 2026-10-01：default:// 协议必须经 resolveCoverSource 转 $rawfile；
                // 未设置封面（null）时落内置默认封面 c1（用户："没修改过分组的显示默认封面"）
                // 2026-10-04：补书脊式圆角（同内置封面 SVG，90 宽画布左 4 / 右 8 等比）。
                Image(resolveCoverSource(item.coverUrl ?? '') ?? $rawfile('cover_defaults/c1.svg'))
                  .draggable(false)
                  .alt($r('app.media.icon_book_default_cover_one'))
                  .borderRadius(coverCorners(88))
                  .width(88)
                  .height(120)
              }.alignContent(Alignment.BottomStart)
            }
            .zIndex(2)

            // 2026-10-05（用户："太复杂了，一起简化"）："书页叠层 + 底条"装饰统一受
            // `UiMotion.SHELF_COVER_STACK` 控制（默认 false ⇒ 卡片只留一张封面）。
            if (UiMotion.SHELF_COVER_STACK && item.coverType !== 2) {
              Row() {
                Image($r('app.media.occlusion1')).draggable(false)
              }
              .zIndex(1)
              .width(95).height(110)

              Row() {
                Image($r('app.media.occlusion2'))
              }.zIndex(0)
              .width(100).height(100)
            }
          }
          .align(Alignment.BottomStart)
        }

        // 2026-10-05（用户："保留色条，色条有点溢出，优化一下"）：
        // 宽度原来 100 > 封面 88，外层 Column 居中 ⇒ 左右各溢出 6vp；现在与封面同宽（88）。
        if (UiMotion.SHELF_COVER_BASE_BAR) {
          Row().width(88).height(20).backgroundColor(ShelfColors.skeleton()).borderRadius(10)
        }
      }

      Text(item.groupName)
        .fontSize(15)
        .fontWeight(700)
        .textOverflow({
          overflow: TextOverflow.Ellipsis
        })
        .ellipsisMode(EllipsisMode.END)
        .maxLines(2)
      Text(`共${item.bookIds?.length || 0}本`)
        .fontSize(12)
        .fontColor('rgb(174,174,174)')
        .textOverflow({
          overflow: TextOverflow.Ellipsis
        })
        .ellipsisMode(EllipsisMode.END)
        .fontWeight(500)
        .maxLines(1)
    }
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: 8,
      right: 8,
      bottom: 5,
      top: 5
    })
  }

  @Builder
  bookFolderInfo(group: BookGroups) {
    Flex(
      {
        alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.SpaceBetween
      }
    ) {
      Row({
        space: 20
      }) {
        BookOverlay({
          bookImage: group.coverUrl,
          isTop: group.isTop,
          coverType: group.coverType
        })
        Column({
          space: 24
        }) {
          Text(group.groupName)
            .fontWeight(700)
          Column() {
            Text(`共${group.bookIds?.length || 0}本`)
              .fontSize(12)
              .fontColor('rgb(174,174,174)')
              .textOverflow({
                overflow: TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(400)
              .maxLines(1)
              .lineHeight(20)
            // Text(group.newUpdateBook?group.newUpdateBook:'暂无更新')
            //   .fontSize(12)
            //   .fontWeight(400)
            //   .textOverflow({
            //     overflow:TextOverflow.Ellipsis
            //   })
            //   .ellipsisMode(EllipsisMode.END)
            //   .maxLines(1)
            //   .lineHeight(20)
          }
          .width('60%')
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
    }
    .padding(10)
    .borderRadius(10)
  }

  @State dialogGroupData: BookGroups = new BookGroups()
  groupInfoDialog: CustomDialogController | null = new CustomDialogController({
    builder: FolderInfoDialog({
      itemData: this.dialogGroupData,
      // 真开真关（2026-10-01 用户方案）：子关闭→重查该分组→open，全新实例=全新快照
      reopen: (): void => { this.reopenGroupInfoDialog() },
      cancel: () => {
        this.exitDialog()
      }
    }),
    cancel: this.exitDialog,
    autoCancel: true,
    // ★ 悬空四圆角 + 系统真材质（2026-09-22）。与书架其它长按弹窗保持同一观感。
    //   `customStyle: false` 是材质生效的**必要条件**；options 无 margin 字段，
    //   左右边距靠 width，上下靠 offset。逐条依据见 `BookInfos.ets` 同处注释。
    width: '92%',
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -16 },
    cornerRadius: 20,
    customStyle: false,
    // 弹窗材质走官方 options 渠道（依据见 BookInfos.ets 同处注释）
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),

  })

  //退出弹框
  exitDialog() {
    this.groupInfoDialog?.close()
  }

  /** 真开真关（2026-10-01 用户方案）：重查该分组 → 更新 dialogGroupData → open。
   *  FolderInfoDialog 无 @Consume，open 重建实例安全且快照天然新数据。 */
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

  /** 「书单」（系统单元）长按 → 直达封面样式弹窗（与 GroupType 同款，2026-10-01） */
  private worksCoverDialog: CustomDialogController | null = null
  private openWorksCoverDialog(item: BookGroups): void {
    this.worksCoverDialog = new CustomDialogController({
      builder: coverInfoDialog({
        itemData: item,
        // 2026-10-12：必须真的 close（旧写法只置 null ⇒ 弹窗关不掉；
        // 子组件内自己 close 不可靠，真机两次验证见 `ReaderSaveSchemeDialog.ets:205-208`）
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
}