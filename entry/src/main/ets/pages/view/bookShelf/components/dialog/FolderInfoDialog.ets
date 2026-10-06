import bookGroupUtil from '../../../../../common/utils/bookGroupUtils'
import { Haptics } from '../../../../../common/utils/Haptics';
import { NightMode } from '../../../../../common/utils/NightMode'
import commonInputDialog from '../../../../../componets/common/commonInputDialog'
import confirmDialogExample from '../../../../../componets/common/confirmDialog'
import MarkToolButton from '../../../../../componets/common/MarkToolButton'
import { showMessage } from '../../../../../componets/common/promptShow'
import TitleContentDialog from '../../../../../componets/common/TitleContentDialog'
import { buttonList } from '../../../../../componets/dataList/buttonList'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import BookGroupsDao from '../../../../../database/dao/BookGroupsDao'
import booksDao from '../../../../../database/dao/BooksDao'
import BookSelectGroupDialog from './BookSelectGroupDialog'
import AddToBookListDialog from './AddToBookListDialog'
import coverInfoDialog from './coverInfoDialog'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../../../common/utils/UiMotion'

@CustomDialog
/**
 * 文件夹长按弹窗
 */
export default struct FolderInfoDialog{
  controller?: CustomDialogController

  /**
   * 弹窗背板（2026-09-21 接入沉浸光感）。底部面板、高度不大，
   * 不属官方点名的「接近全屏的超大面积」。用修饰器的原因见
   * `MaterialColumnModifier` 注释 —— 这行白底会把 Dialog 的**自动沉浸**挡掉。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  //推送提醒
  @Prop itemData:BookGroups
  @State pushReminder:boolean = false
  // v3.21：图标 symbol 化（SDK 符号表核实）——eye/eye_slash 随 show 状态在 build 里切换
  @State buttonListInfo:buttonList[] = [
    new buttonList(1,'重命名',$r('sys.symbol.square_and_pencil')),
    new buttonList(2,'置顶',$r('sys.symbol.pin')),
    new buttonList(3,'移动至',$r('sys.symbol.folder')),
    new buttonList(4,'加入书单',$r('sys.symbol.book')),
    new buttonList(5,'封面样式',$r('sys.symbol.picture')),
    new buttonList(6, this.itemData.show?'隐藏分组':'显示分组',this.itemData.show?$r('sys.symbol.eye_slash'):$r('sys.symbol.eye')),
    new buttonList(7,'解散分组',$r('sys.symbol.trash')),
    new buttonList(8,'删除',$r('sys.symbol.ohos_trash'))
  ]
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  /**
   * 「共N本」的**真实值**（2026-10-06）。
   *
   * 原来是直接读 `this.itemData.bookIds?.length` —— 那是 `book_groups.bookIds` 这个陈旧
   * 冗余列（只在「移动分组」时追加，导入/删除都不同步），真机 novel.db 实测自建分组名下
   * 8 本书而该列是空串；再叠加 `DbUtil.parseResultSet` 把空串读成 undefined
   * （`DbUtil.ets:333`）⇒ 恒显示"共0本"。
   * 现在按 `books.bookGroup` 现算（WHERE 与点进去的列表同源），初值仍取 @Prop 的快照值
   * 以免异步回来前闪一下 0。
   */
  @State realBookCount: number = this.itemData.bookIds?.length || 0
  aboutToAppear(): void {
    this.refreshBookCount()
  }

  /** 现算本分组书籍数（入口处 + 兜底重查后都要调） */
  private async refreshBookCount(): Promise<void> {
    const id: number | undefined = this.itemData.groupId
    if (id === undefined) {
      return
    }
    try {
      const ids: string[] = await booksDao.queryBookIds({
        type: this.itemData.groupType,
        bookGroup: id
      })
      this.realBookCount = ids.length
    } catch (e) {
      console.log('FolderInfoDialog refreshBookCount, Error, ', JSON.stringify(e))
    }
  }
  cancel: () => void = () => {

  }

