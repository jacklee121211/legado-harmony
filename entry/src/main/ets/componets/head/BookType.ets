import { ThemeStorageKey } from "../../common/constants/Theme"
import { ThemeItem } from "../../common/model/Theme"
import { NightMode } from "../../common/utils/NightMode"

@Component
export default struct BookType {
  @Prop title:string
  @Prop bookType:string
  @Prop index:number
  @Prop bookTypeNumber:number = 0

  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：只为触发重绘（取色走 `NightMode`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  build() {
    Column() {
      Text(this.title)
        .fontColor(this.index === this.bookTypeNumber ? this.theme.mainColor
          : (NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.80)' : 'rgba(0,0,0,0.8)'))
        .fontSize(12)
        .fontWeight(this.index === this.bookTypeNumber ? 700 : 700)
    }
    .borderRadius(8)
    .padding(8)
    // 未选中：日间是浅灰实底 `rgb(240,240,240)`，夜间换成同层次的深灰块
    .backgroundColor(this.index === this.bookTypeNumber ? this.theme.secondColor
      : (NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.12)' : 'rgb(240,240,240)'))
  }
}