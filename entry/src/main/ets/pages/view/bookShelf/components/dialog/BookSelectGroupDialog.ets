/**
 * @author 2008
 * @datetime 2024/7/25 13:44
 * @className: BookSelectGroupDialog
 * 移动分组弹窗
 */
import CommonConstants from '../../../../../common/constants/CommonConstants'
import { Haptics } from '../../../../../common/utils/Haptics';
import PaddingConstants from '../../../../../common/constants/PaddingConstants'
import bookGroupUtils from '../../../../../common/utils/bookGroupUtils'
import booksUtils from '../../../../../common/utils/booksUtils'
import addBookTypeDialog, { AddGroupChannel } from '../../../../../componets/common/addBookTypeDialog'
import { showMessage } from '../../../../../componets/common/promptShow'
import TitleContentDialog from '../../../../../componets/common/TitleContentDialog'
// 三选项确认框（2026-10-22 新增）：分组管理模式下点分组 → 删除 / 解散 / 取消
import ThreeActionDialog from '../../../../../componets/common/ThreeActionDialog'
import BookGroupsDao from '../../../../../database/dao/BookGroupsDao'
// 2026-10-22 分组管理「删除」需要取组内书籍 id + 逐本删除（见 doDeleteGroup）
import BooksDao from '../../../../../database/dao/BooksDao'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
import UiMotion from '../../../../../common/utils/UiMotion'

