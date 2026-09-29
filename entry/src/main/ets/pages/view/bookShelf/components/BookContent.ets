import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { Haptics } from '../../../../common/utils/Haptics';
import BasicDataSource from '../../../../common/LazyIDataSource/BasicDataSource'
import { ThemeItem } from '../../../../common/model/Theme'
import booksDao from '../../../../database/dao/BooksDao'
import { Books } from '../../../../database/entities/Books'
import BookInfoGrids from './BookInfoGrids'
import BookInfos from './BookInfos'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import { shelfEntrance } from '../../../../common/utils/EntranceWave'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'
import { FileHandler } from '../../../../common/utils/FileHandler'

@Component
export default struct BookContent {
  @State bookList:Books[] = []
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  /** App 级夜间开关：只为触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @Provide('booksDataSource') booksDataSource: BasicDataSource<Books> = new BasicDataSource<Books>()
  /**
   * 「渐次入场」波次编号（2026-09-24 新增）。
   *
   * 每开一波就 +1，通过 `@Prop` 下发给每个列表项的 `waveId`；项侧用 `@Watch('onWaveChanged')`
   * 重置并重播动画。**为什么不能只靠 `aboutToAppear`**：切分组时 `LazyForEach` 收到 `RELOAD`
   * 后不保证销毁重建键值相同的项（复用会保留 `entered = true`）⇒ 动画只会播第一次。
   */
  @State entranceWaveId: number = 0

  async aboutToAppear(): Promise<void> {
    // 种子书（2026-09-27）：首次启动把内置《默认协议》以"用户导入"同款流程入库。
    // ⚠️ 必须 await 串行 ⇒ 必然先于下方书架查询（幂等：Preferences 标志 + FileHandler
    //   静态去重，重复调用直接复用同一个 Promise）。
    await FileHandler.seedDefaultBook()
    this.getBookCount()
    if (this.bookList.length === 0) {
      this.getBookList()
    }
  }

  async getBookCount(){
    this.bookCount =  await booksDao.getBookCount({
      type:this.currentIndex,
      bookGroup:this.bookTypeNumber,
    })
  }
  @State bookCount:number = 0
  // ── EXHIBIT 补 @Watch（2026-09-24）────────────────────────────────────────
  // 需求第 5 点要求「图书列表以及九宫格动画」在**切换展示形态**时也复现。
  // 原来 EXHIBIT 没有 @Watch ⇒ 切「列表 / 宫格」只换渲染分支、不重拉数据、
  // 也就没有任何"新的一波"可播。挂上 @Watch 后复用 `changeBookType()` 这条路：
  // 它会 `currentPage = 1` 并重新 `getBookList()` ⇒ 数据落盘时开新波次。
  @Prop @Watch('changeBookType') EXHIBIT:string
  @Prop @Watch('changeBookType')searchValue:string
  @Prop @Watch('changeBookType')currentIndex: number
  @Prop @Watch('changeBookType')bookTypeNumber:number
  //更新数据累加刷新数据页面
  @StorageLink('BOOK_IS_BOOK_REFRESHING') @Watch("isRefresh")isBookRefreshing: number = 0
  /**
   * 「本次加载是否要开一波入场动画」（2026-09-24）。
   *
   * 需求第 5 点只点名了两个复现时机：**冷启动**、**点分组标签切换**（外加切列表↔宫格）。
   * 而 `BOOK_IS_BOOK_REFRESHING` 是**所有**数据变更的公共信号 —— 删除一本书、置顶、
   * 移出分组、导入书籍都会触发它。若这些也重播整屏入场，用户每删一本书都要看一屏"翻牌"，
   * 是噪音而不是反馈 ⇒ 这些路径只刷新数据、**不开新波次**。
   * （不开波次时 `EntranceWave.delayFor()` 返回 -1，列表项直接以终态渲染。）
   */
  private animateOnNextLoad: boolean = true
  isRefresh(){
    this.currentPage = 1
    // if (this.booksDataSource.totalCount() > 0){
    //   this.booksDataSource.clear()
    // }
    if (this.isBookRefreshing >= 0) {
      this.animateOnNextLoad = false
      // ⚠️ bookCount 必须随刷新重取（2026-09-24 导入修复）：它只是 aboutToAppear 时
      // 取过一次的旧值，而 onReachEnd 的续页门槛是 `bookList.length < this.bookCount`
      // ⇒ 导入新书后旧 count 偏小，`loadMoreBooks` 永远不触发，
      // 新书只能看到第一页 21 本，重启应用（重取 count）才恢复。
      this.getBookCount()
      this.getBookList()
    }
  }

