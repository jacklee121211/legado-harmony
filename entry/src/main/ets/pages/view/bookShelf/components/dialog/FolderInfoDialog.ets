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
import { GroupMutation } from '../../../../../common/group/GroupMutation'
import { DialogHost } from '../../../../../common/dialog/DialogHost'
// 2026-11-02 第 26 轮（B②）：分组树唯一真源
import { GroupStore } from '../../../../../common/group/GroupStore'
import booksDao from '../../../../../database/dao/BooksDao'
import { BooksMutation } from '../../../../../common/books/BooksMutation'
import BookSelectGroupDialog from './BookSelectGroupDialog'
import booksUtil from '../../../../../common/utils/booksUtils'
import { GroupTree } from '../../../../../common/group/GroupTree'
import ThreeActionDialog from '../../../../../componets/common/ThreeActionDialog'
import GroupMergeDialog, { MergeConflictInfo } from './GroupMergeDialog'
import { BookShareBridge, buildSelection, MAX_SHARE_RECORDS } from '../../../../../common/share/BookShareBridge'
import bookDataPreferences from '../../../../../common/utils/DataPreferencesUtils'
import { Books } from '../../../../../database/entities/Books'
import { common } from '@kit.AbilityKit'
// 2026-10-25：`AddToBookListDialog`（加入书单弹窗）已随书单功能删除
import coverInfoDialog from './coverInfoDialog'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../../../common/utils/UiMotion'
import { ShelfRefresh } from '../../../../../common/shelf/ShelfRefresh';

/** 分享游标（持久化 + 生命周期，2026-11-01）：按分组隔离，30 分钟内有效 */
interface ShareCursorData {
  cursor: number
  total: number
  ts: number
}

/** 游标有效期：30 分钟（超时/书数变化/已发完 ⇒ 从头开始） */
const SHARE_CURSOR_TTL_MS: number = 30 * 60 * 1000