@Component
@CustomDialog
export default struct BookSelectGroupDialog{
  oldGroupId?:number
  controller?: CustomDialogController
  currentIndex:number = 0
  Ids:number|number[] = 0
  isMoveStatus:number = 0
  /**
   * **分组管理模式**（2026-10-22 新增，用户需求第 1 条）。
   *
   * ── 用户原话 ──────────────────────────────────────────────────────────────
   * 「用户在分组状态下，也就是三段开关的分组开关下，点击更多，在书籍导入/批量管理之下
   *   应该增加一个分组管理，点击之后进入移动至分组的弹窗，虽然我们复用移动至分组的弹窗，
   *   但是和移动至分组不一样，我们的弹窗是分组管理，里面有默认的未分组，还有新建分组，
   *   这个和移动至分组很像，但是我们因为没有选定书籍，所以我们点击除了未分组以外的
   *   其他分组，都是弹窗询问是否删除或者解散该分组，该弹窗有三个选项，删除，解散，取消，
   *   删除顾名思义是包含书籍全删除，解散则是解散分组书籍保留，和现有逻辑应该相同。」
   *
   * ── 与「移动至分组」的差异（三处，其余全部复用）───────────────────────────
   *   ① 标题：「移动分组」→「分组管理」；
   *   ② 「未分组」格：移动模式下点它 = 把书移到未分组；本模式下**点击无反馈**
   *      （未分组不是 `book_groups` 里的真实行，没有可删除/解散的实体）；
   *   ③ 其余分组格：移动模式下点它 = 移到该组；本模式下点它 = 弹三选一
   *      （删除 / 解散 / 取消）。
   * 新建分组（「+」格）、列表预取、新建后的真开真关重开 —— **完全共用**。
   */
  isManageMode: boolean = false
  moveGroup:Function = ()=>{

  }
  /**
   * 本弹窗被取消（取消按钮/遮罩）时通知父级 —— 子退父进（2026-10-01 统一联动规范）。
   * 注意：moveGroup（确认移动完成）**不**走这里 —— 移动完成后父弹窗保持关闭。
   */
  onClose: () => void = () => {

  }
  /**
   * **新建分组成功后**通知调用方（2026-10-13 新增，修「新建分组后移动分组弹窗里看不到新组」）。
   *
   * ── 为什么必须交给调用方重开 ─────────────────────────────────────────────
   * 点「+」时本弹窗已经 `this.controller?.close()`（见 `title()` builder 的 v3.21 出规则），
   * 而旧实现是在 `onAccept()` 里 `setTimeout(500) → this.getGroupList()` 自刷新 ——
   * 那 500ms 之后组件实例**已经被销毁**，`this.groupList = ...` 写在一个死实例上，
   * 界面当然不会变。更糟的是重开时 `aboutToAppear` 又会用
   * `presetGroups`（**创建瞬间的旧快照**，里面没有新组）把列表覆盖回去。
   *
   * ⇒ 现在：由**持有 controller 的调用方** `close → 重新预取分组 → new controller → open`，
   *    与工程已确立的"真开真关"完全一致（`BookInfoDialogs.openMoveGroupDialog` 等）。
   * 未传（null）时保持旧行为（自刷新 + 自己 open），不影响其它宿主。
   */
  onGroupCreated: (() => void) | null = null
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  /** 书架书列表重查信号（2026-10-12）：自动解散分组时同时广播，让书的 bookGroup 变化落到界面 */
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  /**
   * **父级预取好的分组列表**（2026-10-12 新增，修用户反馈的"未分组过一会儿才刷新出来"）。
   *
   * ── 症状与根因 ────────────────────────────────────────────────────────────
   * 用户原话：「用户把111放在自定义分组1之后，进入自定义分组1，长按菜单-移动至，
   *   此时未分组还没被刷新出来，过一会儿才刷新出来」。
   * 根因是本弹窗的内容靠 `aboutToAppear()` 里的**异步** `getGroupList()` 填充：
   * ```
   * aboutToAppear(): void {
   *   this.getGroupList()          // 异步，不 await
   * }
   * getGroupList(){
   *   BookGroupsDao.search({...}).then((val)=>{ this.groupList = val })   // 几百 ms 后才到
   * }
   * ```
   * ⇒ 弹窗**打开的瞬间 `groupList` 是空的**，网格里只剩「未分组」和「+」两个格子，
   *   其余分组要等查询回来才"跳"出来 —— 这就是用户看到的"脱节"。
   *
   * ── 修法 ──────────────────────────────────────────────────────────────────
   * 调用方（`BookInfoDialogs.openMoveGroupDialog()` / `BookManagePage.openMoveGroup()`）
   * 在 `controller.open()` **之前** `await` 把分组查好，经本字段传入
   * ⇒ 弹窗首帧就拿到完整列表，不再有异步空窗期。
   * `aboutToAppear` 保留 `getGroupList()` 只作为**兜底**（未传时仍能工作）。
   *
   * ⚠️ 传的是**创建瞬间的数组引用**；弹窗内只读不写（本弹窗不改分组数据）。
   *    这与规范 §4.4「参数动态更新无效 ⇒ 打开瞬间 new 一个新 controller」一致 ——
   *    调用方本来就是"每次打开都新建"，所以快照天然是当次最新。
   */
  presetGroups: BookGroups[] | null = null
  /**
   * 卡片背板：**调用方已通过 `CustomDialogControllerOptions.systemMaterial` 提供材质**
   * ⇒ 第二个参数传 `true`，内容层让出背景把材质透出来（2026-09-22）。
   * 详见 `MaterialColumnModifier` 的注释与根 `Column` 处的说明。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(NightMode.isDarkSurface() ? ShelfColors.card() : Color.White, true)
  aboutToAppear(): void {
    // ★ 2026-10-12：优先用**父级预取好的列表**（首帧就有内容，不再"过一会儿才刷出来"）。
    //   未传（null）才回落到异步现查 —— 保证这个弹窗被别处单独使用时行为不变。
    if (this.presetGroups !== null) {
      this.groupList = this.presetGroups
      return
    }
    this.getGroupList()
  }

  @State groupList:BookGroups[] = []
  getGroupList(){
    BookGroupsDao.search({
      type:this.currentIndex
    }).then((val)=>{
      this.groupList = val
    })
  }

  build() {
    Column() {
      Column(){
        // 2026-10-22：分组管理模式标题不同（其余结构完全一致）
        Text(this.isManageMode ? '分组管理' : '移动分组')
          .fontSize(16)
          .fontWeight(700)
          .lineHeight(24)

      }.padding({right:20,left:20,top:12,bottom:12})

      Divider().strokeWidth(0.5)
      Scroll(){
        GridRow({
          columns:3
        }){
          // ★ 「未分组」选项（第一格，锁定在列表最前面；2026-10-12 新增）
          //   只在当前有分组（oldGroupId 已指向自定义分组）时才显示——
          //   如果书本身就在未分组里，点"未分组"没有任何意义。
          if (this.oldGroupId !== 3) {
            GridCol(){
              this.ungroupedTitle()
            }
          }
          GridCol(){
            this.title()
          }
          ForEach(this.groupList,(item:BookGroups)=>{
            // ── 2026-10-22：分组管理模式下**隐藏的分组也要显示** ────────────────
            // 本模式是"管理全部分组"，若沿用移动模式的 `item.show` 过滤，
            // 用户被隐藏的分组将**永远无法删除/解散**（设置页的"显示/隐藏分组"两栏
            // 已在 2026-10-20 按用户要求删除，见 `groupTypePanel` 的注释）
            // ⇒ 管理模式下不看 `show`，其余条件（真实分组、非系统、非当前组）不变。
            if (item.groupId && !item.isSystem
              && (this.isManageMode || item.show)
              && this.oldGroupId !== item.groupId) {
              GridCol(){
                this.title(item)
              }
            }
          }, (item: BookGroups): string => item.groupId !== undefined ? 'g' + item.groupId : item.groupName)
        }.padding(PaddingConstants.PADDING_20)
      }
      .align(Alignment.Top)
      .height('65%')
      .scrollBar(BarState.Off)
      Divider().strokeWidth(0.5)
      // ══════════════════════════════════════════════════════════════════════
      // 「取消」按钮（2026-10-12 修：点它没反应 / 弹窗不消失 / 父弹窗被召回）
      // ══════════════════════════════════════════════════════════════════════
      // ── 真机症状（用户原话）──────────────────────────────────────────────────
      //   「点击移动分组弹窗的取消，子弹窗没取消，父弹窗回来了，循环。
      //     点击其他区域可以关闭弹窗，手势可以关闭弹窗，**就是点击取消按钮不行**」。
      //
      // ── 日志证据（`docs/日志.md`，点"取消"那一次）────────────────────────────
      // ```
      // 4256: ITK Id:316698, TTHNI:fId: 0{ T: Dialog, D: 2 };
      // 4257: ITK Id:316698, TTHRTI: T ClickRecognizer info: { T: Dialog };   ← 命中链里**只有 Dialog**
      // 4263: Click try accept Dialog
      // 4265: The current state of the dialog is DISAPPEARING.
      // 4272: on dialog/1611 close event enter
      // ```
      // 对照**点到 Column** 的那一次（同文件 4349-4350）：
      // ```
      // 4350: TTHRTI: T ClickRecognizer info: { T: Column }; { T: Dialog };
      // ```
      // ⇒ 点"取消"时落点**根本没进任何子节点**，而是打在弹窗根容器的空白处
      //   ⇒ 被 `autoCancel: true` 当成"点遮罩"⇒ 关弹窗 ⇒ 走 options 的 `cancel`
      //   ⇒ `childDialogClosed()` 把**父弹窗**恢复 ⇒ 父弹窗回来、子弹窗却没了
      //   ⇒ 用户看到"取消没生效、父弹窗冒出来"，反复操作就是"循环"。
      //
      // ── 为什么会落空 ─────────────────────────────────────────────────────────
      // 旧写法是 `Column(){ Text('取消') }` —— **高度完全由 Text 撑开**（约 24vp 文字
      // + padding top 16），且是一个**窄的自适应宽度**（没有 `.width('100%')`）。
      // 用户在按钮**文字附近但不在文字上**的位置点，就落到根 Column 的空白里。
      //
      // ── 修法（两条，缺一不可）──────────────────────────────────────────────────
      // ① **命中区做实**：`.width('100%')` + `.height(56)` + 垂直居中 ⇒ 整条都是按钮，
      //    不再有"看着像按钮、点着是空白"的死区；
      // ② **弹窗不由自己 close**：`this.controller?.close()` 在 `@CustomDialog`
      //    子组件里**无效**（这条已在 `RenameBookDialog` 上真机确认并修过）。
      //    原来"先 onClose() 恢复父弹窗、再 close() 自己"⇒ 父弹窗回来了、子弹窗还在
      //    ⇒ **正是用户说的循环**。现在只回调，关闭由调用方（持有 controller 的那一侧）做。
      Column() {
        Text('取消').fontSize(16).fontWeight(400)
          .lineHeight(24)
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      .height(56)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        Haptics.tap()
        // 只通知调用方「用户点了取消」；**关自己 + 恢复父弹窗**都由调用方执行
        // （它才持有两个 controller，`BookSelectGroupDialog.onClose` 的注释同此口径）
        this.onClose()
      })
    }
    .width(CommonConstants.FULL_WIDTH)
    .height(CommonConstants.FULL_HEIGHT)
    // ── 让出背景，由 dialog 层承载沉浸光感材质（2026-09-22）────────────────
    // 用户要求：「加入书单的材质应该和**移动分组**的材质对齐，这几个 sheet
    // 都应该和移动分组的材质对齐」。
    // 注意：移动分组此前**并没有**材质（只有 `customStyle:false` + `cornerRadius:25`），
    // 所以这里先把它做成"有材质"的基准，其它弹窗再向它对齐。
    // `hasOptionsMaterial = true` ⇒ 材质可用时本层**不设 backgroundColor**，
    // 让调用方 options 里的 `systemMaterial` 透出来；材质不可用时回落白实底。
    // 原理与依据见 `MaterialColumnModifier` 的注释。
    .attributeModifier(this.surface)
  }
  @State moveGroupId:number = 0
  @State moveTitle:string = ''
  /** 「未分组」按钮（2026-10-12 新增）；点后把书/分组移到 bookGroup=3（未分组状态） */
  @Builder ungroupedTitle() {
    Column() {
      Text('未分组').fontSize(14).maxLines(1)
    }
    .onClick(()=>{
      // ── 2026-10-22：分组管理模式下「未分组」**点击完全无反馈**（用户拍板）────────
      // 理由：「未分组」不是 `book_groups` 里的一行（`bookGroup = 3` 是 books 表的特殊值，
      //   见 `bookGroupUtils.dissolveIfEmpty` 注释③），没有可删除/解散的实体；
      //   而本模式下也没有"选定的书籍"可以移动 ⇒ 它只作为**默认项占位**显示。
      // ⚠️ 连 `Haptics.tap()` 都不做：震了却什么都不发生，用户会当成"点了没反应"的 bug。
      //   回退：删掉下面这个 return 即恢复"移到未分组"的旧语义。
      if (this.isManageMode) {
        return
      }
      Haptics.tap();
      this.moveGroupId = 3
      this.moveTitle = '未分组'
      this.clickBookTypeDialog?.open()
    })
    .margin({
      bottom:PaddingConstants.PADDING_16
    })
    .width(85).height(36)
    .backgroundColor(ShelfColors.chip())
    .padding({
      left:16,
      right:16,
      top:8,
      bottom:8
    })
  }
  @Builder title(item?:BookGroups) {
    Column() {
      if (item){
        Text(item.groupName).fontSize(14).textOverflow({
          overflow:TextOverflow.Ellipsis
        }).ellipsisMode(EllipsisMode.END).maxLines(1)
      } else {
        Image($r('app.media.add')).width(24)
      }
    }
    .onClick(()=>{
      Haptics.tap();
      if(!item){
        // ── 2026-10-22：分组管理模式的「+」走**连续创建**通道（不关父弹窗）──────
        // 用户要求：「每次创建后底部的父弹窗需要实时更新，不然用户不清楚是否真正创建成功」
        // ⇒ 父弹窗必须**留在屏幕上**，所以不能走下面的"子开父退"（那会把父弹窗关掉，
        //   实例一销毁就再也刷不了列表）。这里改成规范 §4.3 的"二级短确认框"叠加方式。
        if (this.isManageMode) {
          this.openManageAddTypeDialog()
          return
        }
        // v3.21 出规则：子弹窗（新建分组）出现 ⇒ 父弹窗（移动分组）退出；
        // 子关闭/确定后由 onCancel/onAccept 重开父弹窗
        this.controller?.close()
        this.addBookType?.open()
        return
      }
      if (item.groupId) {
        // ── 2026-10-22：分组管理模式 ⇒ 弹「删除 / 解散 / 取消」三选一 ──────────
        if (this.isManageMode) {
          // 每次点击都新建 controller（builder 参数不支持动态更新，见 openManageDialog 注释）
          this.openManageDialog(item)
          return
        }
        this.moveGroupId = item.groupId
        this.moveTitle = item.groupName
        this.clickBookTypeDialog?.open()
      }
    })
    .margin({
      bottom:PaddingConstants.PADDING_16
    })
    .width(85).height(36)
    .backgroundColor(ShelfColors.chip())
    .padding({
      left:16,
      right:16,
      top:8,
      bottom:8
    })
  }
  // ══════════════════════════════════════════════════════════════════════════
  // 分组管理模式：连续创建（2026-10-22 新增，用户需求第 3 条）
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * 连续创建用的新建分组弹窗（**每次点「+」都新建**）。
   *
   * ── 用户原话 ──────────────────────────────────────────────────────────────
   * 「新建分组弹窗不用点完确定取消，而是可以连续创建，比如输入 1，点击确定，1 已经被
   *   创建了，但是这个弹窗没动，只是输入框重制了，可以继续输入，并且内部的内容从
   *   请输入分组名称变成了创建成功，可继续输入创建。这个逻辑就避免有的用户想要一次性
   *   多创建，反复打开弹窗问题。**但是每次创建后底部的父弹窗需要实时更新**，不然用户
   *   会不清楚是否真正创建成功。」
   *
   * ── 与「移动至分组」那条路径的三处差异 ──────────────────────────────────────
   *   ① **父弹窗不关**：`addBookTypeDialog` 的 `keepOpen = true` ⇒ 确定后不 close 自己；
   *      这里也**不**调用 `this.controller?.close()`（那是"子开父退"，会销毁父实例，
   *      列表就再也刷不出来了）；
   *   ② **每次创建后当场重查父弹窗的列表**：`await this.getGroupListAsync()` 直接写回
   *      `this.groupList`（父实例还活着，写入**是有效的** —— 这与 `onGroupCreated` 那条
   *      "实例已销毁、写了没用"的坑刚好相反，见该字段注释）；
   *   ③ **关闭权仍归调用方**：用户点「取消」才真正关闭，走 `cancel()` → `onCancel()`。
   *
   * ── 为什么"父弹窗还活着"这件事必须由本方法保证 ────────────────────────────
   * `@CustomDialog` 的 `@State` 在弹窗 close 之后**实例就没了**，此后任何 `this.groupList = …`
   * 都写在一个死实例上（2026-10-13 踩过：新建分组后列表永远看不到新组）。
   * ⇒ 连续创建的前提就是"父弹窗一直在"，本方法靠"不关父弹窗"满足它。
   */
  private manageAddTypeDialog: CustomDialogController | null = null

