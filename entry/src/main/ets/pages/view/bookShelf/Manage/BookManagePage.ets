import bookListManage from './bookManage/bookListManage';
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import { Haptics } from '../../../../common/utils/Haptics';
import {showMessage} from '../../../../componets/common/promptShow'
import confirmDialogExample from '../../../../componets/common/confirmDialog';
import BookFolderManages from './bookManage/BookFolderManages';
import hideDialogExample from '../../../../componets/common/hideDialog';
import booksDao from '../../../../database/dao/BooksDao';
import { Books } from '../../../../database/entities/Books';
import { buttonList } from '../../../../componets/dataList/buttonList';
import booksUtil from '../../../../common/utils/booksUtils';
import BookSelectGroupDialog from '../components/dialog/BookSelectGroupDialog';
import BookGroupsDao from '../../../../database/dao/BookGroupsDao';
import { BookGroups } from '../../../../database/entities/BookGroups';
import bookGroupUtil from '../../../../common/utils/bookGroupUtils';
import catalogAddShelf from './components/catalogAddShelf';
import Header from '../../../../componets/common/Header';
import WorksBookLists from '../Shelf/WorksBookLists';
import worksListsDao from '../../../../database/dao/WorksListsDao';
import { WorksLists } from '../../../../database/entities/WorksLists';
import worksListsUtils from '../../../../common/utils/WorksListsUtils';
import { ThemeItem } from '../../../../common/model/Theme';
import { ThemeStorageKey } from '../../../../common/constants/Theme';
import AppRouter, { BookManageRouteParam } from '../../../../common/router/AppRouter';
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode';

/**
 * 管理跳转页面
 *
 * 迁 Navigation 第 4 期：去掉 `@Entry` + 补 `export default`，
 * 参数由 `Index.appRoutes()` 经 `initParam` 注入（原来是 `router.getParams()`）。
 */
@Component
export default struct BookManagePage {
  /**
   * 由 `Index.appRoutes()` 注入；未注入时用零值占位
   * （原来这里会直接崩，因为 `router.getParams()` 返回 undefined 时取属性就抛了）。
   *
   * ⚠️ 字段名**不能**叫 `initParam` —— 编译器原文告警：
   *    「Methods, properties and accessors in structures decorated by '@Component'
   *      and '@ComponentV2' cannot have name as 'initParam'.」
   * 所以新建的页面一律用 `routeParam`。
   */
  routeParam: BookManageRouteParam = { currentIndex: 0, EXHIBIT: '', bookTypeNumber: 0 }
  @State currentIndex: number = 0
  @State EXHIBIT: string = ''
  @State bookTypeNumber:number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @State isAddShelfShow:boolean = false
  @State topTitle:string = '置顶'
  @State bookList:Books[] = []
  @State checkLists: Record<number, boolean> = {}
  @State checkListNumber:number[] = []
  @State bookGroups:BookGroups[] = [] // 分组
  @State worksLists:WorksLists[] =[] //书单
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') @Watch('getGroupList')BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级深浅色：订阅只为深浅切换时触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  //判断是否全部置顶或取消置顶
  selectIsAllTop(){
    let allTopNumber = 0
    if (this.checkListNumber.length <= 0){
      this.topTitle = '置顶'
      return
    }
    this.checkListNumber.forEach((index)=>{
      //从bookList更具id查询是否都isTop
      if (this.bookTypeNumber === 5){
        this.worksLists.filter((item)=>{
          if (item.isTop && Number(index) === item.worksId){
            allTopNumber++
          }
        })
      } else if (this.bookTypeNumber === 1){
        this.bookGroups.filter((item)=>{
          if (item.isTop && Number(index) === item.groupId && !item.isSystem){
            allTopNumber++
          }

        })
      } else {
        this.bookList.filter((item)=>{
          if (item.isTop && Number(index) === item.id){
            allTopNumber++
          }
        })
      }
   
    })
    if (allTopNumber === this.checkListNumber.length) {
      this.topTitle = '取消置顶'
    } else {
      this.topTitle = '置顶'
    }
  }
  //书单
  getWorkLists() {
    worksListsDao.search({
      type:this.currentIndex
    }).then((val)=>{
      this.worksLists = val
    })
  }
  //书籍
  getBookList(){
    // pageSize=0 ⇒ 全量（BooksDao.searchPage 约定）：管理页必须列出全部书籍，
    // 旧实现 (1,100) 在批量导入超过 100 本时只显示前 100 本。
    booksDao.searchPage({
      type:this.currentIndex,
      bookGroup:this.bookTypeNumber
    },1,0).then((val)=>{
      this.bookList = val
    })
  }
  //分组
  getGroupList(){
    BookGroupsDao.search({
      type:this.currentIndex
    }).then((val)=>{
      this.bookGroups = val
    })
  }
  /**
   * 注入路由参数（迁 Navigation 第 4 期）。
   *
   * 原来这三个值是在**字段初始化器**里 `(router.getParams() as routerParams).xxx` 取的。
   * 迁后参数改由 `Index.appRoutes()` 经 `initParam` 传入，而字段初始化器执行时
   * `routeParam` 已就绪，理论上也能直接读；这里放 `aboutToAppear` 是为了与其它
   * 已迁移页面（`BookDetailPage` / `ReaderPage3`）保持**同一种注入惯例**。
   */
  aboutToAppear(): void {
    this.currentIndex = this.routeParam.currentIndex
    this.EXHIBIT = this.routeParam.EXHIBIT
    this.bookTypeNumber = this.routeParam.bookTypeNumber
    this.pageInit()
  }

