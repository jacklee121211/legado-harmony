import CommonConstants from '../../../../../common/constants/CommonConstants'
import { Haptics } from '../../../../../common/utils/Haptics';
import FontConstants from '../../../../../common/constants/FontConstants'
import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { ThemeItem } from '../../../../../common/model/Theme'
import { Books } from '../../../../../database/entities/Books'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
import { resolveBookCover, coverCorners, stripBookExt } from '../../../../../common/utils/CoverSource'
import { MANAGE_SEL_VERSION_KEY } from './ManageBrush'

@Component
/**
 * 书签_宫格
 */
export default struct BookInfoGridManage{

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

  // ══════════════════════════════════════════════════════════════════════════
  // 勾选视觉与"整卡可点"（2026-10-25 重做）
  // ══════════════════════════════════════════════════════════════════════════
  // 用户原话：「批量管理状态下，我们只能一个个点击书籍，并且**只能点击书籍的选择圈**，
  //   这个不对…整个书籍全能被点击选中或取消，不仅仅是选择圈。」
  //
  // ── 旧实现的两个毛病 ──────────────────────────────────────────────────────
  //   ① 只有 `Checkbox` 自身能点（`onClick` + `onChange` 都挂在它身上）⇒ 点封面没反应；
  //   ② 勾选视觉完全由 `Checkbox` 自己的内部状态维持 ⇒ 外部（全选 / 划选）改了
  //      `checkGroup` 也**不会**让某个格子变色。
  //
  // ── 现在的分工 ────────────────────────────────────────────────────────────
  //   · `Checkbox` 只当**显示件**：`.select(this.checked)` + `hitTestBehavior(None)`
  //     ⇒ 触摸穿透给整张卡片，不会与卡片点击打架（否则点圈会"翻转两次"）；
  //   · `@State checked` 是本格的**视觉真源**：点哪都走 `toggle()`，改它 + 写
  //     `checkGroup[id]` + 通知父级重算已选数量；
  //   · 外部批量改动（全选 / 划选 / 刷新后回填）通过 `MANAGE_SEL_VERSION_KEY`
  //     广播 + `@Watch` 回读 ⇒ 见 `ManageBrush.ets` 该键的说明。
  @State checked: boolean = false
  /** 外部批量改动版本号（全选 / 划选 / 刷新回填）⇒ 回读 checkGroup 对齐视觉 */
  @StorageProp(MANAGE_SEL_VERSION_KEY) @Watch('resyncChecked') selVersion: number = 0

  aboutToAppear(): void {
    this.resyncChecked()
  }

  /** 从 `checkGroup` 回读本格勾选态 */
  private resyncChecked(): void {
    const id: number | undefined = this.bookData.id
    this.checked = id !== undefined && id !== null ? (this.checkGroup[id] ?? false) : false
  }

  /** 整卡点击：切换勾选（用户要求"点整本书都能选/取消"） */
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
    Column({
      space:CommonConstants.SPACE_6
    }) {
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
          if (this.isManage){
            Checkbox({
              name: JSON.stringify(this.bookData.id),
              group: 'checkboxGroup'
            })
              // 只作显示件：勾选态由本组件 `@State checked` 决定（见上方说明）
              .select(this.checked)
              .selectedColor(this.theme.mainColor)
              .unselectedColor(ShelfColors.checkboxIdle())
              .zIndex(2)
              // 触摸穿透给整张卡片 ⇒ 点圈与点封面走同一条 toggle 路径，不会双翻转
              .hitTestBehavior(HitTestMode.None)
          }
          Stack(){
            if (this.bookData.isTop){
              Text('置顶').fontColor(Color.White).fontWeight(300).fontSize(8).padding(3).borderRadius(5)
                .backgroundColor('rgba(0, 0, 0, 0.45)').zIndex(1)
            }
            // 2026-10-06：同 BookInfoManage —— 封面与书架同源（customCoverUrl > coverUrl > alt），
            // 否则书架换过封面后管理页宫格仍显示默认封面（用户 2026-10-06 反馈）。
            // 圆角对齐书架宫格（`BookInfoGrids.ets` 用 coverCorners(100)）。
            Image(resolveBookCover(this.bookData))
              .draggable(false)
              .alt($r('app.media.icon_book_default_cover_one'))
              .borderRadius(coverCorners(100))
              .width(100)
              .height(120)
          }.alignContent(Alignment.BottomStart)
        }
        .alignContent(Alignment.BottomEnd)
        .backgroundColor($r('app.string.color_black_45'))
        .borderRadius(10)
      }
      .alignContent(Alignment.TopEnd)


      Text(stripBookExt(this.bookData.bookName, this.showFileExt))
        .fontSize(15)
        .fontWeight(700)
        .textOverflow({
          overflow:TextOverflow.Ellipsis
        })
        .ellipsisMode(EllipsisMode.END)
        .maxLines(2)

      Text(this.bookData.intro).fontSize(12).fontColor(ShelfColors.textSub())
        .textOverflow({
          overflow:TextOverflow.Ellipsis
        })
        .ellipsisMode(EllipsisMode.END)
        .fontWeight(500)
        .maxLines(1)
    }
    .padding({ left:8,right:8,bottom:5,top:5 })
    // 2026-10-25：整张卡片可点（含封面 / 书名 / 简介 / 空白处），不再只有选择圈能点
    .onClick((): void => {
      this.toggle()
    })
  }
}