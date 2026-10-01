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
  /**
   * 卡片背板：**调用方已通过 `CustomDialogControllerOptions.systemMaterial` 提供材质**
   * ⇒ 第二个参数传 `true`，内容层让出背景把材质透出来（2026-09-22）。
   * 详见 `MaterialColumnModifier` 的注释与根 `Column` 处的说明。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(NightMode.isDarkSurface() ? ShelfColors.card() : Color.White, true)
  aboutToAppear(): void {
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
      Column() {
        Text('取消').fontSize(16).fontWeight(400)
          .lineHeight(24)
      }
      .onClick(()=>{
        Haptics.tap();
        this.onClose()
        this.controller?.close()
      })
      .alignItems(HorizontalAlign.Center)
      .padding({
        left: 32,
        right:32,
        top: 16
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
        booksUtils.updateBooks(this.Ids,this.moveGroupId);
        break
      //1标识分组
      case 1:
        bookGroupUtils.moveBookByGroupId(this.Ids,this.moveGroupId)
        break
    }
    showMessage(`已移动到${this.moveTitle}`)
  }

}
