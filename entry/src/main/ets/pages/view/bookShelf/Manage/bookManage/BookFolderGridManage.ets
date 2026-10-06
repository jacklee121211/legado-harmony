import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { Haptics } from '../../../../../common/utils/Haptics';
import { ThemeItem } from '../../../../../common/model/Theme'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
import UiMotion from '../../../../../common/utils/UiMotion'
import { resolveCoverSource, coverCorners } from '../../../../../common/utils/CoverSource'

/**
 * 文件夹宫格_管理页
 */
@Component
export default struct BookFolderGridManage {
  @Prop group:BookGroups
  @Link checkGroup:Record<number, boolean>
  @Prop isManage:boolean
  onSelect:Function = () => {}
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  build() {
    Column() {
      Stack() {
        Stack(){
          if (this.isManage){
            Checkbox()
              .zIndex(9)
              .select(this.group.groupId?this.checkGroup[this.group.groupId] ?? false:false)
              .selectedColor(this.theme.mainColor)
              .onChange((val: boolean) => {
                if (this.group.groupId) {
                  this.checkGroup[this.group.groupId] = val
                }
              })
              .onClick(()=>{
                Haptics.tap(); this.onSelect()
              })
          }
          Stack(){
            if (this.group.isTop){
              Text('置顶').fontColor(Color.White).fontWeight(300).fontSize(8).padding(3).borderRadius(5)
                .backgroundColor('rgba(0, 0, 0, 0.45)').zIndex(1)
            }
            // 2026-10-06：分组封面与书架文件夹视图**同一解析契约**（`CoverSource.ets` 头注释；
            // 规范 `docs/标准-弹窗与按钮统一规范.md:200`「任何显示端不得手写 substring，
            // 统一走 resolveCoverSource()」）。此前直接 `Image(this.group.coverUrl)` ⇒
            // 用户挑的内置封面存成 `default://cover_defaults/cN.svg`，Image 认不出这个协议
            // ⇒ 落到 alt 默认图（"书架的封面改变，管理中还是默认的封面"的分组版）；
            // 未设封面（undefined）时与书架一致显示内置 c1。
            Image(resolveCoverSource(this.group.coverUrl ?? '') ?? $rawfile('cover_defaults/c1.svg'))
              .draggable(false)
              .alt($r('app.media.icon_book_default_cover_one'))
              .borderRadius(coverCorners(88))
              .width(88)
              .height(120)
          }.alignContent(Alignment.BottomStart)
        }
        .alignContent(Alignment.BottomEnd)
        .zIndex(2)


        // 2026-10-05：同款"书页叠层 + 底条"装饰统一受 UiMotion.SHELF_COVER_STACK 控制
        if (UiMotion.SHELF_COVER_STACK) {
          Row() {
            Image($r('app.media.occlusion1')).draggable(false)
          }
          .zIndex(1).width(95).height(110)
          Row() {
            Image($r('app.media.occlusion2')).draggable(false)
          }
          .zIndex(0).width(100).height(100)
        }
      }
      .alignContent(Alignment.BottomStart)
      // 2026-10-05：色条**保留**（独立开关，见 UiMotion.SHELF_COVER_BASE_BAR 注释）；
      // 宽度与封面同宽（88）⇒ 修掉原来 100 宽导致的左右各 6vp 溢出。
      if (UiMotion.SHELF_COVER_BASE_BAR) {
        Row().width(88).height(20).backgroundColor(ShelfColors.skeleton()).borderRadius(10)
      }
      Text(this.group.groupName)
          .fontSize(15)
          .fontWeight(700)
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(2)
      Text(`共${this.group.bookIds?.length||0}本`).fontSize(12).fontColor(ShelfColors.textSub())
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .fontWeight(500)
          .maxLines(1)
    }
    .padding({ left:8,right:8,bottom:5,top:5 })
  }
}