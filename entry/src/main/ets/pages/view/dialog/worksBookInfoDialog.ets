import worksListsUtils from '../../../common/utils/WorksListsUtils'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
import confirmDialogExample from '../../../componets/common/confirmDialog'
import InsideCircleIcon from '../../../componets/common/InsideCircleIcon'
import { buttonList } from '../../../componets/dataList/buttonList'
import { WorksLists } from '../../../database/entities/WorksLists'
import newBookShelf from '../bookShelf/Manage/bookManage/newBookShelf'
import { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil'
import { showMessage } from '../../../componets/common/promptShow'

@CustomDialog
/**
 * 书单长按弹窗
 */
export default struct worksBookInfoDialog{
  controller?: CustomDialogController

  /**
   * 弹窗背板（2026-09-21 接入沉浸光感，2026-09-22 改悬空四圆角 + 系统真材质）。
   * 第二个参数传 `true` ⇒ 内容层**一个背景属性都不设**，让弹窗层材质透出来；
   * 前提是调用方已把 `customStyle` 设为 `false`（见 `WorksBookLists.ets` 调用点）。
   * 依据与完整说明见 `MaterialColumnModifier` 注释。
   *
   * 注意：同文件 `showEditBook()` 那个是**全屏** `bindContentCover`，
   * 按官方功耗文档「控制弹窗尺寸」（避免接近全屏）**刻意不加**材质。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  //推送提醒
  @Prop works:WorksLists
  @State buttonListInfo:buttonList[] = [
    new buttonList(1,'编辑',$r('app.media.edit')),
    new buttonList(2,'分享',$r('app.media.icon_share')),
    new buttonList(3,'删除',$r('app.media.ic_public_delete'))
  ]

  cancel: () => void = () => {
  }

  build() {
    Column(){
      Divider().strokeWidth(0.5).color(ShelfColors.line()).padding({bottom:16})
      GridRow({
        columns:4
      }){
        ForEach(this.buttonListInfo,(item:buttonList)=>{
          GridCol(){
            InsideCircleIcon({
              icon:item.icon,
              title:item.title
            })
              .onClick(()=>{
                switch (item.id){
                  case 1:
                    this.isShowEditBook = true
                    break
                  case 2:
                    // 2026-10-06：**只保留系统分享**。原「自定义分享弹窗」（`shareWorksBook`）已删除，
                    // 原因：它其实是"生成书单图片 + 微信/QQ/朋友圈/QQ空间 占位按钮"，
                    // 且那些第三方品牌图标未接入任何官方 SDK（商标风险）；其内部"系统分享"也只是提示。
                    // 书单与分组一样**没有可分享的文件**（系统分享必须提供 utd + uri 的文件），
                    // 所以这里与既有先例 `BookManagePage.manageShare()` 的分组分支保持同一处理。
                    showMessage('书单暂不支持分享，请选择书籍')
                    break
                  case 3:
                    this.delDialog?.open()
                    break;
                }
              })
          }
        }, (item: buttonList): string => 'bl' + item.id)

      }
      Divider().strokeWidth(0.5).color(ShelfColors.line()).padding({bottom:16})
      Column(){
        Text('取消')
          .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)')
          .fontSize(16)
          .fontWeight(400)
          .lineHeight(24)
          .textAlign(TextAlign.Center)
      }
      .onClick(()=>{
        this.cancel()
        this.controller?.close()
      })
      .alignItems(HorizontalAlign.Center)
      .padding({bottom:16})
      Flex()
        .bindContentCover($$this.isShowEditBook, this.showEditBook(), {
          modalTransition: ModalTransition.DEFAULT,
          onDisappear: () => {
            this.isShowEditBook = false;
          }
        })
    }
    // 四角都圆（原来只圆上面两个角、下面两个角贴底）⇒ 配合调用点的
    // `cornerRadius: 20` + `offset{dx:0,dy:-16}` 形成悬空四圆角矩形。
    // 依据见 `BookInfos.ets` / `MaterialColumnModifier` 的注释。
    .borderRadius(20)
    .attributeModifier(this.surface)
    .width('100%')
  }
  @State isShowEditBook:boolean = false
  @StorageLink('BOOK_IS_BOOK_WORKS_BOOK_LIST') isWorksBookListRefreshing: number = 0
  @Builder showEditBook(){
    Column(){
      newBookShelf({
        currentIndex:this.works.worksType,
        changeShowNumber:()=>{
          this.isShowEditBook = false
          setTimeout(()=>{
            this.isWorksBookListRefreshing++
          },100)
        },
        returnClose:true,
        workBookListStatus: 2,
        lastWorkBookList:this.works
      })
    }
    .backgroundColor(ShelfColors.pageBg())
  }

  //删除确认弹出框
  @State delCache:boolean = false
  delDialog: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      confirm: ()=> {
        if (this.works.worksId) {
          worksListsUtils.delWorksByIds(this.works.worksId);
          this.controller?.close()
          this.cancel()
        }
      },
      delCache:this.delCache
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })
}
