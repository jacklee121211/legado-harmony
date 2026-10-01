import confirmDialogExample from '../../../../componets/common/confirmDialog'
import { Haptics } from '../../../../common/utils/Haptics';
import { Books } from '../../../../database/entities/Books'
import { router } from '@kit.ArkUI'
import AppRouter, { RouteName, ReaderRouteParam } from '../../../../common/router/AppRouter'
import BookInfoDialogs from './dialog/BookInfoDialogs'
import booksDao from '../../../../database/dao/BooksDao'
import CommonConstants from '../../../../common/constants/CommonConstants'
import FontConstants from '../../../../common/constants/FontConstants'
import clickUtil from '../../../../common/utils/ClickUtils'
import UiMotion from '../../../../common/utils/UiMotion'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import { LongTakeFlightData } from '../../../../common/utils/LongTakeBook'
import { shelfEntrance } from '../../../../common/utils/EntranceWave'

@Component
/**
 * 书签_宫格
 */
export default struct BookInfoGrids{

  // D-12（Round 28）：@Prop → @ObjectLink，省掉每项 Books 的深拷贝（Books 45 字段，且含嵌套 source/sourceList）。
  // 依据：① 同步源 BookContent.ets:11 `@State bookList:Books[]` 在 @ObjectLink 同步源白名单内；
  //      ② `Books` 由 @Observed 装饰（database/entities/Books.ets:10）；
  //      ③ 本组件不整体赋值 this.book、不写 this.book.* 属性；④ 非 @Entry 组件。
  @ObjectLink book:Books

  // ── 渐次入场（2026-09-24 新增）──────────────────────────────────────────────
  /** 本项在列表里的下标，由 `BookContent` 的 `LazyForEach` 传入（决定错峰延迟）。 */
  @Prop itemIndex: number = 0
  /**
   * 波次编号。父组件每开一波（冷启动 / 切分类 / 切分组 / 切列表↔宫格 / 下拉刷新）就 +1。
   * ⚠️ 为什么不能只靠 `aboutToAppear`：切换分组时 `LazyForEach` 收到 `RELOAD` 后
   *   **不保证销毁重建**已存在的项（键值相同的项会被复用），那样"已入场"标记会残留成 true
   *   ⇒ 动画只播第一次。用 `@Watch` 监听波次编号，可以让**已存在**的项也重置并重播。
   */
  @Prop @Watch('onWaveChanged') waveId: number = 0
  /**
   * 一镜到底（2026-09-23）：封面卡片的组件 id（`LongTakeFlightData.capture()` 按它拍几何）。
   * 由 `BookContent` 传 `'ltCoverG' + index`。
   * ⚠️ 默认空串 = **不参与**一镜到底：书架放大镜搜索浮窗（`ShelfSearchPanel`）也复用本组件
   *    且不传此 prop ⇒ 浮窗里的封面既没有 id 也不会置臂旗，避免"同一本书两个候选起点"
   *    （spec §2.2）—— 浮窗点书走普通转场。
   */
  @Prop longtakeId: string = ''
  /** 是否已经入场（false = 停在动画初态：透明 + 略小 + 略靠下） */
  @State private entered: boolean = false
  /** 入场定时器句柄，卸载时要清掉，避免回调打到已销毁的组件上 */
  private enterTimer: number = -1
  /** 本项的入场延迟；`-1` = 波次已结束，**不播动画** */
  private enterDelay: number = -1

  /**
   * 应用入场策略。
   *
   * 语义（需求第 7 点）：
   *   · `delayFor()` 返回 `-1`（波次已结束）⇒ **同步**把 `entered` 置 true。
   *     此时 `aboutToAppear` 还没走到首次 `build()`，属性压根没经历过"未入场"状态，
   *     ⇒ 即使 `.animation()` 挂着也**一帧动画都不会产生**，等于"直接渲染"。
   *   · 返回 `>= 0`（波次进行中）⇒ 先停在初态，等够延迟再入场 ⇒ 错峰"陆续出现"。
   */
  private applyEntrance(): void {
    if (this.enterTimer !== -1) {
      clearTimeout(this.enterTimer)
      this.enterTimer = -1
    }
    this.enterDelay = shelfEntrance.delayFor(this.itemIndex)
    if (this.enterDelay < 0) {
      this.entered = true
      return
    }
    this.entered = false
    this.enterTimer = setTimeout(() => {
      this.enterTimer = -1
      this.entered = true
    }, this.enterDelay)
  }

  aboutToAppear(): void {
    this.applyEntrance()
  }

