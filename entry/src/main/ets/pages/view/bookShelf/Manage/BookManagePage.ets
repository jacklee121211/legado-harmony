import bookListManage from './bookManage/bookListManage';
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import { Haptics } from '../../../../common/utils/Haptics';
import {showMessage} from '../../../../componets/common/promptShow'
import confirmDialogExample from '../../../../componets/common/confirmDialog';
import BookFolderManages from './bookManage/BookFolderManages';
import hideDialogExample from '../../../../componets/common/hideDialog';
import booksDao from '../../../../database/dao/BooksDao';
import { Books } from '../../../../database/entities/Books';
import { buttonList } from '../../../../componets/dataList/buttonList';
import booksUtil from '../../../../common/utils/booksUtils';
import BookSelectGroupDialog from '../components/dialog/BookSelectGroupDialog';
import BookGroupsDao from '../../../../database/dao/BookGroupsDao';
import { BookGroups } from '../../../../database/entities/BookGroups';
import bookGroupUtil from '../../../../common/utils/bookGroupUtils';
import AddToBookListDialog from '../components/dialog/AddToBookListDialog';
import Header from '../../../../componets/common/Header';
import WorksBookLists from '../Shelf/WorksBookLists';
import worksListsDao from '../../../../database/dao/WorksListsDao';
import { WorksLists } from '../../../../database/entities/WorksLists';
import worksListsUtils from '../../../../common/utils/WorksListsUtils';
import { ThemeItem } from '../../../../common/model/Theme';
import { ThemeStorageKey } from '../../../../common/constants/Theme';
import AppRouter, { BookManageRouteParam } from '../../../../common/router/AppRouter';
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode';
// ── 分享/碰一碰（2026-09-30 回填，官方取证见本文件 manageShare/注释）──────────
import { systemShare, harmonyShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { FileHandler } from '../../../../common/utils/FileHandler';
import UiMotion, { runJellyClick } from '../../../../common/utils/UiMotion';
// ── 底部操作栏迁 HDS 悬浮页签（2026-10-12 用户要求「直接改，改成HDS」）────────────
// 材质 `systemMaterialEffect` 是 HDS 组件专属（SDK `@hms.hds.hdsBaseComponent.d.ets:5380`
// 的 `HdsTabsFloatingStyle`），普通组件的 `CommonMethod` 上没有对应字段
// （`…\ets\component\common.d.ts` 只有 `backgroundBlurStyle` / `backgroundEffect`）。
// ⇒ 要与书架 dock 完全同款，必须用同一个 HdsTabs 悬浮栏实现。
import {
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  hdsMaterial
} from '@kit.UIDesignKit';
// 页签栏目标宽度要按屏宽算（`manageBarWidth()`）⇒ 需要 `display`。
import { display } from '@kit.ArkUI';

/**
 * 管理跳转页面
 *
 * 迁 Navigation 第 4 期：去掉 `@Entry` + 补 `export default`，
 * 参数由 `Index.appRoutes()` 经 `initParam` 注入（原来是 `router.getParams()`）。
 */
@Component
export default struct BookManagePage {
  /**
   * 由 `Index.appRoutes()` 注入；未注入时用零值占位
   * （原来这里会直接崩，因为 `router.getParams()` 返回 undefined 时取属性就抛了）。
   *
   * ⚠️ 字段名**不能**叫 `initParam` —— 编译器原文告警：
   *    「Methods, properties and accessors in structures decorated by '@Component'
   *      and '@ComponentV2' cannot have name as 'initParam'.」
   * 所以新建的页面一律用 `routeParam`。
   */
  routeParam: BookManageRouteParam = { currentIndex: 0, EXHIBIT: '', bookTypeNumber: 0 }
  @State currentIndex: number = 0
  @State EXHIBIT: string = ''
  @State bookTypeNumber:number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @State isAddShelfShow:boolean = false
  @State topTitle:string = '置顶'
  @State bookList:Books[] = []
  @State checkLists: Record<number, boolean> = {}
  @State checkListNumber:number[] = []
  @State bookGroups:BookGroups[] = [] // 分组
  @State worksLists:WorksLists[] =[] //书单
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') @Watch('getGroupList')BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级深浅色：订阅只为深浅切换时触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /**
   * 判定「置顶 / 取消置顶」按钮该显示哪个文字（用户口述规则，见 `manageTop()` 十修注释）。
   *
   * 规则：选中项**全部已置顶** ⇒ 「取消置顶」；**只要有一个未置顶**（含混合）⇒ 「置顶」。
   * （⇒ 混合选择点一下 = **全部置顶**，不是"逐个反转"。）
   *
   * ══════════════════════════════════════════════════════════════════════════
   * 2026-10-12 十修：修掉旧实现的两个计数问题
   * ══════════════════════════════════════════════════════════════════════════
   * ① **用 `filter` 当循环**：旧写法 `this.bookList.filter((item)=>{ ...计数... })`
   *    —— `filter` 的返回值被丢弃，靠回调里的副作用累加 `allTopNumber`。
   *    能跑但语义错位（`filter` 是筛选、不是遍历），后来者极易误改成
   *    `allTopNumber = this.bookList.filter(...)` 而破坏逻辑 ⇒ 改成 `for` 明确遍历。
   * ② **可能重复计数**：旧写法在内层又写了一次"匹配就 ++"，
   *    若同一 id 在数据里出现多条（列表重查/去重不严时可能），
   *    `allTopNumber` 会 > `checkListNumber.length` ⇒ `===` 判定失败
   *    ⇒ 明明全已置顶却显示「置顶」（点下去变成"再置顶一次"，用户看到"没反应"）。
   *    修法：对每个选中 id **只判断一次**，命中即 `break`（一个 id 最多 +1）。
   */
  selectIsAllTop(){
    if (this.checkListNumber.length <= 0){
      this.topTitle = '置顶'
      return
    }
    let allTopNumber = 0
    // 对每个选中 id 只判断一次（② 防重复计数）
    for (const id of this.checkListNumber) {
      const key: number = Number(id)
      let hit = false
      if (this.bookTypeNumber === 5){
        // 书单
        for (const item of this.worksLists) {
          if (item.isTop && key === item.worksId) { hit = true; break }
        }
      } else if (this.bookTypeNumber === 1){
        // 分组（系统分组不参与置顶）
        for (const item of this.bookGroups) {
          if (item.isTop && key === item.groupId && !item.isSystem) { hit = true; break }
        }
      } else {
        // 书籍
        for (const item of this.bookList) {
          if (item.isTop && key === item.id) { hit = true; break }
        }
      }
      if (hit) {
        allTopNumber++
      }
    }
    // 全部已置顶 ⇒ 取消置顶；否则（含混合）⇒ 置顶
    if (allTopNumber >= this.checkListNumber.length) {
      this.topTitle = '取消置顶'
    } else {
      this.topTitle = '置顶'
    }
  }
  //书单
  getWorkLists() {
    worksListsDao.search({
      type:this.currentIndex
    }).then((val)=>{
      this.worksLists = val
    })
  }
  //书籍
  getBookList(){
    // pageSize=0 ⇒ 全量（BooksDao.searchPage 约定）：管理页必须列出全部书籍，
    // 旧实现 (1,100) 在批量导入超过 100 本时只显示前 100 本。
    booksDao.searchPage({
      type:this.currentIndex,
      bookGroup:this.bookTypeNumber
    },1,0).then((val)=>{
      this.bookList = val
    })
  }
  //分组
  // 2026-10-06：「共N本」按 books.bookGroup 现算（book_groups.bookIds 是陈旧冗余列，
  // 真机实测自建分组恒显示"共0本"，证据见 bookGroupUtil.fillRealBookIds 注释）。
  async getGroupList(){
    const val: BookGroups[] = await BookGroupsDao.search({
      type: this.currentIndex
    })
    await bookGroupUtil.fillRealBookIds(val, this.currentIndex)
    this.bookGroups = val
  }
  /**
   * 注入路由参数（迁 Navigation 第 4 期）。
   *
   * 原来这三个值是在**字段初始化器**里 `(router.getParams() as routerParams).xxx` 取的。
   * 迁后参数改由 `Index.appRoutes()` 经 `initParam` 传入，而字段初始化器执行时
   * `routeParam` 已就绪，理论上也能直接读；这里放 `aboutToAppear` 是为了与其它
   * 已迁移页面（`BookDetailPage` / `ReaderPage3`）保持**同一种注入惯例**。
   */
  aboutToAppear(): void {
    this.currentIndex = this.routeParam.currentIndex
    this.EXHIBIT = this.routeParam.EXHIBIT
    this.bookTypeNumber = this.routeParam.bookTypeNumber
    this.pageInit()
    // 碰一碰监听（官方文档：离开页面/退后台应及时 off —— 本页 aboutToDisappear 处理；
    // 系统能力用官方推荐的 canIUse 判定，不支持碰一碰的设备静默跳过）
    if (canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      harmonyShare.on('knockShare', (target: harmonyShare.SharableTarget) => {
        this.knockCallback(target)
      })
    }
  }

  aboutToDisappear(): void {
    // 官方要求：不需要碰一碰或离开页面/退后台时及时取消监听，避免资源浪费与异常触发
    if (canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      harmonyShare.off('knockShare')
    }
  }

  //初始
  pageInit(): void {
    if (this.bookTypeNumber === 1) {
      this.getGroupList()
      this.isMoveStatus = 1
    } else if (this.bookTypeNumber === 5){
      this.getWorkLists()
      this.isMoveStatus = 2
    } else {
      this.getBookList()
      this.isMoveStatus = 0
    }
  }

  /**
   * 「加入书单」统一弹窗（2026-10-01 从 bindSheet 改 CustomDialog）。
   * sheet 载不了沉浸光感材质（SheetOptions 无 systemMaterial 字段，取证见
   * AddToBookListDialog 类注释）；控制器**打开时新建**——SDK NOTE「Custom dialog box
   * parameters do not support dynamic updates」，ids/bookOrFolder 随勾选变化只能快照。
   * 本页是整页（非弹窗），背后无需退出，子关闭后原地刷新列表即可。
   */
  private addToBookListDialog: CustomDialogController | null = null
  private openAddToBookList(): void {
    this.addToBookListDialog = new CustomDialogController({
      builder: AddToBookListDialog({
        currentIndex: this.currentIndex,
        ids: this.checkListNumber,
        bookOrFolder: this.bookOrFolder,
        // ══════════════════════════════════════════════════════════════════════
        // 2026-10-12 九修：**「取消」不再清除勾选**（用户反馈）
        // ══════════════════════════════════════════════════════════════════════
        // ── 症状（用户原话）────────────────────────────────────────────────────
        //   「选定一本书，点击加入书单，然后点击加入书单的取消之后，这个选定没了？？
        //     实际上选定之后移动至或者删除被中断都不会清除选定」
        //
        // ── 根因 ──────────────────────────────────────────────────────────────
        //   这里原来调的是 `this.refreshData()`，而 `refreshData()` 末尾有一行
        //   **`this.dataMoveCheckList(false)`**（见本文件 `refreshData()`）——
        //   它把 `checkLists` 里**所有 key 强制写成 false** ⇒ 勾选被清空。
        //   「移动至」/「删除」被中断时**不调 `refreshData()`**，所以勾选保留
        //   ⇒ 三个入口行为不一致，正是用户察觉到的那种"不一样"。
        //
        // ── 修法：取消 = 只关弹窗，**不碰勾选、不重查列表** ────────────────────
        //   理由：用户点「取消」的语义是"我这次不加入书单了"，
        //   **不含**"顺便取消我选中的书"。勾选由用户自己在列表里点掉。
        //   列表也不需要重查 —— 取消没有改任何数据（只有确认加入才会改，
        //   那条路径由 `AddToBookListDialog` 内部的成功回调负责刷新）。
        //
        //   ⚠️ 回退：把 `this.refreshData()` 加回来即恢复"取消也清空勾选"的旧行为。
        //   ⚠️ 若将来"确认加入"后需要刷新列表，请在 AddToBookListDialog 的
        //      **成功回调**里调 `refreshData()`，不要把刷新挂在取消路径上。
        cancel: () => {
          this.addToBookListDialog?.close()
          this.addToBookListDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '80%',
      height: 400,
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      // 遮罩 / 返回键：与「取消」同一条路径（同样不碰勾选）
      cancel: (): void => {
        this.addToBookListDialog?.close()
        this.addToBookListDialog = null
      }
    })
    this.addToBookListDialog.open()
  }
  @State showNumber:number = 0
  @State bookOrFolder:number = 0
  build() {
    // ══════════════════════════════════════════════════════════════════════════
    // 底部手势条那一带（2026-10-12 三修，用户截图：底部有一条**白边**）
    // ══════════════════════════════════════════════════════════════════════════
    // ── 这条白边是什么 ────────────────────────────────────────────────────────
    // 旧结构（2026-09-25 那版）是：
    //   内层 Column `.margin({ bottom: bottomRectHeight })` **让出**系统手势条那一条
    //   （真机实测 ≈27.85vp，见 `WindowAbility.ets:183`），
    //   外层 Column 再刷 `.backgroundColor(ShelfColors.card())` 把那一条**填色**。
    // 这套在"管理页是白色底栏"时是对的（填的白色 = 底栏白，接缝消失）。
    // **但管理页现在是主题渐变底**（本次第 2 点改动）：
    //   `ShelfColors.card()` 日间 = **`#FFFFFF` 纯白**（`NightMode.ets:285-287` 原文
    //   `return NightMode.isDarkSurface() ? '#26262A' : '#FFFFFF';`）
    //   ⇒ 让出那一条被刷成纯白，压在紫粉渐变下面 = **用户看到的白边**。
    //
    // ── 书架的正确答案（本文件照抄）────────────────────────────────────────────
    // 书架**根本不让出**：`Index.ets:731/819` 给 Tabs 与每个 TabContent 都挂
    //   `.expandSafeArea([SafeAreaType.SYSTEM])` ⇒ 渐变一路铺到屏幕最底，
    //   悬浮 dock 再靠 `barBottomMargin: bottomRectHeight + 8` 悬在手势条之上
    //   （`Index.ets:575`）。**"贯通"是靠铺满实现的，不是靠让出+填色。**
    //
    // ⇒ 本次改为同款：
    //   ① 删掉内层的 `.margin({ bottom: bottomRectHeight })`（不再让出）；
    //   ② 删掉外层的白色填充（不再需要"填缝"）；
    //   ③ 整页 `.expandSafeArea([SafeAreaType.SYSTEM])` ⇒ 渐变铺进手势条区；
    //   ④ 底部 dock 自己带 `bottomRectHeight + 8` 的底部外边距（悬浮在手势条上方）。
    //
    // 一键回退：把 ② 的填充与 ① 的 margin 加回去（即回到 2026-09-25 那一版的行为）。
    Column(){
      Column(){
        Header({
          customLeftBuilder: () => {
            this.selectAll()
          },
          title:`已选${this.checkListNumber.length}项`,
          customRightBuilder: () => {
            this.complete()
          }
        })
        Column(){
          this.bookManage()
        }
        .layoutWeight(1)
        // 主题渐变兜底底色（2026-10-12）：见下方 `.linearGradient` 处的说明 ——
        // 本层**不能**再刷 `ShelfColors.pageBg()`（它会把渐变整个盖住）。
      }
      .linearGradient({
        direction: GradientDirection.Bottom, // 渐变方向
        // 暗色档走 ShelfColors 的深色渐变（对齐 MyCenter 顶部渐变的做法）
        // ⚠️ 这不是"重复着色"：`repeating` 默认 `false`（官方
        //   `…/视效与模糊/颜色渐变/ts-universal-attributes-gradient-color`），
        //   0→0.2 之间是 mainColor→secondColor 的渐变，0.2 以下**恒为 secondColor**。
        //   （书架侧曾误判成重复着色，实测推翻，见 `IndexShelf.ets:305-313` 与
        //    `docs/底部手势区贯通-排查记录.md` §3 的"踩过的误判"。）
        colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0.0],
          [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]]
      })
      .borderRadius({ bottomRight: 5, bottomLeft: 5 })
    }
    .width('100%')
    .height('100%')
    // ③ 铺进系统安全区（状态栏 + 手势条）：与书架 `Index.ets:819` 同款
    .expandSafeArea([SafeAreaType.SYSTEM])
  }
  //主要操作页面
  /**
   * 管理页主体 + 底部操作栏（2026-10-12 **改为 HDS 悬浮页签承载**）。
   *
   * ── 为什么改成 HDS（用户要求原文）──────────────────────────────────────────
   *   「进入管理页明显卡顿……底部dock为什么不能和书架dock一样，你给我个解释，
   *     我还是不理解」「管理页底部还是和我想的不一样，**直接改，改成HDS**，
   *     我怀疑卡顿就是没改HDS，然后现有方案出现的卡顿」。
   *
   * ── 之前为什么做不到（取证结论，不是借口）────────────────────────────────────
   * 沉浸光感材质 `systemMaterialEffect` **只存在于 HDS 组件的样式结构里**
   * （SDK `@hms.hds.hdsBaseComponent.d.ets`：
   *   `5380: export declare interface HdsTabsFloatingStyle { … systemMaterialEffect?: SystemMaterialParams; }`、
   *   `HdsNavigation*` 系列）。而普通组件的 `CommonMethod` 上**没有**
   * `backgroundMaterial` / `foregroundMaterial`（`…\ets\component\common.d.ts` 逐个 grep：
   * 只有 `17891 backgroundBlurStyle` / `17946/17962/17988 backgroundEffect`）。
   * ⇒ 用普通 `Column` 画的底栏**物理上拿不到那个材质**，只能拿 `backgroundEffect` 近似。
   * 现在按用户要求**换成 HdsTabs**：底部栏就是 HDS 自己的悬浮页签栏，
   * 材质/圆角/几何**与书架 dock 同一套实现**，观感自然一致。
   *
   * ── 结构说明（这里没有"页签"语义）──────────────────────────────────────────
   * 管理页底部是**操作栏**（置顶/移动至/加入书单/隐藏/删除/分享），不是导航页签。
   * 借 `HdsTabs` 的形态：**只用一个 TabContent 装列表**，`tabBar` 里画操作按钮；
   * 按钮点击**不切页签**（`index` 恒为 0），行为与改造前完全一致。
   * `.barHeight(0)` 不可用（会把整条栏压没），故保留默认 56 —— 与书架 dock 同高。
   */
  @Builder bookManage(){
    HdsTabs({ index: 0, barPosition: BarPosition.End, controller: this.manageTabController }) {
      TabContent() {
        Scroll(){
          if (this.bookTypeNumber === 5){
            WorksBookLists({
              worksLists:this.worksLists,
              checkGroup:this.checkLists,
              EXHIBIT:this.EXHIBIT,
              isShowCheck:true,
              onSelect:()=>{
                this.listenCheckList()
              }
            })
          } else {
            if (this.bookTypeNumber === 1){
              BookFolderManages({
                checkGroup:this.checkLists,
                EXHIBIT:this.EXHIBIT,
                bookGroups:this.bookGroups,
                onSelect:()=>{
                  this.listenCheckList()
                }
              })
            } else {
              bookListManage({
                checkGroup:this.checkLists,
                EXHIBIT:this.EXHIBIT,
                bookList:this.bookList,
                onSelect:()=>{
                  this.listenCheckList()
                }
              })
            }
          }
        }
        // ════════════════════════════════════════════════════════════════════
        // 2026-10-12 八修（用户：「图书还是居中呢？不是从上往下排列」）
        // ════════════════════════════════════════════════════════════════════
        // ── 真机证据（1320×2848px，密度 3.375）────────────────────────────
        //   TabContent : y 300  -> 2848  H=2548   ← 满高
        //   Scroll     : y 1036 -> 2112  H=1076   ← **只有内容高**，且垂直居中
        //   3 本书的标题 y=1132 / 1502 / 1872 ⇒ 从屏幕中间才开始排。
        //
        // ── 根因：`layoutWeight(1)` 在这里**不生效** ───────────────────────
        //   官方原文（documentId
        //   `API参考/ArkUI_方舟UI框架/ArkTS组件/通用属性/布局与边框/Flex布局/
        //    ts-universal-attributes-flex-layout`）：
        //     「设置组件在父容器剩余空间中所占的比例。**仅作为 Flex、Column、Row 和
        //       DynamicLayout 容器的子组件时支持设置此属性。**」
        //   ⇒ `Scroll` 的直接父级是 **`TabContent`**（不在上述四类里）
        //     ⇒ `.layoutWeight(1)` 被忽略 ⇒ `Scroll` 退回"内容自适应高度"（1076px）
        //     ⇒ HdsTabs/TabContent 把这个矮盒子**垂直居中** ⇒ 表现为"书整体居中"。
        //
        // ── 修法：显式撑满高度 ────────────────────────────────────────────
        //   把 `.layoutWeight(1)` 换成 `.height('100%')`（百分比只依赖父级高度，
        //   不需要父级是 Flex/Column/Row）⇒ `Scroll` 占满 2548px ⇒ 内容从顶部排。
        //   `.align(Alignment.TopStart)` 保留：它是**Scroll 自身在父容器里的对齐**，
        //   满高后无副作用，留着可防将来父级又是居中容器时旧病复发。
        //
        //   ⚠️ 回退：把 `.height('100%')` 换回 `.layoutWeight(1)` 即复发"内容居中"。
        .height('100%')
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      // ⚠️ 2026-10-12 四修：**不要把 `tabBar` 指向一个"再嵌套调用别的 @Builder"的
      //   中转 builder**。上一版是 `.tabBar(this.manageTabBar())`，而
      //   `manageTabBar()` 里只有 `if/else { this.footerTitle() }` —— 多套了一层。
      //   真机节点链（`docs/日志.md:5`）：
      //     `TTHNI:fId: 0{ T: TabBar, D: 14 };{ T: Stack, D: 16 };{ T: Column, D: 15 };`
      //   层级深度交错（14/16/15），TabBar 下没有拿到预期的直接子节点。
      //   书架 `Index.ets:721` 的写法是**直接把内容 builder 交给 tabBar**
      //   （`.tabBar(this.TabBuilder(item.index, item.title, item.symbol!))`，
      //     而 `TabBuilder` 内部直接画 Column/Flex/SymbolGlyph，**不再转发**）。
      //   ⇒ 这里照做：三元选择**内容 builder 本身**，去掉 `manageTabBar()` 中转层。
      .tabBar(this.bookTypeNumber === 5 ? this.footerDel() : this.footerTitle())
      // 官方参考实现（documentId `…/沉浸光感典型场景/arkts-immersive-light-sample`）把
      // `.expandSafeArea([SafeAreaType.SYSTEM])` 同时挂在 Tabs 与每个 TabContent 上，
      // 理由原文：「设置底部 Tabs 悬浮并为 Tabs 组件开启沉浸光感，同时使用 ExpandSafeArea
      // 将显示内容延伸至状态栏区域，使应用整体体验更加一致。」
      .expandSafeArea([SafeAreaType.SYSTEM])
    }
    // ⚠️ 沉浸光感的硬性前提（官方原文，见 `Index.ets` 同处注释）：
    //   「悬浮样式仅在 **barOverlap 为 true**、vertical 为 false、barPosition 为
    //     BarPosition.End 时生效，三个条件需同时满足，否则 systemMaterial 设置不生效。」
    //   本处：barPosition = End ✓、vertical 未设（默认 false）✓ ⇒ 必须补 barOverlap(true)。
    .barOverlap(ImmersiveMaterialUtil.isOn())
    .scrollable(false)
    // 与书架 dock **同款悬浮样式**（同一份 `manageFloatingStyle()`，
    // 几何/材质/关蒙层的做法逐字段对齐 `Index.hdsFloatingStyle()`）
    .barFloatingStyle(this.manageFloatingStyle())
    .layoutWeight(1)
  }
  // （2026-10-12 已删 `manageTabBar()` 中转 builder：`tabBar` 直接给内容 builder，
  //   理由与真机节点链证据见 `.tabBar(...)` 调用处的注释。）

  /** HdsTabs 控制器（本页只有 0 号页签，仅用于满足构造签名） */
  private manageTabController: HdsTabsController = new HdsTabsController()

  /**
   * 底部操作栏**项间距**（vp）—— 唯一可调点（用户 2026-10-12 要求
   * 「保持每一个图标一样的间距」，随后又要求「适量增加一点」）。
   *
   * ── 真机实测（1320×2848px，密度 3.375；TabBar 宽 1212px = 359vp）──────────
   *   5 项按内容宽度排，各自宽度（px / vp）：
   *     置顶 82/24.3　移动至 112/33.2　加入书单 149/44.1　删除 82/24.3　分享 82/24.3
   *     内容总宽 = 507px = **150vp**
   *   ⇒ 要铺满 359vp，4 个间距共需 ~209vp，即**每档 ~52vp**（那是"均分"的上限）。
   *
   * ── 取值 ──────────────────────────────────────────────────────────────
   *   `space: 18` 时实测整组只占 1132px（左右各空 40px 看着还行，但图标偏挤）。
   *   本版按用户"适量增加"取 **28vp**：明显松开、又不至于让首尾贴到胶囊圆角。
   *   ⚠️ 想更散就把这个数调大（上限约 52vp，再大首尾会顶到圆角）。
   */
  private readonly MANAGE_DOCK_ITEM_SPACE: number = 28

  /** `manageBarWidth()` 的缓存（render 期间不重复查显示信息） */
  private manageBarWCache: number = 0

  /**
   * 页签栏目标宽度（vp）= **屏宽 - 左右各 16vp**（与 `barSideMargin: 16` 对齐）。
   *
   * 为什么需要它：HDS 页签栏宽度默认按「**页签个数**」分档（官方原文见
   * `manageFloatingStyle()` 内 ④ 段注释），本页只有 1 个 `TabContent`
   * ⇒ 落到最小分档 `76×1+8 = 84vp` ⇒ 真机 284px 挤在屏幕中央。
   * 这里显式给出满宽目标值把这个默认档覆盖掉。
   *
   * ⚠️ 用 `UIContext.px2vp` 而不是全局 `px2vp()`：
   *   全局 `px2vp` **已废弃**（SDK `component/common.d.ts:6043-6045` 原文
   *   「@deprecated since 18」「@useinstead ohos.arkui.UIContext.UIContext#px2vp」）。
   *   同款写法在先例 `pages/view/Reader/ReaderListenDialog.ets:129-145`。
   * ⚠️ 取不到显示信息时兜底 360vp（典型手机宽），**绝不返回 0** ——
   *   `barWidth` 传 0 会让整条操作栏消失，比"宽度略偏"严重得多。
   */
  private manageBarWidth(): number {
    if (this.manageBarWCache > 0) {
      return this.manageBarWCache
    }
    let w = 360
    try {
      const px = display.getDefaultDisplaySync().width
      const vp = this.getUIContext().px2vp(px)
      if (vp > 0) {
        w = vp
      }
    } catch (e) {
      // 保持兜底值：宁可宽度差一点，也不能让操作栏宽度变 0
    }
    // 两侧各让出 16vp（`barSideMargin: 16`），再留 2vp 余量避免边界被裁
    this.manageBarWCache = w - 80 > 0 ? w - 80 : w
    return this.manageBarWCache
  }

  /**
   * 管理页悬浮页签样式 —— **逐字段对齐书架** `Index.ets` 的 `hdsFloatingStyle()`。
   *
   * 同款三要素（缺一就不是同一个观感）：
   *  ① `systemMaterialEffect`（ADAPTIVE/ADAPTIVE）—— 沉浸光感材质本身；
   *  ② `gradientMask: { maskColor: Color.Transparent }` —— **关掉 HDS 自带的底部灰白蒙层**
   *     （官方默认浅色 `#CCF1F3F5` 全宽铺底 72vp，压在主题色上就是一条白带；
   *      官方明确「蒙层高度不可设置为 0」⇒ 唯一关法是颜色全透明）。
   *      证据链与像素验算见 `docs/底部手势区贯通-排查记录.md` §1 —— 这正是用户本次
   *      截图里那条**白边**的成因（另一个页面上的同一个坑）。
   *  ③ 几何 `barSideMargin: 16` / `barBottomMargin: bottomRectHeight + 8` —— 与书架同值，
   *     否则切页签时两页 dock 高度/位置会跳。
   *  ④ `barWidth` —— **管理页独有**，书架不需要（2026-10-12 五修，见下方长注释）。
   */
  private manageFloatingStyle(): HdsTabsFloatingStyle {
    const st: HdsTabsFloatingStyle = {
      barSideMargin: 16,
      barBottomMargin: this.bottomRectHeight + 8,
      // ② 关掉 HDS 自带底部蒙层（与 `Index.ets` 同款；回退：删掉本行即恢复官方默认白带）
      gradientMask: { maskColor: Color.Transparent },
      // ④ ★★ 2026-10-12 五修：把页签栏从 84vp 撑到满宽（本次「挤在一起」的**真正根因**）★★
      //
      // ── 真机证据（1320×2848px，密度 3.375）────────────────────────────────
      //   `devecocli ui layout --format json --mode full` 原样摘录：
      //     Tabs      x=0    y=300  -> x2=1320 y2=2848   W=1320  ← 容器满宽
      //     TabContent W=1320
      //     TabBar    x=518  y=2538 -> x2=802  y2=2727   W=284   ← 只有 284px，居中
      //       └ Column x=558 -> 762  W=204
      //           └ Row x=558 -> 762  W=204   ← 5 项各 33px，挤成一团
      //
      // ── 官方原文（决定性）─────────────────────────────────────────────────
      //   官方 API 参考（documentId
      //   `API参考/UI_Design_Kit_UI设计套件/ArkTS组件/HdsTabs_底部页签/ui-design-hdstabs`）
      //   对 `barFloatingStyle.barWidth` 的默认值原文：
      //     「页签栏分档宽度。默认值：页签个数小于等于3时，且 HdsTabs 宽度小于 600vp，
      //       页签栏宽度等于 **76vp*页签个数+8vp**，当 HdsTabs 宽度大于等于 600vp 时，
      //       页签栏宽度等于 **80vp*页签个数+8vp**。页签个数大于等于 4 时，页签栏最大
      //       宽度不超过 328vp。」
      //   ⇒ 本页只有 **1 个 `TabContent`** ⇒ 页签个数 = 1 ⇒ 宽度 = `76×1+8 = 84vp`
      //     ⇒ `84 × 3.375 = 283.5px` ≈ 真机实测 **284px** ✓（公式与实测吻合到 0.5px）
      //
      // ── 为什么书架不挤、只有管理页挤 ───────────────────────────────────────
      //   书架（`Index.ets`）有 **4 个 `TabContent`** ⇒ 走「页签个数大于等于4」分支
      //   （上限 328vp），所以从来不需要显式设 `barWidth`。
      //   管理页是**借 `HdsTabs` 的形态画操作栏**（只有 1 个内容页，见 `bookManage()`
      //   上方结构说明）⇒ 恰好落进"页签个数=1"的最小分档。
      //   ★ 教训：**照抄"同款样式"时，只对齐了显式写的字段，漏掉了「由页签个数隐式
      //     决定的那一档默认值」** —— 三要素齐了也不等于几何一致。
      //
      // ── 为什么之前「三修」的 `.width('100%')` 没修好 ───────────────────────
      //   真机上 `Row` 与它外层 `Column` 宽度**完全相同**（都是 558→762 = 204px）
      //   ⇒ `.width('100%')` **确实生效了**，只是百分比是相对那个 284px 的 `TabBar`
      //     解析的。改内层永远撑不出父层没有的宽度。
      //
      // ── 取值 ──────────────────────────────────────────────────────────────
      //   三档都设成「屏宽 - 两侧 16vp 边距」（`barSideMargin: 16` 是左右各 16vp）。
      //   三档同值 ⇒ 不论设备/宽高比命中哪一档，都是同一个满宽结果，避免不同机型跳变。
      //   ⚠️ 不用百分比：SDK 该字段类型是 `Length`，但官方对同结构的
      //     `HdsBarWidthRangeOptions` 各字段都注明「**不支持设置百分比单位**」。
      //     证据：`@hms.hds.hdsBaseComponent.d.ets:5085-5114`（`smallWidth`/`mediumWidth`/
      //     `largeWidth`，均 `@since 6.1.0(23)`）、`:5380-5389`（`barWidth?:
      //     HdsBarWidthRangeOptions`）。
      //
      // ⚠️ 回退：删掉本行 ⇒ 恢复官方默认分档（管理页回到 84vp = 284px 的居中挤团）。
      barWidth: {
        smallWidth: this.manageBarWidth(),
        mediumWidth: this.manageBarWidth(),
        largeWidth: this.manageBarWidth()
      }
    };
    // ① 一键回退点与书架一致：`ImmersiveMaterialUtil.ENABLED = false` 时不设材质
    if (ImmersiveMaterialUtil.isOn()) {
      st.systemMaterialEffect = {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      };
    }
    return st;
  }
  //书单弹窗
  //（2026-10-01 已删除 bindSheet 版 @Builder dialogCatalogAddShelf：SheetOptions 没有
  //  systemMaterial 字段载不了沉浸光感，统一改走 AddToBookListDialog，见 openAddToBookList。）
  @State allCheck:boolean = false
  @Builder
  selectAll() {
    Row({
      space:5
    }) {
      Checkbox()
        .select(this.allCheck)
        .selectedColor(this.theme.mainColor)
        .onClick(() => {
          Haptics.tap();
          if (this.verificationDate()) {
            return
          }
          this.allCheck = !this.allCheck
          this.dataMoveCheckList(this.allCheck)
          this.listenCheckList()
        })
      // Text(!this.allCheck?'全选':'取消全选')
    }

    .alignItems(VerticalAlign.Center)
  }
  //校验是否存页面数据内容
  verificationDate() {
    switch (this.bookTypeNumber){
      case 1:
        if (this.bookGroups.length === 0){
          showMessage('页面暂无操作数据')
          return true
        }
        break
      case 5:
        if (this.worksLists.length === 0){
          showMessage('页面暂无操作数据')
          return true
        }
        break
      default:
        if (this.bookList.length === 0){
          showMessage('页面暂无操作数据')
          return true
        }
        break
    }
    return false
  }


  //遍历列表数据
  dataMoveCheckList(value:boolean){

    this.checkLists = {};
    if (this.bookTypeNumber === 1){
      this.bookGroups.forEach((item)=>{
        item.groupId && !item.isSystem && item.show ?this.checkLists[item.groupId] = value:''
      })
    } else if (this.bookTypeNumber === 5){
      this.worksLists.forEach((item)=>{
        item.worksId?this.checkLists[item.worksId] = value:''
      })
    } else {
      this.bookList.forEach((item)=>{
        item.id?this.checkLists[item.id] = value:''
      })
    }
    if(!value){
      this.allCheck = false;
    }
  }


  @Builder
  complete() {
    Column() {
      Text('完成')
    }
    .onClick(async () => {
      Haptics.tap();
      // ⚠️ 返回前先广播刷新（2026-09-29 修正）：旧实现在 `AppRouter.back()` **之后**
      // setTimeout(100) 里才 `isBookRefreshing++` —— 那时本组件可能已随出栈销毁，
      // @StorageLink 不再回写 AppStorage ⇒ 书架不刷新（"置顶/删除后书架还是旧排序"）。
      // 组件还活着时写，保证书架（BookContent / GroupType / BookFolder）收到信号。
      if (this.bookTypeNumber === 1) {
        this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      } else if (this.bookTypeNumber !== 5) {
        this.isBookRefreshing++
      }
      // 迁 Navigation 第 4 期：本页现在是 NavDestination ⇒ 必须走门面返回。
      AppRouter.back()
    })
  }
  //书单底部操作栏（同为 HdsTabs 的 tabBar 内容 ⇒ 撑满页签栏高度、不自己画背景）
  @Builder footerDel(){
    Column(){
      Text('删除').fontSize(16).fontWeight(500).lineHeight(24).fontColor('#EF4444')
    }.onClick(()=>{
      Haptics.tap();
      if (this.checkListNumber.length <= 0) {
        showMessage('请选择要操作的内容');
        return
      }
      this.delDialog?.open();
    })
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
  }
  // 底部操作栏（2026-09-30 v3 回填：图标全面 symbol 化 + 新增「分享」）
  // symbol 名全部经 SDK 符号表（sysResource.js，4042 项）核实存在。
  @State buttonListInfo5:buttonList[] = [
    new buttonList(1,'置顶',$r('sys.symbol.pin')),
    new buttonList(2,'移动至',$r('sys.symbol.folder')),
    new buttonList(3,'加入书单',$r('sys.symbol.book')),
    new buttonList(4,'隐藏分组',$r('sys.symbol.eye_slash')),
    new buttonList(5,'删除',$r('sys.symbol.trash')),
    new buttonList(6,'分享',$r('sys.symbol.share'))
  ]

  @State buttonListInfo4:buttonList[] = [
    new buttonList(1,'置顶',$r('sys.symbol.pin')),
    new buttonList(2,'移动至',$r('sys.symbol.folder')),
    new buttonList(3,'加入书单',$r('sys.symbol.book')),
    new buttonList(5,'删除',$r('sys.symbol.trash')),
    new buttonList(6,'分享',$r('sys.symbol.share'))
  ]
  /**
   * 底部操作栏（2026-10-12 起作为 **HdsTabs 的 `tabBar` 内容**渲染）。
   *
   * 与改造前的差异：**不再自己画背景**。背景 = HDS 悬浮页签栏的沉浸光感材质
   * （`manageFloatingStyle()` 里的 `systemMaterialEffect`），与书架 dock 同一套。
   * 自己刷任何不透明底色都会把那层材质挡掉（这是本项目反复踩过的同一个错误模式：
   * `pageBg` 挡渐变、`card()` 挡材质）。
   *
   * ══════════════════════════════════════════════════════════════════════════
   * 2026-10-12 二修（用户反馈「图标还是挤在一起」）—— **容器选型错了**
   * ══════════════════════════════════════════════════════════════════════════
   * 上一版用 `GridRow(columns).GridCol()` 排布。`GridRow` 是**栅格布局容器**
   * （官方定位：`API参考/ArkUI_方舟UI框架/ArkTS组件/栅格与分栏/GridRow/ts-container-gridrow`，
   *   用途是"响应式布局、多设备适配、响应式断点"），它按**行**组织子项并参与行高分配；
   * 而页签栏的语义是"一列一个、等宽平铺、垂直居中"。
   *
   * 对照**书架已成功**的写法（`Index.ets:470-490` 的 `TabBuilder`）：
   * ```
   * @Builder TabBuilder(index = 0, name: string, symbol: Resource) {
   *   Column() {
   *     Flex({ direction: FlexDirection.Column, alignItems: ItemAlign.Center,
   *            justifyContent: FlexAlign.Center }) {
   *       SymbolGlyph(symbol).fontSize(24)
   *       Text(name).fontSize(11).margin(5)
   *     }
   *   }
   *   .width('100%').margin({ top: 4 }).height("100%")
   * }
   * ```
   * ⇒ 它用**纯 Flex 容器 + 双向居中 + height('100%')**，没有任何栅格语义。
   *
   * 官方 HdsTabs 示例同样是简单容器（`开发指南/UI_Design_Kit_UI设计套件/底部页签/
   * 设置页签的图标出血样式/…` 的 `tabBuilder()` 只放一个 `Column`；
   * 「设置页签栏的悬浮样式」示例用 `Row` + `Image`/`Text`）。
   *
   * ⇒ 本次改为 **`Row` + 每项 `layoutWeight(1)`（等宽平铺）+ `Column` 垂直居中**，
   *    与书架同构、也不依赖任何栅格行为。
   */
  /**
   * 底部操作栏（2026-10-12 起作为 **HdsTabs 的 `tabBar` 内容**渲染）。
   *
   * ══════════════════════════════════════════════════════════════════════════
   * 2026-10-12 七修（用户原话）：「五个元素每个文字都不同导致宽度不同……
   *   加入书单和删除的间距偏小，置顶距左边距、分享距右边距也不对。
   *   我的建议是**保持每一个图标一样的间距，然后五个图标在这个 HDS 里面居中**」
   * ══════════════════════════════════════════════════════════════════════════
   * ── 为什么"等分宽度"反而不均匀（上一版的做法）─────────────────────────────
   *   上一版用 `ForEach{ ManageToolButton().layoutWeight(1) }` ⇒ **等分**父行宽度
   *   （真机实测每项 **221px**，5 项恰好铺满）。父行等分**没错**，错在：
   *   每个按钮的**文字宽度不同**（"加入书单"4 字、"删除"2 字），
   *   等分后每格一样宽、但格内内容宽度不一 ⇒ **图标中心之间的间距依然不等**
   *   （用户看到的就是"加入书单↔删除 偏小、置顶距左/分享距右 不对"）。
   *
   * ── 本版改法：**按内容宽度排 + 统一间距 + 整体居中** ──────────────────────
   *   ① 去掉子项上的 `.layoutWeight(1)` ⇒ 每项按**自身内容宽度**定宽；
   *   ② `Row({ space: N })` 给**统一的项间距**（图标中心间距 = 项宽 + N，
   *      虽仍随文字宽度有微差，但**边界间距**与"贴边"问题被消除，
   *      视觉上就是"图标等间距"——这是纯 Flex 能做到的最接近你要求的形态）；
   *   ③ `Row().justifyContent(FlexAlign.Center)` ⇒ 5 项**整组在 HDS 条内居中**，
   *      左右留白自动相等（不再需要靠 `.padding` 硬凑）。
   *
   *   ⚠️ 仍必须保留 `.width('100%')`：`tabBar` builder 拿到的容器是 wrap-content，
   *      不显式撑满就量不出宽度，`justifyContent(Center)` 也就无从居中。
   *
   *   ⚠️ 回退：把 `.layoutWeight(1)` 加回子项、删掉 `space` 与 `justifyContent`
   *      ⇒ 回到"等分 221px 但图标间距不均"的上一版。
   */
  @Builder footerTitle(){
      Row({ space: this.MANAGE_DOCK_ITEM_SPACE }){
        ForEach(this.bookTypeNumber===1?this.buttonListInfo5:this.buttonListInfo4,(item:buttonList)=>{
          ManageToolButton({
            icon: item.icon,
            label: item.id === 1 ? this.topTitle : item.title,
            onTap: (): void => {
              this.bookInfoButton(item.id)
            }
          })
          // ⚠️ 七修：**这里不再 `.layoutWeight(1)`**（等分会因文字宽窄不同而图标间距不均）
        })
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)
      // ③ 五项整组在 HDS 条内**居中**（左右留白自动相等）
      .justifyContent(FlexAlign.Center)
    }
  //底部操作栏功能
  bookInfoButton(index:number){
    if (this.checkListNumber.length <= 0) {
      showMessage('请选择要操作的内容');
      return
    }
    this.dataCheckList()
    switch (index){
      case 1 :
       this.manageTop(); break;
      case 2 :
        // 「移动至」：打开前先预取分组（2026-10-12），避免弹窗首帧空白
        this.openMoveGroup().catch((e: Error): void => {
          console.error('openMoveGroup failed: ' + e.message)
        }); break;
      case 3 :
        if (this.bookTypeNumber === 1) {
          this.bookOrFolder = 1
        } else {
          this.bookOrFolder = 0
        }
        this.openAddToBookList();
        break;
      case 4 :
        this.clickHideDialog?.open()
        break
      case 5 :
        this.delDialog?.open(); break;
      case 6 :
        this.manageShare(); break;
    }
  }

  /**
   * 分享选中书籍（2026-09-30 回填）——官方 API：
   * `systemShare.SharedData`（SharedRecord: utd+uri，官方 share-system-share 示例同款）
   * + `ShareController.show(context, options)` 拉起系统分享面板。
   * utd 由文件后缀运行时解析（官方 knock 示例：
   * `uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(suffix)`）；
   * 沙箱路径转 uri 用 `fileUri.getUriFromPath`（官方 Share Kit 术语/uri 说明）。
   * 对端装了喵阅（注册 ShareExtensionAbility）⇒ 分享面板推荐区直达 ⇒ 分享即入库。
   */
  private async manageShare(){
    if (this.bookTypeNumber === 1) {
      showMessage('分组暂不支持分享，请选择书籍');
      return
    }
    const checked = new Set<number>(this.checkListNumber)
    const books: Books[] = this.bookList.filter((b: Books) => checked.has(b.id ?? -1) && !!b.bookUrl)
    if (books.length <= 0) {
      showMessage('选中书籍没有可分享的文件');
      return
    }
    try {
      const shareData: systemShare.SharedData | null = this.buildBookShareData(books)
      if (shareData === null) {
        showMessage('书籍文件不存在，无法分享');
        return
      }
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData)
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.BATCH,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      })
    } catch (err) {
      const e = err as BusinessError
      console.error(`LTBOOK share failed. code: ${e.code}, message: ${e.message}`)
      showMessage('分享失败：' + e.message)
    }
  }

  /** 把选中书籍构造成 SharedData（首条进构造器、其余 addRecord，官方范式） */
  private buildBookShareData(books: Books[]): systemShare.SharedData | null {
    let data: systemShare.SharedData | null = null
    for (const b of books) {
      const path: string = b.bookUrl ?? ''
      if (!path) {
        continue
      }
      const suffix: string = path.substring(path.lastIndexOf('.'))
      let utdId: string = 'general.text'
      try {
        utdId = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(suffix) ?? 'general.text'
      } catch (err) {
        // 后缀无法识别时退回 general.text（txt 场景的官方声明值）
      }
      const record: systemShare.SharedRecord = {
        utd: utdId,
        uri: fileUri.getUriFromPath(path),
        title: b.bookName ?? '书籍'
      }
      if (data === null) {
        data = new systemShare.SharedData(record)
      } else {
        data.addRecord(record)
      }
    }
    return data
  }

  /**
   * 碰一碰回调（2026-09-30 回填）——官方 API（最佳实践 bpta-application-knock-file-share）：
   * `harmonyShare.on('knockShare', (target: harmonyShare.SharableTarget) => {...})`
   * 回调里构建 SharedData 后 `target.share(shareData)`；页面离开/后台必须 off。
   * 约束：双端亮屏+解锁+华为分享开启；应用路由需手动签名（联调注意）。
   */
  private knockCallback(target: harmonyShare.SharableTarget): void {
    if (this.bookTypeNumber === 1 || this.checkListNumber.length <= 0) {
      showMessage('请先勾选要碰一碰分享的书籍');
      return
    }
    const checked = new Set<number>(this.checkListNumber)
    const books: Books[] = this.bookList.filter((b: Books) => checked.has(b.id ?? -1) && !!b.bookUrl)
    if (books.length <= 0) {
      return
    }
    const shareData: systemShare.SharedData | null = this.buildBookShareData(books)
    if (shareData === null) {
      return
    }
    target.share(shareData)
  }
  //置顶功能
  // ⚠️ 2026-09-29 重写（审核问题②「置顶成功后数据未实时更新」）：
  // ① 旧实现写入不 await，靠 setTimeout(500) 赌写库完成 ⇒ 慢一时就查到旧数据；
  // ② 重查后**没有**给书架广播刷新信号（`isBookRefreshing++` 被注释）⇒ 身后的
  //    书架一直停在旧排序。现在写入完成 → 立即重查本页 + 广播书架刷新。
  /**
   * 置顶 / 取消置顶（批量）。
   *
   * ══════════════════════════════════════════════════════════════════════════
   * 2026-10-12 十修（用户口述规则，**以本条为准**）
   * ══════════════════════════════════════════════════════════════════════════
   * 用户原话：
   *   「已经置顶的书籍选择之后，置顶按钮会变成取消置顶，但是如果多选，
   *     有的置顶有的没置顶呢？**都按照第一次点击为全部置顶**，进行统一，
   *     **置顶按钮也不清空选定**。」
   *
   * ⇒ 规则固化为：
   *   ① 按钮文字（`topTitle`）由 `selectIsAllTop()` 判定：
   *      **全部已置顶** ⇒ 「取消置顶」；**只要有一个未置顶**（含混合）⇒ 「置顶」。
   *      （混合选择 = 点一下 = **全部置顶**，不搞"反转"语义。）
   *   ② 动作方向**只看 `topTitle`**：'置顶' ⇒ isTop = true；'取消置顶' ⇒ isTop = false。
   *   ③ **完成后不清空勾选**（用户明确要求）。
   *
   * ── 本次修掉的 3 个问题 ────────────────────────────────────────────────────
   *  【A】分组置顶**不广播** ⇒ 书架分组卡片不刷新
   *      旧代码 `if (this.bookTypeNumber !== 1) { this.isBookRefreshing++ }`
   *      ⇒ 分组（`bookTypeNumber === 1`）那条**一个信号都没发**。
   *      而书架侧监听是两个**不同**的键（`grep` 实证）：
   *        · `BOOK_IS_BOOK_REFRESHING`        → 书列表（`BookContent.ets:55`）
   *        · `BOOK_IS_BOOK_GROUPS_REFRESHING` → 分组卡片（`BookFolder.ets:29`、
   *                                              `GroupType.ets:130`）
   *      ⇒ 在管理页给**分组**置顶 ⇒ 书架分组卡片永远停在旧排序。
   *      修法：按类型广播**对应的**键（与 `refreshData()` 里的 case 保持一致）。
   *
   *  【B】完成后清空勾选（`this.checkListNumber = []` / `this.checkLists = {}`）
   *      与用户要求相反。且这两行**本来就是多余的** —— 上面 `refreshData()`
   *      末尾已经调了 `dataMoveCheckList(false)`，等于连清两遍。
   *
   *  【C】`topTitle` 被无条件重置成 '置顶' ⇒ 连续操作时按钮文字与实际状态脱节。
   *      （用户要求"不清空选定"，那选中项还在，按钮文字就该跟着它们的真实状态走。）
   *      修法：操作后用 `selectIsAllTop()` **重新判定**，而不是硬写 '置顶'。
   *
   * ⚠️ 回退：删掉本方法的 ① 广播分支、把 ② 的 `selectIsAllTop()` 换回
   *    `this.topTitle = '置顶'`、并在末尾加回 `checkListNumber = []` / `checkLists = {}`
   *    ⇒ 回到十修前行为。
   */
  async manageTop(){
    const top: boolean = this.topTitle === '置顶'
    if (this.bookTypeNumber === 1) {
      await bookGroupUtil.isTopGroup(this.checkListNumber, top)
    } else {
      await booksUtil.isTopBook(this.checkListNumber, top)
    }
    // 写库已完成 ⇒ 本页列表立即按新 isTop 重排（查询本身按 `isTop DESC` 排序）
    //
    // ⚠️ `refreshData()` 内部会 `dataMoveCheckList(false)`（清勾选）+ `dataCheckList()`。
    //   但**本方法要求保留勾选** ⇒ 这里不能直接用它，见下方"保留勾选"处理。
    this.reloadListKeepSelection()
    // ① 广播给身后的书架 —— 按类型发**对应**的键（十修 A）
    if (this.bookTypeNumber === 1) {
      // 分组：书架看的是 BOOK_IS_BOOK_GROUPS_REFRESHING（BookFolder / GroupType）
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
    } else {
      // 书籍 / 书单：书架看的是 BOOK_IS_BOOK_REFRESHING（BookContent）
      this.isBookRefreshing++
    }
    // ③ 不清空勾选 ⇒ 按钮文字按选中项的真实状态**重新判定**（十修 B/C）
    this.selectIsAllTop()
    showMessage('操作成功')
  }

  /**
   * 重查列表但**保留当前勾选**（十修新增，专供"操作后不清空选定"的路径）。
   *
   * 为什么不能直接用 `refreshData()`：它末尾的 `dataMoveCheckList(false)`
   * 会把 `checkLists` 里所有 key 写成 false ⇒ 勾选全丢。
   * 这里只做"重查数据"这一半，**不碰** `checkLists`。
   *
   * ⚠️ 重查会重建列表（`bookList` 等被整体替换）。勾选状态**独立存在**
   *    `checkLists: Record<number, boolean>` 里，只要 id 没变，
   *    重建后 `Checkbox().select(this.checkGroup[id])` 仍能正确回显 ⇒ 勾选视觉保留。
   */
  reloadListKeepSelection(){
    switch (this.bookTypeNumber){
      case 1:
        this.getGroupList();
        break;
      case 5:
        this.getWorkLists();
        break;
      default:
        this.getBookList();
        break;
    }
    // 只重算"选中 id 列表"，不动 checkLists 本身
    this.dataCheckList()
  }
  //删除确认弹窗
  @State delCache:boolean = false
  delDialog: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      confirm: ()=> { this.manageDelete() },
      delCache:this.delCache
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    // 2026-09-25 用户反馈：删除确认弹窗材质与全局统一（原 options 漏了 systemMaterial）
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })
  //删除功能
  manageDelete(){
    this.checkListNumber.forEach((item:number)=>{
      switch (this.bookTypeNumber){
        case 1:
          bookGroupUtil.delGroupById(item); break;
        case 5:
          worksListsUtils.delWorksByIds(item);break;
        default:
          booksUtil.delBooksById(item);break;
      }
    })
    setTimeout(()=>{
      this.refreshData()
      showMessage('已删除')
    },500)
    this.delDialog?.close()
  }
  //是否隐藏分组弹窗
  clickHideDialog: CustomDialogController | null = new CustomDialogController({
    builder: hideDialogExample({
      confirm: ()=> { this.clickHideAccept() }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })
  //隐藏操作
  clickHideAccept() {
   bookGroupUtil.updateGroupShow(this.checkListNumber)
    setTimeout(()=>{
      this.refreshData()
      showMessage('已隐藏')
    },500)
  }

  //操作状态
  @State isMoveStatus:number = 0
  /**
   * 「移动至」弹窗（2026-10-12 改为**打开时新建 controller + 预取分组**）。
   *
   * 与 `BookInfoDialogs.openMoveGroupDialog()` 同款改动，理由也相同：
   * 弹窗的分组列表原本在它自己的 `aboutToAppear()` 里**异步**查，弹窗打开瞬间是空的
   * ⇒ 用户看到"分组要过一会儿才刷出来"（用户原话：「此时未分组还没被刷新出来，
   * 过一会儿才刷新出来」「我的建议是增加实时刷新联动，不要脱节」）。
   *
   * ⇒ 这里在 `open()` **之前** await 预取，经 `presetGroups` 传进弹窗，首帧即成型。
   * 同时符合规范 §4.4「参数动态更新无效 ⇒ 打开瞬间 new 一个新 controller」。
   */
  private bookMoveGroup: CustomDialogController | null = null
  private async openMoveGroup(): Promise<void> {
    const groups: BookGroups[] = await bookGroupUtil.prefetchGroups(this.currentIndex)
    const dlg = new CustomDialogController({
      builder: BookSelectGroupDialog({
        moveGroup: (): void => {
          setTimeout((): void => {
            this.refreshData()
          }, 500)
          this.bookMoveGroup?.close()
          this.bookMoveGroup = null
        },
        // ══════════════════════════════════════════════════════════════════════
        // 2026-10-12 九修：「取消」按钮点了没反应（用户反馈）
        // ══════════════════════════════════════════════════════════════════════
        // ── 根因 ──────────────────────────────────────────────────────────────
        //   `BookSelectGroupDialog` 的「取消」按钮**只调 `this.onClose()`**，
        //   自己不 close（见该文件 `:180-185`；`this.controller?.close()` 在
        //   `@CustomDialog` 子组件里是空操作 —— 这条已在 `RenameBookDialog` 上真机确认）。
        //   ⇒ **关闭动作完全依赖调用方传进来的 `onClose`**。
        //   书架 `BookInfoDialogs.openMoveGroupDialog()` 传了（`:552-556`），
        //   而**管理页这里原来根本没传 `onClose`** ⇒ 它取默认空实现
        //   （`BookSelectGroupDialog.ets:36-38` 的 `onClose: () => void = () => {}`）
        //   ⇒ 点「取消」什么都不发生。
        //
        // ── 为什么书架正常、只有管理页坏 ───────────────────────────────────────
        //   这正是「统一弹窗取消键」那一轮排查的**遗漏页**：当时改的是
        //   `BookInfoDialogs` / `FolderInfoDialog` / `BookManageDialog` 这些
        //   **弹窗宿主**，而管理页是**整页宿主**（`BookManagePage`），不在那批里。
        //   ⇒ 教训：统一规范落地时，**要把"整页宿主"也列进清单**，
        //     不能只扫文件名带 Dialog 的。
        //
        // ── 修法 ──────────────────────────────────────────────────────────────
        //   与书架逐字对齐：`onClose` 里**先真正 close 子弹窗** → 再清引用。
        //   （管理页是整页、背后没有父弹窗要恢复，所以不需要书架的 `childDialogClosed()`。）
        //   ⚠️ 顺序不能反：先置空引用就再也没有人能 close 它了 —— 那正是
        //     `BookInfoDialogs.ets:545-551` 记录过的 "只置空、根本没关" 的老坑。
        //
        //   ⚠️ 取消时**不调 `refreshData()`**：见 `openAddToBookList()` 处
        //     关于"取消不该清除勾选"的说明（九修同批修复）。
        onClose: (): void => {
          this.bookMoveGroup?.close()
          this.bookMoveGroup = null
        },
        oldGroupId: this.bookTypeNumber,
        currentIndex: this.currentIndex,
        Ids: this.checkListNumber,
        isMoveStatus: this.isMoveStatus,
        presetGroups: groups
      }),
      height: 400,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      customStyle: false,
      cornerRadius: 25,
      // 遮罩 / 返回键：与「取消」按钮同一条收尾路径。
      // ⚠️ 原来这里只有 `this.bookMoveGroup = null` —— **只置空、没 close**，
      //    与 `BookInfoDialogs` 修过的那个坑一模一样，本次一并补齐。
      cancel: (): void => {
        this.bookMoveGroup?.close()
        this.bookMoveGroup = null
      }
    })
    this.bookMoveGroup = dlg
    dlg.open()
  }

  //刷新数据方法
  refreshData(){
   switch (this.bookTypeNumber){
     case 1:
       this.getGroupList();
       this.BOOK_IS_BOOK_GROUPS_REFRESHING++
       break;
     case 5:
       this.getWorkLists();
       break;
       default:
         this.getBookList();
         // this.isBookRefreshing++
         break;
   }
   this.dataMoveCheckList(false)
   this.dataCheckList()
  }

  //将checkLists取key值转换为string[]
  dataCheckList(){
    const keys = Object.keys(this.checkLists)
      .filter(key => this.checkLists[Number(key)])
      .map(key => Number(key));
    this.checkListNumber = keys
  }
  //判断checkLists变化值当key的值为false移除当前值
  listenCheckList() {
    this.dataCheckList()
    this.selectIsAllTop()
    this.allCheck = this.checkListNumber.length !== 0
  }
}

/**
 * 管理页底部操作按钮（2026-09-30 抽取；2026-10-12 适配 HdsTabs 页签栏）。
 *
 * 组成：symbol 图标 + 文字标签 + 独立 Q弹（`runJellyClick` 自驱 scale）+ 统一震动。
 * 抽成子组件是为了每个按钮有**独立的弹跳状态**（父组件用数组下标更新不触发 V1 渲染）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 2026-10-12 二修：**尺寸与对齐改为对齐书架 `TabBuilder`（已成功的参照物）**
 * ══════════════════════════════════════════════════════════════════════════
 * 书架 `Index.ets:470-490`（真机验证过、不挤）的取值：
 *   · `SymbolGlyph.fontSize(24)`、`Text.fontSize(11)`、`Text.margin(5)`
 *   · 外层 `Flex(direction: Column, alignItems: Center, justifyContent: Center)`
 *   · 容器 `.width('100%').height('100%')`
 *
 * 本组件与之的**唯一实质差异**：多一个 `layoutWeight(1)` 由父 `Row` 给（等分宽度）。
 * ⇒ `width('100%')` 必须**删掉**：在 `layoutWeight` 已经决定宽度的前提下再声明
 *   `width('100%')`，宽度约束会与 flex 分配打架（复用旧代码留下的写法）。
 *   ⚠️ **2026-10-12 五修：这一条当时只写在注释里、代码没删，本次真机复核才发现**
 *   —— 上面「挤」的直接原因有两层：外层 `TabBar` 只有 284px（见 `manageFloatingStyle()`
 *   ④ 段），内层这里又让 5 项各自停在最小宽度。两层都要修，只修一层仍挤。
 *   真机证据（`devecocli ui layout --format json --mode full` 快照，临时 dump 已清理）：
 *   `TabBar` W=284、每项 W=33。
 * ⇒ 同时删掉上一版为"迁就栅格"而缩小的尺寸（22/11/2），**回到书架的 24/11/5**
 *   —— 既然容器语义已经对齐，尺寸就不该另行发明一套。
 */
@Component
struct ManageToolButton {
  icon: Resource = $r('sys.symbol.pin')
  label: string = ''
  onTap: () => void = (): void => {}
  @State jellyScale: number = 1

  build() {
    Column() {
      Flex({
        direction: FlexDirection.Column,
        alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.Center
      }) {
        SymbolGlyph(this.icon)
          .fontSize(24)
          .fontColor([ShelfColors.icon()])
          .scale({ x: this.jellyScale, y: this.jellyScale })
        Text(this.label)
          .fontSize(11)
          .fontColor(ShelfColors.icon())
          .margin({ top: 5 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    // ⚠️ 2026-10-12 五修：**这里不能写 `.width('100%')`**（本次真机复核时删掉的）。
    //   本组件的宽度由父 `Row` 的 `.layoutWeight(1)` 分配（等分 5 份）。
    //   若这里再声明 `width('100%')`，宽度约束会与 flex 分配打架：
    //   5 个各按父宽 100% 参与测量，最终每项停在**最小内容宽**
    //   —— 真机 dump 实测每项 33px（`Row` 宽 204px / 5 项的最小宽度之和），
    //      正是"5 个图标挤成一团"的直接来源。
    //   （旧代码的注释早已写明「必须删掉」，但代码里一直没删，本次补齐。）
    //   真机原始数据（当时用 `devecocli ui layout --format json --mode full` 取的，临时
    //   dump 文件已清理，结论记录在 `docs/底部手势区贯通-排查记录.md` 同款排查流程里）：
    //     TabBar   W=284（应满宽 1320）；Row W=204；每项 W=33。
    //
    // 2026-10-12 六修（垂直居中）：**用 `.justifyContent(FlexAlign.Center)`，
    //   绝不能加 `.margin({ top: 4 })`**。这一条是踩过坑后按真机数据定的：
    //
    //   书架 `Index.ets:488` 确实写了 `.margin({ top: 4 })`，但**不能照抄到这里** ——
    //   书架的 Column 是"内容自适应高度 + 顶部留 4vp"；而**本组件**的 Column 处在
    //   `Row` 的 `layoutWeight(1)` 分配格子里、且被 `.height('100%')` 拉满，
    //   此时 `.margin({top:4})` 的 4vp 会**叠加在 100% 高度之外** ⇒ 整个盒子被下推
    //   4vp 并溢出父格子。真机 dump 实测（同一次会话的快照）：
    //     Row          y 2551 -> 2714
    //     item Column  y 2564 -> 2727   ← 底边 2727 与 TabBar 底边齐平（溢出，被裁）
    //     icon 2575->2656 / text 2672->2716 ⇒ 内容中心 2645.5，比 TabBar 中心 2632.5
    //                                         **低 13px**（肉眼就是"整体下沉"）
    //   ⇒ 去掉 margin，改回 `justifyContent(FlexAlign.Center)`，
    //     让"图标+文字"这组内容在**满高盒子内**真正垂直居中。
    //   ✅ 修后真机复核（同密度 3.375）：三个按钮的墨迹中心 2631 / 2633 / 2633.5，
    //      药丸中心 2632 ⇒ **居中误差 ≤1px**；各按钮墨迹都在 2567..2695 区间。
    //
    //   ⚠️ 同批去掉标签 `.fontWeight(500)`：书架用默认字重，字重会改变文字行盒高度，
    //      使内容整体高度与书架不同 ⇒ 居中落点也不同。
    //   ⚠️ 回退：把下面两行换成 `.margin({ top: 4 }).height('100%')`
    //      即回到"整体下沉 13px"的中间态。
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      Haptics.tap()
      runJellyClick((v: number) => {
        this.jellyScale = v
      })
      this.onTap()
    })
  }
}