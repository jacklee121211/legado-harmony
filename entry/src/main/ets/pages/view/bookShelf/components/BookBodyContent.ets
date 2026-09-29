/**
 * @author 2008
 * @datetime 2024/7/23 12:01
 * @className: BookBodyContent
 */
import groupTypeComponent from '../../../../componets/group/GroupType'
import { Haptics } from '../../../../common/utils/Haptics';
import IndexSearchType from '../../../../componets/head/IndexSearchType'
import AppRouter, { RouteName, BookManageRouteParam } from '../../../../common/router/AppRouter'
import BookContentRefresh from './BookContentRefresh'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'

@Component
export default struct BookBodyContent {
  @Prop index:number
  @Prop currentIndex: number = 0
  @State EXHIBIT_NAMES: string[] = ['列表', '宫格']
  @State GROUP_NAMES: string[] = ['标签', '文件夹']
  @Link EXHIBIT: string
  @Link GROUP: string
  @State searchValue: string = '最近阅读'
  @Link bookTypeNumber:number
  @State title: string = '最近阅读'
  @State groupCoverShow: boolean = false
  @State bookBodyIndex: number = 0
  tabsBookBodyController: TabsController = new TabsController();
  /**
   * 「最近阅读」行**尾部**的动作区（2026-09-29 新增）。
   * 由 `IndexShelf` 传入 `ShelfTopActions()`（搜索 / 更多 两个图标）——原来它们挂在
   * 顶部「小说/漫画/有声书」行的右侧；摘除「浏览历史」后本行尾部空了、与上一行
   * 失去对齐，用户裁定把图标挪到这个空位。@BuilderParam 的箭头函数闭包绑在
   * IndexShelf 上 ⇒ 弹窗/菜单/动效状态都在父组件（官方依据见 IndexShelf 同日注释）。
   */
  @BuilderParam trailingActions: () => void
  /** App 级夜间开关：只为触发重绘（取色走 NightMode/ShelfColors） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  build() {
    Column() {
      Flex(
        {
          alignContent: FlexAlign.Center,
          alignItems: ItemAlign.Center,
          justifyContent: FlexAlign.SpaceBetween
        }
      ) {
        Scroll() {
          Flex({
            alignItems: ItemAlign.Center,
            justifyContent: FlexAlign.SpaceBetween
          }) {
            Row({ space: 15 }) {
              IndexSearchType({ title: this.title, searchValue: this.searchValue })
              // ── 「浏览历史」入口已移除（2026-09-29，审核问题①）──────────────────
              // book_history 表全工程只有一个写入点（BookDetailPage.jumpReadPage），
              // 书架→阅读器的主流程不经过它 ⇒ 列表恒空；功能又与「最近阅读」重叠。
              // 数据表与 DAO 保留（BookDetailPage 仍在写），后续想恢复入口可直接接回
              // BookHistoryContent（BookContentRefresh 里的分支同日一并摘除）。
              this.GroupBuilder()
              this.ExhibitBuilder()
                Text('管理')
                  .onClick(() => {
                    Haptics.tap();
                    // 迁 Navigation 第 4 期：管理页已改为 NavDestination，改走路由门面。
                    AppRouter.push(RouteName.BOOK_MANAGE, {
                      currentIndex: this.currentIndex,
                      EXHIBIT: this.EXHIBIT,
                      bookTypeNumber: this.bookTypeNumber
                    } as BookManageRouteParam)
                  })
                  .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.6)' : 'rgba(0,0,0,0.5)')
                  .fontSize(15)
                  .fontWeight(400)
            }
            // ── 2026-09-23「书架顶部向沉浸光感看齐」（用户选 A：调到最像）──────────────
            // 自绘内容拿不到真材质（官方生效范围见 `IndexShelf` 顶部同款注释）⇒ 通用属性模拟，
            // 取值与阅读页胶囊一致：半透明底 + COMPONENT_ULTRA_THICK + 圆角 20。
            .backgroundColor(ShelfColors.surface())
            .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
            .borderRadius(20)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          }
        }
        .scrollBar(BarState.Off)
        .scrollable(ScrollDirection.Horizontal)

        // ── 行尾动作区：搜索 / 更多（2026-09-29 自顶部行下移，填充「浏览历史」撤除后的空位）──
        // Flex 是 SpaceBetween ⇒ 本节点贴行尾；垂直随 alignItems 与胶囊居中。
        if (this.trailingActions) {
          this.trailingActions()
        }
      }
      .padding(15)

      Stack() {
        groupTypeComponent({
            bookTypeNumber:this.bookTypeNumber,
            currentIndex: this.currentIndex,
            groupCoverShow: this.groupCoverShow,
            GROUP: this.GROUP
          }).zIndex(999)
        Tabs({
          controller:this.tabsBookBodyController,
          index: this.bookBodyIndex
        }){
          TabContent(){
            BookContentRefresh({
              EXHIBIT: this.EXHIBIT,
              GROUP: this.GROUP,
              searchValue: this.searchValue,
              currentIndex: this.currentIndex,
              bookTypeNumber:this.bookTypeNumber
            })
          }
          .align(Alignment.Top)
        }
        .scrollable(false)
        .barWidth(0)
        .barHeight(0)
        // ⚠️ 2026-09-23 撤掉这里给"分组栏让位"的 top margin：
        //   分组栏本来就有一套让位逻辑 —— `BookContentRefresh` 的根节点写着
        //   `.margin({ top: searchView === '浏览历史' ? 0 : 30 })`（那边的"30"就是留给分组栏的）。
        //   我上一版在**这里**又加了 `shelfGroupRowH + 4` ⇒ **两处叠加**（30 + 40 + 4 ≈ 74）
        //   ⇒ 用户反馈「间隙还是大」。现在统一到 `BookContentRefresh` 那一处按实测高度算。
        .onChange((index) => {
          this.tabsBookBodyController.changeIndex(index)
          this.bookBodyIndex = index
        })
      }
      .layoutWeight(1)
      .alignContent(Alignment.Top)
    }
  }

  @Builder
  GroupBuilder() {
    Row({ space: 10 }) {
      ForEach(this.GROUP_NAMES, (item: string) => {
        if (item !== this.GROUP) {
          IndexSearchType({ title: item, searchValue: this.searchValue })
            .onClick(() => {
              Haptics.tap();
              this.GROUP = item
            })
          Divider()
            .vertical(true)
            .height(15)
            .color(ShelfColors.line())
            .opacity(0.5)
            .strokeWidth(1)
        }
      })
    }
  }
  @Builder
  ExhibitBuilder() {
    Row({ space: 10 }) {
      ForEach(this.EXHIBIT_NAMES, (item: string) => {
        if (item !== this.EXHIBIT) {
          IndexSearchType({ title: item, searchValue: this.searchValue })
            .onClick(() => {
              Haptics.tap();
              this.EXHIBIT = item
            })
          Divider()
            .vertical(true)
            .height(15)
            .color(ShelfColors.line())
            .opacity(0.5)
            .strokeWidth(1)
        }
      })
    }
  }
}