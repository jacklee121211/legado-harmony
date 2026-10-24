import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { Haptics } from '../../../../../common/utils/Haptics';
import { ThemeItem } from '../../../../../common/model/Theme'
import BookOverlay from '../../../../../componets/bookDetail/BookOverlay'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
import { MANAGE_SEL_VERSION_KEY } from './ManageBrush'

/**
 * 文件夹列表_管理页
 */
@Component
export default struct BookFolderInfoManage {
  @Prop group:BookGroups
  @Link checkGroup:Record<number, boolean>
  @Prop isManage:boolean
  onSelect:Function = () => {}
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  // ── 勾选视觉与"整行可点"（2026-10-25 重做）────────────────────────────────
  // 与书籍列表 `BookInfoManage` 同一套（理由详见 `BookInfoGridManage` 注释）：
  //   Checkbox 只当显示件（触摸穿透），整行点击走 toggle()，外部批量改动靠
  //   `MANAGE_SEL_VERSION_KEY` 广播回读。
  @State checked: boolean = false
  @StorageProp(MANAGE_SEL_VERSION_KEY) @Watch('resyncChecked') selVersion: number = 0

  aboutToAppear(): void {
    this.resyncChecked()
  }

  private resyncChecked(): void {
    const id: number | undefined = this.group.groupId
    this.checked = id !== undefined && id !== null ? (this.checkGroup[id] ?? false) : false
  }

  private toggle(): void {
    if (!this.isManage) {
      return
    }
    Haptics.tap()
    this.checked = !this.checked
    const id: number | undefined = this.group.groupId
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
        BookOverlay({
          bookImage:this.group.coverUrl,
          isTop:this.group.isTop,
          coverType:this.group.coverType
        })
        Column({
          space:24
        })
        {
          Text(this.group.groupName)
            .fontWeight(700)
          Column(){
            Text(`共${this.group.bookIds?.length||0}本`).fontSize(12).fontColor(ShelfColors.textSub())
              .textOverflow({
                overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(400)
              .maxLines(1)
              .lineHeight(20)
            // Text(this.group.?this.folderList.newUpdateBook:'暂无更新')
            //   .fontSize(12)
            //   .fontWeight(400)
            //   .textOverflow({
            //     overflow:TextOverflow.Ellipsis
            //   })
            //   .ellipsisMode(EllipsisMode.END)
            //   .maxLines(1)
            //   .lineHeight(20)
          }
          .width('60%')
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
      if (this.isManage){
        Row() {
          Checkbox()
            //判断是否存在当前id
            // 只作显示件：勾选态由本组件 `@State checked` 决定
            .select(this.checked)
            .selectedColor(this.theme.mainColor)
            // 触摸穿透给整行 ⇒ 点圈与点封面同一条 toggle 路径
            .hitTestBehavior(HitTestMode.None)
        }
        .padding({ left: 15, right: 15, bottom: 5, top: 5 })
      }


    }
    .padding(10)
    .borderRadius(10)
    // 2026-10-25：整行可点（含封面 / 分组名 / 空白处）
    .onClick((): void => {
      this.toggle()
    })
  }


}