  aboutToDisappear(): void {
    if (this.enterTimer !== -1) {
      clearTimeout(this.enterTimer)
      this.enterTimer = -1
    }
  }

  onWaveChanged(): void {
    this.applyEntrance()
  }
  onDelete: () => void = () => {

  }
  /**
   * 点击封面进入阅读器前的回调（2026-09-24 新增，需求第 4 项）。
   * 书架本体的用法不需要；书架搜索浮窗（`ShelfSearchPanel`）复用本组件时传入，
   * 用来在**点书进阅读器的同时关掉浮窗** —— 否则从阅读器返回后浮窗还挂着。
   */
  onBookOpen: () => void = () => {
  }
  @State delCache:boolean = false
  //弹窗
  bookInfoDel: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      cancel: ()=> { this.onCancel() },
      confirm: ()=> { this.onAccept() },
      delCache:this.delCache,
      isShowCache:true
    }),
    cancel: this.exitApp,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    // offset: { dx: 0, dy: '-40%' },
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

  onCancel() {
    console.info('取消')
  }

  onAccept() {
    this.onDelete()
  }

  exitApp() {
    console.info('点外围取消')
  }


  build() {
    Column({
      space:8
    }) {
      Stack(){
        if (this.book.isLocalBook){
          Text('本地')
            .fontColor('#FFEDD4')
            .fontWeight(FontConstants.FONT_WEIGHT_400)
            .fontSize(9)
            .padding(3)
            .backgroundColor('#523000')
            .zIndex(1)
            .borderRadius({
              topRight: 6,
              bottomLeft: 6,
            })
        }
        Stack(){
          if (this.book.isTop){
            Text('置顶')
              .fontColor(Color.White)
              .fontWeight(FontConstants.FONT_WEIGHT_400)
              .fontSize(9)
              .padding(3)
              .borderRadius(5)
              .backgroundColor('rgba(0, 0, 0, 0.45)')
              .zIndex(1)
          }
          Image(this.book.coverUrl)
            .draggable(false)
            .alt($r('app.media.icon_book_default_cover_one'))
            .width(100)
            .height(120)
        }
        .alignContent(Alignment.BottomStart)
      }
      .alignContent(Alignment.TopEnd)
      .backgroundColor($r('app.string.color_black_45'))
      .borderRadius(10)
      // 视觉升级（2026-09-21）：给整张封面卡片加柔和投影。
      // 纯增量属性，不动尺寸/布局 ⇒ 零回归风险。
      .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.22)', offsetX: 0, offsetY: 5 })
      // 一镜到底（2026-09-23）：起飞点。id 挂在这层 Stack 上 —— 宫格封面图本身**没有圆角**
      // （圆角是这层 Stack 的 borderRadius(10)），且这层的位置/尺寸就是封面卡片的可视矩形
      // ⇒ 首帧才能与它精确重合。
      .id(this.longtakeId !== '' ? this.longtakeId : 'ltIdle')
      Column({
        space:CommonConstants.SPACE_2
      }){
        Text(this.book.bookName)
          .fontSize(15)
          .fontWeight(700)
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .maxLines(2)
        //描述
        Text(this.book.customIntro).fontSize(12).fontColor($r('app.color.text_secondary'))
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .fontWeight(500)
          .maxLines(1)
        Text(this.book.durChapterTitle).fontSize(12).fontColor($r('app.color.text_secondary'))
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .fontWeight(500)
          .maxLines(1)
      }
      .width(100)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left:8,right:8,bottom:5,top:5 })
    .onClick(()=>{
      Haptics.tap();
      clickUtil.preventClick(()=>{
        // ── 需求第 6 项修复（2026-09-24）──────────────────────────────────────
        // 原来这里推的是 `RouteName.BOOK_DETAIL`（书籍详情页），与**列表模式**不一致：
        //   `BookInfos.ets` （列表）推的是 `RouteName.READER`（阅读页）。
        // 用户原话：「在宫格模式下，点击书籍是进入书籍详情页，这不对，应该直接进入阅读器」。
        // ⇒ 与列表模式对齐，统一推阅读页。
        // 参数类型必须显式声明（ArkTS `arkts-no-untyped-obj-literals` 禁止无类型字面量）。
        // 2026-09-23：一镜到底正式版 —— 机制同 BookInfos.ets（拍几何 + 置臂旗）。
        //   圆角取 10vp：宫格封面图本身无圆角，圆角是外层 Stack 的 borderRadius(10)。
        //   longtakeId 为空（搜索浮窗复用）⇒ 不参与一镜到底，走普通转场。
        const rp: ReaderRouteParam = { bookData: this.book };
        // ⚠️ 双重冷却闸（与 BookInfos 同款）：ltArm 未释放 / arm released 后 400ms 内
        // 点击 ⇒ 降级普通转场（危险窗口实测 54~84ms，框架层打断缺陷见 Index.ets 注释）
        if (UiMotion.LONGTAKE_ENABLED && this.longtakeId !== ''
          && AppStorage.get<boolean>('ltArm') !== true
          && Date.now() - (AppStorage.get<number>('ltArmReleasedAt') ?? 0) > 400) {
          const ui = this.getUIContext()
          const f = LongTakeFlightData.capture(ui, this.longtakeId,
            ui.vp2px(10), this.book.coverUrl ?? '', this.book.bookName)
          if (f !== null) {
            rp.longTake = f
            AppStorage.setOrCreate('ltArm', true)
          }
        }
        // 点书进阅读器的同时通知宿主（搜索浮窗借机关掉自己，2026-09-24 需求第 4 项）
        this.onBookOpen()
        AppRouter.push(RouteName.READER, rp)
      })
    })
    .gesture(
      LongPressGesture({ repeat: false,duration:500 })
        .onAction((event: GestureEvent) => {
            Haptics.tap();
            this.bookInfoDialog?.open()
        }))
    // 点击按压反馈（2026-09-21）。依据见 `UiMotion` 注释；缩放收紧到 0.96 以规避
    // 官方 NOTE 的「触摸点可能落到控件外」风险。
    .clickEffect(UiMotion.CLICK)
    // ── 渐次入场（2026-09-24 新增，需求第 5 / 7 点）──────────────────────────
    // 只动图形变换属性（opacity / scale / translate），不触发重新布局 ——
    // 官方最佳实践《动画帧率优化》原文：「使用图形变换属性变化组件，而不是直接修改布局属性，
    // 减少布局计算和重绘，降低丢帧率」。
    // ⚠️ `.animation()` 必须放在这三个属性**之后**：官方《出现/消失转场》说明
    //   「TransitionEffect 中 animation 的调用顺序是从上往下，上面 TransitionEffect 的
    //     animation 也会作用到下面 TransitionEffect」—— 属性动画同理，它作用于**它之前**的属性。
    .opacity(this.entered ? 1 : 0)
    .scale({
      x: this.entered ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM,
      y: this.entered ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM
    })
    .translate({ y: this.entered ? 0 : UiMotion.ITEM_ENTER_TRANSLATE_Y })
    .animation(UiMotion.itemEnterParam())
  }
  bookInfoDialog: CustomDialogController | null = new CustomDialogController({
    builder: BookInfoDialogs({
      bookData:this.book,
      // 真开真关（2026-10-01 用户方案），与 BookInfos.ets 同款：子关闭→创建者重查→open
      reopen: (): void => { this.reopenInfoDialog() },
      cancel: () => {
        this.exitDialog()
      }
    }),
    cancel: this.exitDialog,
    autoCancel: true,
    // ★ 与 `BookInfos.ets` 里的长按弹窗**必须完全一致**（同一个弹窗、两个入口）。
    //   悬空四圆角 + 系统真材质；`customStyle: false` 是材质生效的必要条件。
    //   逐条依据见 `BookInfos.ets` 同处注释（SDK `custom_dialog_controller.d.ts:116/125/130-134/681`）。
    width:'92%',
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -16 },
    cornerRadius: 20,
    customStyle:false,
    // 弹窗材质走官方 options 渠道（说明见 BookInfos.ets 同处注释）
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })
  //退出弹框
  exitDialog(){
    this.bookInfoDialog?.close()
  }

  /**
   * 真开真关（2026-10-01 用户方案），与 BookInfos.ets 同款：
   * 子弹窗关闭后重查本书刷新列表项数据，再 open —— 弹窗全新实例，@Prop 快照天然新数据。
   */
  private async reopenInfoDialog(): Promise<void> {
    const id = this.book.id
    if (id !== undefined) {
      const fresh = await booksDao.getBookByIds([id])
      if (fresh.length > 0) {
        this.book.customCoverUrl = fresh[0].customCoverUrl
        this.book.coverUrl = fresh[0].coverUrl
        this.book.bookName = fresh[0].bookName
        this.book.author = fresh[0].author
        this.book.isTop = fresh[0].isTop
      }
    }
    this.bookInfoDialog?.open()
  }
}