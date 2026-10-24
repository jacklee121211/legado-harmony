import FontConstants from '../../../../../common/constants/FontConstants'
import { Haptics } from '../../../../../common/utils/Haptics';
import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { ThemeItem } from '../../../../../common/model/Theme'
import { Books } from '../../../../../database/entities/Books'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
import { resolveBookCover, coverCorners, stripBookExt } from '../../../../../common/utils/CoverSource'
import { MANAGE_SEL_VERSION_KEY } from './ManageBrush'

@Component


export default struct BookInfoManage{
  @Prop isManage:boolean
  @Prop bookData:Books
  @Link checkGroup:Record<number, boolean>
  onSelect:Function = () => {}
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /** 书架书名是否显示文件拓展名（我的-设置；与书架 `BookInfos`/`BookInfoGrids` 同键同源） */
  @StorageLink('setExtName') showFileExt: boolean = false

  // ── 勾选视觉与"整行可点"（2026-10-25 重做）────────────────────────────────
  // 与宫格 `BookInfoGridManage` 同一套做法（理由详见那边注释）：
  //   · `Checkbox` 退化成显示件（`hitTestBehavior(None)`，触摸穿透给整行）；
  //   · 整行点击走 `toggle()` ⇒ 点封面/书名/空白处都能选/取消；
  //   · 外部批量改动（全选 / 划选 / 刷新回填）靠 `MANAGE_SEL_VERSION_KEY` 广播回读。
  @State checked: boolean = false
  @StorageProp(MANAGE_SEL_VERSION_KEY) @Watch('resyncChecked') selVersion: number = 0

  aboutToAppear(): void {
    this.resyncChecked()
  }

  private resyncChecked(): void {
    const id: number | undefined = this.bookData.id
    this.checked = id !== undefined && id !== null ? (this.checkGroup[id] ?? false) : false
  }

  private toggle(): void {
    if (!this.isManage) {
      return
    }
    Haptics.tap()
    this.checked = !this.checked
    const id: number | undefined = this.bookData.id
    if (id !== undefined && id !== null) {
      this.checkGroup[id] = this.checked
    }
    this.onSelect()
  }

  build() {
    Flex(
      {
        alignItems:ItemAlign.Center,
        justifyContent:FlexAlign.SpaceBetween
      }
    ) {
      Row({
        space:20
      }){
        Stack(){
          if (this.bookData.isLocalBook){
            Text('本地')
              .fontColor('#FFEDD4')
              .fontWeight(FontConstants.FONT_WEIGHT_400)
              .fontSize(9)
              .padding(3)
              .backgroundColor('#523000')
              .zIndex(1)
              .borderRadius({
                topRight: 6,
                bottomLeft: 6,
              })
          }
          Stack(){
            if (this.bookData.isTop){
              Text('置顶').fontColor(Color.White).fontWeight(FontConstants.FONT_WEIGHT_400).fontSize(9).padding(3).borderRadius(5)
                .backgroundColor('rgba(0, 0, 0, 0.45)').zIndex(1)
            }
            // 2026-10-06：封面必须与书架**同源**（`CoverSource.ets` 头注释的契约：
            // customCoverUrl > coverUrl > alt）。此前这里只读 `coverUrl` ⇒ 书架换过封面
            // （写入 `Books.customCoverUrl`）后，管理页/批量管理页仍显示书源封面或默认封面
            // ——"书架的封面改变，但是在管理中还是默认的封面"（用户 2026-10-06 反馈）。
            // 圆角与书架列表项同曲率（`BookInfos.ets` 用 coverCorners(60)），否则自定义
            // 图片封面在这里是直角、在书架是书脊式圆角。
            // 2026-10-13：统一走 `resolveBookCover`（四层：自定义 > 自带 > 书源 > 默认），
            // 自带封面（导入时从 epub 等提取）在管理页同样生效。
            Image(resolveBookCover(this.bookData))
              .draggable(false)
              .alt($r('app.media.icon_book_default_cover_one'))
              .borderRadius(coverCorners(60))
              .width(60)
              .height(80)
          }
          .alignContent(Alignment.BottomStart)
        }
        .alignContent(Alignment.TopEnd)

        Column({
          space:24
        })
        {
          Text(stripBookExt(this.bookData.bookName, this.showFileExt))
            .fontWeight(700)
          Column(){
            Text(this.bookData.intro).fontSize(12).fontColor(ShelfColors.textSub())
              .textOverflow({
                overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(500)
              .maxLines(1)
            Text(this.bookData.durChapterTitle).fontSize(12).fontColor(ShelfColors.textSub())
              .textOverflow({
                overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(500)
              .maxLines(1)
          }
          .width('40%')
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
      if (this.isManage){
        Row() {
          Checkbox({
            name: JSON.stringify(this.bookData.id)
          })
            // 只作显示件：勾选态由本组件 `@State checked` 决定（见上方字段注释）
            .select(this.checked)
            .selectedColor(this.theme.mainColor)
            .unselectedColor(ShelfColors.checkboxIdle())
            // 触摸穿透给整行 ⇒ 点圈与点封面走同一条 toggle 路径，不会双翻转
            .hitTestBehavior(HitTestMode.None)
        }
        .padding({ left: 15, right: 15, bottom: 5, top: 5 })
      }
    }
    .padding(10)
    .borderRadius(10)
    // 2026-10-25：整行可点（含封面 / 书名 / 空白处），不再只有选择圈能点
    .onClick((): void => {
      this.toggle()
    })
  }
}