  //初始
  pageInit(): void {
    if (this.bookTypeNumber === 1) {
      this.getGroupList()
      this.isMoveStatus = 1
    } else if (this.bookTypeNumber === 5){
      this.getWorkLists()
      this.isMoveStatus = 2
    } else {
      this.getBookList()
      this.isMoveStatus = 0
    }
  }

  @State isCatalogAddShelf:boolean = false
  @State showNumber:number = 0
  @State bookOrFolder:number = 0
  build() {
    // ── 底部手势条沉浸（2026-09-25 修复「暗色模式下底部是个单独的黑色条」）──────────
    // 根因：内层 Column 用 `.margin({ bottom: bottomRectHeight })` **让出**了系统导航条
    //   那一条（真机实测 ≈27.85vp，见 `WindowAbility.ets:183`），让出之后**没有任何节点
    //   去画它** ⇒ 露出窗口自己的底色。窗口底色我们从未设置过：
    //   SDK 原文（`@ohos.window.d.ts:6411-6412`，`setWindowBackgroundColor`）
    //     「If this API is not called, the default background color of the window is
    //       **'#FFF0F0F0'** in light mode and **'#FF1A1A1A'** in dark mode.」
    //   ⇒ 日间 #F0F0F0 / 夜间 #1A1A1A。暗色下它紧贴在 `ShelfColors.card()`（#26262A）
    //     的底栏下面，就是用户看到的那条"独立黑条"。
    // 修法：外面再套一层 Column 铺满并刷**与底栏同色**（`ShelfColors.card()`），
    //   让底栏的底色**延伸到手势条区域**（这才是"沉浸"的语义），内层 Column 原样不动
    //   （margin / 渐变 / 圆角全部保留，视觉与改造前一致）。
    // 回退：删掉外层这一层（把内层 Column 提回 build 根），即回到改造前行为。
    Column(){
      Column(){
        Header({
          customLeftBuilder: () => {
            this.selectAll()
          },
          title:`已选${this.checkListNumber.length}项`,
          customRightBuilder: () => {
            this.complete()
          }
        })
        Column(){
          this.bookManage()
        }
        .layoutWeight(1)
        .backgroundColor(ShelfColors.pageBg())
        Flex()
          .bindSheet($$this.isCatalogAddShelf, this.dialogCatalogAddShelf(), {
            height:400,
            dragBar: true,
            showClose: false,
            onDisappear: () => {
              this.isCatalogAddShelf = false
            }
          })
      }
      .margin({
        bottom:this.bottomRectHeight
      })
      .linearGradient({
        direction: GradientDirection.Bottom, // 渐变方向
        // 暗色档走 ShelfColors 的深色渐变（对齐 MyCenter 顶部渐变的做法）
        colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0.0],
          [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]] // 数组末尾元素占比小于1时满足重复着色效果
      })
      .borderRadius({ bottomRight: 5, bottomLeft: 5 })
    }
    .width('100%')
    .height('100%')
    // 手势条那一带的填充色 = 紧挨着它的底栏底色 ⇒ 接缝消失（暗色下也不再露窗口的 #1A1A1A）
    .backgroundColor(ShelfColors.card())
  }
  //主要操作页面
  @Builder bookManage(){
    Flex({
      justifyContent:FlexAlign.SpaceBetween,
      alignContent:FlexAlign.Center,
      alignItems:ItemAlign.Center,
      direction:FlexDirection.Column,
      wrap:FlexWrap.NoWrap
    }) {
      Column(){
        Scroll(){
          if (this.bookTypeNumber === 5){
            WorksBookLists({
              worksLists:this.worksLists,
              checkGroup:this.checkLists,
              EXHIBIT:this.EXHIBIT,
              isShowCheck:true,
              onSelect:()=>{
                this.listenCheckList()
              }
            })
          } else {
            if (this.bookTypeNumber === 1){
              BookFolderManages({
                checkGroup:this.checkLists,
                EXHIBIT:this.EXHIBIT,
                bookGroups:this.bookGroups,
                onSelect:()=>{
                  this.listenCheckList()
                }
              })
            } else {
              bookListManage({
                checkGroup:this.checkLists,
                EXHIBIT:this.EXHIBIT,
                bookList:this.bookList,
                onSelect:()=>{
                  this.listenCheckList()
                }
              })
            }
          }
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      Column(){
        Divider().color(ShelfColors.line())
        if (this.bookTypeNumber === 5){
          this.footerDel()
        } else {
          this.footerTitle()
        }
      }.backgroundColor(ShelfColors.card())
    }
  }
  //书单弹窗
  @Builder dialogCatalogAddShelf(){
    Column(){
      catalogAddShelf({
        onClickShelf:(val:boolean)=>{
          this.isCatalogAddShelf = val
          this.refreshData()
        },
        currentIndex:this.currentIndex,
        ids:this.checkListNumber,
        bookOrFolder:this.bookOrFolder
      })
    }
  }
  @State allCheck:boolean = false
  @Builder
  selectAll() {
    Row({
      space:5
    }) {
      Checkbox()
        .select(this.allCheck)
        .selectedColor(this.theme.mainColor)
        .onClick(() => {
          Haptics.tap();
          if (this.verificationDate()) {
            return
          }
          this.allCheck = !this.allCheck
          this.dataMoveCheckList(this.allCheck)
          this.listenCheckList()
        })
      // Text(!this.allCheck?'全选':'取消全选')
    }

    .alignItems(VerticalAlign.Center)
  }
  //校验是否存页面数据内容
  verificationDate() {
    switch (this.bookTypeNumber){
      case 1:
        if (this.bookGroups.length === 0){
          showMessage('页面暂无操作数据')
          return true
        }
        break
      case 5:
        if (this.worksLists.length === 0){
          showMessage('页面暂无操作数据')
          return true
        }
        break
      default:
        if (this.bookList.length === 0){
          showMessage('页面暂无操作数据')
          return true
        }
        break
    }
    return false
  }


  //遍历列表数据
  dataMoveCheckList(value:boolean){

    this.checkLists = {};
    if (this.bookTypeNumber === 1){
      this.bookGroups.forEach((item)=>{
        item.groupId && !item.isSystem && item.show ?this.checkLists[item.groupId] = value:''
      })
    } else if (this.bookTypeNumber === 5){
      this.worksLists.forEach((item)=>{
        item.worksId?this.checkLists[item.worksId] = value:''
      })
    } else {
      this.bookList.forEach((item)=>{
        item.id?this.checkLists[item.id] = value:''
      })
    }
    if(!value){
      this.allCheck = false;
    }
  }


  @Builder
  complete() {
    Column() {
      Text('完成')
    }
    .onClick(async () => {
      Haptics.tap();
      // 迁 Navigation 第 4 期：本页现在是 NavDestination ⇒ 必须走门面返回。
      AppRouter.back()
      setTimeout(()=>{
        this.refreshData()
        this.isBookRefreshing++
      },100)
    })
  }
  //书单底部操作栏
  @Builder footerDel(){
    Column(){
      Text('删除').fontSize(16).fontWeight(500).lineHeight(24).fontColor('#EF4444')
    }.onClick(()=>{
      Haptics.tap();
      if (this.checkListNumber.length <= 0) {
        showMessage('请选择要操作的内容');
        return
      }
      this.delDialog?.open();
    })
    .alignItems(HorizontalAlign.Center)
    .padding(20)
  }
  @State buttonListInfo5:buttonList[] = [
    new buttonList(1,'置顶',$r('app.media.top')),
    new buttonList(2,'移动至',$r('app.media.folder')),
    new buttonList(3,'加入书单',$r('app.media.shelf')),
    new buttonList(4,'隐藏分组',$r('app.media.hide')),
    new buttonList(5,'删除',$r('app.media.ic_public_delete'))
  ]

  @State buttonListInfo4:buttonList[] = [
    new buttonList(1,'置顶',$r('app.media.top')),
    new buttonList(2,'移动至',$r('app.media.folder')),
    new buttonList(3,'加入书单',$r('app.media.shelf')),
    new buttonList(5,'删除',$r('app.media.ic_public_delete'))
  ]
  //底部操作栏
  @Builder footerTitle(){
      GridRow({
        columns:this.bookTypeNumber===1?5:4
      }){
        ForEach(this.bookTypeNumber===1?this.buttonListInfo5:this.buttonListInfo4,(item:buttonList)=>{
          GridCol(){
            if (item.id === 1) {
              Column({
                space:5
              }){
                Image(item.icon).width(25).fillColor(ShelfColors.icon())
                Text(this.topTitle).fontSize(14).fontWeight(500)
              }
              .onClick(()=>{
                Haptics.tap();
                this.bookInfoButton(item.id)
              })
            } else {
              Column({
                space:5
              }){
                Image(item.icon).width(25).fillColor(ShelfColors.icon())
                Text(item.title).fontSize(14).fontWeight(500)
              }
              .onClick(()=>{
                Haptics.tap();
                this.bookInfoButton(item.id)
              })
            }
          }
        })
      }
      .padding({
        top:10,
        bottom:10
      })
      .backgroundColor(ShelfColors.card())
    }
  //底部操作栏功能
  bookInfoButton(index:number){
    if (this.checkListNumber.length <= 0) {
      showMessage('请选择要操作的内容');
      return
    }
    this.dataCheckList()
    switch (index){
      case 1 :
       this.manageTop(); break;
      case 2 :
        this.bookMoveGroup?.open(); break;
      case 3 :
        this.isCatalogAddShelf = true
        if (this.bookTypeNumber === 1) {
          this.bookOrFolder = 1
        } else {
          this.bookOrFolder = 0
        }
        break;
      case 4 :
        this.clickHideDialog?.open()
        break
      case 5 :
        this.delDialog?.open(); break;
    }
  }
  //置顶功能
  manageTop(){
    if(this.bookTypeNumber === 1){
      bookGroupUtil.isTopGroup(this.checkListNumber, this.topTitle==='置顶'?true:false)
    } else {
      booksUtil.isTopBook(this.checkListNumber, this.topTitle==='置顶'?true:false)
    }
    setTimeout(()=>{
      this.refreshData()
      this.checkListNumber = []
      this.checkLists = {}
      this.topTitle = '置顶'
      showMessage('操作成功')
    },500)
  }
  //删除确认弹窗
  @State delCache:boolean = false
  delDialog: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      confirm: ()=> { this.manageDelete() },
      delCache:this.delCache
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    // 2026-09-25 用户反馈：删除确认弹窗材质与全局统一（原 options 漏了 systemMaterial）
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
  })
  //删除功能
  manageDelete(){
    this.checkListNumber.forEach((item:number)=>{
      switch (this.bookTypeNumber){
        case 1:
          bookGroupUtil.delGroupById(item); break;
        case 5:
          worksListsUtils.delWorksByIds(item);break;
        default:
          booksUtil.delBooksById(item);break;
      }
    })
    setTimeout(()=>{
      this.refreshData()
      showMessage('已删除')
    },500)
    this.delDialog?.close()
  }
  //是否隐藏分组弹窗
  clickHideDialog: CustomDialogController | null = new CustomDialogController({
    builder: hideDialogExample({
      confirm: ()=> { this.clickHideAccept() }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })
  //隐藏操作
  clickHideAccept() {
   bookGroupUtil.updateGroupShow(this.checkListNumber)
    setTimeout(()=>{
      this.refreshData()
      showMessage('已隐藏')
    },500)
  }

  //操作状态
  @State isMoveStatus:number = 0
  //移动分组弹窗
  bookMoveGroup: CustomDialogController | null = new CustomDialogController({
    builder: BookSelectGroupDialog({
      moveGroup: ()=> {
        setTimeout(()=>{
          this.refreshData()
        },500)
        this.bookMoveGroup?.close()
      },
      oldGroupId:this.bookTypeNumber,
      currentIndex:this.currentIndex,
      Ids:this.checkListNumber,
      isMoveStatus:this.isMoveStatus
    }),
    height: 400,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

  //刷新数据方法
  refreshData(){
   switch (this.bookTypeNumber){
     case 1:
       this.getGroupList();
       this.BOOK_IS_BOOK_GROUPS_REFRESHING++
       break;
     case 5:
       this.getWorkLists();
       break;
       default:
         this.getBookList();
         // this.isBookRefreshing++
         break;
   }
   this.dataMoveCheckList(false)
   this.dataCheckList()
  }

  //将checkLists取key值转换为string[]
  dataCheckList(){
    const keys = Object.keys(this.checkLists)
      .filter(key => this.checkLists[Number(key)])
      .map(key => Number(key));
    this.checkListNumber = keys
  }
  //判断checkLists变化值当key的值为false移除当前值
  listenCheckList() {
    this.dataCheckList()
    this.selectIsAllTop()
    this.allCheck = this.checkListNumber.length !== 0
  }
}