  // ── 子进父退 / 子退父进（2026-10-01 统一联动规范）────────────────────────────
  // 出规则：任何子弹窗打开前先关掉本弹窗（父退），子弹窗才进（子进）；
  // 入规则：子弹窗关闭后恢复本弹窗。
  // ⚠️ 恢复方式（2026-10-01 用户方案「真正的打开和关闭」）：创建者传入 `reopen` 时走
  // 创建者重建（重查数据 + 全新实例 = 全新 @Prop 快照，天然刷新）；未传时回退旧的
  // 自恢复路径（重查 + controller.open 复用）。
  // 三类例外（子弹窗确认后父弹窗**不**恢复，直接全关）：
  //   · 移动至：分组已搬走；· 隐藏/解散/删除：分组已不存在。
  reopen: (() => void) | null = null
  private openChildDialog(controller: CustomDialogController | null): void {
    this.controller?.close()
    controller?.open()
  }
  private async childDialogClosed(): Promise<void> {
    if (this.reopen) {
      this.reopen()
      return
    }
    // 兜底：创建者未接 reopen —— 重查该分组后原地复用 controller 打开
    if (this.itemData.groupId) {
      const groups: BookGroups[] = await BookGroupsDao.search({ type: this.itemData.groupType ?? 0 })
      const fresh = groups.find((g: BookGroups) => g.groupId === this.itemData.groupId)
      if (fresh) {
        this.itemData = fresh
        this.topTitle = fresh.isTop ? '取消置顶' : '置顶'
        await this.refreshBookCount()
      }
    }
    this.controller?.open()
  }

