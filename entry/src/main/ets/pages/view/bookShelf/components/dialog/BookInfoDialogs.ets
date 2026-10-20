import { buttonList } from '../../../../../componets/dataList/buttonList'
import { Haptics } from '../../../../../common/utils/Haptics';
import { Books } from '../../../../../database/entities/Books'
import { router } from '@kit.ArkUI'
import AppRouter, { RouteName } from '../../../../../common/router/AppRouter'
import { showMessage } from '../../../../../componets/common/promptShow'
import confirmDialogExample from '../../../../../componets/common/confirmDialog'
import booksUtil from '../../../../../common/utils/booksUtils'
// 2026-10-12：「移动至」打开前预取分组，避免弹窗首帧空白
import bookGroupUtils from '../../../../../common/utils/bookGroupUtils'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import booksDao from '../../../../../database/dao/BooksDao'
import BookSelectGroupDialog from './BookSelectGroupDialog'
import AddToBookListDialog from './AddToBookListDialog'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import { NightMode } from '../../../../../common/utils/NightMode'
// ── v3.20：长按弹窗按钮 symbol 化 + Q弹 + 单本分享（与管理页同款配方）─────────
import UiMotion, { runJellyClick } from '../../../../../common/utils/UiMotion';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ShelfColors } from '../../../../../common/utils/NightMode'
import { resolveBookCover } from '../../../../../common/utils/CoverSource'
import CoverStyleDialog from './CoverStyleDialog'
import RenameBookDialog from './RenameBookDialog'
import MarkToolButton from '../../../../../componets/common/MarkToolButton'

@CustomDialog
/**
 * 书籍长按
 */
export default struct BookInfoDialogs{
  controller?: CustomDialogController
  //推送提醒
  @Prop bookData:Books
  @State pushReminder:boolean = false
  /**
   * 真开真关（2026-10-01 用户方案）：子弹窗关闭后由**创建者**（BookInfos/BookInfoGrids）
   * 重查数据并**新建 controller** 全新实例打开。未传（null）时回退旧的自恢复路径。
   * ⚠️ 背景：本弹窗原来的 `@Consume('booksDataSource')` 在 close→open 复用重建时
   * 解析不到 @Provide，真机 BusinessError 140112 三连闪退（2.md 18:22/18:23，进程被杀）
   * —— @Consume 字段本身已随死代码一并删除，此类崩溃不可能再发生。
   */
  reopen: (() => void) | null = null
  /**
   * 改名完成回调（2026-10-05）：**由创建者**重查本书 + 广播 `BOOK_IS_BOOK_REFRESHING`。
   * 语义与 `reopen` 不同 —— 改名后**不恢复本弹窗**（对象已改名，本弹窗的 @Prop 快照作废；
   * 规范 §4.2「确认后父弹窗不恢复」的同类：操作改变了对象 ⇒ 整条链关闭）。
   */
  onBookRenamed: ((newName: string) => void) | null = null
  /** 「重命名」入口的 Q 弹缩放（规范 §1.2 三件套，每个按钮独立状态） */
  @State renameScale: number = 1
  // ⚠️ 第 1 项（置顶）的 title 只是**兜底初值** —— build() 里会按 bookData.isTop 实时覆盖
  // （数组初始化器只在组件创建时执行一次，不能依赖它联动，依据见 build() 内注释）。
  // v3.20：图标 symbol 化（SDK 符号表核实）+ 新增「分享」（华为分享，单本直达对方喵阅）
  @State buttonListInfo:buttonList[] = [
    new buttonList(1,this.bookData.isTop?'取消置顶':'置顶',$r('sys.symbol.pin')),
    new buttonList(2,'移动至',$r('sys.symbol.folder')),
    // ── 2026-10-19：移除「加入书单」入口（用户需求第 3 条）─────────────────────
    // 用户原话：「删除单本书籍长按弹窗的加入书单入口」。
    // 「删除所有书单入口…只针对入口，具体功能暂时不引用了，屏蔽入口。」
    // ⇒ 只从菜单里去掉这一项；`openAddToBookList()` / `AddToBookListDialog` 组件
    //   与 `worksListsDao` 全部保留，零功能删除。
    // 想恢复入口：把 `new buttonList(3,'加入书单',$r('sys.symbol.book'))` 插回本数组
    //   第 3 位即可（`buttonClick` 的 case 3 分支仍然完好）。
    //   注意该项的 id 是 3，其它项 id 不变 ⇒ 恢复不会影响置顶/移动/删除/分享的绑定。
    new buttonList(4,'删除',$r('sys.symbol.trash')),
    new buttonList(6,'分享',$r('sys.symbol.share'))
  ]
  // （2026-10-01 已删除 `@Consume('booksDataSource')` 死字段：它只被从未被调用的
  //  getIndexByIsTopFalse() 引用，且在弹窗 close→open 复用重建时 @Provide 解析失败，
  //  真机 BusinessError 140112 三连闪退（2.md 18:22:50 / 18:22:59 / 18:23:41）。
  //  数据刷新已统一走 BOOK_IS_BOOK_REFRESHING 广播 + LazyForEach 键值重建。）