  changeBookType(){
    this.currentPage = 1
    if (this.bookTypeNumber !== 1 && this.bookTypeNumber !== 5) {
      if (this.bookCount === 0){
        this.getBookCount()
      }
      // if (this.booksDataSource.totalCount() > 0) {
      //   this.booksDataSource.clear()
      // }
      this.getBookList()
    }
  }

  async getBookList(){
    const list: Books[] = await booksDao.searchPage({
      type:this.currentIndex,
      bookGroup:this.bookTypeNumber,
      order:this.searchValue
    }, this.currentPage)
    this.bookList = list
    // ── 开一波「渐次入场」（2026-09-24）──────────────────────────────────────
    // ★ 位置很关键：必须在**数据就绪的这一刻**才 begin()。
    //   `EntranceWave.delayFor()` 以 `Date.now()` 起算；若在发起查询之前就 begin()，
    //   查询耗时会被算进波次窗口，前几项的延迟被白白吃掉（甚至整波已经过半）。
    // ★ 先 begin() 再 ++waveId：这样子组件的 `@Watch` 一触发，读到的就是刚开的这一波。
    // ★ `animateOnNextLoad`：只有"冷启动 / 切分类 / 切分组 / 切列表↔宫格"才开波次；
    //   纯数据刷新（删除 / 置顶 / 导入 / 移动分组）不开（见该字段注释）。
    if (this.animateOnNextLoad) {
      shelfEntrance.begin()
      this.entranceWaveId++
    }
    this.animateOnNextLoad = true
    // ★ LazyForEach 的数据源（2026-09-24 起真正启用）。
    //   改前：`ForEach(this.bookList, …)` 会**一次性创建全部**列表项，书架上百本时
    //   冷启动要建上百个节点。官方《LazyForEach：数据懒加载》原文：
    //     「当 LazyForEach 用于滚动容器时，框架会根据滚动容器可视区域按需创建组件，
    //       当组件滑出可视区域外时，框架会销毁并回收组件以降低内存占用。」
    this.booksDataSource.resetAllData(list)
  }