  // v3.21：加入书单改 CustomDialog（统一范式，通用包装 AddToBookListDialog）。
  // ⚠️ 2026-10-01 闪退修复：这里原来是 `builder: catalogAddShelf({...})` —— catalogAddShelf
  // 是普通 @Component（无 @CustomDialog 装饰器），放进 controller 字段初始化器的 builder 里
  // 真机必崩（日志原文：FolderInfoDialog.ets:52:14 "TypeError: class constructor cannot
  // called without 'new'" ← GroupType.ets:41:16 长按分组打开本弹窗时，Kill Reason: Js Error）。
  catalogAddShelfDialog: CustomDialogController | null = new CustomDialogController({
    builder: AddToBookListDialog({
      currentIndex: this.itemData.groupType,
      ids: this.itemData.groupId ? [this.itemData.groupId] : [],
      bookOrFolder: 1,
      cancel: () => {
        this.childDialogClosed()
      }
    }),
    autoCancel: true,
    // 标准居中四圆角卡片：固定高度 400（内部 catalogAddShelf 根节点是 height('100%')，
    // 父级无确定高度会把弹窗撑满整屏）+ 沉浸光感材质 + 弹簧动画（统一规范）。
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

  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  @State topTitle:string = this.itemData.isTop?'取消置顶':'置顶'
  build() {
    Column(){
      Flex({
        justifyContent:FlexAlign.SpaceBetween,
        alignItems:ItemAlign.Center
      }){
        Column(){
          Text(this.itemData.groupName).fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)').fontSize(16).fontWeight(500).lineHeight(24)
          Text(`共${this.realBookCount}本`).fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.45)' : 'rgba(0, 0, 0, 0.45)').fontWeight(400).lineHeight(20).fontSize(12)
        }
      }.padding(20)
      // ── 图标区（2026-10-01 间距统一，用户："两行图标之间…没有间距，看起来难受"）────
      // SDK 证据：`grid_row.d.ts:371` `gutter?: Length | GutterOption`，`GutterOption.y`
      // 原文「Vertical spacing between grid child components. Unit: vp.」（@since 9）。
      // 规范：同功能组内部行距 12（不太大也不紧贴）；组与"取消"键之间 24（相对大些）。
      GridRow({
        columns:4,
        gutter:{ x:0, y:12 }
      }){
        ForEach(this.buttonListInfo,(item:buttonList)=>{
          GridCol(){
            MarkToolButton({
              icon: item.icon,
              label: item.id === 2 ? this.topTitle : item.title,
              onTap: (): void => {
                this.folderInfo(item.id)
              }
            })
          }
        })

      }
      .padding({ left:12, right:12, top:8 })
      Column(){
        Text('取消').fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)').fontSize(16).fontWeight(400).lineHeight(24).textAlign(TextAlign.Center)
      }
      .onClick(()=>{
        Haptics.tap();
        this.cancel()
        this.controller?.close()
      })
      .alignItems(HorizontalAlign.Center)
      // 图标组（元素A）与取消键（元素B）之间取大间距（统一规范 24）
      .margin({ top:24 })
      .padding({bottom:16})
      // v3.21：加入书单从 bindSheet 改 CustomDialog（sheet 无 systemMaterial 字段，
      // 载不了沉浸光感——本文件 catalogAddShelfDialog 旁注释同款取证）
      Flex()
    }
    // 四角都圆（原来只圆上面两个角、下面两个角贴底）⇒ 配合调用点的
    // `cornerRadius: 20` + `offset{dx:0,dy:-16}` 形成悬空四圆角矩形。
    // 依据见 `BookInfos.ets` / `MaterialColumnModifier` 的注释。
    .borderRadius(20)
    .attributeModifier(this.surface)
    .width('100%')
  }

  folderInfo(id:number){
    switch (id){
      case 1 :
        this.restTitle(); break;
      case 2 :
        this.isFolderTop(); break;
      case 3 :
        this.openChildDialog(this.bookMoveGroup); break;
      case 4 :
        this.openChildDialog(this.catalogAddShelfDialog); break;
      case 5 :
        this.openChildDialog(this.coverDialog);
        break;
      case 6 :
        if (this.itemData.show) {
          this.dialogTitle = this.dialogHideTitle;
          this.dialogContent = this.dialogHideContent;
        } else {
          this.dialogTitle = '显示分组'
          this.dialogContent = ''
        }
        this.openChildDialog(this.hideDisbandDelDialog);
        break;
      case 7 :
        this.dialogTitle = this.dialogDisbandTitle;
        this.dialogContent = this.dialogDisbandContent;
        this.openChildDialog(this.hideDisbandDelDialog);
        break;
      case 8 :
        this.openChildDialog(this.groupDelDialog); break;
    }
  }
  //打开重名弹窗
  restTitle(){
    // 2026-10-01 用户定义：全部/本地/书单/分组/未分组 五个基础单元**不允许改名**。
    // 触发改名 → 弹窗提示规则（正常到不了这里——各创建者入口已拦，此处兜底）。
    if (this.itemData.isSystem) {
      showMessage('「' + (this.itemData.groupName ?? '') + '」是系统基础单元，不允许改名')
      return
    }
    this.openChildDialog(this.restTitleDialog)
    this.inputValue = this.itemData.groupName
  }
  //置顶/取消置顶
  isFolderTop(){
    if (this.itemData.groupId) {
      bookGroupUtil.isTopGroup(this.itemData.groupId, !this.itemData.isTop)
      this.itemData.isTop = !this.itemData.isTop
    }

    setTimeout(() => {
      showMessage(this.itemData.isTop? '置顶成功' : '取消置顶成功')
      this.topTitle = this.itemData.isTop?'取消置顶':'置顶'
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
    },500)
  }
  //重命名弹窗
  @State inputValue:string = ''
  restTitleDialog: CustomDialogController | null = new CustomDialogController({
    builder: commonInputDialog({
      textValue:this.inputValue,
      cancel: () => {
        this.restTitleCancel()
      },
      confirm: () => {
        this.restTitleConfirm()
      },
      placeholder:'请输入分组名称',
      title:'重命名'
    }),
    gridCount: 4,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 25,
    // 弹窗材质走官方 options 渠道（依据见 BookInfos.ets 同处注释）
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    // 子退父进：遮罩/返回关闭本子弹窗 ⇒ 父弹窗恢复
    cancel: (): void => {
      this.childDialogClosed()
    }
  })

  restTitleCancel(){
    // commonInputDialog 的取消按钮先自己 close 再回调本方法 ⇒ 这里只需恢复父弹窗
    this.inputValue = ''
    this.childDialogClosed()
  }

  async restTitleConfirm(){
    let result = await bookGroupUtil.onlyGroupUpdateName(this.inputValue, this.itemData.groupId ?? 0)
    if (result) {
      this.itemData.groupName = this.inputValue
      showMessage('重命名成功')
      setTimeout(() => {
        this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      },500)
    } else {
      showMessage('已存在其它相同分组名')
    }
    this.inputValue = ''
    // commonInputDialog 的确认按钮先自己 close 再回调 ⇒ 无论成败都恢复父弹窗
    this.childDialogClosed()
  }

  //移动分组弹窗
  bookMoveGroup: CustomDialogController | null = new CustomDialogController({
    builder: BookSelectGroupDialog({
      moveGroup: ()=> {
        setTimeout(()=>{
          this.isBookRefreshing++
          this.BOOK_IS_BOOK_GROUPS_REFRESHING++
        },500)
        this.bookMoveGroup?.close()
      },
      // 子退父进：移动分组弹窗被取消（取消按钮/遮罩）⇒ 本弹窗恢复
      onClose: ()=> {
        this.childDialogClosed()
      },
      oldGroupId:this.itemData.groupId,
      currentIndex:this.itemData.groupType,
      Ids:this.itemData.groupId,
      isMoveStatus: 1
    }),
    height: 400,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    cancel: (): void => {
      this.childDialogClosed()
    }
  })

  @State delCache:boolean = false
  //删除分组弹窗
  groupDelDialog: CustomDialogController | null = new CustomDialogController({
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
  //删除分组
  deleteGroup() {
    if (this.itemData.groupId) {
      bookGroupUtil.delGroupById(this.itemData.groupId)
    }
    this.cancel()
    setTimeout(()=>{
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      showMessage('删除成功')
    },500)
  }

  @State dialogTitle:string = ''
  @State dialogContent:string = ''

  @State dialogHideTitle:string = '隐藏分组'
  @State dialogHideContent:string = '隐藏后可点击分组标签栏右侧分组管理入口查看隐藏分组并进入'
  @State dialogDisbandTitle:string = '解散分组'
  @State dialogDisbandContent:string = '解散分组后，原组内书籍不会被删除，将自动移动至未分组'

  //隐藏、解散分组弹窗
  hideDisbandDelDialog: CustomDialogController | null = new CustomDialogController({
    builder: TitleContentDialog({
      confirm: ()=> { this.hideOrDisband() },
      title:this.dialogTitle,
      content:this.dialogContent,
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
  //显示/隐藏
  hideOrDisband(){
    if (this.dialogTitle === '隐藏分组' || this.dialogTitle === '显示分组') {
      this.hideGroup()
    } else {
      this.disbandGroup()
    }
  }
  //解散分组
  disbandGroup(){
    bookGroupUtil.delGroupById(this.itemData.groupId ?? [])
    setTimeout(()=>{
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      this.cancel()
      showMessage('解散分组成功')
    },500)
  }

  //隐藏分组
  hideGroup(){
    this.itemData.show = this.itemData.show ? false : true
    if (this.itemData.groupId) {
      bookGroupUtil.updateGroupShow(this.itemData.groupId)
    }
    setTimeout(()=>{
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      this.cancel()
      showMessage(this.itemData.show ? '隐藏成功' : '显示成功')
    },500)
  }

  coverDialog: CustomDialogController | null = new CustomDialogController({
    builder: coverInfoDialog({
      itemData:this.itemData,
      cancel:()=>{
        this.childDialogClosed()
      }
    }),
    autoCancel: true,
    width:'92%',
    alignment: DialogAlignment.Center,
    cornerRadius: 20,
    customStyle:false,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    cancel: (): void => {
      this.childDialogClosed()
    }
  })

}