  private coverStyleDialog: CustomDialogController | null = null
  // ── 子进父退 / 子退父进（2026-10-01 统一联动规范，与 FolderInfoDialog 同款）──────
  // 出规则：子弹窗打开前先关掉本弹窗；入规则：子弹窗取消/遮罩关闭后把本弹窗开回来。
  // 例外（确认后父弹窗**不**恢复）：移动至（书已搬走）、删除（书已不存在）。
  private openChildDialog(controller: CustomDialogController | null): void {
    this.controller?.close()
    controller?.open()
  }
  private childDialogClosed(): void {
    this.controller?.open()
  }
  /** 父弹窗恢复前重查本书（2026-10-01 修"换封面后长按弹窗头部预览还是旧封面"）：
   *  CustomDialog 的 @Prop 是**创建瞬间的快照**（SDK NOTE「Custom dialog box parameters
   *  do not support dynamic updates」），controller.open() 复用旧快照 ⇒ 必须显式重查。 */
  private async refreshSelfBook(): Promise<void> {
    if (!this.bookData.id) {
      return
    }
    const fresh: Books[] = await booksDao.getBookByIds([this.bookData.id])
    if (fresh.length > 0) {
      this.bookData = fresh[0]
    }
  }
  /** 父弹窗恢复：优先走创建者的"真开真关"重建；未传时回退旧的 refresh+open */
  private reopenSelf(): void {
    if (this.reopen) {
      this.reopen()
      return
    }
    this.refreshSelfBook()
    this.controller?.open()
  }

