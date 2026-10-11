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
import addBookTypeDialog from '../../../../../componets/common/addBookTypeDialog'
import { showMessage } from '../../../../../componets/common/promptShow'
import TitleContentDialog from '../../../../../componets/common/TitleContentDialog'
import BookGroupsDao from '../../../../../database/dao/BookGroupsDao'
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
  moveGroup:Function = ()=>{

  }
  /**
   * 本弹窗被取消（取消按钮/遮罩）时通知父级 —— 子退父进（2026-10-01 统一联动规范）。
   * 注意：moveGroup（确认移动完成）**不**走这里 —— 移动完成后父弹窗保持关闭。
   */
  onClose: () => void = () => {

  }
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
        Text('移动分组')
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
            if (item.groupId && !item.isSystem && item.show && this.oldGroupId !== item.groupId) {
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
        // v3.21 出规则：子弹窗（新建分组）出现 ⇒ 父弹窗（移动分组）退出；
        // 子关闭/确定后由 onCancel/onAccept 重开父弹窗
        this.controller?.close()
        this.addBookType?.open()
        return
      }
      if (item.groupId) {
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
  //添加分组弹窗
  @State bookType:string = ''
  addBookType: CustomDialogController | null = new CustomDialogController({
    builder: addBookTypeDialog({
      cancel: ()=> { this.onCancel() },
      confirm: ()=> { this.onAccept() },
      bookType: this.bookType
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
  onAccept(){
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
      BookGroupsDao.insert(bookGroups)
      showMessage(`已添加${newName}分组`)
      setTimeout(()=>{
        this.BOOK_IS_BOOK_GROUPS_REFRESHING++
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
