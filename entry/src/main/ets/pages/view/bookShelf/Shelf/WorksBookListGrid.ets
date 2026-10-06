import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { Haptics } from '../../../../common/utils/Haptics';
import { ThemeItem } from '../../../../common/model/Theme'
import { WorksLists } from '../../../../database/entities/WorksLists'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'
import UiMotion from '../../../../common/utils/UiMotion'
import { resolveCoverSource, coverCorners } from '../../../../common/utils/CoverSource'

@Component
export default struct WorksBookListGrid {

  @Prop work:WorksLists
  @Prop isShowCheck:boolean
  @Link checkGroup:Record<number, boolean>
  onSelect:Function = () => {}
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：只为触发重绘（取色走 ShelfColors） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  build() {
    Column() {
      Stack() {
        if (this.isShowCheck){
          Flex({
            alignItems: ItemAlign.End,
            justifyContent: FlexAlign.End
          }){
            Checkbox()
              .zIndex(2)
              .selectedColor(this.theme.mainColor)
              .unselectedColor(ShelfColors.checkboxIdle())
              .select(this.work.worksId?this.checkGroup[this.work.worksId] ?? false:false)
              .selectedColor(this.theme.mainColor)
              .onChange((val: boolean) => {
                Haptics.tap();
                if (this.work.worksId) {
                  this.checkGroup[this.work.worksId] = val
                }
              })
              .onClick(() => {
                Haptics.tap();
                this.onSelect()
              })
          }
          .zIndex(3)
          .backgroundColor('rgba(0,0,0,0.45)')
          .width(88).height(120)
        }
          Stack(){
            if (this.work.isTop){
              Text('置顶')
                .fontColor(Color.White)
                .fontWeight(300)
                .fontSize(8)
                .padding(3)
                .borderRadius(5)
                .backgroundColor('rgba(0, 0, 0, 0.45)')
                .zIndex(1)
            }
            // 2026-10-06：书单封面与书架/分组**同一解析契约**（`CoverSource.ets` 头注释；
            // 规范 `docs/标准-弹窗与按钮统一规范.md:200`）。此前直接 `Image(worksCoverUrl)`：
            //   · 新建书单会取首本书的封面（现按 customCoverUrl > coverUrl 存原样协议），
            //     其中 `default://cover_defaults/cN.svg` 是内置封面协议 ⇒ Image 认不出 ⇒
            //     落到 alt 默认图（"书单封面换不了/不同步"）；列表形态走 BookOverlay 是正常的
            //     （BookOverlay 自己解析）—— 两种形态必须一致。
            //   · 未设封面（空串）时与 BookOverlay/文件夹视图一致显示内置 c1。
            Image(resolveCoverSource(this.work.worksCoverUrl ?? '') ?? $rawfile('cover_defaults/c1.svg'))
              .draggable(false)
              .alt($r('app.media.icon_book_default_cover_one'))
              .borderRadius(coverCorners(88))
              .width(88)
              .height(120)
          }
          .zIndex(2)
          .alignContent(Alignment.BottomStart)
        // 2026-10-05：同款"书页叠层 + 底条"装饰统一受 UiMotion.SHELF_COVER_STACK 控制
        if (UiMotion.SHELF_COVER_STACK) {
          Row() {
            Image($r('app.media.occlusion1'))
              .draggable(false)
          }
          .zIndex(1)
          .width(95)
          .height(110)

          Row() {
            Image($r('app.media.occlusion2'))
              .draggable(false)
          }
          .zIndex(0)
          .width(100)
          .height(100)
        }
      }
      .align(Alignment.BottomStart)

      // 2026-10-05：色条**保留**（独立开关，见 UiMotion.SHELF_COVER_BASE_BAR 注释）；
      // 宽度与封面同宽（88）⇒ 修掉原来 100 宽导致的左右各 6vp 溢出。
      if (UiMotion.SHELF_COVER_BASE_BAR) {
        Row().width(88).height(20).backgroundColor(ShelfColors.skeleton()).borderRadius(10)
      }

      Text(this.work.worksName)
          .fontSize(15)
          .fontWeight(700)
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(2)
        Text(`共${this.work.worksBookNum}本`).fontSize(12).fontColor(ShelfColors.textSub())
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .fontWeight(500)
          .maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left:8,right:8,bottom:5,top:5 })
  }
}