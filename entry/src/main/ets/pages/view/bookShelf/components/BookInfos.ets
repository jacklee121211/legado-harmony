import { resolveCoverSource } from "../../../../common/utils/CoverSource"

import { Haptics } from '../../../../common/utils/Haptics'
import { Books } from '../../../../database/entities/Books'
import { router } from '@kit.ArkUI'
import BookInfoDialogs from './dialog/BookInfoDialogs'
import { ezCustomTransition } from '../../../../common/ezlt'
import booksDao from '../../../../database/dao/BooksDao'
import FontConstants from '../../../../common/constants/FontConstants'
import UiMotion from '../../../../common/utils/UiMotion'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import AppRouter, { RouteName, ReaderRouteParam } from '../../../../common/router/AppRouter'
import { shelfEntrance } from '../../../../common/utils/EntranceWave'

@Component
  /**
   * 书签
   */
export default struct BookInfos {
  @Prop currentIndex: number
  // D-12（Round 28）：@Prop → @ObjectLink，省掉每项 Books 的深拷贝（Books 45 字段，且含嵌套 source/sourceList）。
  // 依据：① 同步源 BookContent.ets:11 `@State bookList:Books[]` 在 @ObjectLink 同步源白名单内；
  //      ② `Books` 由 @Observed 装饰（database/entities/Books.ets:10）；
  //      ③ 本组件不整体赋值 this.book、不写 this.book.* 属性；④ 非 @Entry 组件。
  @ObjectLink book: Books
  @State delCache: boolean = false
  /** 书架书名是否显示文件拓展名（我的-设置；默认关=隐藏 .txt 等后缀） */
  @StorageLink('setExtName') showFileExt: boolean = false

  /** 书名显示：开关关闭时剥掉末尾拓展名（.txt/.epub 等，最多 5 位字母数字） */
  private bookDisplayName(): string {
    if (this.showFileExt) {
      return this.book.bookName
    }
    return this.book.bookName.replace(/\.[a-zA-Z0-9]{1,5}$/, '')
  }

  // ── 渐次入场（2026-09-24 新增，需求第 5 / 7 点）──────────────────────────────
  // 与 `BookInfoGrids.ets` 里那一份**逐行同构**（同一个列表的两种展示形态，
  // 手感必须一致）；详细依据与 `.animation()` 的调用顺序要求见那边的注释。
  /** 本项在列表里的下标，由 `BookContent` 的 `LazyForEach` 传入（决定错峰延迟）。 */
  @Prop itemIndex: number = 0
  /** 波次编号：父组件每开一波就 +1 ⇒ 已存在的项也会重置并重播动画。 */
  @Prop @Watch('onWaveChanged') waveId: number = 0
  /**
   * 一镜到底（2026-09-23）：封面节点的组件 id（`LongTakeFlightData.capture()` 按它拍几何）。
   * 由 `BookContent` 传 `'ltCoverL' + index`；空串 = 不参与（当前列表模式恒有值）。
   */
  @Prop longtakeId: string = ''
  /** 是否已经入场（false = 停在动画初态：透明 + 略小 + 略靠下） */
  @State private entered: boolean = false
  /** 入场定时器句柄，卸载时要清掉，避免回调打到已销毁的组件上 */
  private enterTimer: number = -1
  /** 本项的入场延迟；`-1` = 波次已结束，**不播动画**（直接以终态渲染） */
  private enterDelay: number = -1

