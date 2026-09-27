/**
 * @author 2008
 * @datetime 2024/5/23 22:21
 * @className: shareShelfBook
 */
import InsideCircleIcon from '../../../componets/common/InsideCircleIcon'
import { Haptics } from '../../../common/utils/Haptics';
import { buttonList } from '../../../componets/dataList/buttonList'
import componentSnapshot from '@ohos.arkui.componentSnapshot'
import image from '@ohos.multimedia.image'
import fs from '@ohos.file.fs';
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { showMessage } from '../../../componets/common/promptShow'
import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { hostContext } from '../../../common/utils/HostContextUtil'
import { BusinessError } from '@kit.BasicServicesKit'
import { WorksLists } from '../../../database/entities/WorksLists'
import worksListsUtils from '../../../common/utils/WorksListsUtils'
import BooksDao from '../../../database/dao/BooksDao'
import { Books } from '../../../database/entities/Books'
import PaddingConstants from '../../../common/constants/PaddingConstants'

/**
 * ── T30（本次对话 · 用户决策 D-1 选项 A）：保存图片改用官方安全控件 `SaveButton` ──────────
 * **默认 `false` = 旧行为**（运行时申请 `ohos.permission.WRITE_IMAGEVIDEO`）。回退 = 改这一行。
 *
 * 为什么换 —— 官方依据（原文）：
 *  · FAQ `FAQ/本地数据和文件/媒体文件管理_Media_Library/如何通过安全控件_弹窗授权实现媒体资源保存/faqs-media-library-28`：
 *    「`ohos.permission.WRITE_IMAGEVIDEO` 是**受限开放**的权限，在不满足权限申请条件的情况下，
 *      应用可以通过**安全控件或授权弹窗**的方式，将指定的媒体资源保存到相册中。」
 *  · 文档 `API参考/ArkUI_方舟UI框架/ArkTS组件/安全/SaveButton/ts-security-components-savebutton`：
 *    「用户首次使用该控件时会展示弹窗，在点击允许后**自动授权**，应用会获取访问媒体库接口的**临时授权**。
 *      后续使用无需弹窗授权。」授权时长：**API 20 及以上为 1 分钟**（本项目 API 26）。
 *    「开发者应在**授权有效期内**调用媒体库接口获取文件句柄，并完成创建媒体资源等需要临时授权的操作。」
 *  · SDK `…\ets\component\save_button.d.ts`：`SaveIconStyle{FULL_FILLED=0, LINES=1}`、
 *    `SaveDescription{DOWNLOAD=0, DOWNLOAD_FILE=1, SAVE=2, SAVE_IMAGE=3, SAVE_FILE=4}`、
 *    `SaveButtonOnClickResult{SUCCESS=0, TEMPORARY_AUTHORIZATION_FAILED=1}`。
 *  · SDK `…\ets\component\security_component.d.ts`：安全控件**不支持通用属性/通用事件**，
 *    只继承 `iconSize/fontSize/fontColor/iconColor/size/borderRadius/...` 这一套；
 *    属性设错会导致**授权失败**（错误码 2 列出 10 种情形，含"字体或图标设置过小""与背景颜色相近"
 *    "按钮被其他组件或窗口遮挡""按钮整体尺寸过大"等）⇒ **本实现刻意只设 iconSize/fontSize，保持官方默认外观**。
 *
 * ⚠️ 已知代价：那一格的**外观会变成系统安全控件的样子**（无法做成现在那个自定义圆形图标），
 *    这是走官方路线的固有约束，不是实现缺陷。上机对比后再决定是否长期保留。
 */
const SAVE_IMAGE_USE_SAVEBUTTON: boolean = false;

@CustomDialog
@Preview
@Component
export default struct shareWorksBook {
  controller?: CustomDialogController
  @Prop works:WorksLists
  @State buttonListInfo: buttonList[] = [
    new buttonList(1, '微信', $r('app.media.wechat')),
    new buttonList(2, 'QQ', $r('app.media.QQ_blue')),
    new buttonList(3, '朋友圈', $r('app.media.circle_friends')),
    new buttonList(4, 'QQ空间', $r('app.media.QQ_space')),
    new buttonList(5, '导出本地', $r('app.media.export')),
    new buttonList(6, '复制链接', $r('app.media.copy_link')),
    new buttonList(7, '保存图片', $r('app.media.save_img')),
    new buttonList(8, '系统分享', $r('app.media.more'))
  ]
  @State bookList:Books[] = []

