import { ThemeStorageKey } from '../../../../common/constants/Theme'
import ShelfPrefs, { SortDir, SortKey } from '../../../../common/utils/ShelfPrefs'
import BasicDataSource from '../../../../common/LazyIDataSource/BasicDataSource'
import { ThemeItem } from '../../../../common/model/Theme'
import booksDao from '../../../../database/dao/BooksDao'
// 建表/迁移就绪信号（2026-10-20 闪退修复，见 aboutToAppear 注释）
import DataBase from '../../../../database/index'
import { Books } from '../../../../database/entities/Books'
import { BooksTypeSearchParams } from '../../../../database/types/BooksType'
import BookInfoGrids from './BookInfoGrids'
import BookInfos from './BookInfos'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import { shelfEntrance } from '../../../../common/utils/EntranceWave'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'
import { FileHandler } from '../../../../common/utils/FileHandler'
import { showMessage } from '../../../../componets/common/promptShow'
// 外部文件接收（2026-10-19 双响炮）：EntryAbility 只登记，这里（DB 已就绪）才真正导入
import { IncomingFiles, INCOMING_TICK } from '../../../../common/format/IncomingFiles'
import { intl } from '@kit.LocalizationKit'

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
    // ★★ 2026-10-21：**只在"手里没数据"时才显示 loading** ★★
    // 用户录像反馈：「三段切换，会有一个巨大的加载中一闪而过。」
    // 根因：切档会让 `BookContent` 销毁重建（`BookContentRefresh` 的分支变了），
    //   新实例 `bookList = []` ⇒ 若此时无条件置 `isLoading = true`，就会闪一个大 loading。
    // ⇒ 只有 `bookList` 为空（真正的首次加载/冷启动）才置 true；
    //   有数据时全程静默查询，配合父级淡入淡出，切换观感连续。
    // ★ 2026-10-21 三修：**再用"延迟显示"兜一层** —— 即使首帧无数据，
    //   只要查询在 250ms 内回来，`showLoadingUi` 就永远不会变 true ⇒ 一帧都不闪。
    //   这样"快速连点切换"也完全看不到 loading（见 `showLoadingUi` 的注释）。
    if (this.bookList.length === 0) {
      this.isLoading = true
      this.scheduleLoadingUi()
    }
    // ★★ 2026-10-20 闪退修复：**必须先等建表/补列完成** ★★
    // 真机证据（`docs/日志.md`）：
    //   `19:46:16.193 duplicate column name: finishedTime` ← 迁移还在跑
    //   `19:46:16.195 查询成功！查询行数：`                   ← 本组件已经在查了
    //   `19:46:16.246 GetColumnIndex:Failed, columnName : fil***` → `Kill Reason:Js Error`
    // `whenReady()` 永不 reject（迁移失败也放行），所以不会把首屏卡死；
    // 它只保证"表结构已定"这个前提成立，缺口由 `DbUtil.parseResultSet` 兜底。
    await DataBase.whenReady()
    await FileHandler.seedDefaultBook()
    // 冷启动进来的「分享 / 用其他应用打开」文件（2026-10-19）：此时 DB 已就绪
    await this.importIncomingFiles()
    // 存量书的文件大小回填（2026-10-19，排序面板「文件大小」用；内部有一次性标志，
    // 只有首次真的会扫一遍。失败/超时都不阻塞书架首屏，见该方法的注释）
    await booksDao.backfillFileSize()
    this.getBookCount()
    // 无论有无旧数据都查一次（`isLoading` 已在方法开头按"有无数据"决定过，
    // 有数据时不会显示 loading ⇒ 切档无闪烁）
    this.getBookList()
  }

  /** 外部文件信号（应用已在后台时被唤起 ⇒ aboutToAppear 不会再跑，靠它） */
  @StorageLink(INCOMING_TICK) @Watch('onIncomingFiles') incomingTick: number = 0

  private onIncomingFiles(): void {
    this.importIncomingFiles()
  }

  /**
   * 导入"分享进来 / 用其他应用打开"的文件。
   *
   * ⚠️ 必须逐本 `await` 到"拷贝+写库"完成再刷书架（2026-09-24 导入竞态的老教训，
   *    见 `IndexShelf.pickLocalBooks` 同款注释）；`CopyFile` 内部已 await 写库。
   * ⚠️ 失败不弹第二次 toast：`CopyFile` 自己会 showMessage。
   */
  private async importIncomingFiles(): Promise<void> {
    const uris: string[] = IncomingFiles.take()
    if (uris.length === 0) {
      return
    }
    let ok = 0
    for (const uri of uris) {
      try {
        const success: boolean = await FileHandler.CopyFile(uri, this.currentIndex)
        if (success) {
          ok++
        }
      } catch (e) {
        // CopyFile 内部已提示，这里只记日志
        console.error('incoming import failed: ' + JSON.stringify(e))
      }
    }
    if (ok > 0) {
      showMessage(`已导入 ${ok} 个文件`)
      // 广播书架刷新（与 WiFi 传书同一信号，见 WifiBookServer:2506）
      this.isBookRefreshing = this.isBookRefreshing + 1
    }
  }

  async getBookCount(){
    // 与列表**同一份查询口径**（2026-10-19）：否则「最近」模式下
    // 续页门槛用的是分组计数，`onReachEnd` 会算错 ⇒ 翻页提前停止。
    this.bookCount =  await booksDao.getBookCount({
      type:this.currentIndex,
      bookGroup: this.onRecentChip ? 2 : this.bookTypeNumber,
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
  @Prop @Watch('changeBookType') bookTypeNumber:number
  /**
   * 排序变更信号（2026-10-19）。
   *
   * ⚠️ 为什么用 `@StorageLink` 而不是 `@Prop`：
   *   排序面板最终挂在**分组管理弹窗**里（`groupTypePanel.SortSection`，需求指定的
   *   "隐藏分组下面"），它与书架列表**不是父子关系**（一个是 @CustomDialog 内容、
   *   一个是页面内的 List）⇒ 只能靠 AppStorage 这条公共通道广播。
   *   面板里 `SHELF_SORT_TICK++`，这里 `@Watch` 重查并按新顺序渲染。
   * **弹窗不会关**（用户要求），所以这是唯一的驱动路径。
   */
  @StorageLink('SHELF_SORT_TICK') @Watch('changeBookType') sortTick: number = 0
  /**
   * 「最近」chip 状态的**跨组件**通道（同上原因，面板里一排序就要退出「最近」）。
   * 与 `IndexShelf` / `GroupType` 的 `@Link onRecentChip` 是**同一份语义**，
   * 但那条链只覆盖"分组行 → 页面"；分组管理弹窗不在这条链上 ⇒ 补一条 AppStorage。
   */
  @StorageLink('SHELF_RECENT_CHIP') @Watch('changeBookType') onRecentChip: boolean = true
  //更新数据累加刷新数据页面
  @StorageLink('BOOK_IS_BOOK_REFRESHING') @Watch("isRefresh")isBookRefreshing: number = 0
  /**
   * dock 切回书架信号（2026-10-12）：Index.ets 的 onAnimationStart 在切到
   * 书架 tab（targetIndex=0 ∧ index≠0）时自增本值 ⇒ @Watch 触发动画波次。
   * 为什么不走 isRefresh：isRefresh 是所有数据变更的公共信号，触发它会导致
   * getBookList() 重查数据库；而 dock 切回书架只要动画不需要重查。
   */
  @StorageLink('shelfDockReturn') @Watch('onDockReturn') dockReturnCount: number = 0
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

  /**
   * dock 切回书架时触发（2026-10-12）。
   *
   * 目标：给切回来的书单一次干净的入场动画。不能走清空+重查（冷启动那条路），
   * 因为冷启动时 dataSource 本来就是空的。切回来时书在且已渲染在终态。
   *
   * ⚠️ 2026-10-19 用户口径变更：「只保留冷启动进入动画，进入后 dock 切换回书架，
   *    书架书籍无需动画。」⇒ 本方法的 `begin()` 会被 `EntranceWave.allowColdStartWave()`
   *    **闸掉**（冷启动窗口早已过去），`entranceWaveId++` 仍照旧发出，子项拿到
   *    `delayFor() === -1` 直接把 `entered` 置 true ⇒ 终态渲染、一帧动画都没有。
   *    这里**不减代码**：闸门集中在 `EntranceWave.COLD_START_ONLY` 一个常量上，
   *    改回 `false` 即完整恢复"dock 切回重播"的旧行为。
   */
  onDockReturn(): void {
    if (this.booksDataSource.totalCount() > 0) {
      this.animateOnNextLoad = true
      shelfEntrance.begin()
      this.entranceWaveId++
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

  /**
   * 组装查询参数（**唯一真源**，`getBookList` / `loadMoreBooks` / `getBookCount` 三处共用）。
   *
   * ── 2026-10-19 需求第 3 / 6 条 ─────────────────────────────────────────────
   * 用户原话：「最近只有一种排序就是最近↓，然后其他的标签包括后续用户自定义的标签分组
   *   都会随着排序进行排序。」
   * ⇒ 两条互斥路径：
   *   ① `onRecentChip` ⇒ **全部书 + 锁死最近阅读降序**（不受排序面板影响）；
   *   ② 否则          ⇒ 按 `bookTypeNumber` 分组 + `ShelfPrefs` 的档位与方向。
   * `bookGroup = 2` 在 `BooksDao.buildWhereClause` 里表示"不加分组条件"= 全部书
   * （原文见该方法的注释：「`bookGroup = 2` → 不加分组条件（"全部"）」）。
   */
  private buildQueryParams(): BooksTypeSearchParams {
    if (this.onRecentChip) {
      return {
        type: this.currentIndex,
        bookGroup: 2,
        sortKey: SortKey.RECENT_READ,
        sortDir: SortDir.DESC
      };
    }
    return {
      type: this.currentIndex,
      bookGroup: this.bookTypeNumber,
      sortKey: ShelfPrefs.getSortKey(),
      sortDir: ShelfPrefs.getSortDir()
    };
  }

  /**
   * 首字母（拼音）排序 —— **在内存里排**，SQL 侧排不了。
   *
   * ── 为什么必须用官方能力而不是自建拼音表 ──────────────────────────────────
   * 用户裁定：「就用你说的官方原生能力，然后我们进行手动测试」。
   * 官方取证：
   *   · SDK `@ohos.intl.d.ts:1506` `export class Collator`，
   *     `:1527 constructor(locale: string | Array<string>, options?: CollatorOptions)`，
   *     `:1542 compare(first: string, second: string): number`；
   *   · `CollatorOptions.collation`（`:1461`）的官方取值表里明确包含
   *     `:1438`「**pinyin**: Pinyin sorting.」与 `:1432`「**gb2312**: Pinyin sorting,
   *       only for Chinese.」
   *   ⇒ 用 `collation: 'pinyin'` 让系统做汉字拼音排序，不需要任何映射表。
   *
   * ⚠️ 【待验证】本机无法验证 `pinyin` 这个 collation 在鸿蒙设备上对**中英混排书名**
   *   的实际顺序（属系统行为，只能在真机上手动确认）。若真机上退化成码点序，
   *   改 `collation` 为 `'gb2312'` 即可（同一取舍表的另一项），
   *   或退回到 `Transliterator('Any-Latn')` 先转拼音再比（官方 FAQ
   *   `FAQ/无障碍和本地化/本地化开发_Localization/如何使用实现汉字转拼音/faqs-localization-11`
   *   给出的写法：`i18n.Transliterator.getInstance('Any-Latn').transform('中国')`）。
   *
   * ⚠️ 只在**当前页**内排序：分页是 SQL 侧 LIMIT，跨页的全局拼音序无法在内存里保证。
   *   这是当前架构的已知限制，真机上若觉得"翻页后顺序跳"再单独讨论（需要落拼音列）。
   */
  private sortByPinyin(list: Books[], dir: SortDir): Books[] {
    try {
      const collator = new intl.Collator('zh-Hans', { collation: 'pinyin' });
      const sorted: Books[] = list.slice();
      sorted.sort((a: Books, b: Books): number => {
        const r: number = collator.compare(a.bookName ?? '', b.bookName ?? '');
        return dir === SortDir.ASC ? r : -r;
      });
      return sorted;
    } catch (e) {
      // 设备不支持该 collation ⇒ 保持 SQL 侧给的 bookName 序，绝不抛到界面上
      console.error('sortByPinyin failed: ' + JSON.stringify(e));
      return list;
    }
  }

  async getBookList(){
    // ★ 2026-10-21 二修：**不再在查询开始时置 isLoading**。
    //
    // ── 一修为什么不行（真机录像实证）─────────────────────────────────────────
    // 一修写的是「进方法先 `isLoading = true`，build 走加载中分支」。
    // 但用户录像显示：三段切换时**一个巨大的"加载中"一闪而过**。
    // 根因有两层：
    //   ① `BookContentRefresh` 的分支（`onRecentChip` / `bookTypeNumber`）不同时，
    //      `BookContent` 会**销毁重建** ⇒ 新实例 `bookList = []`、`isLoading = false`，
    //      随即 `aboutToAppear` 调本方法又置 true ⇒ 一帧 loading 大图标；
    //   ② 就算不重建，每次查询都闪一次 loading 也是噪音。
    //
    // ── 现在的做法 ────────────────────────────────────────────────────────────
    // 查询全程**不动 `isLoading`**，只在"确实没有数据可显示"时才让 build 显示 loading
    //   （判断写在 build 里：`isLoading && bookList.length === 0`）。
    // 这样：
    //   · 有旧数据（切档场景）⇒ 继续显示旧列表，查完静默替换（父级还有淡入淡出兜着）；
    //   · 真正首次加载（冷启动）⇒ `bookList` 为空，`aboutToAppear` 里显式置一次
    //     `isLoading = true`，用户看到正常的加载提示。
    try {
      const params: BooksTypeSearchParams = this.buildQueryParams();
      let list: Books[] = await booksDao.searchPage(params, this.currentPage)
      // 首字母档：SQL 只能给 bookName 兜底序，真正的拼音序在这里做（见 sortByPinyin 注释）
      if (!this.onRecentChip && ShelfPrefs.getSortKey() === SortKey.PINYIN) {
        list = this.sortByPinyin(list, ShelfPrefs.getSortDir());
      }
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
    } finally {
      // 只有真正"加载完"才放开；同时**取消待显示的 loading**
      // （数据在 250ms 内回来 ⇒ 定时器被取消 ⇒ 一帧 loading 都不显示）
      this.isLoading = false
      this.cancelLoadingTimer()
    }
  }

  @State isLoading: boolean = false
  /**
   * **UI 上实际显示的 loading 标志**（2026-10-21 新增，解决"快速切换仍闪"）。
   *
   * ── 为什么不能直接用 `isLoading` ──────────────────────────────────────────
   * 用户反馈：「点击得快还是会有这个加载中…就没法在快速切换的时候完全删除吗」。
   * 根因：切档会重建 `BookContent`（分支变了），新实例 `bookList = []`
   *   ⇒ `isLoading && bookList.length === 0` 成立 ⇒ 立刻闪一帧 loading。
   *   而查询本身可能只要 20~50ms ⇒ 这一帧纯属"来得太快"的噪音。
   *
   * ── 做法：**延迟显示**（业界标准，避免闪烁）──────────────────────────────
   * 需要 loading 时**不立刻显示**，先挂一个 `LOADING_DELAY_MS` 定时器；
   *   · 数据在延迟内回来（快速切换）⇒ 取消定时器 ⇒ **一帧都不显示**；
   *   · 数据确实慢（>延迟）⇒ 到点才显示 loading（用户需要"有反馈"）。
   * ⇒ 快速连点完全无感，慢查询仍有提示。
   */
  @State showLoadingUi: boolean = false
  /** 延迟显示 loading 的定时器句柄（-1 = 无） */
  private loadingTimer: number = -1
  /** 延迟阈值（ms）：低于它的查询不显示 loading。250 是"人类感知卡顿"的经验下限 */
  private static readonly LOADING_DELAY_MS: number = 250

  /** 取消待显示的 loading（数据已就绪时调用） */
  private cancelLoadingTimer(): void {
    if (this.loadingTimer !== -1) {
      clearTimeout(this.loadingTimer)
      this.loadingTimer = -1
    }
    if (this.showLoadingUi) {
      this.showLoadingUi = false
    }
  }

  /** 需要 loading 时调用：延迟 `LOADING_DELAY_MS` 后才真正显示 */
  private scheduleLoadingUi(): void {
    if (this.loadingTimer !== -1) {
      return
    }
    this.loadingTimer = setTimeout(() => {
      this.loadingTimer = -1
      // 到点时若仍在加载中，才显示（数据已回来的话 isLoading 已是 false）
      if (this.isLoading) {
        this.showLoadingUi = true
      }
    }, BookContent.LOADING_DELAY_MS)
  }
  @State currentPage:number = 1
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  async loadMoreBooks() {
    if (!this.isLoading) {
      this.isLoading = true;
      this.currentPage += 1;

      const moreBooks = await booksDao.searchPage(this.buildQueryParams(), this.currentPage);
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
  /**
   * 一镜到底的封面节点 id。
   *
   * ★★ 2026-10-09 修复（用户实测：「回落甚至都变到第二本书的位置去了」）★★
   * 旧实现是 'ltCoverL' + index —— **按下标**。而书架会因为「读完一本 / 置顶」重排，
   * 同一个下标在重排前后指向**不同的书** ⇒ 点击时拍到的几何属于别人，
   * 回落自然飞错位置。
   * ⇒ 改用 Books.id（数据库主键，跟着书走）。重排只会让同一个 id 换个屏幕位置，
   *   那正是我们要的"实时反映书真实所在的位置"。
   * 极端兜底：id 缺失时退回下标（保证 id 唯一，绝不返回相同字符串）。
   */
  private longtakeIdFor(prefix: string, item: Books, index: number): string {
    const key: string = item.id !== undefined && item.id !== null ? String(item.id) : ('i' + index);
    return prefix + key;
  }
  build() {
    // ★★ 2026-10-21：**只在"首次加载"时显示 loading，切换档位时不闪** ★★
    // 用户反馈：「三段切换，会有一个巨大的加载中一闪而过，有点难受。」
    // 根因：`isLoading` 一置 true 就把整屏内容换成 `LoadingProgress`（还占满宽度）
    //   ⇒ 每次切档都闪一下大图标。
    // ⇒ 两条修正：
    //   ① 只有 `bookList` 还是空（真正的首次加载）才显示 loading；
    //      已有数据时静默查询、查完直接替换（配合父级淡入淡出，观感连续）；
    //   ② loading 态也**不再撑满整屏**（去掉 `width('50%')`，改为居中小尺寸），
    //      万一真出现也不刺眼。
    if (this.showLoadingUi && this.bookList.length === 0) {
      Row({ space: 8 }) {
        LoadingProgress()
          .color(this.theme.mainColor)
          .width(24)
          .height(24)
        Text('加载中...')
          .fontSize(13)
          .fontColor(ShelfColors.textSub())
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .margin({ top: 120 })
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
                // ★ 2026-10-09 三个问题之一的正解：**id 必须用稳定的"书身份"，不能用下标**
                //   旧实现是 `'ltCoverG' + index` / `'ltCoverL' + index`。而书架会因为
                //   「读完一本 / 置顶」而**重排**（用户原话：「进入某一本书，退出，这个书会到最上方」）
                //   ⇒ 同一个 `ltCoverL2` 在重排前后指向**不同的书**
                //   ⇒ 一镜到底的起飞/回落几何落到别人身上（用户实测：「回落甚至都变到第二本书的位置」）。
                //   改用 `Books.id`（数据库主键，永远跟着书走）后，重排只会让同一个 id
                //   换个屏幕位置 —— 那正是我们要的"实时更新书真实所在的位置"。
                longtakeId: this.longtakeIdFor('ltCoverG', item, index)
              })
            } else {
              BookInfos({
                book: item,
                itemIndex: index,
                waveId: this.entranceWaveId,
                longtakeId: this.longtakeIdFor('ltCoverL', item, index)
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
          //   · customCoverUrl（2026-10-01 修"换封面必须重启才生效"）：封面样式弹窗保存后
          //     广播 BOOK_IS_BOOK_REFRESHING ⇒ BookContent 重查数据库，但键值若不含封面
          //     字段，LazyForEach 对键值相同的项**复用旧组件、不重绑数据** ⇒ 封面停在旧值。
          //     与 CoverStyleDialog 的广播是同一条链的两半，缺一不可。
          //   · bookName（2026-10-05 修"改名后列表还是旧名"）：改名是**级联改名**
          //     （见 common/utils/BookRename.ets 的唯一清单），但 LazyForEach 不认数据变了，
          //     只认键值变了 ⇒ 键值必须带上书名；规范 §5.3/§6 已把这条列为硬要求
          //     （`docs/标准-弹窗与按钮统一规范.md:201,212`「改名/换封面不刷新」）。
          const flag: string = (item.isTop ? 'T' : 'F') + (item.durChapterTime ?? 0)
            + (item.customCoverUrl ?? '') + (item.bookName ?? '')
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
      // 2026-10-01 改用 dockContentEndOffset（含安全区实测值）：旧值 72 不含
      // bottomRectHeight，手势机上 dock 实际覆盖 ~92 ⇒ 最后一本书仍被压角
      //（用户实测反馈"最后一本书应该停在 dock 上面"）。
      .contentEndOffset(ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight))
      .onReachEnd(() => {
        if (this.bookList.length < this.bookCount) {
          this.loadMoreBooks()
        }
      })
      // ★★ 2026-10-11 删掉原来的 `bottom: 20`（自 d2b00b5 首次导入起就有，全仓无注释、无理由）★★
      //   它把**列表盒子本身**截在"屏幕底往上 20vp"，于是最后一行书永远画不进最底下那一条。
      //   真机实测（`devecocli ui layout` dump，Mate 80 Pro Max 1320×2848，密度 3.25）：
      //     · 书架 List 盒子 = [50, 668 → 1270, **2781**] ⇒ 底边比屏幕底（2848）少 67px ≈ 20vp；
      //     · 对照设置页 MySetPage 的 List = [0, 293 → 1320, **2848**] ⇒ 铺到屏幕最底。
      //   ⇒ 用户看到的就是这 20vp：「最下面一行书被挡住 / 手势条那一行有颜色、有东西 /
      //     不是直接从屏幕到最底端」——旧版那里还叠着 HDS 页签的背板蒙层（`gradientMask`，
      //     已在 `Index.ets` 关掉），所以更明显。两处修完才是真正的"贯通"。
      //   ⚠️ 底部避让**本来就由上面那行 `contentEndOffset` 负责**（它只偏移内容末尾、不动盒子，
      //     滚到底时最后一本书仍停在 dock 上方）⇒ 删掉这个外边距不会让书被 dock 压住。
      //   回退：把 `bottom: 20` 加回来即恢复旧观感（最底 20vp 空白）。
      //   ★★ 【通用规则 · 写给后来者】滚动容器（List / Scroll / Grid / WaterFlow）**盒子自身的
      //     底部 margin / padding 会把内容截在屏幕底以上**，在主题色底上就是一条"内容到不了底"的
      //     空白带。需要底部让位时一律用 `contentEndOffset`（只动内容末尾）或给**内容**加内边距，
      //     **不要再给盒子留底部外边距**。排查过程见 `docs/底部手势区贯通-排查记录.md`。
      .margin({
        left: 20,
        right: 20
      })
    }
  }
}