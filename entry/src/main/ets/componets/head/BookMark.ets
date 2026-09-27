import { ThemeStorageKey } from "../../common/constants/Theme"
import { Haptics } from '../../common/utils/Haptics';
import { ThemeItem } from "../../common/model/Theme"
import { NightMode } from "../../common/utils/NightMode"

@Component
export default struct BookMark {
  isBackground: boolean = true
  @Prop title:string
  @Prop currentIndex:number
  @Prop index:number

  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：只为触发重绘（取色走 `NightMode`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  /**
   * 未选中态的「小说 / 漫画 / 有声书」标签色。
   * 日间用的是主题的 `secondColor`（5 套浅色主题，见 `constants/Theme.ets:5-9`，
   * 如 `#ffece0`）—— 夜间压在深色书架上会变成一片亮色 ⇒ 夜里换成次级浅灰。
   */
  private idleColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.62)' : this.theme.secondColor
  }

  build() {
    Column() {
      if (this.isBackground) {
        Text(this.title)
          .fontColor(this.currentIndex === this.index ? this.theme.mainColor : this.idleColor())
          .fontSize(this.currentIndex === this.index ? 25 : 16)
          .fontWeight(this.currentIndex === this.index ? 700 : 500)
          .lineHeight(30)
          .zIndex(999)
          // .backgroundImage(this.currentIndex === this.index ? $r('app.media.underline') : '')
          // .backgroundImageSize(this.currentIndex === this.index ? { width: '100%', height: 15 } : {})
          // .backgroundImagePosition(Alignment.Center)
          .animation({
            duration: 200,
          })
      } else {
        Text(this.title)
          .fontColor(this.currentIndex === this.index
            ? (NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 1)' : 'rgba(0, 0, 0, 1.00)')
            : (NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.62)' : 'rgba(0,0,0,0.5)'))
          .fontSize(this.currentIndex === this.index ? 25 :  16)
          .fontWeight(this.currentIndex === this.index ? 700 : 500)
          .lineHeight(30).zIndex(999)
          .animation({
            duration: 200,
          })
      }
    }
    .margin(this.index !== 0 ? { left: 20 } : {
      left: 0,
      right: 0
    })
  }
}