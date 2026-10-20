/**
 * @author 2008
 * @datetime 2024/7/23 12:01
 * @className: BookBodyContent
 */
import groupTypeComponent from '../../../../componets/group/GroupType'
import BookContentRefresh from './BookContentRefresh'
import { NightMode } from '../../../../common/utils/NightMode'
// 2026-10-13：三胶囊共用的「可调玻璃」配方（唯一真源）
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
// ⚠️ 2026-10-20「终极简化」后本文件不再需要的 import（全部删除，避免未使用告警）：
//   · IndexSearchType —— 「喵阅」「列表/宫格」文字按钮已删（后者搬进三横弹窗）
//   · AppRouter / RouteName / BookManageRouteParam —— 「管理」文字按钮已删
//     （用户：「管理直接删除就行，因为在更多里面有入口」⇒ 「⋯」里的「批量管理」同页）
//   · ShelfColors —— 只剩 `NightMode` 在用

@Component
export default struct BookBodyContent {
  @Prop index:number
  @Prop currentIndex: number = 0
  @State EXHIBIT_NAMES: string[] = ['列表', '宫格']
  @Link EXHIBIT: string
  @Link GROUP: string
  /**
   * 第一列标题文字（2026-10-19 需求第 1 条）。
   *
   * 用户原话：「现有的最近阅读是四个字，我们换成喵阅两个字…这时候，喵阅这两个字就变成
   *   固定的字，点击没用就ok了。」
   *
   * ⇒ 它从「最近阅读」（一个**看起来像功能**的名字）改成品牌名「喵阅」，且**纯文字、不可点**。
   *   真正的「最近」功能已迁到分组行第一个 chip（见 `GroupType` 的虚拟 chip）。
   * ⚠️ 注意它与 `searchValue` 是两回事：`searchValue` 用于 chip 高亮判定
   *   （`IndexSearchType.chipFg` 比较 `searchValue === title`），本字段只负责**显示**。
   */
  @State title: string = '喵阅'
  /**
   * chip 高亮的判定基准（下拉/排序面板 2026-10-01 删除后，全工程无任何地方改它）。
   * 保持 `'最近阅读'` 不变 ⇒ 所有 chip 都走"未选中"的分支，行为与改造前一致。
   */
  @State searchValue: string = '最近阅读'
  @Link bookTypeNumber:number
  @State groupCoverShow: boolean = false
  @State bookBodyIndex: number = 0
  tabsBookBodyController: TabsController = new TabsController();
  /**
   * 「最近」虚拟 chip 状态 + 排序变更信号（2026-10-19 需求第 3 / 6 条）。
   *
   * ⚠️ 两者都不再作为 props 往下传：它们的真实载体是 **AppStorage**
   *   （`SHELF_RECENT_CHIP` / `SHELF_SORT_TICK`），因为排序面板挂在分组管理弹窗里，
   *   与书架列表不是父子关系。这里保留 `@Prop` 只为兼容父级传参，实际消费方
   *   （`BookContent` / `GroupType`）各自用 `@StorageLink` 直连同一份数据。
   */
  @Prop onRecentChip: boolean = true
  @Prop sortTick: number = 0

  // ══════════════════════════════════════════════════════════════════════════
  // 内容区滑动切换（2026-10-21 新增）
  // ══════════════════════════════════════════════════════════════════════════
  // （2026-10-21 删除 `headerMerged`：融合开关按用户要求移除，顶栏固定分离式）

  /**
   * 内容区左右滑动切换 最近/全部/分组。
   *
   * ── 用户澄清（2026-10-21）────────────────────────────────────────────────
   * 「滑动切换你理解错了…我的意思是**滑动书籍区域**，而不是那个开关，做到自然切换。」
   * ⇒ 手势挂在**书籍内容区**（`Stack` 那一层），不在开关上。
   *
   * ── 官方方案（documentId `FAQ/UI框架/组件使用/如何实现自定义分段按钮跟手滑动/faqs-arkui-1367`）
   * 原文：「使用 `PanGesture` 滑动手势事件，动态计算 `offsetX` 实现拖拽跟随效果」。
   */
  private swipePan: PanGestureOptions =
    new PanGestureOptions({ direction: PanDirection.Left | PanDirection.Right })
  /** 本次滑动累计位移（用于松手时判定方向与阈值） */
  private swipeAccum: number = 0

  /** 滑动阈值：超过才切档，避免误触（与点击区分开） */
  private static readonly SWIPE_THRESHOLD: number = 60
  /** 内容区透明度（滑动切档时做淡出淡入，见 `onSwipeEnd` 的注释） */
  @State private contentOpacity: number = 1