  /**
   * 应用入场策略。语义见 `EntranceWave.delayFor()`：
   * 返回 `-1` ⇒ 同步置 true（首次 build 前就已是终态 ⇒ 零动画帧，等于直接渲染）；
   * 返回 `>= 0` ⇒ 先停在初态，等够延迟再入场。
   */
  /**
   * 一镜到底「转场进行中」闸：转场没收尾就先等，收尾后再推阅读页。
   * 依据见 `onClick` 里那段注释（真机日志定位的"纯黑阅读器"）。
   * `tries` 上限 8 ≈ 2.2s，防止异常情况下永远不跳。
   */
  private openReaderWhenIdle(rp: ReaderRouteParam, tries: number): void {
    if (AppStorage.get<boolean>(UiMotion.LT_FLAG_TRANSITIONING) === true && tries < 8) {
      setTimeout((): void => {
        this.openReaderWhenIdle(rp, tries + 1)
      }, UiMotion.LT_CLICK_GUARD_MS)
      return
    }
    AppRouter.push(RouteName.READER, rp)
  }

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
  bookInfoDialog: CustomDialogController | null = new CustomDialogController({
    builder: BookInfoDialogs({
      bookData: this.book,
      // 真开真关（2026-10-01 用户方案）：子弹窗关闭后由创建者重查数据再 open ——
      // 弹窗全新实例=全新 @Prop 快照，天然刷新；同时根除 @Consume 重建崩溃（140112）。
      reopen: (): void => { this.reopenInfoDialog() },
      cancel: () => {
        this.exitDialog()
      }
    }),
    cancel: this.exitDialog,
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    // ★ 悬空四圆角（2026-09-22 用户反馈「弹窗有点丑，底部是连着的」）。
    //   options 里**没有** margin 字段（已逐字段核对 `custom_dialog_controller.d.ts:51-682`），
    //   所以左右边距只能用 width 表达；上下方向用 offset：
    //   `offset?: Offset;`（`custom_dialog_controller.d.ts:116`）「Offset of the dialog box
    //   relative to the alignment position.」；`Offset = { dx: Length; dy: Length }`
    //   且**两个字段都是必填**（`units.d.ts:1790/1818`，无 `?`）⇒ 必须写成 `{dx:0, dy:-16}`。
    width: '92%',
    offset: { dx: 0, dy: -16 },
    cornerRadius: 20,
    // ★ `customStyle: true → false` —— 这是**材质能显示出来的必要条件**。
    //   SDK `custom_dialog_controller.d.ts:130-134` 原文：
    //     「When this parameter is set to **true**: 1. The rounded corner radius is 0,
    //       and **the background color is transparent**.」
    //   ⇒ 原来 `true` 时弹窗层是透明的、没有背景，材质无处附着（上次"全透明"的根因）。
    //     `false` 时弹窗才自带一层背景/圆角/阴影，`systemMaterial` 才有地方画。
    //   副作用：系统默认圆角 32vp（同文件 :125），故上面显式给 20。
    customStyle: false,
    // 弹窗材质走**官方对弹窗的正规渠道**（options 字段），而不是内容节点上的通用属性。
    // 官方「组件适配沉浸光感」原文：「弹出框支持通过**弹出框 options 参数中的 systemMaterial
    // 字段**设置沉浸光感效果，如 CustomDialogControllerOptions…」；SDK 声明见
    // `…\ets\component\custom_dialog_controller.d.ts:681` `systemMaterial?: SystemUiMaterial;`（@since 26.0.0）。
    // 配套：`BookInfoDialogs` 里的 `MaterialColumnModifier(..., true)` 会让内容层
    // **一个背景属性都不设**，把这一层的材质透出来。两者必须**同时**存在（见该修饰器的注释）。
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })

