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
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial()
  })
  //取消
  onCancel(){
    this.bookType = ''
  }
  //确定
  onAccept(){
    if (this.bookType.length === 0) {
      showMessage('分组名称不能为空')
      return
    }
    let isInsert = true
    //对比bookType看是否BooTypeList数组中存在
    this.groupList.forEach((element:BookGroups) => {
      if (element.groupName === this.bookType) {
        showMessage(`已存${this.bookType}分组`)
        this.bookType= ''
        isInsert = false
      }
    })
    if(isInsert){
      let bookGroups = new BookGroups()
      bookGroups.groupName = this.bookType
      bookGroups.groupType = this.currentIndex
      BookGroupsDao.insert(bookGroups)
      this.bookType= ''
      showMessage(`已添加${this.bookType}分组`)
      setTimeout(()=>{
        this.BOOK_IS_BOOK_GROUPS_REFRESHING++
        this.getGroupList()
      },500)
    }
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