  /**
   * 内容区滑动手势处理。
   * 左滑 ⇒ 下一档；右滑 ⇒ 上一档。到边界不循环（与系统分段控件一致）。
   *
   * ── 2026-10-21 二修：加过渡动画（用户：「没动画，不够丝滑太生硬」）──────────
   * 切换档位会重建整个列表，直接切是"硬跳"。这里用 `animateTo` 包住"内容淡出→切换→淡入"：
   *   ① 先把内容透明度压到 0（`contentOpacity = 0`），时长 `UiMotion.DUR_FAST`；
   *   ② 动画过半时真正切档（广播 `SHELF_CHIP_STEP`）；
   *   ③ 新数据渲染后把透明度拉回 1。
   * ⇒ 观感是"内容轻轻一淡、换成下一档"，比硬切自然得多，且不需要跟手重排（代价低）。
   *
   * ⚠️ 为什么不用跟手位移（官方 FAQ 那种 `offsetX` 拖拽）：
   *   那是给**分段指示器**（一个 8vp 小方块）用的，位移代价极低；
   *   而这里要平移的是**整屏书籍列表**（LazyForEach 上百节点），
   *   逐帧重排会明显掉帧 ⇒ 淡入淡出是这个场景的最优解。
   */
  private onSwipeEnd(): void {
    const delta: number = this.swipeAccum
    this.swipeAccum = 0
    if (Math.abs(delta) < BookBodyContent.SWIPE_THRESHOLD) {
      return
    }
    const step: number = delta < 0 ? 1 : -1
    // ⚠️ 用 `this.getUIContext().animateTo()` 而不是全局 `animateTo` ——
    //    后者在本 SDK 已标 `@deprecated`（MCP check 会报 depreciatedSymbol）。
    const ui: UIContext = this.getUIContext()
    // ① 淡出
    ui.animateTo({ duration: 120, curve: Curve.EaseIn }, () => {
      this.contentOpacity = 0
    })
    // ② 切档 + ③ 淡入（延时一点，让淡出先完成，避免闪跳）
    setTimeout(() => {
      AppStorage.setOrCreate<number>('SHELF_CHIP_STEP', step)
      ui.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        this.contentOpacity = 1
      })
    }, 120)
  }
  /**
   * 「最近阅读」行**尾部**的动作区（2026-09-29 新增）。
   * 由 `IndexShelf` 传入 `ShelfTopActions()`（搜索 / 更多 两个图标）——原来它们挂在
   * 顶部分类页签行的右侧（当时那一行是「小说/漫画/有声书」，2026-10-11 起只剩「书架」）；摘除「浏览历史」后本行尾部空了、与上一行
   * 失去对齐，用户裁定把图标挪到这个空位。@BuilderParam 的箭头函数闭包绑在
   * IndexShelf 上 ⇒ 弹窗/菜单/动效状态都在父组件（官方依据见 IndexShelf 同日注释）。
   */
  @BuilderParam trailingActions: () => void
  /** App 级夜间开关：只为触发重绘（取色走 NightMode/ShelfColors） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  build() {
    Column() {
      // ══════════════════════════════════════════════════════════════════════════
      // ★★ 2026-10-20「终极简化」：**两行顶栏合并成一行** ★★
      // ══════════════════════════════════════════════════════════════════════════
      // 用户原话：「两条顶栏可能要合并成一条顶栏了…喵阅字样取消，这一行全都取消，
      //   下面一行的未分组后面接着搜索，搜索之后是三横，然后三横里面的显示分组和
      //   隐藏分组也不在需要了，只剩下排序了，把列表/宫格挪进三横的弹窗里面，
      //   管理直接删除就行，因为在更多里面有入口。三横只用来排序了，可以优化一下弹窗，
      //   三横之后是更多，也就是书籍导入/批量管理列表的那个更多按钮。」
      //
      // ── 改动前后 ────────────────────────────────────────────────────────────
      // 旧（两行）：
      //   第 1 行：[喵阅] [列表] [宫格] [管理]              🔍 ⋯
      //   第 2 行：[最近][全部][书单][分组][未分组][自定义…]      ≡
      // 新（一行）：
      //   [最近] [全部] [分组] [自定义…]                🔍 ≡ ⋯
      //
      // ── 各项去哪了 ──────────────────────────────────────────────────────────
      //   · 「喵阅」纯装饰字      → 删除（用户：「喵阅字样取消，这一行全都取消」）
      //   · 「列表 / 宫格」切换   → 挪进三横弹窗（`groupTypePanel.SortSection`）
      //   · 「管理」文字按钮      → 删除（用户：「管理直接删除就行，因为在更多里面有入口」
      //                             ⇒ 「⋯」里的「批量管理」就是同一个页面）
      //   · 「未分组」chip        → 删除（用户：「其实未分组也可以删除，因为在分组中
      //                             有未分组的置顶目录」）
      //   · 搜索 / ≡ / ⋯         → 全部收到本行尾部，顺序按用户指定：搜索 → 三横 → 更多
      //
      // ⚠️ `GROUP` / `searchValue` / `title` 等字段**保留**：它们仍被 `BookContentRefresh`
      //    与 chip 高亮逻辑读取，删掉会牵连一大片。只是不再有对应的 UI 控件。
      // ══════════════════════════════════════════════════════════════════════════
      Flex(
        {
          alignContent: FlexAlign.Center,
          alignItems: ItemAlign.Center,
          justifyContent: FlexAlign.SpaceBetween
        }
      ) {
        // ── 左：分组 chip 行 ─────────────────────────────────────────────────
        // 2026-10-21 三修：用户反馈「不仅三段没变窄，三按钮还被挤出去了」。
        // 上一版我把 chip 写死 88vp（整条 276vp），而可用宽度只有约 214vp
        // ⇒ 溢出、把右侧图标胶囊挤出屏幕。
        //
        // ⇒ 正确做法：**左侧只占"剩余空间 - 右侧胶囊 - 中间间隙"**，
        //   由 Flex 的 `layoutWeight(1)` 自动分配；右侧胶囊用 `flexShrink(0)` 固定不被压；
        //   中间间隙用 `margin` 表达（不用 `Blank()` —— `Blank` 在 SpaceBetween 下行为不确定）。
        //
        // 这样：三段开关宽度 = 屏宽 - 左右padding(30) - 右胶囊(约116) - 间隙(12)
        //   ⇒ 在 390vp 屏上约 **232vp**，比改造前（撑满约 360vp）明显变窄，
        //     且绝不会溢出（因为它是"剩余"而非"固定"）。
        Column() {
          groupTypeComponent({
            bookTypeNumber: this.bookTypeNumber,
            currentIndex: this.currentIndex,
            groupCoverShow: this.groupCoverShow,
            GROUP: this.GROUP
          })
        }
        .layoutWeight(1)

        // ── 右：搜索 → 三横 → 更多（顺序由用户指定）──────────────────────────
        // 三横（≡）不再由 `GroupType` 画，统一收到这里 —— 用户要求它紧跟在搜索后面、
        // 后面再接「更多」。分组行因此只负责 chip，不再管尾部按钮。
        if (this.trailingActions) {
          Row() {
            this.trailingActions()
          }
          // ⚠️ `flexShrink(0)`：绝不被左侧压缩（否则窄屏下会被挤变形/挤出屏幕）
          .flexShrink(0)
          // 与左侧开关之间的空隙（用户要求"间距大一些"）
          .margin({ left: 12 })
          // 与左侧 chip 同款玻璃（配方唯一真源 `ImmersiveMaterialUtil.glassOptions()`）
          .backgroundEffect(ImmersiveMaterialUtil.glassOptions())
          .borderRadius(21)
          // ★ 2026-10-20：**高度必须与左侧三段按钮严格等高**（用户：「三个图标按钮的胶囊
          //   高度需要和左侧的三段按钮高度对齐」）。
          //   左侧 `GlassSegment` 的实际高度 = 外层 `padding(4)*2` + chip `height(34)` = **42vp**。
          .height(42)
          .padding({ left: 12, right: 12 })
          .alignItems(VerticalAlign.Center)
        }
      }
      .padding({ left: 15, right: 15, top: 15, bottom: 10 })

      Stack() {
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
      // 滑动切档时的淡出淡入（见 `onSwipeEnd` 的注释）
      .opacity(this.contentOpacity)
      // ══ 内容区左右滑动切换档位（2026-10-21）══════════════════════════════════
      // 用户原话：「我的意思是**滑动书籍区域**，而不是那个开关，做到自然切换」。
      // ⇒ 手势挂在 Stack（书籍内容区）上，列表/宫格两种形态都覆盖。
      //
      // ⚠️ 为什么用 `PanGesture` + `onActionEnd` 而不是跟手动画：
      //   切换的是**整个列表数据**（重查数据库 + LazyForEach 重建），跟手拖拽代价过大
      //   且会有明显卡顿。这里只做"松手判定方向 + 一次切换"，体感最接近系统分段控件。
      // ⚠️ 阈值 60vp：低于此视为误触（与点击、竖向滚动区分）。
      .gesture(
        PanGesture(this.swipePan)
          .onActionStart(() => {
            this.swipeAccum = 0
          })
          .onActionUpdate((event: GestureEvent) => {
            // 只累计水平位移；竖向交给列表自己滚
            this.swipeAccum = event.offsetX
          })
          .onActionEnd(() => {
            this.onSwipeEnd()
          })
          .onActionCancel(() => {
            this.swipeAccum = 0
          })
      )
    }
  }
  // ══════════════════════════════════════════════════════════════════════════════
  // ⚠️ 2026-10-20：「列表 / 宫格」切换按钮已从本行**移出**（`ExhibitBuilder` 整个删除）。
  // 用户原话：「把列表/宫格挪进三横的弹窗里面」。
  // ⇒ 现在由 `groupTypePanel.SortSection` 里的「列表 / 宫格」分段控件负责，
  //   写入的仍然是 `@Link EXHIBIT`（经 `ShelfPrefs.setGrid()` 持久化），本组件只消费。
  // ══════════════════════════════════════════════════════════════════════════════
}
