/**
 * @author 2008
 * @datetime 2024/7/26 20:35
 * @className: catalogAddShelf
 * 加入书单弹窗
 */
import CommonConstants from '../../../../../common/constants/CommonConstants'
import { Haptics } from '../../../../../common/utils/Haptics';
import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { ThemeItem } from '../../../../../common/model/Theme'
import bookGroupUtil from '../../../../../common/utils/bookGroupUtils'
import worksListsUtils from '../../../../../common/utils/WorksListsUtils'
import { showMessage } from '../../../../../componets/common/promptShow'
import worksListsDao from '../../../../../database/dao/WorksListsDao'
import { WorksBookList } from '../../../../../database/entities/WorksBookList'
import { WorksLists } from '../../../../../database/entities/WorksLists'
import NewBookShelfDialog from '../../components/dialog/NewBookShelfDialog'
import ImmersiveMaterialUtil from '../../../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../../../common/utils/UiMotion'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'

@Component
export default struct catalogAddShelf{
  onClickShelf:Function = (_isCatalogAddShelf:boolean)=>{
  }
  @Prop ids:number[]
  @Prop bookOrFolder:number = 0
  @Prop currentIndex:number = 0
  @Prop showNumber:number = 0
  // （2026-10-01 已删 @State worksBook：编辑目标改由 openNewShelf(status, last) 传参，
  //  原字段在 bindContentCover 移除后已无引用。）

  @State worksLists:WorksLists[] =[]
  @State newBookIds:number[] = []
  /** App 级深浅色：订阅只为深浅切换时触发重绘（取色走资源 token / `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  getWorkLists() {
    worksListsDao.search({
      type:this.currentIndex
    }).then((val)=>{
      this.worksLists = val
    })
  }

  async aboutToAppear(): Promise<void> {
    if (this.bookOrFolder === 1){
      let bookId =  await bookGroupUtil.queryBookByGroupId(this.ids)
      if (bookId.length) {
        this.newBookIds = bookId
      }
    } else {
      this.newBookIds = this.ids
    }
    this.getWorkLists()
  }

  //校验书单中存放的书籍bookIds和newBookIds都存在就为true
  isExistBook(worksBookList: WorksBookList[]): boolean {
    if (!worksBookList || worksBookList.length === 0 || this.newBookIds.length === 0) {
      return false;
    }
    const bookIds = worksListsUtils.getBookIds(worksBookList);
    return this.newBookIds.every(item => bookIds.includes(item));
  }


  build() {
    Flex({
      justifyContent:FlexAlign.SpaceBetween,
      alignContent:FlexAlign.Center,
      direction:FlexDirection.Column
    }) {
      Column(){
        Column(){
          Text('加入书单').fontSize(16).fontWeight(700).lineHeight(24)
        }
        .padding({right:20,left:20,top:12,bottom:12})
        Divider().strokeWidth(0.5).color(ShelfColors.line())
        Flex(){
          this.ColumnTitle()
        }
        Scroll(){
          Column(){
            ForEach(this.worksLists,(item:WorksLists)=>{
              this.ColumnTitle(item)
            }, (item: WorksLists): string => item.worksId !== undefined ? 'w' + item.worksId : item.worksName)
          }
        }
        .align(Alignment.TopStart)
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      Column(){
        Divider().strokeWidth(0.5).color(ShelfColors.line())

        Text('取消')
          .onClick(() => {
            Haptics.tap();
            this.onClickShelf(false)
          })
          .margin({
            top:12,bottom:12
          })

      }
      .padding(20)
    }
    .width(CommonConstants.FULL_WIDTH)
    .height(CommonConstants.FULL_HEIGHT)
  }

  /**
   * 新建/编辑书单（2026-10-01 从 bindContentCover 改 CustomDialog，修"点击新建没用"）：
   * bindContentCover 是**页面级**模态，盖不过已打开的加入书单 CustomDialog
   * （长按书籍/长按分组入口）⇒ 用户实测无反应。CustomDialog 可叠加于弹窗之上，
   * 页面宿主（管理页）同样成立。控制器打开时新建（参数随选中项变化，
   * SDK NOTE：Custom dialog box parameters do not support dynamic updates）。
   */
  private newShelfDialog: CustomDialogController | null = null
  openNewShelf(status: number, last?: WorksLists): void {
    this.newShelfDialog = new CustomDialogController({
      builder: NewBookShelfDialog({
        currentIndex: this.currentIndex,
        workBookListStatus: status,
        lastWorkBookList: last ?? new WorksLists(),
        bookIds: this.newBookIds,
        changeShowNumber: (): void => {
          this.newShelfDialog = null
          setTimeout(() => {
            this.getWorkLists()
          }, 200)
        },
        submit: (): void => {
          this.newShelfDialog = null
          this.onClickShelf(false)
        },
        onClose: (): void => {
          this.newShelfDialog = null
        }
      }),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      width: '92%',
      height: '90%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.newShelfDialog = null
      }
    })
    this.newShelfDialog.open()
  }

  @Builder ColumnTitle(work?:WorksLists) {
    Column() {
      if (!work){
        Flex({
          justifyContent:FlexAlign.SpaceBetween,
          alignItems:ItemAlign.Center
        }){
          Row({
            space:12
          }){
            Image($r('app.media.add')).width(24).fillColor(this.theme.mainColor)
            Text('新建书单').fontSize(14).fontColor(this.theme.mainColor).fontWeight(400).lineHeight(22)
          }.onClick(()=>{
            Haptics.tap();
            this.openNewShelf(0)
          })
        }
      } else {
        Flex({
          justifyContent:FlexAlign.SpaceBetween,
          alignItems:ItemAlign.Center
        }){
          Row({
            space:12
          }){
            Image($r('app.media.shelf')).width(24).fillColor(ShelfColors.icon())
            Text(work.worksName)
              .fontSize(14)
              .fontWeight(400)
              .lineHeight(22)
              .textOverflow({
              overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .maxLines(1)
          }

          if (this.isExistBook(work.worksBookList ?? [])) {
            Text('已在书单').fontSize(12).fontWeight(400).lineHeight(20).fontColor($r('app.string.color_black_45'))
          } else {
            Image($r('app.media.ic_public_return_right')).width(24).height(24).fillColor(ShelfColors.icon())
          }
        }
        .onClick(() => {
          Haptics.tap();
          if (this.newBookIds.length === 0){
            showMessage('暂无相关内容可加入')
            return
          }
          if (!this.isExistBook(work.worksBookList ?? [])) {
            this.openNewShelf(2, work)
          }
        })
      }
    }
    .padding({
      left:20,
      right:20,
      top:12,
      bottom:12
    })
  }
}
