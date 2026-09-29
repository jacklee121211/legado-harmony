import { buttonList } from '../../../../../componets/dataList/buttonList'
import { Haptics } from '../../../../../common/utils/Haptics';
import { Books } from '../../../../../database/entities/Books'
import { router } from '@kit.ArkUI'
import AppRouter, { RouteName } from '../../../../../common/router/AppRouter'
import InsideCircleIcon from '../../../../../componets/common/InsideCircleIcon'
import { showMessage } from '../../../../../componets/common/promptShow'
import confirmDialogExample from '../../../../../componets/common/confirmDialog'
import booksUtil from '../../../../../common/utils/booksUtils'
import BookSelectGroupDialog from './BookSelectGroupDialog'
import ShelfAddToBookListDialog from './ShelfAddToBookListDialog'
import PaddingConstants from '../../../../../common/constants/PaddingConstants'
import CommonConstants from '../../../../../common/constants/CommonConstants'
import BasicDataSource from '../../../../../common/LazyIDataSource/BasicDataSource'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import { NightMode } from '../../../../../common/utils/NightMode'

@CustomDialog
/**
 * 书籍长按
 */
export default struct BookInfoDialogs{
  controller?: CustomDialogController
  //推送提醒
  @Prop bookData:Books
  @State pushReminder:boolean = false
  // ⚠️ 第 1 项（置顶）的 title 只是**兜底初值** —— build() 里会按 bookData.isTop 实时覆盖
  // （数组初始化器只在组件创建时执行一次，不能依赖它联动，依据见 build() 内注释）。
  @State buttonListInfo:buttonList[] = [
    new buttonList(1,this.bookData.isTop?'取消置顶':'置顶',$r('app.media.top')),
    new buttonList(2,'移动至',$r('app.media.folder')),
    new buttonList(3,'加入书单',$r('app.media.shelf')),
    new buttonList(4,'删除',$r('app.media.ic_public_delete'))
  ]
  @Consume('booksDataSource')  booksDataSource: BasicDataSource<Books>
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
      Row(){
        Row({
          space:CommonConstants.SPACE_12
        }){
          Image(this.bookData.coverUrl)
            .alt($r('app.media.icon_book_default_cover_one'))
            .width(45).height(65)
          Column({
            space:PaddingConstants.PADDING_20
          }){
            Text(this.bookData.bookName).fontSize(16).fontWeight(500).fontColor($r('app.string.color_black_88'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('75%')
            Text(this.bookData.author).fontSize(12).fontWeight(400).fontColor($r('app.string.color_black_45'))
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('80%')

        Row({
          space:8
        }){
          Text('书籍详情').fontSize(12).fontWeight(400).fontColor($r('app.string.color_black_45'))
          Image($r('app.media.icon_right')).width(20).height(20).fillColor($r('app.string.color_black_45'))
        } .onClick(()=>{
          Haptics.tap();
          // 迁 Navigation 第 2 期：详情页已改为 NavDestination，改走路由门面
          AppRouter.push(RouteName.BOOK_DETAIL, this.bookData)
          this.controller?.close()
        })
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .margin(20)
      Divider().strokeWidth(0.5).padding({bottom:16})
      GridRow({
        columns:4
      }){
        ForEach(this.buttonListInfo,(item:buttonList)=>{
          GridCol(){
            InsideCircleIcon({
              icon:item.icon,
              // ⚠️ 置顶键字样**渲染时实时**按 bookData.isTop 取（2026-09-29）：
              // buttonListInfo 数组初始化器只在弹窗组件创建时执行一次，bookData 若是
              // 旧对象就会永远显示"置顶"（审核反馈：置顶后重进弹窗不变成"取消置顶"）。
              title:item.id === 1 ? (this.bookData.isTop ? '取消置顶' : '置顶') : item.title
            })
              .onClick(()=>{
                Haptics.tap();
                this.bookInfoButton(item.id)
              })
          }
        })
      }
      Divider().strokeWidth(0.5).padding({bottom:16})
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
    builder: ShelfAddToBookListDialog({
      bookData: this.bookData,
      cancel: () => {
        this.catalogAddShelfDialog?.close()
      }
    }),
    cancel: this.exitApp,
    autoCancel: true,
    // 2026-09-25 用户反馈：加入书单弹窗改**标准居中四圆角材质**（原贴底老款式）
    alignment: DialogAlignment.Center,
    width: '80%',
    cornerRadius: 20,
    customStyle: false,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })

  bookInfoButton(id:number){
    switch (id){
      case 1 :
        this.isTopBook(); break;
      case 2 :
        this.bookMoveGroup?.open(); break;
      case 3 :
        this.catalogAddShelfDialog?.open();break;
      case 4 :
        this.bookDelDialog?.open(); break;
    }
  }

  @State delCache:boolean = false
  //弹窗
 bookDelDialog: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      confirm: ()=> { this.deleteGroup() },
      delCache:this.delCache
    }),
    cancel: this.exitApp,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

  deleteGroup() {
    this.deleteBook()
    this.cancel()
  }

  exitApp() {
    this.bookDelDialog?.close()
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
  //从booksDataSource数据中查询从第一位查询最先出现isTop为false下标返回
  getIndexByIsTopFalse() {
    const dataArray = this.booksDataSource.getOriginDataArray();
    const index = dataArray.findIndex(item => !item.isTop);
    return index;
  }

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
      oldGroupId:this.bookData.bookGroup,
      currentIndex:this.bookData.bookType,
      Ids:this.bookData.id
    }),
    height: 400,
    cancel: this.exitApp,
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
  })

  //刷新懒加载数据
  async refreshLazyData(){
    // this.booksDataSource.reloadNewData([this.bookData])
  }

}