  /**
   * 打开「重命名」子弹窗（2026-10-05）。
   * 规范要点：
   *  · §4.4 地雷表「弹窗参数动态更新无效」⇒ **打开瞬间 new 一个新 controller**（不复用字段）；
   *  · §2.2 options 配方（customStyle:false + cornerRadius:20 + systemMaterial + SPRING_FAST）；
   *  · §4.1 子进父退：先 `openChildDialog`（父退 + 子进）；
   *  · 取消/遮罩 ⇒ `childDialogClosed()` 恢复父弹窗（入规则）；
   *  · 改名成功 ⇒ **不恢复父弹窗**（对象已改名，快照作废）+ 通知创建者刷新列表（§4.2 同类）。
   *
   * ⚠️ 2026-10-12 修复：子组件 `RenameBookDialog` 内 `this.controller?.close()` 无效
   * （SDK 限定只能由创建 controller 的父组件关），所以**本方法持有 renameDialog 引用**，
   * 在 cancel/onRenamed/options.cancel 回调里**主动 close** 它，再决定是否恢复父弹窗。
   */
  private renameDialogCtrl: CustomDialogController | null = null
  private openRenameDialog(): void {
    const renameDialog = new CustomDialogController({
      builder: RenameBookDialog({
        bookData: this.bookData,
        cancel: (): void => {
          // 先关子，再恢复父
          this.renameDialogCtrl?.close()
          this.renameDialogCtrl = null
          this.childDialogClosed()
        },
        onRenamed: (newName: string): void => {
          // 先关子，再通知刷新（不恢复父弹窗：对象已改名，快照作废）
          this.renameDialogCtrl?.close()
          this.renameDialogCtrl = null
          if (this.onBookRenamed) {
            this.onBookRenamed(newName)
          }
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '80%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        // 遮罩/返回键：先关子，再恢复父
        this.renameDialogCtrl?.close()
        this.renameDialogCtrl = null
        this.childDialogClosed()
      }
    })
    this.renameDialogCtrl = renameDialog
    this.openChildDialog(renameDialog)
  }

  cancel: () => void = () => {
  }
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0

  /** 卡片背板：**调用方已通过 `CustomDialogControllerOptions.systemMaterial` 提供材质**，
   *  所以第二个参数传 `true` ⇒ 内容层**一个背景属性都不设**，把弹窗层材质透出来。
   *  详见 `MaterialColumnModifier` 的注释（让开背景只有在"确实有材质兜底"时才安全）。
   *
   *  ⚠️ 2026-09-22 改版：调用方已把 `customStyle` 从 `true` 改成 `false`。
   *  这是材质能显示的**必要条件** —— SDK
   *  `custom_dialog_controller.d.ts:130-134` 原文：
   *    「When this parameter is set to **true**: 1. The rounded corner radius is 0,
   *      and **the background color is transparent**.」
   *  ⇒ `customStyle: true` 时弹窗层根本没有背景，材质无处可画（这正是上次"全透明"的根因）；
   *    只有 `false` 时弹窗才有自己那一层来承载 `systemMaterial`。
   *  万一材质没生效，`MaterialColumnModifier` 会自动落回白实底（不会又变透明）。 */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  build() {
    Column(){
      // ── 头部行（2026-10-01 重排，修"书名与右侧图标间距过大、封面/书籍详情溢出"）──
      // 旧结构：左侧 Row 固定 `width('80%')` + 书名 Text 固定 `width('75%')`，
      // 书名把右侧（封面/书籍详情/箭头）挤出边界。新结构：封面图 + 中间列
      // `layoutWeight(1)`（自适应吃剩余宽度、书名/作者超长省略）+ 右侧动作区
      // `flexShrink(0)`（绝不压缩），间距由 layoutWeight 自然分配。
      Row({ space: 12 }){
        // 2026-10-13：走 `resolveBookCover`（四层：自定义 > 自带 > 书源 > 默认）；
        // 换封面/重置后本弹窗恢复时会 `refreshSelfBook` 重查 ⇒ 预览实时同步。
        Image(resolveBookCover(this.bookData))
          .alt($r('app.media.icon_book_default_cover_one'))
          .width(45).height(65)
          .draggable(false)
          .borderRadius(4)
        Column({ space: 4 }){
          Text(this.bookData.bookName).fontSize(16).fontWeight(500).fontColor($r('app.string.color_black_88'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // ── 「重命名」入口（2026-10-05 用户方案：作者行换成重命名入口，不再显示作者）──
          // 规范 §1.2 手写三件套：SymbolGlyph + Haptics.tap() + runJellyClick（+ clickEffect）。
          // 符号名取自 SDK 资源表 `openharmony/toolchains/id_defined.json`：
          //   `{ "type": "symbol", "name": "square_and_pencil", "order": 2504 }`（同表还有 _fill）
          //   —— 不猜名字，按表取值。
          Row({ space: 4 }){
            SymbolGlyph($r('sys.symbol.square_and_pencil'))
              .fontSize(13)
              .fontColor([$r('app.string.color_black_45')])
            Text('重命名').fontSize(12).fontWeight(400).fontColor($r('app.string.color_black_45'))
          }
          .scale({ x: this.renameScale, y: this.renameScale })
          .onClick((): void => {
            Haptics.tap()
            runJellyClick((v: number): void => {
              this.renameScale = v
            })
            this.openRenameDialog()
          })
          .clickEffect(UiMotion.CLICK)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({
          space:8
        }){
          // v3.21：自定义封面入口（用户需求：书籍详情前加 symbol 图标按钮）
          Row({
            space:4
          }){
            SymbolGlyph($r('sys.symbol.picture'))
              .fontSize(14)
              .fontColor([$r('app.string.color_black_45')])
            Text('封面').fontSize(12).fontWeight(400).fontColor($r('app.string.color_black_45'))
          }
          .onClick(()=>{
            Haptics.tap();
            // 子弹窗出现 ⇒ 父弹窗退出（出规则，见 coverStyleDialog 联动）
            this.controller?.close()
            this.coverStyleDialog = new CustomDialogController({
              builder: CoverStyleDialog({
                bookData: this.bookData,
                onClose: (): void => {
                  // ⚠️ 2026-10-12：**先真的 close 封面弹窗**。
                  //   `CoverStyleDialog` 内部自己也会 `controller.close()`，但**子组件内
                  //   close() 不可靠**（真机两次验证，见 `ReaderSaveSchemeDialog.ets:205-208`）
                  //   ⇒ 这里由持有引用的调用方补一道，确保它真的关掉；
                  //   否则父弹窗被 `reopenSelf()` 召回、封面弹窗还留着 ⇒ 双弹窗叠加。
                  this.coverStyleDialog?.close()
                  this.coverStyleDialog = null
                  // 子弹窗退出 ⇒ 父弹窗出现（入规则）
                  this.reopenSelf()
                }
              }),
              autoCancel: true,
              alignment: DialogAlignment.Center,
              width: '92%',
              cornerRadius: 20,
              customStyle: false,
              systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
              openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
              closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
              cancel: (): void => {
                // ⚠️ 2026-10-12：遮罩/返回键路径同样**必须真的 close**，
                //   只置空引用会让子弹窗留在屏幕上而父弹窗被召回（同 bookMoveGroup 那个坑）。
                this.coverStyleDialog?.close()
                this.coverStyleDialog = null
                this.reopenSelf()
              }
            })
            this.coverStyleDialog?.open()
          })
          // ── 「书籍详情」入口（2026-10-18 改为**独立子组**）──────────────────
          // 真机问题：旧实现把 `onClick`（跳详情）挂在**外层 Row** 上，而「封面」是它的
          // 子节点 —— ArkUI 的 `onClick` 会沿父链触发，点「封面」时**两个都执行**
          // （封面弹窗刚建出来就被 `AppRouter.push(BOOK_DETAIL)` 覆盖/打乱）。
          // 现在两个入口各自成组、各挂各的 onClick，外层不再有 onClick。
          Row({
            space:4
          }){
            Text('书籍详情').fontSize(12).fontWeight(400).fontColor($r('app.string.color_black_45'))
            Image($r('app.media.icon_right')).width(20).height(20).fillColor($r('app.string.color_black_45'))
          }
          .onClick(()=>{
            Haptics.tap();
            // 迁 Navigation 第 2 期：详情页已改为 NavDestination，改走路由门面
            AppRouter.push(RouteName.BOOK_DETAIL, this.bookData)
            this.controller?.close()
          })
        }
        .flexShrink(0)
      }
      .alignItems(VerticalAlign.Center)
      .margin(20)
      // v3.21：移除按钮区上下两条 Divider（用户反馈"上下各有一条灰色的线"）
      // 图标区间距与长按分组弹窗同规范（grid_row.d.ts:371 gutter.y；组与取消键间距 24）
      GridRow({
        columns:5,
        gutter:{ x:0, y:12 }
      }){
        ForEach(this.buttonListInfo,(item:buttonList)=>{
          GridCol(){
            // v3.20：symbol + Q弹（runJellyClick 自驱 scale，与管理页 ManageToolButton 同款）
            MarkToolButton({
              icon: item.icon,
              label: item.id === 1 ? (this.bookData.isTop ? '取消置顶' : '置顶') : item.title,
              onTap: (): void => {
                this.bookInfoButton(item.id)
              }
            })
          }
        })
      }
      .padding({ left:12, right:12, top:8 })
      // v3.21：移除第二条 Divider（用户反馈）
      Column(){
        Text('取消')
          .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)')
          .fontSize(16).fontWeight(400).lineHeight(24).textAlign(TextAlign.Center)
      }
      .onClick(()=>{
        Haptics.tap();
        this.cancel()
        this.controller?.close()
      })
      .alignItems(HorizontalAlign.Center)
      .margin({ top:24 })
      .padding({bottom:16})

      Flex()
    }
    // 四角都圆（原来是只圆上面两个角、下面两个角贴底）。
    // 配合两个调用点 options 里的 `cornerRadius: 20` + `offset{dx:0,dy:-16}` ⇒ 悬空四圆角矩形。
    // 这里只是**兜底**：材质生效时背景由弹窗层画、圆角也由它裁；
    // 材质不可用时内容层回落成白实底，四角也必须是圆的才不会露直角。
    .borderRadius(20)
    // 背板（2026-09-21 接入沉浸光感）。本卡片宽度铺满、高约 300vp，
    // 不属于官方点名的「接近全屏的超大面积」（官方功耗文档正例 328×216、反例 100%×100%）。
    // 用修饰器而不是 `.backgroundColor(Color.White)`：官方原文「已主动设置背景色…则不呈现
    // 沉浸光感效果」，所以开启时**必须根本不调** backgroundColor，见 MaterialColumnModifier 注释。
    .attributeModifier(this.surface)
    .width('100%')
  }

  /**
   * 「加入书单」弹窗（2026-09-22 从 `bindSheet` 改成 `@CustomDialog`）。
   *
   * ── 为什么必须改 ──────────────────────────────────────────────────────────
   * 用户原话：「我的意思是**加入书单的弹窗是白色的**，不是这种（半透明沉浸光感）…
   *            阅读器目录书签 sheet 也需要独立圆角，材质也要统一上面那种沉浸光感，
   *            书架搜索浮窗同上」。
   *
   * 而 **`SheetOptions` 里没有任何材质字段** —— 已逐个核对 `common.d.ts` 的
   * `interface SheetOptions` 全部 36 个字段（`height`/`dragBar`/`maskColor`/`detents`/
   * `blurStyle`/`showClose`/`preferType`/`title`/…/`radius`/`placement`/
   * `placementOnTarget`/…），**没有 `systemMaterial`**
   * ⇒ **sheet 载不了沉浸光感材质**，只能实色/半透明模拟。
   *
   * ⇒ 官方给弹窗材质的正规渠道是 `CustomDialogControllerOptions.systemMaterial`
   *   （`custom_dialog_controller.d.ts:681`，@since 26.0.0），且实测**前提是
   *   `customStyle: false`**（`true` 时 dialog 层背景透明、材质无处附着）。
   *   本工程长按书籍弹窗就是这么做的，已是真机验证过的"半透明沉浸光感"。
   *
   * 所以这里改成 `@CustomDialog` + `customStyle:false` + `systemMaterial` +
   * `offset{dy:-16}`（悬空四圆角），与长按弹窗**完全同款**。
   */
  catalogAddShelfDialog: CustomDialogController | null = new CustomDialogController({
    builder: AddToBookListDialog({
      currentIndex: this.bookData.bookType,
      ids: this.bookData.id ? [this.bookData.id] : [],
      bookOrFolder: 0,
      cancel: () => {
        // 子退父进：加入书单弹窗取消 ⇒ 关闭子弹窗 + 父弹窗恢复
        //
        // ⚠️ 2026-10-12：**必须先真的 close 子弹窗**。旧写法只调 `childDialogClosed()`
        //   把父弹窗召回来，子弹窗却还留在屏幕上 ⇒ 与「移动分组」完全同款的双弹窗叠加。
        //   （`AddToBookListDialog` 内部自己的 `controller.close()` 在 @CustomDialog
        //    子组件里不可靠 —— 真机两次独立验证，见 `ReaderSaveSchemeDialog.ets:205-208`
        //    与 `RenameBookDialog` 的类注释。）
        this.catalogAddShelfDialog?.close()
        this.childDialogClosed()
      }
    }),
    autoCancel: true,
    // 2026-09-25 用户反馈：加入书单弹窗改**标准居中四圆角材质**（原贴底老款式）
    // 2026-10-01 补 `height: 400`：内部 catalogAddShelf 根节点是 `height('100%')`，
    // 弹窗层无确定高度时百分比按最大约束解 ⇒ 弹窗被撑满整屏、圆角顶到屏幕边缘，
    // 观感退回老式全屏 sheet（用户复测："还是没有实现四圆角那种项目统一"）。
    // 固定高 400 与"移动分组"弹窗同款（其 options 即 `height: 400`）。
    alignment: DialogAlignment.Center,
    width: '80%',
    height: 400,
    cornerRadius: 20,
    customStyle: false,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    // 遮罩/返回键：同一条收尾路径，一样要 close 子弹窗（2026-10-12 一并修）
    cancel: (): void => {
      this.catalogAddShelfDialog?.close()
      this.childDialogClosed()
    }
  })

  bookInfoButton(id:number){
    switch (id){
      case 1 :
        this.isTopBook(); break;
      case 2 :
        // 「移动至」：打开前先预取分组（2026-10-12），避免弹窗首帧空白
        this.openMoveGroupDialog().catch((e: Error): void => {
          console.error('openMoveGroupDialog failed: ' + e.message)
        }); break;
      case 3 :
        this.openChildDialog(this.catalogAddShelfDialog); break;
      case 4 :
        this.openChildDialog(this.bookDelDialog); break;
      case 6 :
        this.shareSingle(); break;
    }
  }

  /**
   * 单本分享（v3.20，与管理页 manageShare 同一 API 链）：systemShare.SharedData
   * （utd 按后缀解析 + fileUri）→ ShareController.show 拉起华为分享面板。
   * 对端装了喵阅 ⇒ 分享面板推荐区直达 ⇒ 分享即入库。
   */
  private async shareSingle(){
    const path: string = this.bookData.bookUrl ?? ''
    if (path === '') {
      showMessage('该书没有可分享的文件');
      return
    }
    try {
      const suffix: string = path.substring(path.lastIndexOf('.'))
      let utdId: string = 'general.text'
      try {
        utdId = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(suffix) ?? 'general.text'
      } catch (err) {
        // 未知后缀退回 general.text
      }
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utdId,
        uri: fileUri.getUriFromPath(path),
        title: this.bookData.bookName ?? '书籍'
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData)
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      })
    } catch (err) {
      const e = err as BusinessError
      showMessage('分享失败：' + e.message)
    }
  }

  @State delCache:boolean = false
  //弹窗
 bookDelDialog: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      confirm: ()=> { this.deleteGroup() },
      delCache:this.delCache,
      // 2026-10-12：取消路径**必须真的 close** 删除确认弹窗，否则它留在屏幕上而长按弹窗被召回
      cancel: ()=> {
        this.bookDelDialog?.close()
        this.childDialogClosed()
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    // 遮罩/返回键：同上（2026-10-12 一并修）
    cancel: (): void => {
      this.bookDelDialog?.close()
      this.childDialogClosed()
    }
  })