  @State isLoading: boolean = false
  @State currentPage:number = 1
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  async loadMoreBooks() {
    if (!this.isLoading) {
      this.isLoading = true;
      this.currentPage += 1;

      const moreBooks = await booksDao.searchPage({
        type:this.currentIndex,
        bookGroup:this.bookTypeNumber,
        order:this.searchValue,
      }, this.currentPage);
      if (moreBooks.length > 0) {
        this.bookList.push(...moreBooks);
        // ★ 追加分页**刻意不开新波次**（需求第 7 点）：
        //   若此刻波次仍在进行，新滚进来的项会按 `delayFor()` 的结果错峰入场；
        //   若波次已经结束，`delayFor()` 返回 -1 ⇒ 项侧直接把 `entered` 置 true，
        //   **一帧动画都不产生**，等于"直接渲染" —— 这正是用户要的
        //   「动画已经停止，则不渲染了」。
        for (const more of moreBooks) {
          this.booksDataSource.appendData(more)
        }
      }
      this.isLoading = false;
    }
  }
  scroller: Scroller = new Scroller()
  build() {
    if (this.isLoading) {
      Row(){
        LoadingProgress()
          .color(this.theme.mainColor)
          .width('50%')
        Text('加载中...')
      }
    } else if (this.bookList.length === 0){
      Column() {
        Image($r('app.media.no_record')).width(200).height(200)
        Text('暂无浏览记录')
          .fontSize(12)
          .fontColor(ShelfColors.textSub())
          .fontWeight(500)
          .padding(5)
      }
      .margin({ top: 120 })
    } else {
      List({
        space:10,
        scroller:this.scroller
      }){
        // ── ForEach → LazyForEach（2026-09-24，需求第 7 点）──────────────────
        // 官方《LazyForEach：数据懒加载》使用限制原文：
        //   ·「LazyForEach 必须在容器组件内使用，仅有 List、ListItemGroup、Grid、Swiper
        //      以及 WaterFlow 组件支持数据懒加载（可配置 cachedCount 属性，即只加载可视部分
        //      以及其前后少量数据用于缓冲）」
        //   ·「LazyForEach 在每次迭代中，必须创建且只允许创建一个子组件；即 LazyForEach 的
        //      子组件生成函数**有且只有一个根组件**」⇒ 下面 ListItem 是唯一根，if/else 在其内部。
        //   ·「键值生成器必须针对每个数据生成唯一的值，如果键值相同，将导致键值相同的 UI
        //      组件渲染出现问题」⇒ 沿用原来的 id 优先策略，并在**兜底分支**追加下标，
        //      彻底杜绝"无 id 且无 bookUrl"的书互相撞键。
        LazyForEach(this.booksDataSource, (item: Books, index: number) => {
          ListItem(){
            if (this.EXHIBIT === '宫格') {
              BookInfoGrids({
                book: item,
                // 渐次入场：下标决定错峰延迟，waveId 决定"要不要重播"
                itemIndex: index,
                waveId: this.entranceWaveId,
                // 一镜到底（2026-09-23）：封面节点 id（点击时按它拍几何）。
                // 列表/宫格前缀不同 ⇒ 切形态瞬间新旧两份组件共存也不会撞 id。
                longtakeId: 'ltCoverG' + index
              })
            } else {
              BookInfos({
                book: item,
                itemIndex: index,
                waveId: this.entranceWaveId,
                longtakeId: 'ltCoverL' + index
              })
            }
          }
        }, (item: Books, index: number): string => {
          // ⚠️ 键值必须带上**会变、且影响封面显示**的字段（2026-09-29 修"置顶角标/弹窗字样不联动"）：
          // LazyForEach 对键值相同的项**复用旧组件、不重绑数据** —— 旧键 `'b'+id` 在置顶前后
          // 不变 ⇒ 复用组件里的 Books 还是旧对象：封面"置顶"角标不出现、长按弹窗（捕获的
          // 正是这个旧对象）永远显示"置顶"。管理页是普通 ForEach + 全量重查 + 重排重建，
          // 所以那边一直正常 —— 以它为准，把变化特征并进键值：
          //   · isTop：置顶/取消置顶 ⇒ 角标与弹窗字样立即同步（重建就一条，开销可忽略）；
          //   · durChapterTime：读书回来"读到第X章"文案同理会停留旧值，一并修掉。
          const flag: string = (item.isTop ? 'T' : 'F') + (item.durChapterTime ?? 0)
          return item.id !== undefined ? 'b' + item.id + flag
            : (item.bookUrl !== undefined && item.bookUrl.length > 0 ? 'u' + item.bookUrl + flag
              : 'n' + item.bookName + '#' + index)
        })
      }
      .alignListItem(ListItemAlign.Center)
      .layoutWeight(1)
      .lanes(this.EXHIBIT === '宫格' ? 3 : 1)
      .scrollBar(BarState.Off)
      // ── 预加载区大小（2026-09-24，需求第 7 点「省资源」）────────────────────
      // SDK `component/list.d.ts:1195`：`cachedCount(value: number): ListAttribute;`
      // ⚠️ 单位是**行**不是项，SDK 原文（同文件 `:1175-1178`）：
      //   「When **cachedCount** is set for the list, the system preloads and lays out the
      //     **cachedCount**-specified number of **rows** of list items both above and below the
      //      currently visible area of the list. When calculating the number of rows for list
      //      items, the system takes into account the number of rows from the list items within
      //      a list item group.」
      //   默认值原文（`:1184-1186`）：「Default value: **number of nodes visible on the screen,
      //      with the maximum value of 16**」—— 即默认会把"一整屏"都预建出来。
      // 取 **3 行**：可视区上下各留 3 行缓冲，明显小于默认的一屏，滚动时又足够避免白块
      // （SDK 注释里点名的最佳实践就叫《Minimizing White Blocks During Swiping》）。
      // 宫格模式（`lanes(3)`）下同样是"3 行"= 上下各 9 个格子，无需为两种形态分别取值。
      .cachedCount(3)
      // 悬浮页签条是**叠在列表之上**的（barOverlap 的官方语义）⇒ 给内容末尾留出条高，
      // 滚到底时最后一本书不会被压住。用 `contentEndOffset` 而不是给容器加 padding：
      // 前者只偏移**内容末尾**、不动列表盒子，因此不会露出窗口底色（真机上就是"底部白块"）。
      .contentEndOffset(ImmersiveMaterialUtil.tabsContentBottomInset())
      .onReachEnd(() => {
        if (this.bookList.length < this.bookCount) {
          this.loadMoreBooks()
        }
      })
      .margin({
        // ★ 2026-09-23 用户反馈：「书籍左侧应该与分组对齐，现在太贴边了」。
        //   分组栏（`GroupType`）左内缩 15vp，这里给列表同样的 15vp（左右对称）
        //   ⇒ 书籍首列与「分组/全部/未分组/本地」左边缘对齐。
        left: 15,
        right: 15,
        bottom: 20
      })
    }
  }
}