  private openManageAddTypeDialog(): void {
    this.bookType = ''
    // 每次打开都从"未创建成功"起步（避免上次的成功提示串到新一次）
    AppStorage.setOrCreate<boolean>(AddGroupChannel.KEY_OK, false)
    this.manageAddTypeDialog = new CustomDialogController({
      builder: addBookTypeDialog({
        // 连续创建模式（见 addBookTypeDialog 类注释）
        keepOpen: true,
        // 创建成功后的输入框提示（用户原话给的文案）
        doneHint: '创建成功，可继续输入创建',
        // ⚠️ 不再传 `bookType`：它是子弹窗的 `@StorageLink`（AppStorage 通道），
        //    传参会触发 lint「mandatory to specify」/ 且方法内 new 时 @Link 会崩溃
        //    （真机证据见 addBookTypeDialog 文件头）。
        // 用户点「取消」= 结束连续创建 ⇒ 关闭子弹窗（关闭权在本侧，持有 controller）
        cancel: (): void => {
          this.manageAddTypeDialog?.close()
          this.manageAddTypeDialog = null
          this.bookType = ''
        },
        // 每次点「确定」都会回调这里 —— 建组 + **当场刷新父弹窗列表**
        confirm: (): void => {
          this.createGroupKeepOpen().catch((e: Error): void => {
            console.error('createGroupKeepOpen failed: ' + e.message)
          })
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      customStyle: false,
      cornerRadius: 20,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      // 遮罩/返回键：等同于"结束连续创建"
      cancel: (): void => {
        this.manageAddTypeDialog?.close()
        this.manageAddTypeDialog = null
        this.bookType = ''
      }
    })
    this.manageAddTypeDialog.open()
  }

  /**
   * 建一个分组，然后**立刻刷新父弹窗的列表**（不关任何弹窗）。
   *
   * 校验与提示口径与 `onAccept()` 完全一致（空名 / 重名），只是不涉及任何 close/open：
   *   · 空名 ⇒ toast「分组名称不能为空」，不建组、不显示成功提示；
   *   · 重名 ⇒ toast「已存X分组」，不建组、不显示成功提示；
   *   · 成功 ⇒ toast「已添加X分组」+ 重查列表 + 广播 + 置 `manageCreateOk = true`。
   */
  private async createGroupKeepOpen(): Promise<void> {
    const newName: string = this.bookType.trim()
    if (newName.length === 0) {
      AppStorage.setOrCreate<boolean>(AddGroupChannel.KEY_OK, false)
      showMessage('分组名称不能为空')
      return
    }
    // 重名判据用**当前列表**（`groupList` 每次创建后都会重查，所以是最新的）
    const dup: BookGroups | undefined =
      this.groupList.find((g: BookGroups): boolean => g.groupName === newName)
    if (dup !== undefined) {
      AppStorage.setOrCreate<boolean>(AddGroupChannel.KEY_OK, false)
      showMessage(`已存${newName}分组`)
      return
    }
    const bookGroups: BookGroups = new BookGroups()
    bookGroups.groupName = newName
    bookGroups.groupType = this.currentIndex
    // ⚠️ 必须 await：紧接着就要重查列表，不等待提交会漏掉刚建的这一组
    await BookGroupsDao.insert(bookGroups)
    showMessage(`已添加${newName}分组`)
    // ① 当场重查父弹窗列表（父实例仍存活 ⇒ 这次写入**是有效的**）
    await this.getGroupListAsync()
    // ② 广播：书架分组行 / 分组卡片重查（规范第 5 节）
    this.BOOK_IS_BOOK_GROUPS_REFRESHING++
    // ③ 告诉子弹窗"这次真的成功了" ⇒ placeholder 切到「创建成功，可继续输入创建」
    AppStorage.setOrCreate<boolean>(AddGroupChannel.KEY_OK, true)
  }

  /**
   * `getGroupList()` 的 **await 版**（2026-10-22 新增，供连续创建用）。
   *
   * 原 `getGroupList()` 是 fire-and-forget（`.then` 里赋值），调用方拿不到"已经刷新完"
   * 的时点；连续创建要求"创建完 ⇒ 列表立刻是最新的"，所以必须能 await。
   */
  private async getGroupListAsync(): Promise<void> {
    try {
      const list: BookGroups[] = await BookGroupsDao.search({ type: this.currentIndex })
      this.groupList = list
    } catch (e) {
      console.error('getGroupListAsync failed: ' + JSON.stringify(e))
    }
  }

  //添加分组弹窗
  /**
   * 新建分组的输入内容 —— **`@StorageLink`（AppStorage 通道），不是普通 `@State`**。
   *
   * ⚠️ 2026-10-22 真机崩溃后的连带修改：
   *   子弹窗 `addBookTypeDialog` 的 `bookType` 已从 `@Link` 改为 `@StorageLink`
   *   （原因见该文件头 `AddGroupChannel`：方法内 new controller 时 `@Link` 无父组件可绑 ⇒
   *   真机 `SyntaxError: undefined 'bookType' … must be defined` ⇒ 杀进程）。
   *   `@Link` 那套是"父 @State ↔ 子 @Link"的双向绑定，改成 AppStorage 后，
   *   **父级这一侧也必须挂同一个 key**，否则两边读写的是两份不同的数据
   *   （父读到空串 ⇒ 永远提示「分组名称不能为空」）。
   */
  @StorageLink(AddGroupChannel.KEY_TEXT) bookType: string = ''
  addBookType: CustomDialogController | null = new CustomDialogController({
    builder: addBookTypeDialog({
      cancel: ()=> { this.onCancel() },
      confirm: ()=> { this.onAccept() }
      // ⚠️ 不再传 `bookType`：它已是子弹窗的 `@StorageLink`（同一个 AppStorage key）
    }),
    cancel: this.onCancel,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 20,
    // 2026-09-25 用户反馈：新建分组弹窗材质与全局统一（原来漏了 systemMaterial ⇒ 白实底）
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    // ── 子开父退 / 子关父回（统一联动规范，2026-10-01 修）───────────────────────
    // 出/入规则全部由**人肉回调**驱动：点 + 时父弹窗已 close（见 title() builder）、
    // 取消走 onCancel、确定走 onAccept —— 三条路径各自 `this.controller?.open()` 收尾。
    // ⚠️ 不要再加 options 级 `onDidAppear` 重开父弹窗：那是在子弹窗**出现时**就把父弹窗
    // 顶回顶层（真机复测："点击新建后父窗口关闭又弹出，出现在了顶层，多了这一个"）。
    // （当初想要的 options.onDisappear 在 CustomDialogControllerOptions 里不存在，
    // 误写成 onDidAppear —— 见 SDK custom_dialog_controller.d.ts 的 options 字段表。）
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
  })
  //取消
  onCancel(){
    this.bookType = ''
    this.controller?.open()
  }
  //确定
  async onAccept(): Promise<void> {
    // ⚠️ 子弹窗（addBookTypeDialog）确认时**先自己 close 再回调**本方法 ⇒ 本方法无论走
    // 哪个分支，末尾都必须把父弹窗（移动分组）open 回来，否则提前 return 的分支
    // （空名/重名）会让屏幕上两层弹窗全消失。
    if (this.bookType.length === 0) {
      showMessage('分组名称不能为空')
      this.controller?.open()
      return
    }
    let isInsert = true
    //对比bookType看是否BooTypeList数组中存在
    // 先留名字再清输入（2026-10-01 修：原来先 `this.bookType=''` 再拼提示语，
    // toast 永远是"已添加分组"，丢了组名）
    const newName: string = this.bookType
    this.groupList.forEach((element:BookGroups) => {
      if (element.groupName === newName) {
        showMessage(`已存${newName}分组`)
        isInsert = false
      }
    })
    this.bookType= ''
    if(isInsert){
      let bookGroups = new BookGroups()
      bookGroups.groupName = newName
      bookGroups.groupType = this.currentIndex
      // ⚠️ 必须 await（2026-10-13）：重开弹窗时调用方会**立刻**重查分组列表，
      //    不等待提交就会漏掉刚建的这一组（前端表现仍是"看不到新分组"）
      await BookGroupsDao.insert(bookGroups)
      showMessage(`已添加${newName}分组`)
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      if (this.onGroupCreated !== null) {
        // 真开真关：本弹窗已被关闭 ⇒ 交给调用方重开（它会重新预取分组）。
        // 绝不能再在这里 `getGroupList()`：实例已销毁，写了也不会显示（见字段注释）。
        this.onGroupCreated()
        return
      }
      // 兜底（未传 onGroupCreated 的宿主）：保持旧的自刷新行为
      setTimeout(()=>{
        this.getGroupList()
      },500)
    }
    // 入规则：建组完成（或重名放弃）⇒ 父弹窗（移动分组）恢复
    this.controller?.open()
  }

  //是否确认移动分组
  clickBookTypeDialog: CustomDialogController | null = new CustomDialogController({
    builder: TitleContentDialog({
      confirm: async ()=> {
        await this.clickBookAccept()
        setTimeout(()=>{
          this.moveGroup()
        },500)
      },
      title:`移动分组至${this.moveTitle}`
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

 async clickBookAccept() {
    switch (this.isMoveStatus){
      //0标识书籍
      case 0:
        await booksUtils.updateBooks(this.Ids,this.moveGroupId);
        // 2026-10-12：书移走后，检查原分组是否还有书，若无则自动解散
        await this.cleanupOldGroup()
        break
      //1标识分组
      case 1:
        bookGroupUtils.moveBookByGroupId(this.Ids,this.moveGroupId)
        break
    }
    showMessage(`已移动到${this.moveTitle}`)
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 分组管理模式：删除 / 解散（2026-10-22 新增，用户需求第 1 条）
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * 三选一确认弹窗（**每次点击都新建**）。
   *
   * ⚠️ 为什么不能用字段初始化器 new 一个复用：
   *   SDK `custom_dialog_controller.d.ts:756` NOTE 原文「Custom dialog box parameters
   *   **do not support dynamic updates**」⇒ 复用实例的话，标题里的分组名永远是
   *   **第一次点的那一个**。这与工程既有做法一致（`BookInfoDialogs.openRenameDialog()`、
   *   `GroupType.openGroupPanel()` 都是"打开瞬间新建"）。
   */
  private manageDialog: CustomDialogController | null = null

  /**
   * 打开「删除 / 解散 / 取消」三选一。
   *
   * 语义（用户原话）：「删除顾名思义是包含书籍全删除，解散则是解散分组书籍保留，
   *   和现有逻辑应该相同」。
   *   · **删除** = 组内书籍**一起删掉** + 删掉分组行 ⇒ 走 `booksUtils.delBooksById`（书籍）
   *     + `bookGroupUtils.delGroupById`（分组行）。`delBooksById` 内部已处理书签/进度/
   *     封面文件等派生数据的清理（见该方法注释），比裸删行安全得多。
   *   · **解散** = 分组行删掉、组内书籍**保留**并落到「未分组」（`bookGroup = 3`）
   *     ⇒ 与工程既有「解散分组」**完全同一条实现**：`bookGroupUtils.delGroupById`
   *     内部就是「删分组行 + `BooksDao.queryBookByGroup(Ids, 3)`」
   *     （`bookGroupUtils.ets:35-42`，即 `FolderInfoDialog.disbandGroup()` 用的同一个方法）。
   *
   * ── 为什么必须等写库提交完再广播 ────────────────────────────────────────────
   * 规范第 5 节第 2 条「广播必须发生在 DB 提交之后」。
   * 本次一并把底层两处**裸调**修成 `await`（不 await 就会"删了分组还在 / 书没进未分组"）：
   *   · `bookGroupUtils.delGroupById` —— 原来两行 DAO 调用全裸调；
   *   · `BooksDao.queryBookByGroup` —— 原来 `forEach` 里裸调 `this.update(item)`。
   * ⇒ 现在 `await bookGroupUtils.delGroupById(...)` 返回时，写库**确实已提交**。
   */
  private openManageDialog(item: BookGroups): void {
    if (item.groupId === undefined) {
      return
    }
    const gid: number = item.groupId
    const gname: string = item.groupName ?? ''
    this.manageDialog = new CustomDialogController({
      builder: ThreeActionDialog({
        title: `「${gname}」要怎么处理？`,
        rawTitle: true,
        hintPrimary: '删除：分组和组内书籍一起删除',
        hintSecondary: '解散：只解散分组，书籍保留并移至未分组',
        primaryText: '删除',
        secondaryText: '解散',
        cancelText: '取消',
        onPrimary: (): void => {
          this.doDeleteGroup(gid, gname).catch((e: Error): void => {
            console.error('deleteGroup in manage mode failed: ' + e.message)
          })
        },
        onSecondary: (): void => {
          this.doDissolveGroup(gid, gname).catch((e: Error): void => {
            console.error('dissolveGroup in manage mode failed: ' + e.message)
          })
        },
        onCancel: (): void => {
          // 取消 = 什么都不做（本弹窗是叠在分组管理之上的二级短确认框，规范 §4.3）
          this.manageDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      customStyle: false,
      cornerRadius: 25,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      // 遮罩/返回键：同一条收尾路径（只清引用，分组管理弹窗本身不动）
      cancel: (): void => {
        this.manageDialog = null
      }
    })
    this.manageDialog.open()
  }

  /** 删除：组内书籍全删 + 分组行删除（await 到底后再广播） */
  private async doDeleteGroup(groupId: number, groupName: string): Promise<void> {
    try {
      // ① 先取组内书籍 id（用精准 `bookGroup IN (…)`，不叠加 bookType —— 口径见
      //    `bookGroupUtils.dissolveIfEmpty` 注释①，`searchPage` 会因 bookType 漏书）
      const bookIds: number[] = await BooksDao.queryBooksByGroupId([groupId])
      // ② 逐本删（`delBooksById` 内部清理书签/进度/封面，必须 await 完再继续）
      if (bookIds.length > 0) {
        await booksUtils.delBooksById(bookIds)
      }
      // ③ 再删分组行（此时组内已无书，内部"书置 3"是幂等的空操作）
      await bookGroupUtils.delGroupById(groupId)
      showMessage(bookIds.length > 0
        ? `已删除「${groupName}」及 ${bookIds.length} 本书`
        : `已删除「${groupName}」`)
    } catch (e) {
      console.error('doDeleteGroup failed: ' + JSON.stringify(e))
      showMessage('删除失败')
    } finally {
      this.afterGroupChanged()
    }
  }

  /** 解散：只删分组行，组内书籍保留并落到「未分组」（`bookGroup = 3`） */
  private async doDissolveGroup(groupId: number, groupName: string): Promise<void> {
    try {
      // 与 `FolderInfoDialog.disbandGroup()` **同一条实现**（用户：「和现有逻辑应该相同」）。
      // `delGroupById` 内部 = 「组内书置 3」+「删分组行」，且 2026-10-22 已改为逐个 await
      // ⇒ 本方法 resolve 时写库**确实已提交**，随后的广播才读得到新数据。
      await bookGroupUtils.delGroupById(groupId)
      showMessage(`已解散「${groupName}」，书籍已移至未分组`)
    } catch (e) {
      console.error('doDissolveGroup failed: ' + JSON.stringify(e))
      showMessage('解散失败')
    } finally {
      this.afterGroupChanged()
    }
  }

  /**
   * 分组变更后的收尾：重查本弹窗的分组列表 + 广播两个刷新信号。
   *
   * 三个信号各自的作用（与工程既有约定一致，见规范第 5 节）：
   *   · `BOOK_IS_BOOK_GROUPS_REFRESHING` ⇒ 书架分组行 / 分组卡片重查；
   *   · `isBookRefreshing`（`BOOK_IS_BOOK_REFRESHING`）⇒ 书架书列表重查
   *     （删除路径下书籍确实变了；解散路径下书籍的 `bookGroup` 也变了）；
   *   · 本弹窗自己的 `groupList` 也要重查 —— 它已经被销毁过（`onGroupCreated` 的
   *     同款问题），所以**不能在这里写**，必须交给持有 controller 的调用方重开。
   *
   * ⇒ 用 `onGroupCreated` 这条**既有**的"真开真关"通道通知调用方重开（它本来就做
   *   「close → 重新预取分组 → new controller → open」这件事，语义完全吻合）。
   */
  private afterGroupChanged(): void {
    this.BOOK_IS_BOOK_GROUPS_REFRESHING++
    this.isBookRefreshing++
    if (this.onGroupCreated !== null) {
      this.onGroupCreated()
      return
    }
    // 兜底（未传 onGroupCreated 的宿主）：关掉自己，让宿主自行处理
    this.onClose()
  }

  /**
   * 书被移走后，检查原分组是否还有书；若无则自动解散（2026-10-12）。
   *
   * ⚠️ 两条实现要点，都是上一版**没用起来**的原因：
   *  ① **判据必须用 `queryBooksByGroupId`（精准 `bookGroup IN (…)`）**，
   *     不能用 `searchPage({bookGroup, type})` —— 后者会叠加 `bookType` 过滤，
   *     原分组里的书若 bookType 与本页 `currentIndex` 不同就会被漏掉/误判；
   *  ② **解散后必须广播** `BOOK_IS_BOOK_GROUPS_REFRESHING`，否则管理页的分组列表
   *     （`BookManagePage.getGroupList()` 只在 `@Watch` 上重跑）不会重查，
   *     用户看到的就是"分组还在"。
   *
   * 逻辑收敛在 `bookGroupUtils.dissolveIfEmpty()`，把"空分组自动解散"做成**通用能力**，
   * 而不是散落在各个弹窗里（管理页删书 / 移动分组等路径将来也要复用）。
   */
  private async cleanupOldGroup(): Promise<void> {
    const oldGid: number = this.oldGroupId ?? -1
    if (oldGid <= 0 || oldGid === 3) {
      return
    }
    const dissolved: boolean = await bookGroupUtils.dissolveIfEmpty([oldGid])
    if (dissolved) {
      // 广播：管理页 `@Watch('getGroupList')` 据此重查分组列表（分组卡片消失）
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      // 同时让书架的书列表也重查（书的 bookGroup 已经变成未分组）
      this.isBookRefreshing++
      showMessage('该分组已无书籍，已自动解散')
    }
  }

}