  deleteGroup() {
    this.deleteBook()
    this.cancel()
  }

  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0

  async deleteBook(){
    if (this.bookData.id){
      booksUtil.delBooksById(this.bookData.id)
    }
    // let index = this.booksDataSource.getIndex(this.bookData)
    // this.booksDataSource.deleteData(index)
    setTimeout(()=>{
      this.isBookRefreshing++
      this.controller?.close()
    },200)
    showMessage('删除成功')
  }

  async isTopBook(){
    if (this.bookData.id){
      booksUtil.isTopBook(this.bookData.id, !this.bookData.isTop).then((val)=>{
        val?showMessage(!this.bookData.isTop?'置顶成功':'取消置顶成功'):showMessage('数据更新失败')
      })
    }
    // let index = this.booksDataSource.getIndex(this.bookData)
    // this.bookData.isTop = !this.bookData.isTop
    // if (this.bookData.isTop){
    //   this.booksDataSource.deleteData(index)
    //   this.booksDataSource.unshiftData(this.bookData)
    // } else {
    //   let newIndex = this.getIndexByIsTopFalse()
    //   if (newIndex > 1) {
    //     this.booksDataSource.moveDataUpdate(index, newIndex-1,this.bookData)
    //   }
    //   this.booksDataSource.changeData(newIndex > 1?newIndex - 1:index,this.bookData)
    // }
    setTimeout(()=>{
      this.isBookRefreshing++
      this.controller?.close()
    },200)

  }
  //（2026-10-01 已删除 getIndexByIsTopFalse()：唯一调用点早已被注释，其唯一数据依赖
  //  @Consume booksDataSource 正是 140112 闪退源头。）

