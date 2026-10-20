/**
 * @author 2008
 * @datetime 2024/7/23 12:18
 * @className: BookContentRefresh
 */
import { showMessage } from '../../../../componets/common/promptShow'
import RefreshComponent from '../../../../componets/common/RefreshComponent'
import BookFolder from '../BookFolder'
import WorksBookLists from '../Shelf/WorksBookLists'
import BookContent from './BookContent'
// 「返回分组列表」悬浮按钮（2026-10-21）：震动 + Q弹 + 玻璃材质
import { Haptics } from '../../../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../../../common/utils/UiMotion'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import { NightMode } from '../../../../common/utils/NightMode'
import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { ThemeItem } from '../../../../common/model/Theme'

@Component
export default struct BookContentRefresh {
  @State @Watch('changeRefreshing')isRefreshing: boolean = false
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') isGroupRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_WORKS_BOOK_LIST') isWorksBookListRefreshing: number = 0
  /** 「分组 / 全部 / 未分组 / 本地」那一栏的**实测高度**（`GroupType` 上报）——用于给列表让位 */
  @StorageLink('shelfGroupRowH') shelfGroupRowH: number = 0
  @State counter: number = 0
  @State RefreshingTitle: string = '松开刷新'
  @Prop currentIndex: number = 0
  @Link EXHIBIT: string
  @Link GROUP: string
  @Prop searchValue: string
  @Link bookTypeNumber:number
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
        case 5:
          this.isWorksBookListRefreshing++
          break;
        default:
          this.isBookRefreshing++
          break
      }
    }
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
                if (this.bookTypeNumber === 5) {
                  WorksBookLists({
                    checkGroup: this.checkGroup,
                    EXHIBIT: this.EXHIBIT,
                    currentIndex:this.currentIndex,
                    isShowCheck:false
                  })
                } else {
                  BookFolder({
                    EXHIBIT: this.EXHIBIT,
                    currentIndex:this.currentIndex,
                    // 2026-10-13：分组卡片改成"点了**直接切到该分组**"（用户不再要半屏 sheet）
                    // ⇒ 子组件必须能写回这两个状态，故传 @Link（链尾 @Prop 是单向副本，写不生效）。
                    GROUP: this.GROUP,
                    bookTypeNumber: this.bookTypeNumber
                  })
                }
              }
              .padding({ left: 10, right: 10, bottom: 30 })
            }
            .scrollBar(BarState.Off)
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

      // ── 「返回分组列表」悬浮按钮（2026-10-21 新增）──────────────────────────
      // 用户原话：「在分组中点击一个分组进入这个分组，此时我该如何返回上一级呢？…
      //   底部 minibar 上方多一个按钮，叫做返回分组列表，点击后返回分组列表。
      //   如何？可以是 symbol+文字的一个显示效果。点击也要有系统统一的 q弹丝滑动效。」
      //
      // 位置：**底部 minibar 上方** ⇒ 用 `dockContentEndOffset` 算出 minibar 实际占高，
      //   按钮就贴在它上面（自适应不同安全区/手势导航，见该方法的注释）。
      //
      // ★ 2026-10-21 三修：本按钮现在是 `Refresh` 的**兄弟节点**（同属外层 Stack），
      //   所以下拉刷新时**不会跟着平移**（用户：「下划刷新，这个按钮也会跟着被下滑」）。
      if (this.shouldShowBackToGroups()) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(14)
            .fontColor([NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : '#FFFFFF'])
          Text(this.currentGroupName)
            .fontSize(13)
            .fontWeight(500)
            .fontColor(NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : '#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('返回分组列表')
            .fontSize(11)
            .fontColor(NightMode.isDarkSurface() ? 'rgba(248,249,250,0.62)' : 'rgba(255,255,255,0.78)')
            .maxLines(1)
        }
        .constraintSize({ maxWidth: '70%' })
        .padding({ left: 12, right: 14, top: 8, bottom: 8 })
        .borderRadius(18)
        // 用主题主色实底：悬浮按钮需要足够的对比度（半透明玻璃压在书封上会糊）
        .backgroundColor(this.theme.mainColor)
        .scale({ x: this.backScale, y: this.backScale })
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          this.backToGroupList()
        })
        // 底部让位：minibar 实际覆盖高度 + 8 呼吸位（`dockContentEndOffset` 已含安全区）
        // ★ 2026-10-21 二修：改**右对齐**（用户：「应该放在右侧」）⇒ 只给 right 外边距
        .margin({
          right: 20,
          bottom: ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight)
        })
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
