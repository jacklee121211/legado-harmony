// 2026-10-13 清理：排序下拉弹窗删除后，本组件只剩一个 Text，
// 下面四个 import（CommonConstants / Haptics / FontConstants / PaddingConstants）
// 全部不再使用，一并删除。
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
// （2026-10-13 删除未使用的 `BOOK_SEARCH_TYPE` import —— 该常量本身也已删除，
//   排序下拉弹窗 2026-10-01 就废了，见本文件 build() 里的原文。）
import { NightMode } from '../../common/utils/NightMode'

@Component
export default struct IndexSearchType {
  @Prop title:string
  @Link searchValue:string
  @State isShown: boolean = false
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：只为触发重绘（取色走 NightMode），理由见 IndexShelf 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  /** 顶部筛选文字：选中 = 主文字色，未选中 = 次级 */
  private chipFg(): string {
    return this.searchValue === this.title
      ? (NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 1)' : 'rgba(0, 0, 0, 1.00)')
      : (NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.62)' : 'rgba(0,0,0,0.5)');
  }

  build() {
    // 2026-10-01（用户）：「最近阅读」的排序弹窗（更新排序/手动排序）功能已废，
    // 直接删除——标题恢复为纯文字（无下拉箭头、无点击、无 popup）。
    Row(
      {
        space:3
      }
    ) {
      Text(this.title)
        .fontColor(this.chipFg())
        .fontSize(15)
        .fontWeight(this.searchValue === this.title ? 600 : 400)
    }
  }
}