  /**
   * 真开真关（2026-10-01 用户方案）：长按弹窗里的子弹窗（封面样式/加入书单等）关闭后，
   * 由创建者**重查本书并刷新列表项数据**，再 open 弹窗——弹窗是全新实例，
   * @Prop 快照天然是新数据（旧实例复用的快照不具备刷新能力）。
   * `book` 是 @ObjectLink（指向列表项本体，@Observed），就地更新字段即可联动列表与弹窗。
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

  build() {
    Flex({
      alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceBetween
    }) {
      Row({
        space: 20
      }) {
        Stack() {
          if (this.book.isLocalBook) {
            Text('本地')
              .fontColor('#FFEDD4')
              .fontWeight(FontConstants.FONT_WEIGHT_400)
              .fontSize(9)
              .padding(3)
              .backgroundColor('#523000')
              .zIndex(1)
              .borderRadius({
                topRight: 6, bottomLeft: 6,
              })
          }
          Stack() {
            if (this.book.isTop) {
              Text('置顶')
                .fontColor(Color.White)
                .fontWeight(FontConstants.FONT_WEIGHT_400)
                .fontSize(9)
                .padding(3)
                .borderRadius(5)
                .backgroundColor($r('app.color.mask_45'))
                .zIndex(1)
            }
            Image(resolveCoverSource(this.book.customCoverUrl ?? '') ?? this.book.coverUrl)
              .draggable(false)
              .alt($r('app.media.icon_book_default_cover_one'))
              // 视觉升级（2026-09-21）：给封面加圆角 + 柔和投影。
              // 纯**增量**属性（没动原有尺寸/布局/手势）⇒ 零回归风险，且不涉及任何状态。
              // `shadow` 是通用属性（CommonMethod），会跟随 `borderRadius` 的圆角轮廓。
              .borderRadius(4)
              .shadow({ radius: 10, color: 'rgba(0, 0, 0, 0.20)', offsetX: 0, offsetY: 4 })
              .width(60)
              .height(80)
              // 一镜到底（2026-09-23）：起飞点。id 挂在封面图上（60×80 那个矩形就是飞行首帧的位置）
              .id(this.longtakeId !== '' ? this.longtakeId : 'ltIdle')
          }.alignContent(Alignment.BottomStart)
        }.alignContent(Alignment.TopEnd)

        Column({
          space: 12
        }) {
          Text(this.bookDisplayName()).fontWeight(700)
          Column() {
            Text(this.book.intro)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .textOverflow({
                overflow: TextOverflow.Ellipsis
              })
              .maxLines(2)
              .fontWeight(500)
              .width('80%')
            Text(this.book.durChapterTitle)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .textOverflow({
                overflow: TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(500)
              .maxLines(1)
          }.alignItems(HorizontalAlign.Start)
        }.alignItems(HorizontalAlign.Start)
      }
    }.onClick(() => {
      Haptics.tap();
      // todo: 暂时屏蔽书籍详情页
      // 迁 Navigation 第 3 期：阅读页已改为 NavDestination，改走路由门面。
      // 2026-09-24：书架→阅读器的"一镜到底"尝试已全部撤除，恢复内置系统转场。
      // 2026-09-23：一镜到底**正式版**回归 —— 点击瞬间拍下封面几何随路由参数带走，
      //   并置臂旗 ltArm 让 READER 建成「飞行分支」（机制见 Index.ets 字段区注释）。
      //   任何一步失败（id 失效/量不到）都自然退回普通转场，不阻塞点书。
      // 参数类型必须显式声明（ArkTS `arkts-no-untyped-obj-literals` 禁止无类型字面量）。
      const rp: ReaderRouteParam = { bookData: this.book };
      // 一镜到底官方库（2026-10-02 迁移 @hmanimations/ezcustomtransition，skill:
      // hmos-arkui-longtake-transition Step 5）：点击时由 generateLongTakeParam
      // 按封面组件 id 拍几何并生成转场参数，随路由带给阅读页；
      // 失败（id 失效等）返回 undefined ⇒ 阅读页走普通分支，不阻塞点书。
      // 打断/手势/生命周期由官方库 session 管理（自研 lt* 机制已退役）。
      if (UiMotion.LONGTAKE_ENABLED && this.longtakeId !== '') {
        const longTakeTransitionParam = ezCustomTransition.generateLongTakeParam(
          this.getUIContext(), this.longtakeId, 4)
        if (longTakeTransitionParam) {
          rp.longTakeTransitionParam = longTakeTransitionParam
        }
      }
      // ── 「转场进行中」闸（2026-10-04 真机定位的"纯黑阅读器"防护）─────────────
      // 现象：快速「打开→返回→立刻再打开」时，第二次打开的正文区全黑（顶/底栏都在）。
      // 真机日志：命中那几次，新阅读页都是在**上一次返回动画还没跑完**时创建的，且该次
      // 打开的阅读引擎渲染实例（EWP `CreatePage`）**从未创建** ⇒ XComponent 有 surface
      // 却没人画 ⇒ 黑。故：转场进行中点书 ⇒ **等转场收尾后再推路由**。
      // （上一代自研实现也有同款冷却闸，见 Index.ets 的 ltArmReleasedAt 注释与证据链。）
      this.openReaderWhenIdle(rp, 0)

      // clickUtil.preventClick(()=>{
      //   router.pushUrl({
      //     url: 'pages/view/BookDetailPage',
      //     params: this.book
      //   })
      // })
    }).gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction((event: GestureEvent) => {
          Haptics.tap();
          this.bookInfoDialog?.open()
        })).padding(10).borderRadius(10)
      // 点击按压反馈（2026-09-21）。依据见 `UiMotion` 的注释：
      // `clickEffect(value: ClickEffect|null)`（common.d.ts:20575，@since 10）。
      // 这里用比官方默认（0.90）更克制的 0.96，降低官方 NOTE 里那条
      // 「the touch point may fall outside the control」的风险。
      .clickEffect(UiMotion.CLICK)
      // ── 渐次入场（2026-09-24 新增）：只动图形变换属性，不触发重新布局 ──────────
      // `.animation()` 必须放在被动画属性**之后**（顺序依据见 `BookInfoGrids.ets` 同处注释）。
      .opacity(this.entered ? 1 : 0)
      .scale({
        x: this.entered ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM,
        y: this.entered ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM
      })
      .translate({ y: this.entered ? 0 : UiMotion.ITEM_ENTER_TRANSLATE_Y })
      .animation(UiMotion.itemEnterParam())
  }

  //退出弹框
  exitDialog() {
    this.bookInfoDialog?.close()
  }
}