  async aboutToAppear(): Promise<void> {
    if (this.works.worksBookList) {
      let bookIds = worksListsUtils.getBookIds(this.works.worksBookList)
      if (bookIds.length > 0) {
        this.getBookIds(bookIds)
      }
    }
  }
  // T13/D-17：字段初始化阶段组件尚未构造完，拿不到 UIContext ⇒ 传 undefined 走旧路径（行为不变）
  private appContext: common.Context = hostContext(undefined, this) as common.Context;
  private atManager = abilityAccessCtrl.createAtManager();
  getBookIds(ids:number[]){
    BooksDao.getBookByIds(ids).then((val)=>{
      this.bookList = val
    })
  }

  build() {
    Stack() {
      Rect()
        .height('100%')
        .width('100%')
        .backgroundColor(Color.Black)
        .onClick(() => {
          Haptics.tap(); this.controller?.close()
        })
        .opacity(0.15)
        .zIndex(1)
      Flex({
        direction:FlexDirection.Column,
        justifyContent:FlexAlign.SpaceBetween
      }){
        Column({
          space:PaddingConstants.PADDING_10
        }){
          Text(this.works.worksName)
            .textAlign(TextAlign.Center)
            .fontSize(16).fontWeight(500).lineHeight(24).fontColor($r('app.string.color_black_88'))
          Text(this.works.worksDescribe)
            .textAlign(TextAlign.Center)
            .fontSize(12).fontWeight(400).lineHeight(20).fontColor($r('app.string.color_black_88'))
          Column({
            space:PaddingConstants.PADDING_15
          }){
            ForEach(this.bookList,(item:Books,index)=>{
              this.BookShelfInfo(item,index)
            }, (item: Books): string => item.id !== undefined ? 'b' + item.id : (item.bookUrl ?? item.bookName))
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
      .margin(40)
      .padding({ top: 24, left: 20, right: 20, bottom: 24 })
      .backgroundColor(Color.White)
      .zIndex(2)
      //用于图片保存不做显示
      Column(){
        Column({
          space:10
        }){
          Text(this.works.worksName)
            .textAlign(TextAlign.Center)
            .fontSize(16)
            .fontWeight(500)
            .lineHeight(24)
            .fontColor($r('app.string.color_black_88'))
          Text(this.works.worksDescribe)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontWeight(400)
            .lineHeight(20)
            .fontColor($r('app.string.color_black_88'))

          Column({
            space:PaddingConstants.PADDING_15
          }){
            ForEach(this.bookList.slice(0, 4),(item:Books,index)=>{
              this.BookShelfInfo(item,index)
            })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 24, left: 20, right: 20, bottom: 24 })
        .backgroundColor('#FFF7EC')
        this.footerSaveImage()
      }
      .id('shareBook')
      .margin(40)
      .position({y: 0})
      .visibility(Visibility.Hidden)

      Column() {
        Column() {
          Row().width(36).height(4).backgroundColor($r('app.string.color_black_15')).borderRadius(12)
        }
        .padding({ top: 12, bottom: 28 })

        Flex({
          direction: FlexDirection.Row, wrap: FlexWrap.Wrap,
          justifyContent: FlexAlign.Start
        }) {

        }
        GridRow({
          columns:4
        }){
          ForEach(this.buttonListInfo, (item: buttonList) => {
            GridCol(){
              if (SAVE_IMAGE_USE_SAVEBUTTON && item.id === 7) {
                // T30（D-1 选项 A）：系统安全控件 —— 点击允许后自动获得媒体库临时授权（API 26 ⇒ 1 分钟），
                // 无需申请 WRITE_IMAGEVIDEO。刻意只设 iconSize/fontSize，保持官方默认外观以规避规范校验失败。
                SaveButton({
                  icon: SaveIconStyle.FULL_FILLED,
                  text: SaveDescription.SAVE_IMAGE,
                  buttonType: ButtonType.Capsule
                })
                  .iconSize(20)
                  .fontSize(12)
                  .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
                    if (result === SaveButtonOnClickResult.SUCCESS) {
                      this.captureAndSaveToAlbum('保存失败');
                    } else {
                      // TEMPORARY_AUTHORIZATION_FAILED：本次未授权，不应继续调用媒体库接口
                      showMessage('保存失败：未获得媒体库授权');
                    }
                  })
              } else {
                InsideCircleIcon({
                  icon: item.icon,
                  title:item.title
                }).onClick(() => {
                  switch (item.id) {
                    case 1:
                      showMessage('跳转微信');
                      break;
                    case 2:
                      showMessage('跳转QQ');
                      break;
                    case 3:
                      showMessage('跳转朋友圈');
                      break;
                    case 4:
                      showMessage('跳转QQ空间');
                      break;
                    case 5:
                      showMessage('导出本地成功');
                      break;
                    case 6:
                      showMessage('已复制链接');
                      break;
                    case 7:
                      this.requestPermissionSaveImage();
                      break;
                    case 8:
                      showMessage('系统分享');
                      break;
                  }
                })
              }
            }
          }, (item: buttonList): string => 'bl' + item.id)
        }

        Column() {
          this.footerTitle()
        }
        .borderRadius(8)
        .margin({ left: 20, right: 20, bottom: 20 })
        .backgroundColor($r('app.color.share_shelf_book_background'))
      }
      .zIndex(3)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor(Color.White)
    }
    .align(Alignment.Bottom)
  }
  @State pixmap: image.PixelMap | undefined = undefined

  // ── T30（D-1 选项 A）：截图 + 编码 + 写入相册 —— **两条路径共用这一段** ──────────────
  // 共用的理由：`componentSnapshot.get` 与 `imagePacker.packing` 都已废弃（`@deprecated`），
  //   **复制一份会让这两条告警各多一遍**（实测：告警 272 → 276）；共用则只保留一份。
  // 授权来源由调用方负责：旧路径 = 运行时申请 `WRITE_IMAGEVIDEO`；新路径 = `SaveButton` 的临时授权。
  // 官方原文（SaveButton）：「开发者应在**授权有效期内**调用媒体库接口获取文件句柄，并完成创建媒体资源等
  //   需要临时授权的操作。授权到期后，已通过授权获取的文件句柄仍可继续进行读写操作，不受授权时间限制。」
  //   授权窗口 API 20 及以上为 **1 分钟**（本项目 API 26）⇒ `createAsset` 必须落在窗口内。
  // T13/D-17：`createAsset` 位于 `packing(...).then(async …)` **异步回调**内 —— 官方 SDK 明确
  //   「used in an asynchronous callback … the context … may fail to be traced. In this case, `undefined` is returned.」
  //   ⇒ 用 `hostContext(this.getUIContext())`，不要用全局 `getContext()`。
  // ⚠️ 编译器仍会对 `createAsset` 报 `To use this API, you need to apply for the permissions:
  //   ohos.permission.WRITE_IMAGEVIDEO` —— 那是**静态判断**；新路径下运行时由安全控件的临时授权满足它
  //   （官方 FAQ `faqs-media-library-28`：该权限受限开放，不满足申请条件时可用安全控件取得临时授权）。
  //   这条告警**无法通过改代码消除**，属预期。
  private captureAndSaveToAlbum(onFailText: string): void {
    componentSnapshot.get('shareBook').then((pixmap: image.PixelMap) => {
      this.pixmap = pixmap
      const imagePackerApi = image.createImagePacker();
      let packOpts : image.PackingOption = { format:"image/jpeg", quality:98 };
      imagePackerApi.packing(pixmap, packOpts).then(async (data : ArrayBuffer) => {
        let ctx = hostContext(this.getUIContext());
        let helper = photoAccessHelper.getPhotoAccessHelper(ctx);
        let uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
        let file = await fs.open(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        await fs.write(file.fd, data);
        await fs.close(file.fd);
        showMessage('保存成功');
      }).catch((error : BusinessError) => {
        showMessage(onFailText);
        console.error('Failed to pack the image. And the error is: ' + error);
      })
    }).catch((error : BusinessError) => {
      // T30 顺带修复：原来 `componentSnapshot.get(...)` **没有 catch**，截图失败会静默无声。
      showMessage(onFailText);
      console.error('Failed to capture the share image. And the error is: ' + error);
    })
  }

  //申请权限,保存图片（**旧路径**，开关关闭时走这里 = 默认行为）
  async requestPermissionSaveImage() {
    try {
      this.atManager.requestPermissionsFromUser(this.appContext,['ohos.permission.WRITE_IMAGEVIDEO']).then(async ()=>{
        this.captureAndSaveToAlbum('保存失败,未获取权限')
      })
    } catch (e) {
      showMessage('保存失败,未获取权限');
    }
  }

  @State validDate:string = '7天有效'
  @State footerDialogShow:boolean = false
  @Builder footerTitle(){
    Flex({
      direction:FlexDirection.Row,
      justifyContent:FlexAlign.SpaceBetween
    }){
      Text('链接有效期').fontColor($r('app.string.color_black_88')).fontSize(12).fontWeight(400).lineHeight(20).textAlign(TextAlign.Center)
      Row({
        space:8
      }){
        Text(this.validDate).fontColor($r('app.string.color_black_45')).fontSize(12).fontWeight(400)
        Image($r('app.media.icon_right')).width(24).height(24).fillColor(($r('app.string.color_black_45')))
      }
    }
    .onClick(()=>{
      Haptics.tap(); this.footerDialogShow = true
    })
    .bindSheet($$this.footerDialogShow,this.footerDialog(), {
      height:200,
      showClose: false,
      blurStyle:BlurStyle.COMPONENT_ULTRA_THIN,
      maskColor: 'rgba(0,0,0,0.6)',
      onDisappear:()=>{
        this.footerDialogShow = false
      }
    })
    .padding(16)
  }

  @Builder footerSaveImage(){
    Flex({
      justifyContent:FlexAlign.SpaceBetween,
      direction:FlexDirection.Row,
      alignItems:ItemAlign.Center
    }
    ){
      Column(){
        Row({
          space:5
        }){
          Image($r('app.media.legado_icon')).width(32).height(20)
          Image($r('app.media.legado')).width(65).height(15)
        }
        Text('扫描二维码下载 开源阅读').fontSize(10).fontWeight(400).lineHeight(18).textAlign(TextAlign.Center)
      }
      Image($r('app.media.QR_Code')).width(46).height(46)
    }
    .backgroundColor(Color.White)
    .padding({ top: 24,bottom:24, left: 20, right: 20 })
  }


  @Builder footerDialog(){
    Column(){
      Text('链接有效日期')
        .fontColor($r('app.string.color_black_88'))
        .textAlign(TextAlign.Center)
        .padding({top:12,bottom:12})
        .lineHeight(24)
        .fontWeight(500)
    }
    Column(){
      Flex({
        justifyContent:FlexAlign.SpaceBetween,
        alignItems:ItemAlign.Center
      }
      ){
        Text('7天')
          .fontColor($r('app.string.color_black_88'))
          .textAlign(TextAlign.Center)
          .padding({top:12,bottom:12})
          .lineHeight(24)
          .fontWeight(500)

        Image(this.validDate === '7天有效'?$r('app.media.hook'):'').width(24).height(24)
      }
      .onClick(()=>{
        this.validDate = '7天有效'
        this.footerDialogShow = false
        showMessage('修改成功')
      })
      Flex({
        justifyContent:FlexAlign.SpaceBetween,
        alignItems:ItemAlign.Center
      }
      ){
        Text('永久有效')
          .fontColor($r('app.string.color_black_88'))
          .textAlign(TextAlign.Center)
          .padding({top:12,bottom:12})
          .lineHeight(24)
          .fontWeight(500)
        Image(this.validDate === '永久有效'?$r('app.media.hook'):'').width(24).height(24)
      }
      .onClick(()=>{
        this.validDate = '永久有效'
        this.footerDialogShow = false
        showMessage('修改成功')
      })
    }.padding({left:20,right:20})

    Column(){
      Text('取消').fontSize($r('app.string.color_black_88')).textAlign(TextAlign.Center).fontSize(16).fontWeight(400).lineHeight(24)
    }.padding({left:32,right:32,top:16,bottom:16})
    .onClick(()=>{
      Haptics.tap(); this.footerDialogShow = false
    })

  }

  @Builder BookShelfInfo(book:Books,index:number){
    Column(){
      Row({
        space:PaddingConstants.PADDING_10
      }){
        Image(book.coverUrl)
          .draggable(false)
          .alt($r('app.media.icon_book_default_cover_one'))
          .width(69)
          .height(92)

        Column({
          space:10
        }) {
          Text(book.bookName).fontSize(16).fontWeight(500).lineHeight(24)
            .textOverflow({
              overflow:TextOverflow.Ellipsis
            })
            .ellipsisMode(EllipsisMode.END)
            .maxLines(2)
            .position({y: 0})
          Text(book.intro)
            .fontSize(12)
            .lineHeight(20)
            .fontColor('rgba(0, 0, 0, 0.45)')
            .textOverflow({
              overflow:TextOverflow.Ellipsis
            })
            .height(50)
            .ellipsisMode(EllipsisMode.END)
            .maxLines(2)
          Row(){
            Text('卖报小郎君·').fontSize(10).fontWeight(400).fontColor($r('app.string.color_black_45'))
            Text('玄幻·').fontSize(10).fontWeight(400).fontColor($r('app.string.color_black_45'))
            Text('完本·').fontSize(10).fontWeight(400).fontColor($r('app.string.color_black_45'))
            Text('380万字').fontSize(10).fontWeight(400).fontColor($r('app.string.color_black_45'))
          }
        }
      }

      if (this.works.worksBookList && this.works.worksBookList[index].recommend){
        Column(){
          Text(this.works.worksBookList[index].recommend ?? '')
            .padding({
              top:PaddingConstants.PADDING_8,
              bottom:PaddingConstants.PADDING_8,
              left:PaddingConstants.PADDING_12,
              right:PaddingConstants.PADDING_12
            })
        }
        .borderRadius(8)
        .margin({
          top:PaddingConstants.PADDING_16
        })
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .backgroundColor($r('app.string.color_black_4'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
