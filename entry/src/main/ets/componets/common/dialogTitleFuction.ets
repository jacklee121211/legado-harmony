/**
 * @author 2008
 * @datetime 2024/6/28 22:24
 * @className: dialogTitleFuction
 */
import CommonConstants from '../../common/constants/CommonConstants'
import FontConstants from '../../common/constants/FontConstants'
import ImageConstants from '../../common/constants/ImageConstants'
import PaddingConstants from '../../common/constants/PaddingConstants'
import TextConstants from '../../common/constants/TextConstants'

@Component
export default struct dialogTitleFuction{
  isBorder: boolean = true
  @Prop title:string
  @Prop icon:Resource
  /**
   * 是否按**夜间浮层**上色。
   *
   * ⚠️ 为什么用 `@Prop` 而不是直接读 `NightMode.isDarkSurface()`：
   *   本组件被两处复用 —— 书架右上「⋯」菜单（`IndexShelf.MenuBuilder`，夜间是**深色**面板）
   *   和 `Header` 的菜单（用在搜索/管理页，那两页**不做**深色适配，永远是浅色）。
   *   若无条件读全局夜间开关，搜索/管理页的菜单文字也会变白 ⇒ 白字压白底。
   *   ⇒ 由**调用方**声明自己那层是不是深色；`Header` 侧不传 ⇒ 默认 false ⇒ 与改造前一致。
   */
  @Prop nightStyle: boolean = false
  build() {
    Column() {
      Row({
        space:8
      }){
        if (this.icon) {
          Image(this.icon)
            .width(ImageConstants.IMG_WIDTH_20)
            .height(ImageConstants.IMG_HEIGHT_20)
            .fillColor(this.nightStyle ? 'rgba(248, 249, 250, 0.88)' : '#000000')
        }

        Text(this.title)
          .font({
            size:FontConstants.FONT_SIZE_14,
            weight:FontConstants.FONT_WEIGHT_400,
            family:CommonConstants.FAMILY_PingFANG
          })
          .fontColor(this.nightStyle ? 'rgba(248, 249, 250, 0.88)' : $r('app.string.color_black_88'))
          .lineHeight(TextConstants.TEXT_LINE_HEIGHT_22)
      }
      .border({
        style: BorderStyle.Solid,
        width: { bottom: this.isBorder ? 1 : 0 },
        color: this.nightStyle ? 'rgba(248, 249, 250, 0.14)' : '#f5f5f5'
      })
      .padding({
        top:PaddingConstants.PADDING_12,
        bottom:PaddingConstants.PADDING_12})
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .padding({
      left:PaddingConstants.PADDING_20,
      right:PaddingConstants.PADDING_20,})
  }
}