import { buttonList } from '../../../../../componets/dataList/buttonList'
import { Haptics } from '../../../../../common/utils/Haptics';
import { Books } from '../../../../../database/entities/Books'
import { router } from '@kit.ArkUI'
import AppRouter, { RouteName } from '../../../../../common/router/AppRouter'
import { showMessage } from '../../../../../componets/common/promptShow'
import confirmDialogExample from '../../../../../componets/common/confirmDialog'
import booksUtil from '../../../../../common/utils/booksUtils'
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
import { resolveCoverSource } from '../../../../../common/utils/CoverSource'
import CoverStyleDialog from './CoverStyleDialog'
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
  // ⚠️ 第 1 项（置顶）的 title 只是**兜底初值** —— build() 里会按 bookData.isTop 实时覆盖
  // （数组初始化器只在组件创建时执行一次，不能依赖它联动，依据见 build() 内注释）。
  // v3.20：图标 symbol 化（SDK 符号表核实）+ 新增「分享」（华为分享，单本直达对方喵阅）
  @State buttonListInfo:buttonList[] = [
    new buttonList(1,this.bookData.isTop?'取消置顶':'置顶',$r('sys.symbol.pin')),
    new buttonList(2,'移动至',$r('sys.symbol.folder')),
    new buttonList(3,'加入书单',$r('sys.symbol.book')),
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
        // v3.21：小封面也走 resolveCoverSource（换默认/自定义封面后本弹窗预览实时同步）
        Image(resolveCoverSource(this.bookData.customCoverUrl ?? '') ?? this.bookData.coverUrl)
          .alt($r('app.media.icon_book_default_cover_one'))
          .width(45).height(65)
          .draggable(false)
          .borderRadius(4)
        Column({ space: 4 }){
          Text(this.bookData.bookName).fontSize(16).fontWeight(500).fontColor($r('app.string.color_black_88'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.bookData.author).fontSize(12).fontWeight(400).fontColor($r('app.string.color_black_45'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
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
                this.coverStyleDialog = null
                this.reopenSelf()
              }
            })
            this.coverStyleDialog?.open()
          })
          Text('书籍详情').fontSize(12).fontWeight(400).fontColor($r('app.string.color_black_45'))
          Image($r('app.media.icon_right')).width(20).height(20).fillColor($r('app.string.color_black_45'))
        } .onClick(()=>{
          Haptics.tap();
          // 迁 Navigation 第 2 期：详情页已改为 NavDestination，改走路由门面
          AppRouter.push(RouteName.BOOK_DETAIL, this.bookData)
          this.controller?.close()
        })
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
        // 子退父进：加入书单弹窗取消 ⇒ 本弹窗恢复
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
    cancel: (): void => {
      this.childDialogClosed()
    }
  })

  bookInfoButton(id:number){
    switch (id){
      case 1 :
        this.isTopBook(); break;
      case 2 :
        this.openChildDialog(this.bookMoveGroup); break;
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
      cancel: ()=> { this.childDialogClosed() }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    cancel: (): void => {
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
  //弹窗
  bookMoveGroup: CustomDialogController | null = new CustomDialogController({
    builder: BookSelectGroupDialog({
      moveGroup: ()=> {
        // setTimeout(()=>{
        //   // this.booksDataSource.deleteData(this.bookData)
        // },500)
        setTimeout(()=>{
          this.bookMoveGroup?.close()
          this.controller?.close()
          this.isBookRefreshing++
        },200)
      },
      // 子退父进：移动分组弹窗被取消（取消按钮/遮罩）⇒ 本弹窗恢复
      onClose: ()=> {
        this.childDialogClosed()
      },
      oldGroupId:this.bookData.bookGroup,
      currentIndex:this.bookData.bookType,
      Ids:this.bookData.id
    }),
    height: 400,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    // ── 沉浸光感材质（2026-09-22 用户要求）─────────────────────────────────
    // 用户：「加入书单的材质应该和**移动分组**的材质对齐，这几个 sheet 都应该和
    //       移动分组的材质对齐」。
    // 但移动分组此前**并没有**材质 ⇒ 先在这里给它加上，作为"有材质"的基准。
    // 走的是官方对弹窗的正规渠道（`CustomDialogControllerOptions.systemMaterial`，
    // `custom_dialog_controller.d.ts:681`，@since 26.0.0）。
    // 配套：`BookSelectGroupDialog` 的根 Column 已用 `MaterialColumnModifier(Color.White, true)`
    // 让出背景（否则白底会挡住材质）。
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    cancel: (): void => {
      this.childDialogClosed()
    }
  })

  //刷新懒加载数据
  async refreshLazyData(){
    // this.booksDataSource.reloadNewData([this.bookData])
  }

}