  //移动分组
  /**
   * 「移动至」弹窗（2026-10-12 改为**打开时新建 controller + 预取分组**）。
   *
   * ── 为什么要改 ────────────────────────────────────────────────────────────
   * 旧实现是**字段初始化器**里 new 一个 controller 并 `open()` 它（参数在组件构造
   * 那一刻就固化了）。而 `BookSelectGroupDialog` 的分组列表是在自己的
   * `aboutToAppear()` 里**异步**查库的 ⇒ 弹窗打开瞬间列表是空的，几百 ms 后
   * 分组才"跳"出来。用户原话：
   *   「进入自定义分组1，长按菜单-移动至，此时未分组还没被刷新出来，过一会儿才刷新出来」。
   *
   * 修法（与 `openRenameDialog()` 同款，符合规范 §4.4「参数动态更新无效 ⇒
   * 打开瞬间 new 一个新 controller」）：
   *   ① **先 `await` 预取分组**（`bookGroupUtils.prefetchGroups`）；
   *   ② 再把结果经 `presetGroups` 传给弹窗 ⇒ 首帧就有完整列表；
   *   ③ 每次打开都 new controller，参数天然是当次最新。
   */
  private bookMoveGroup: CustomDialogController | null = null
  private async openMoveGroupDialog(): Promise<void> {
    // ① 预取（失败返回空数组，弹窗退回自己的异步兜底路径，不会卡住打开动作）
    const groups: BookGroups[] = await bookGroupUtils.prefetchGroups(this.bookData.bookType)
    const dlg = new CustomDialogController({
      builder: BookSelectGroupDialog({
        moveGroup: (): void => {
          setTimeout((): void => {
            this.bookMoveGroup?.close()
            this.bookMoveGroup = null
            this.controller?.close()
            this.isBookRefreshing++
          }, 200)
        },
        // 子退父进：移动分组弹窗被取消（取消按钮/遮罩）⇒ 本弹窗恢复
        //
        // ⚠️ 2026-10-12 修「取消按钮点了循环」：**必须先真正 close 子弹窗**。
        //   旧写法这里是 `this.bookMoveGroup = null; this.childDialogClosed()` ——
        //   **只把引用置空、根本没关**，而 `BookSelectGroupDialog` 内部自己的
        //   `this.controller?.close()` 在 `@CustomDialog` 子组件里又是空操作
        //   ⇒ 子弹窗一直留在屏幕上，父弹窗却被 `childDialogClosed()` 召回来了
        //   ⇒ 两个弹窗叠着，再操作就是用户说的"循环"。
        //   现在：关闭子弹窗（唯一持有引用的地方）→ 清引用 → 恢复父弹窗。
        onClose: (): void => {
          this.bookMoveGroup?.close()
          this.bookMoveGroup = null
          this.childDialogClosed()
        },
        // ── 新建分组成功后**真开真关**重开本弹窗（2026-10-13）────────────────
        // 旧实现：弹窗自己 `setTimeout(500) → getGroupList()` 刷新，但点「+」时它
        // 已经被 `close()` ⇒ 刷新写在已销毁的实例上；重开时 `aboutToAppear` 又用
        // `presetGroups`（创建瞬间的旧快照）覆盖列表 ⇒ 新分组**永远不出现**。
        // 现在：关掉旧实例 → 重新 `prefetchGroups()` → new controller → open，
        // `presetGroups` 天然是当次最新（与本文件 `openRenameDialog` 同款"打开瞬间重建"）。
        onGroupCreated: (): void => {
          this.bookMoveGroup?.close()
          this.bookMoveGroup = null
          this.openMoveGroupDialog().catch((e: Error): void => {
            console.error('openMoveGroupDialog after create failed: ' + e.message)
          })
        },
        oldGroupId: this.bookData.bookGroup,
        currentIndex: this.bookData.bookType,
        Ids: this.bookData.id,
        // ② 预取好的快照 ⇒ 弹窗首帧就成型
        presetGroups: groups
      }),
      height: 400,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      customStyle: false,
      cornerRadius: 25,
      // ── 沉浸光感材质（2026-09-22 用户要求）─────────────────────────────────
      // 走官方对弹窗的正规渠道 `CustomDialogControllerOptions.systemMaterial`
      // （`custom_dialog_controller.d.ts:681`，@since 26.0.0）。
      // 配套：`BookSelectGroupDialog` 的根 Column 用 `MaterialColumnModifier(Color.White, true)`
      // 让出背景（否则白底会挡住材质）。
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      // 遮罩 / 返回键：与取消按钮同一条收尾路径 —— **必须真的 close 子弹窗**，
      // 否则同样会出现"子弹窗还在、父弹窗冒出来"（2026-10-12 一并修）。
      cancel: (): void => {
        this.bookMoveGroup?.close()
        this.bookMoveGroup = null
        this.childDialogClosed()
      }
    })
    this.bookMoveGroup = dlg
    this.openChildDialog(dlg)
  }

  //刷新懒加载数据
  async refreshLazyData(){
    // this.booksDataSource.reloadNewData([this.bookData])
  }

}
