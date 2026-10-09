import { ThemeStorageKey } from "../../common/constants/Theme"
// ⚠️ 2026-10-11 顺手清了未使用的 `Haptics` import（本文件从不调 `Haptics.tap()`，
//   震动在调用方 `IndexShelf` 的 onClick 里做）。纯清理，无行为变化。
import { ThemeItem } from "../../common/model/Theme"
import { NightMode, ShelfColors } from "../../common/utils/NightMode"

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
   * 未选中态的标签色。
   * 日间用的是主题的 `secondColor`（5 套浅色主题，见 `constants/Theme.ets:5-9`，
   * 如 `#ffece0`）—— 夜间压在深色书架上会变成一片亮色 ⇒ 夜里换成次级浅灰。
   *
   * ⚠️ 2026-10-11 起顶部只剩「书架」一个页签（漫画/有声书入口已删）
   * ⇒ 本方法实际已无调用点（唯一那个页签恒为选中态）；保留以备将来自定义排序/多页签。
   */
  private idleColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.62)' : this.theme.secondColor
  }

  build() {
    Column() {
      if (this.isBackground) {
        Text(this.title)
          // ── 选中态字色（2026-10-11 修）──────────────────────────────────────
          // 原来这里是 `this.theme.mainColor`。而本组件只被书架顶部用
          // （全工程 grep `BookMark(` 只有 `IndexShelf.ets:188` 一处），
          // 那里背景正是**同一个 mainColor 起点的主题渐变彩带**
          // ⇒ 字与底同色系，真机实测对比度 1.36:1（黄主题 1.02:1），几乎看不见。
          // 现改为「主文字色」（日间近黑 / 夜间近白）：压在彩带上 8.6:1。彩带本身不变，
          // 整行依旧随主题换色。取值与同排的搜索/⋯ 图标（`ShelfColors.icon()`）同一族。
          .fontColor(this.currentIndex === this.index ? ShelfColors.textMain() : this.idleColor())
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