@CustomDialog
/**
 * 分组长按弹窗
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
    // 2026-10-25：`new buttonList(4,'加入书单',…)` 已随书单功能删除（用户口径「书单功能早就没了」）。
    //   ⚠️ `id` 是**语义键**不是下标（下面 `folderInfo()` 的 switch 按 id 分发），
    //   所以删掉 id 4 不影响置顶(2)/移动(3)/封面(5)/隐藏(6)/解散(7)/删除(8) 的绑定。
    new buttonList(5,'封面样式',$r('sys.symbol.picture')),
    new buttonList(6, this.itemData.show?'隐藏分组':'恢复显示',this.itemData.show?$r('sys.symbol.eye_slash'):$r('sys.symbol.eye')),
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
  // ── 2026-11-01 碰一碰 / 隔空传送：长按分组即可分享整组书籍 ──────────────────
  /** 分享提示文案（空串 = 不显示徽标） */
  @State private shareHint: string = ''
  private readonly SHARE_OWNER_FOLDER: string = 'folder-info'
  aboutToAppear(): void {
    this.refreshBookCount()
    this.setupShare()
  }

  aboutToDisappear(): void {
    BookShareBridge.get().release(this.SHARE_OWNER_FOLDER)
  }

  /**
   * 碰一碰 / 隔空传送（2026-11-01）。
   *
   * · 内容 = 本分组**直属**书籍的文件 URI（`buildSelection` 内部转 URI + utd）；
   * · 官方上限 500 项（`MAX_SHARE_RECORDS`）⇒ 超过时用本地游标分批，
   *   第一批备好后提示"再碰一次发送剩余 X 本"（用户拍板：手动接续）；
   * · 能力闸门/注册注销都在 bridge 内部，不支持分享的设备静默降级。
   */
  private async setupShare(): Promise<void> {
    const gid: number | undefined = this.itemData.groupId
    if (gid === undefined) {
      return
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      await BookShareBridge.get().acquire(this.SHARE_OWNER_FOLDER, ctx)
      const all: Books[] = await booksDao.queryPreviewByGroups([gid], 5000)
      const key: string = 'GROUP_SHARE_CURSOR_' + gid
      const now: number = Date.now()
      let start: number = 0
      const raw = bookDataPreferences.shared.get(key)
      if (typeof raw === 'string' && raw.length > 0) {
        try {
          const obj = JSON.parse(raw) as ShareCursorData
          if (now - (obj.ts ?? 0) <= SHARE_CURSOR_TTL_MS
            && (obj.total ?? -1) === all.length
            && (obj.cursor ?? 0) > 0 && (obj.cursor ?? 0) < all.length) {
            start = obj.cursor
          }
        } catch (e) {
          start = 0
        }
      }
      const batch: Books[] = all.slice(start, start + MAX_SHARE_RECORDS)
      BookShareBridge.get().setSelection(batch.length > 0 ? buildSelection(batch) : null)
      const remain: number = all.length - start - batch.length
      if (all.length === 0) {
        this.shareHint = ''
        bookDataPreferences.shared.delete(key)
      } else if (remain > 0) {
        this.shareHint = start > 0
          ? `继续发送剩余 ${remain} 本（从第 ${start + 1} 本起）`
          : `已备好 ${batch.length} 本，再碰一次发送剩余 ${remain} 本`
        const data: ShareCursorData = { cursor: start + batch.length, total: all.length, ts: now }
        bookDataPreferences.shared.set(key, JSON.stringify(data))
      } else {
        this.shareHint = `已备好 ${all.length} 本`
        bookDataPreferences.shared.delete(key)
      }
    } catch (e) {
      console.error('setupShare failed: ' + JSON.stringify(e))
    }
  }

  /** 「从头开始」：清掉本组游标后重建分享内容 */
  private async restartShare(): Promise<void> {
    const gid: number | undefined = this.itemData.groupId
    if (gid === undefined) {
      return
    }
    Haptics.tap()
    bookDataPreferences.shared.delete('GROUP_SHARE_CURSOR_' + gid)
    await this.setupShare()
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
    // ── 2026-11-02 第 25 轮（P3 B1b）──────────────────────────────────────
    // 原来是「`this.controller?.close()` + `controller?.open()`」两步手写。
    // `DialogHost.openIf()` 内部就是"先 closeCurrent 再 open" ⇒ 语义完全等价，
    // 但"当前谁开着"由宿主统一记账（不再每个组件各自 close 自己的 controller，
    // 否则宿主账本会和实际状态分叉 —— 正是 S7 那类"父窗没真关"的病根）。
    DialogHost.openIf(controller)
  }

  /**
   * **子退父进的标准收尾**（2026-10-12 新增，修「取消按钮点了循环」）。
   *
   * ── 为什么必须走这一个方法 ────────────────────────────────────────────────
   * 用户原话：「点击移动分组弹窗的取消，子弹窗没取消，父弹窗回来了，循环。
   *   点击其他区域可以关闭弹窗，手势可以关闭弹窗，**就是点击取消按钮不行**」。
   *
   * 真机日志（`docs/日志.md`）把因果链钉死了 —— 点「取消」那一次：
   * ```
   * 4422: TTHRTI: T ClickRecognizer info: { T: Column }; { T: Dialog };   ← 确实点到了按钮
   * 4429: Click try accept Column
   * 4435-4443: 新 Dialog APPEARING，Controller/17 create dialog node/1749  ← 父弹窗被召回
   * 4445: view: Dialog/1749 show
   * 4446: View: Dialog/1715 lost focus                                    ← 子弹窗 1715 **仍在**
   * ```
   * 根因是旧写法只做了"恢复父弹窗"，**没有关闭子弹窗**：
   * ```
   * cancel: () => { this.childDialogClosed() }     // 父弹窗回来了，子弹窗还在
   * ```
   * 而子弹窗**内部**自己的 `this.controller?.close()` 在 `@CustomDialog` 子组件里
   * **不可靠** —— 这条本项目已用真机日志独立验证过两次：
   *   · `ReaderSaveSchemeDialog.ets:205-208`：「点取消时点击识别成功（CLK RACC T: Button）、
   *     onClick 也执行了（Haptics 探测日志都在），但 `this.controller?.close()` 没有关掉弹窗；
   *     而**页面侧**持有的 controller 调 close() 一直可靠 ⇒ **关闭权收回页面**」；
   *   · `RenameBookDialog` 同类（其类注释有完整记录）。
   *
   * ⇒ **关闭权必须归持有 controller 的调用方**。本方法就是这个唯一出口：
   *   先 `close()` 子弹窗（调用方才有引用）→ 再决定是否恢复父弹窗。
   *
   * @param child  要关闭的子弹窗 controller（本组件字段）
   * @param reopenParent 是否恢复父弹窗。默认 true（入规则）；移动至/删除/解散这类
   *        「对象已不存在」的路径传 false（规范 §4.2 例外：直接全关）
   */
  private closeChildAndReopen(child: CustomDialogController | null,
    reopenParent: boolean = true): void {
    child?.close()
    if (reopenParent) {
      this.childDialogClosed()
    } else {
      // 规范 §4.2：确认后父弹窗不恢复 ⇒ 整条链全关（回调给创建者）
      this.cancel()
    }
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
    DialogHost.openIf(this.controller)
  }

  // 2026-10-25：`catalogAddShelfDialog`（加入书单弹窗）整块删除，书单功能下线。
  //   历史坑留档：这里原来是 `builder: catalogAddShelf({...})` —— catalogAddShelf 是普通
  //   @Component（无 @CustomDialog 装饰器），放进 controller 字段初始化器的 builder 里真机必崩
  //   （FolderInfoDialog.ets:52:14 "TypeError: class constructor cannot called without 'new'"）。
  //   组件本身也已随书单一起删除。

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
          // ── 2026-11-01：碰一碰 / 隔空传送 标志（用户：弹窗顶部加个标志就行）──
          if (this.shareHint.length > 0) {
            Row({ space: 6 }) {
              Text('碰一碰')
                .fontSize(10).fontColor(Color.White)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor('rgba(0, 0, 0, 0.30)')
              Text('隔空传送')
                .fontSize(10).fontColor(Color.White)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor('rgba(0, 0, 0, 0.30)')
              Text(this.shareHint)
                .fontSize(10)
                .fontColor(NightMode.isDarkSurface() ? 'rgba(248,249,250,0.62)' : 'rgba(0,0,0,0.45)')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.shareHint.indexOf('继续发送') >= 0) {
                Text('从头')
                  .fontSize(10)
                  .fontColor(NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : 'rgba(0,0,0,0.88)')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                  .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)')
                  .onClick(() => {
                    this.restartShare()
                  })
              }
            }
            .width('100%')
            .margin({ top: 4 })
          }
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
        // 2026-11-01 多级分组：「移动至」= 把**分组本身**挂到另一个分组下（改 parentId）
        this.openGroupMoveDialog(); break;
      case 4 :
        // 2026-10-25：「加入书单」入口已随书单功能删除 ⇒ 本分支不再可达
        break;
      case 5 :
        this.openChildDialog(this.coverDialog);
        break;
      case 6 :
        if (this.itemData.show) {
          this.dialogTitle = this.dialogHideTitle;
          this.dialogContent = this.dialogHideContent;
          this.openChildDialog(this.hideDisbandDelDialog);
        } else {
          // 2026-11-02：父级仍隐藏时，子级不允许单独恢复（恢复后依然不可见，语义混乱）
          this.checkCanRestoreShow();
        }
        break;
      case 7 :
        // 2026-11-01：含子分组时让用户选「一起解散 / 子组保留（上提一级）」；否则沿用旧确认框
        this.prepareDisbandThenOpen(); break;
      case 8 :
        // 2026-11-01：删除 = **真删**（递归子分组 + 书文件），先算数量再弹确认
        this.prepareDeleteThenOpen(); break;
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
  // 2026-11-03（Ⅱ-4）：去掉 500ms 延时 —— await 写入口后立即出提示 + 刷新
  async isFolderTop(){
    if (this.itemData.groupId) {
      try {
        await GroupMutation.setTop(this.itemData.groupId, !this.itemData.isTop)
      } catch (e) {
        const err = e as Error
        console.error('[GRP] setTop failed: ' + err.message)
      }
      this.itemData.isTop = !this.itemData.isTop
    }
    showMessage(this.itemData.isTop? '置顶成功' : '取消置顶成功')
    this.topTitle = this.itemData.isTop?'取消置顶':'置顶'
    ShelfRefresh.groups()
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
    // 2026-10-12：同样必须真的 close（子组件内自己 close 不可靠）
    cancel: (): void => {
      this.closeChildAndReopen(this.restTitleDialog)
    }
  })

  restTitleCancel(){
    // ⚠️ 2026-10-12：旧注释假设「commonInputDialog 的取消按钮先自己 close 再回调本方法」，
    //   但**子组件内 `controller.close()` 不可靠**（真机两次验证，见
    //   `ReaderSaveSchemeDialog.ets:205-208`）⇒ 这里必须由**持有 controller 的调用方**
    //   真正关闭它，否则弹窗留在屏幕上而父弹窗被召回（用户报的"循环"）。
    this.inputValue = ''
    this.closeChildAndReopen(this.restTitleDialog)
  }

  async restTitleConfirm(){
    // 2026-11-03（A2b）：走唯一写入口（刷真源 + 发一次非结构事件），返回 false = 同名冲突
    const result: boolean = await GroupMutation.renameGroup(this.itemData.groupId ?? 0, this.inputValue)
    if (result) {
      this.itemData.groupName = this.inputValue
      showMessage('重命名成功')
      // 2026-11-03（Ⅱ-4）：写入口已 await 提交 ⇒ 立即刷（原 500ms 延时）
      ShelfRefresh.groups()
    } else {
      showMessage('已存在其它相同分组名')
    }
    this.inputValue = ''
    // 2026-10-12：同上 —— 关闭权归调用方（持有 controller 的这一侧）
    this.closeChildAndReopen(this.restTitleDialog)
  }

  //移动分组弹窗
  bookMoveGroup: CustomDialogController | null = new CustomDialogController({
    builder: BookSelectGroupDialog({
      moveGroup: ()=> {
        // 2026-11-03（Ⅱ-4）：移动已在弹窗内 await 提交 ⇒ 立即刷（原 500ms 延时）
        ShelfRefresh.books()
        ShelfRefresh.groups()
        this.bookMoveGroup?.close()
      },
      // 子退父进：移动分组弹窗被取消（取消按钮/遮罩）⇒ **关闭子弹窗** + 本弹窗恢复
      // ⚠️ 2026-10-12：旧写法只 `childDialogClosed()`，子弹窗留在屏幕上 ⇒ 双弹窗叠加
      //    （真机日志 4446 行 `View: Dialog/1715 lost focus` 但 1715 未 close）。
      onClose: ()=> {
        this.closeChildAndReopen(this.bookMoveGroup)
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
    // 遮罩/返回键：同一条收尾路径（2026-10-12 一并修）
    cancel: (): void => {
      this.closeChildAndReopen(this.bookMoveGroup)
    }
  })

  @State delCache:boolean = false
  /** 删除确认框标题（2026-11-01：按实际子分组数/书数动态生成） */
  @State delTitle:string = '删除'
  //删除分组弹窗
  groupDelDialog: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      confirm: ()=> { this.deleteGroup() },
      delCache:this.delCache,
      title:this.delTitle,
      // 2026-10-12：取消路径必须**真的 close**（同 bookMoveGroup 那个坑）
      cancel: ()=> { this.closeChildAndReopen(this.groupDelDialog) }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    cancel: (): void => {
      this.closeChildAndReopen(this.groupDelDialog)
    }
  })
  // ── 删除分组（2026-11-01 按新语义重写）────────────────────────────────────
  /**
   * 打开删除确认框前先算数量：删除 = **递归删子分组 + 真删书**（含书签/进度/封面文件）。
   *
   * 与「分组管理弹窗」的 `doDeleteGroup` 同一口径（`BookSelectGroupDialog.ets:661-681`）。
   * 回退：把 `folderInfo` 的 `case 8` 改回 `this.openChildDialog(this.groupDelDialog)`、
   *   并恢复旧的 `deleteGroup()`（只删组行、书落未分组）即回到 2026-10-31 行为。
   */
  /**
   * 「删除」三选一（2026-11-01 用户拍板）：
   *   ① 全部删除 = 递归删子分组 + 真删书（不可恢复）；
   *   ② 保留有书的子分组 = 删掉本组自己的书与空子分组，**有书的子分组上提一级**；
   *   ③ 取消。
   */
  private async prepareDeleteThenOpen(): Promise<void> {
    const gid: number = this.itemData.groupId ?? -1
    if (gid <= 0) {
      return
    }
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      const tree: GroupTree = await GroupStore.reload()
      const ids: number[] = tree.subtreeIds(gid)
      let bookCount: number = 0
      for (const id of ids) {
        const bookIds: number[] = await booksDao.queryBooksByGroupId([id])
        bookCount += bookIds.length
      }
      const subCount: number = ids.length - 1
      this.openGroupActionDialog(
        `删除「${this.itemData.groupName ?? ''}」`,
        `全部删除：${subCount} 个子分组、${bookCount} 本书一并删除（不可恢复）`,
        '保留子分组：本组自己的书删除，子分组（含空目录）上提一级',
        '全部删除',
        '保留子分组',
        (): void => { this.deleteGroup() },
        (): void => { this.deleteGroupKeepChildFolders() }
      )
    } catch (e) {
      showMessage('删除失败')
      console.error('prepareDeleteThenOpen failed: ' + JSON.stringify(e))
    }
  }

  /** 通用三选一弹窗（删除 / 解散两处共用；关闭权在回调里） */
  groupActionDialog: CustomDialogController | null = null

  private openGroupActionDialog(title: string, hintPrimary: string, hintSecondary: string,
    primaryText: string, secondaryText: string,
    onPrimary: () => void, onSecondary: () => void): void {
    this.groupActionDialog = new CustomDialogController({
      builder: ThreeActionDialog({
        title: title,
        rawTitle: true,
        primaryText: primaryText,
        secondaryText: secondaryText,
        hintPrimary: hintPrimary,
        hintSecondary: hintSecondary,
        onPrimary: (): void => {
          this.groupActionDialog?.close()
          onPrimary()
        },
        onSecondary: (): void => {
          this.groupActionDialog?.close()
          onSecondary()
        },
        onCancel: (): void => {
          this.groupActionDialog?.close()
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      customStyle: false,
      cornerRadius: 25,
      cancel: (): void => {
        this.groupActionDialog?.close()
      }
    })
    DialogHost.openIf(this.groupActionDialog)
  }

  /** 解散入口：含子分组时让用户选「一起解散 / 子组保留」；没有子分组则沿用旧确认框 */
  private async prepareDisbandThenOpen(): Promise<void> {
    const gid: number = this.itemData.groupId ?? -1
    if (gid <= 0) {
      return
    }
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      const tree: GroupTree = await GroupStore.reload()
      const kids: BookGroups[] = tree.childrenOf(gid)
      if (kids.length === 0) {
        this.dialogTitle = this.dialogDisbandTitle
        this.dialogContent = this.dialogDisbandContent
        this.openChildDialog(this.hideDisbandDelDialog)
        return
      }
      this.openGroupActionDialog(
        `解散「${this.itemData.groupName ?? ''}」`,
        `一起解散：连同 ${kids.length} 个子分组全部解散`,
        '子组保留：子分组上提一级，书籍不受影响',
        '一起解散',
        '子组保留',
        (): void => { this.dissolveGroup(false) },
        (): void => { this.dissolveGroup(true) }
      )
    } catch (e) {
      showMessage('解散失败')
      console.error('prepareDisbandThenOpen failed: ' + JSON.stringify(e))
    }
  }

  /**
   * 解散（不删书）：
   * · `keepChildren = true` → 只解散本组：子分组上提一级，本组书移到父组（根级则未分组）；
   * · `keepChildren = false` → 整棵子树一起解散：子树内书全部移到父组（根级则未分组）。
   * 若目标位置已有"同一本书"（书名+作者 或 大小+入库时间）→ 先弹合并冲突弹窗。
   */
  mergeDialog: CustomDialogController | null = null

  private async dissolveGroup(keepChildren: boolean): Promise<void> {
    const gid: number = this.itemData.groupId ?? -1
    if (gid <= 0) {
      return
    }
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      const tree: GroupTree = await GroupStore.reload()
      const all: BookGroups[] = GroupStore.groups()
      const me: BookGroups | undefined = all.find((g: BookGroups): boolean => g.groupId === gid)
      const parentId: number = me?.parentId ?? 0
      const target: number = parentId > 0 ? parentId : 3
      const ids: number[] = keepChildren ? [gid] : tree.subtreeIds(gid)
      const moving: Books[] = []
      for (const id of ids) {
        const list: Books[] = await booksDao.queryPreviewByGroups([id], 5000)
        for (const b of list) {
          moving.push(b)
        }
      }
      const existing: Books[] = await booksDao.queryPreviewByGroups([target], 5000)
      const conflicts: MergeConflictInfo[] = this.findConflicts(moving, existing)
      if (conflicts.length > 0) {
        this.mergeDialog = new CustomDialogController({
          builder: GroupMergeDialog({
            conflicts: conflicts,
            onConfirm: (choices: number[]): void => {
              this.mergeDialog?.close()
              this.applyDissolve(gid, ids, keepChildren, parentId, moving, target, conflicts, choices)
            },
            onClose: (): void => {
              this.mergeDialog?.close()
            }
          }),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          gridCount: 4,
          customStyle: false,
          cornerRadius: 25,
          cancel: (): void => {
            this.mergeDialog?.close()
          }
        })
        DialogHost.openIf(this.mergeDialog)
        return
      }
      await this.applyDissolve(gid, ids, keepChildren, parentId, moving, target, [], [])
    } catch (e) {
      showMessage('解散失败')
      console.error('dissolveGroup failed: ' + JSON.stringify(e))
    }
  }

  /** 冲突判定：书名+作者 相同，或 文件大小+入库时间 相同（2026-11-01 用户拍板） */
  private sameBook(a: Books, b: Books): boolean {
    const na: string = (a.bookName ?? '').trim()
    const nb: string = (b.bookName ?? '').trim()
    const aa: string = (a.author ?? '').trim()
    const ab: string = (b.author ?? '').trim()
    if (na !== '' && na === nb && aa === ab) {
      return true
    }
    const size: number = a.fileSize ?? 0
    if (size > 0 && size === (b.fileSize ?? -1)
      && (a.createTime ?? -1) === (b.createTime ?? -2)) {
      return true
    }
    return false
  }

  private bookDesc(b: Books): string {
    const kb: number = Math.round((b.fileSize ?? 0) / 1024)
    const t: number = b.createTime ?? 0
    const day: string = t > 0 ? new Date(t).toISOString().substring(0, 10) : '未知时间'
    return `${kb}KB · ${day}`
  }

  private findConflicts(moving: Books[], existing: Books[]): MergeConflictInfo[] {
    const out: MergeConflictInfo[] = []
    for (const b of moving) {
      const hit: Books | undefined = existing.find((e: Books): boolean => this.sameBook(b, e))
      if (hit !== undefined && b.id !== undefined && hit.id !== undefined) {
        out.push({
          bookId: b.id,
          bookName: b.bookName,
          detail: this.bookDesc(b),
          oldId: hit.id,
          oldName: hit.bookName,
          oldDetail: this.bookDesc(hit)
        })
      }
    }
    return out
  }

  /** 按用户选择执行：覆盖=删旧、重命名=书名加 (2)、跳过=落未分组；然后删分组行 */
  private async applyDissolve(gid: number, ids: number[], keepChildren: boolean, parentId: number,
    moving: Books[], target: number, conflicts: MergeConflictInfo[], choices: number[]): Promise<void> {
    // ── 2026-11-02 预检 + 回滚快照 ────────────────────────────────────────────
    //  真机实证：本方法自己移书、重挂子组，最后才调 delGroupById（那边回滚管不到前两步），
    //  所以必须在这里独立快照，失败时逆序恢复。
    const gids: number[] = ids.length > 0 ? ids : [gid]
    const allPreview: BookGroups[] = await BookGroupsDao.search()
    let found: boolean = false
    for (const g of allPreview) {
      if (gids.indexOf(g.groupId ?? -1) >= 0) {
        found = true
        break
      }
    }
    if (!found) {
      console.error(`[GRP-PRECHECK] applyDissolve: 目标分组不存在 gid=${gid} ids=${gids.join(',')}，已跳过`)
      this.cancel()
      return
    }
    const snapBookId: number[] = []
    const snapBookGroup: number[] = []
    const pendingDelete: number[] = []
    for (const b of moving) {
      if (b.id !== undefined) {
        snapBookId.push(b.id)
        snapBookGroup.push(b.bookGroup ?? 3)
      }
    }
    const snapChildId: number[] = []
    const snapChildParent: number[] = []
    try {
      for (const b of moving) {
        const idx: number = conflicts.findIndex((c: MergeConflictInfo): boolean => c.bookId === (b.id ?? -1))
        const choice: number = idx >= 0 ? choices[idx] : -1
        if (choice === 2) {
          if (b.id !== undefined) {
            await BooksMutation.moveOne(b.id, 3)
          }
          continue
        }
        if (choice === 0 && idx >= 0) {
          // 2026-11-02：**删旧推迟到最后**（两阶段）—— 真删文件不可恢复，
          //   若后续移书/删组失败会留下"旧书已删"的数据级残留；这里只登记，成功后再删。
          pendingDelete.push(conflicts[idx].oldId)
        }
        if (choice === 1) {
          b.bookName = `${b.bookName} (2)`
          await BooksMutation.update(b)
        }
        if (b.id !== undefined) {
          await BooksMutation.moveOne(b.id, target)
        }
      }
      let promoteTo: number = -1
      if (keepChildren) {
        // 2026-11-02 第 26 轮（B②）：唯一树真源（见 GroupStore.reload）
        // 2026-11-03（Ⅱ-1）：这里**只做快照**；真正"上提子分组"由写入口 `remove(ids, parentId)` 完成，
        //   这样"上提 + 删组"是一次操作、只发一条结构事件（原来弹窗逐个子分组直写 DAO）。
        const tree: GroupTree = await GroupStore.reload()
        for (const c of tree.childrenOf(gid)) {
          snapChildId.push(c.groupId ?? -1)
          snapChildParent.push(c.parentId ?? 0)
        }
        promoteTo = parentId
      }
      // 2026-11-03（A2 / Ⅱ-1）：走唯一写入口 —— 底层 emit 关掉，由 afterChange 刷真源 + 只发一次
      await GroupMutation.remove(ids, promoteTo)
      // 2026-11-02：分组结构已安全变更，最后才真正删除被覆盖的旧书文件
      for (const oldId of pendingDelete) {
        try {
          await booksUtil.delBooksById([oldId])
        } catch (e4) {
          console.error(`[DISSOLVE-CLEANUP] 删除旧书失败 id=${oldId}: ${JSON.stringify(e4)}`)
        }
      }
      showMessage(`已解散「${this.itemData.groupName ?? ''}」`)
    } catch (e) {
      // ── 2026-11-02 失败回滚：书回原分组、子分组回原父级 ──────────────────────
      console.error(`[GRP-ROLLBACK] applyDissolve 失败 gid=${gid}，开始回滚：${JSON.stringify(e)}`)
      // 2026-11-03（P3/A1）：书回滚也走书籍域写入口（内部逐条吞异常、返回成功条数，
      //   语义与原来 UI 里手写的 for + try/catch 完全一致）
      const rb: number = await BooksMutation.restoreGroups(snapBookId, snapBookGroup)
      // 2026-11-03（Ⅱ-1）：子分组回滚也走写入口（一次批量恢复 + 一条结构事件）
      let rg: number = 0
      if (snapChildId.length > 0) {
        try {
          await GroupMutation.restoreParents(snapChildId, snapChildParent)
          rg = snapChildId.length
        } catch (e3) {
          console.error(`[GRP-ROLLBACK] 子分组回滚失败: ${JSON.stringify(e3)}`)
        }
      }
      console.error(`[GRP-ROLLBACK] 已回滚 书 ${rb}/${snapBookId.length} 本、分组 ${rg}/${snapChildId.length} 个`)
      showMessage('解散失败')
    } finally {
      // 2026-11-01：先广播再关窗（同 doMoveGroupNode）
      ShelfRefresh.groups()
      ShelfRefresh.books()
      this.cancel()
    }
  }

  /** 删除但保留有书的子分组：本组自己的书删掉；有书的子组上提，空子树删除 */
  private async deleteGroupKeepChildFolders(): Promise<void> {
    const gid: number = this.itemData.groupId ?? -1
    if (gid <= 0) {
      return
    }
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      await GroupStore.reload()  // 2026-11-03（Ⅱ-1）：只需刷真源拿最新 parentId（树本身已不用，上提进写入口）
      const all: BookGroups[] = GroupStore.groups()
      const me: BookGroups | undefined = all.find((g: BookGroups): boolean => g.groupId === gid)
      const parentId: number = me?.parentId ?? 0
      // ① 本组自己的书：真删
      const own: number[] = await booksDao.queryBooksByGroupId([gid])
      if (own.length > 0) {
        await booksUtil.delBooksById(own)
      }
      // ② 子分组：**一律上提一级**（2026-11-01 用户拍板：空目录也保留，不再自动删空子树，
      //    否则会与「空目录一律保留」规则冲突，也会把用户刚建的空分组静默吃掉）
      // 2026-11-03（Ⅱ-1）：上提动作进写入口（`remove(gid, parentId)`）——
      //   原来在这里逐个子分组 `BookGroupsDao.updatePartialGroup`，属 UI 直写事实。
      // 2026-11-03（A2）：唯一写入口（刷真源 + 单次事件）
      await GroupMutation.remove(gid, parentId)
      showMessage(`已删除「${this.itemData.groupName ?? ''}」`)
    } catch (e) {
      showMessage('删除失败')
      console.error('deleteGroupKeepChildFolders failed: ' + JSON.stringify(e))
    } finally {
      // 2026-11-01：先广播再关窗（同 doMoveGroupNode）
      ShelfRefresh.groups()
      ShelfRefresh.books()
      this.cancel()
    }
  }

  /** 真删：子树内每个分组的书先逐本删（清书签/进度/封面），再删分组行 */
  async deleteGroup(): Promise<void> {
    const gid: number = this.itemData.groupId ?? -1
    if (gid <= 0) {
      return
    }
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      const tree: GroupTree = await GroupStore.reload()
      const ids: number[] = tree.subtreeIds(gid)
      let bookCount: number = 0
      for (const id of ids) {
        const bookIds: number[] = await booksDao.queryBooksByGroupId([id])
        if (bookIds.length > 0) {
          await booksUtil.delBooksById(bookIds)
          bookCount += bookIds.length
        }
      }
      // 2026-11-03（A2）：唯一写入口（刷真源 + 单次事件）
      await GroupMutation.remove(ids)
      showMessage(bookCount > 0
        ? `已删除「${this.itemData.groupName ?? ''}」及 ${bookCount} 本书`
        : `已删除「${this.itemData.groupName ?? ''}」`)
    } catch (e) {
      showMessage('删除失败')
      console.error('deleteGroup failed: ' + JSON.stringify(e))
    } finally {
      // 2026-11-01：先广播再关窗（同 doMoveGroupNode）
      ShelfRefresh.groups()
      ShelfRefresh.books()
      this.cancel()
    }
  }

  /**
   * 移动「分组本身」（2026-11-01 多级分组）。
   *
   * 与旧的「整组移动」不同：这里改的是 `book_groups.parentId`，不是把组内书搬走。
   * 目标可以是任意分组（含子目录），也可以挂回根目录（targetId = 0）。
   * 防环：`disabledIds` = 自身 + 全部子孙，UI 里不可选；DAO 前再校验一次。
   */
  groupMoveGroup: CustomDialogController | null = null

  private async openGroupMoveDialog(): Promise<void> {
    const gid: number = this.itemData.groupId ?? -1
    if (gid <= 0) {
      return
    }
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      const tree: GroupTree = await GroupStore.reload()
      const all: BookGroups[] = GroupStore.groups()
      const disabled: number[] = tree.subtreeIds(gid)
      this.groupMoveGroup = new CustomDialogController({
        builder: BookSelectGroupDialog({
          isMoveGroupNode: true,
          presetGroups: all,
          disabledIds: disabled,
          oldGroupId: gid,
          moveGroupNode: (targetId: number, targetName: string): void => {
            this.doMoveGroupNode(gid, targetId, targetName)
          },
          onClose: (): void => {
            this.groupMoveGroup?.close()
          }
        }),
        autoCancel: true,
        width: '92%',
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -16 },
        cornerRadius: 20,
        customStyle: false,
        systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
        cancel: (): void => {
          this.groupMoveGroup?.close()
        }
      })
      DialogHost.openIf(this.groupMoveGroup)
    } catch (e) {
      showMessage('打开移动弹窗失败')
      console.error('openGroupMoveDialog failed: ' + JSON.stringify(e))
    }
  }

  /** 真正写 parentId：防环 + 深度校验 + 同名拦截（合并/重命名在 S6 做） */
  private async doMoveGroupNode(gid: number, targetId: number, targetName: string): Promise<void> {
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      const tree: GroupTree = await GroupStore.reload()
      const all: BookGroups[] = GroupStore.groups()
      const chk = tree.canMoveTo(gid, targetId)
      if (!chk.ok) {
        showMessage(chk.reason)
        return
      }
      if (tree.hasSiblingNamed(targetId, this.itemData.groupName, gid)) {
        // 2026-11-01 闭环：目标下已有同名分组 → 「合并 / 重命名 / 取消」
        const name: string = this.itemData.groupName ?? ''
        const sibling: BookGroups | undefined = all.find((g: BookGroups): boolean =>
          (g.parentId ?? 0) === targetId && (g.groupName ?? '') === name && g.groupId !== gid)
        const siblingId: number = sibling?.groupId ?? -1
        this.openGroupActionDialog(
          `目标下已有同名分组「${name}」`,
          '合并：把本组书籍并入对方，同名书逐本选择处理',
          `重命名：本组改名为「${name} (2)」再移动`,
          '合并',
          '重命名',
          (): void => { this.mergeGroupInto(gid, siblingId) },
          (): void => { this.renameGroupAndMove(gid, targetId, name) }
        )
        return
      }
      const me: BookGroups | undefined = all.find((g: BookGroups): boolean => g.groupId === gid)
      if (me === undefined) {
        return
      }
      // 2026-11-02 第 26 轮（B⑥）：改走唯一写入口 —— 它负责"写库 + 刷 GroupStore + 刷隐藏集合 +
      //   发一次结构事件"。原来这里直接 `updatePartialGroup` 只 bump 旧 AppStorage 信号，
      //   而根页（`USE_STORE_IN_FOLDER=true`）读的是 `GroupStore` ⇒ 真机出现"把 12 移回 1 后，
      //   根页仍残留一张根级的 12 卡片，要重新进入才消失"（`2026-11-09-U3/50-restored-root.json`）。
      await GroupMutation.moveGroupNode(gid, targetId)
      // 2026-11-01：先广播再关窗 —— 关窗会销毁本组件，广播放后面在部分路径上会丢
      // （双轨期：旧信号继续发，供尚未迁移到 GroupEvents 的组件消费）
      ShelfRefresh.groups()
      ShelfRefresh.books()
      console.log(`[GRP-MOVE] from=${gid} to=${targetId} ok groupsRefresh=${this.BOOK_IS_BOOK_GROUPS_REFRESHING}`)
      this.groupMoveGroup?.close()
      this.cancel()
      showMessage(`已移动到「${targetName}」`)
    } catch (e) {
      showMessage('移动失败')
      console.error('doMoveGroupNode failed: ' + JSON.stringify(e))
    }
  }

  /** 同名合并：把 gid 的书并入 targetGid（同名书走冲突弹窗），成功后删掉 gid */
  private async mergeGroupInto(gid: number, targetGid: number): Promise<void> {
    if (targetGid <= 0) {
      showMessage('目标分组无效')
      return
    }
    try {
      const moving: Books[] = await booksDao.queryPreviewByGroups([gid], 5000)
      const existing: Books[] = await booksDao.queryPreviewByGroups([targetGid], 5000)
      const conflicts: MergeConflictInfo[] = this.findConflicts(moving, existing)
      if (conflicts.length > 0) {
        this.mergeDialog = new CustomDialogController({
          builder: GroupMergeDialog({
            conflicts: conflicts,
            onConfirm: (choices: number[]): void => {
              this.mergeDialog?.close()
              this.applyMergeMove(gid, targetGid, moving, conflicts, choices)
            },
            onClose: (): void => {
              this.mergeDialog?.close()
            }
          }),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          gridCount: 4,
          customStyle: false,
          cornerRadius: 25,
          cancel: (): void => {
            this.mergeDialog?.close()
          }
        })
        DialogHost.openIf(this.mergeDialog)
        return
      }
      await this.applyMergeMove(gid, targetGid, moving, [], [])
    } catch (e) {
      showMessage('合并失败')
      console.error('mergeGroupInto failed: ' + JSON.stringify(e))
    }
  }

  private async applyMergeMove(gid: number, targetGid: number, moving: Books[],
    conflicts: MergeConflictInfo[], choices: number[]): Promise<void> {
    try {
      for (const b of moving) {
        const idx: number = conflicts.findIndex((c: MergeConflictInfo): boolean => c.bookId === (b.id ?? -1))
        const choice: number = idx >= 0 ? choices[idx] : -1
        if (choice === 2) {
          if (b.id !== undefined) {
            await BooksMutation.moveOne(b.id, 3)
          }
          continue
        }
        if (choice === 0 && idx >= 0) {
          await booksUtil.delBooksById([conflicts[idx].oldId])
        }
        if (choice === 1) {
          b.bookName = `${b.bookName} (2)`
          await BooksMutation.update(b)
        }
        if (b.id !== undefined) {
          await BooksMutation.moveOne(b.id, targetGid)
        }
      }
      // 2026-11-03（A2）：唯一写入口（刷真源 + 单次事件）
      await GroupMutation.remove(gid)
      showMessage('已合并')
    } catch (e) {
      showMessage('合并失败')
      console.error('applyMergeMove failed: ' + JSON.stringify(e))
    } finally {
      // 2026-11-01：先广播再关窗（同 doMoveGroupNode）
      ShelfRefresh.groups()
      ShelfRefresh.books()
      this.cancel()
    }
  }

  /** 同名重命名：`name (2)` 后挂到目标下 */
  private async renameGroupAndMove(gid: number, targetId: number, name: string): Promise<void> {
    try {
      const all: BookGroups[] = await BookGroupsDao.search()
      const me: BookGroups | undefined = all.find((g: BookGroups): boolean => g.groupId === gid)
      if (me === undefined) {
        return
      }
            // 2026-11-03（Ⅱ-1）：改名+换父走写入口（一次结构事件）；不再原地改对象 + 直写 DAO
      await GroupMutation.renameAndMove(gid, `${name} (2)`, targetId)


      showMessage(`已重命名为「${name} (2)」并移动`)
    } catch (e) {
      showMessage('重命名失败')
      console.error('renameGroupAndMove failed: ' + JSON.stringify(e))
    } finally {
      // 2026-11-01：先广播再关窗（同 doMoveGroupNode）
      ShelfRefresh.groups()
      ShelfRefresh.books()
      this.cancel()
    }
  }

  @State dialogTitle:string = ''
  @State dialogContent:string = ''

  @State dialogHideTitle:string = '隐藏分组'
  @State dialogHideContent:string = '隐藏后可点击分组标签栏右侧分组管理入口查看隐藏分组并进入'
  @State dialogDisbandTitle:string = '解散分组'
  @State dialogDisbandContent:string = '解散分组后，组内书籍不会被删除，将归还上级分组（根级分组则移入未分组）'

  //隐藏、解散分组弹窗
  hideDisbandDelDialog: CustomDialogController | null = new CustomDialogController({
    builder: TitleContentDialog({
      confirm: ()=> { this.hideOrDisband() },
      title:this.dialogTitle,
      content:this.dialogContent,
      // 2026-10-12：取消路径必须真的 close（同 bookMoveGroup 那个坑）
      cancel: ()=> { this.closeChildAndReopen(this.hideDisbandDelDialog) }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    cancel: (): void => {
      this.closeChildAndReopen(this.hideDisbandDelDialog)
    }
  })
  //显示/隐藏
  hideOrDisband(){
    if (this.dialogTitle === '隐藏分组' || this.dialogTitle === '显示分组' || this.dialogTitle === '恢复显示') {
      this.hideGroup()
    } else {
      this.disbandGroup()
    }
  }
  /**
   * 2026-11-02：恢复显示前的父链校验 —— 父级仍隐藏则拒绝，并给出提示。
   * 校验通过才弹「恢复显示」确认框（`hideDisbandDelDialog`，其 confirm 会走 hideOrDisband → hideGroup 反写）。
   */
  private async checkCanRestoreShow(): Promise<void> {
    const gid: number = this.itemData.groupId ?? -1
    if (gid <= 0) {
      return
    }
    try {
      // 2026-11-02 第 26 轮（B②）：唯一树真源 —— 不再各处自建树（见 GroupStore.reload）
      const tree: GroupTree = await GroupStore.reload()
      let pid: number = this.itemData.parentId ?? 0
      let guard: number = 0
      while (pid > 0 && guard < 12) {
        const up: BookGroups | undefined = tree.get(pid)
        if (up !== undefined && !up.show) {
          showMessage(`请先恢复上级分组「${up.groupName ?? ''}」`)
          return
        }
        pid = up?.parentId ?? 0
        guard++
      }
      this.dialogTitle = '恢复显示'
      this.dialogContent = '恢复后该分组将重新出现在书架中'
      this.openChildDialog(this.hideDisbandDelDialog)
    } catch (e) {
      console.error('checkCanRestoreShow failed: ' + JSON.stringify(e))
      showMessage('恢复失败')
    }
  }

  //解散分组
  disbandGroup(){
    // 2026-11-01：统一走 dissolveGroup —— 旧实现 delGroupById 会把书塞进「未分组」，
    //   与"解散 = 书归还父级"矛盾（真机：在 1 里解散 11 后，11 的书没回到 1）
    this.dissolveGroup(true)
  }

  //隐藏分组
  // 2026-11-03（Ⅱ-4）：去掉 500ms 延时 —— 写入口 await 完成后立即刷新+关窗
  async hideGroup(){
    this.itemData.show = this.itemData.show ? false : true
    if (this.itemData.groupId) {
      // 2026-11-03（Ⅱ-3）：双轨开关已删 —— 隐藏固定走唯一写入口
        // 2026-11-02 架构收敛 P2-1：走唯一写入口（刷新真源 + 单次事件）；
        //   旧信号仍保留在 setTimeout 里，供双轨期未迁移的组件消费。
      try {
        await GroupMutation.setVisible(this.itemData.groupId, this.itemData.show)
      } catch (e) {
        const err = e as Error
        console.error(`[GRP-MUTATION] setVisible failed: ${err.message}`)
      }
    }
      ShelfRefresh.groups()
      // 2026-11-02：**必须同时广播书籍刷新** —— 隐藏/恢复会改变"哪些书可见"，
      //   只刷分组列表的话「全部/最近」还留着该组的书（真机：隐藏 1 后猛龙过江仍在第一位）。
      ShelfRefresh.books()
      this.cancel()
      showMessage(this.itemData.show ? '已恢复显示' : '隐藏成功')
  }

  coverDialog: CustomDialogController | null = new CustomDialogController({
    builder: coverInfoDialog({
      itemData:this.itemData,
      // 2026-10-12：必须真的 close 封面弹窗（同 bookMoveGroup 那个坑）
      cancel:()=>{
        this.closeChildAndReopen(this.coverDialog)
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
      this.closeChildAndReopen(this.coverDialog)
    }
  })

}





