import CommonConstants from '../../common/constants/CommonConstants'
import { Haptics } from '../../common/utils/Haptics';
import FontConstants from '../../common/constants/FontConstants'
import PaddingConstants from '../../common/constants/PaddingConstants'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
import { BOOK_SEARCH_TYPE } from '../../database/entities/Books'
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
    if (BOOK_SEARCH_TYPE.includes(this.title)){
      Row(
        {
          space:3
        }
      ) {
        Text(this.title)
          .fontColor(this.chipFg())
          .fontSize(15)
          .fontWeight(this.searchValue === this.title ? 600 : 400)
        Image(this.isShown?$r('app.media.direction_upper'):$r('app.media.direction_down'))
          .width(15).height(15)
          .opacity(this.title === this.searchValue?1:0.3)
      }
      .onClick(()=>{
        Haptics.tap();
        this.searchValue = this.title
        this.isShown = !this.isShown
      })
      .bindPopup(this.isShown,{
        builder: this.MenuBuilder(),
        placement: Placement.Bottom,
        enableArrow:true,
        radius:12,
        onStateChange: (e) => {
          if (!e.isVisible) {
            this.isShown = false;
          }
        }
      })
      // .bindMenu(this.isShown, this.MenuBuilder,
      //   {
      //     onDisappear: ()=>{
      //       this.isShown = false;
      //     }
      //   })
    } else {
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

  @Builder MenuBuilder() {
    Column(){
      ForEach(BOOK_SEARCH_TYPE, (item:string, index) => {
        Column() {
          Row() {
            Text(item)
              .font({
                size: FontConstants.FONT_SIZE_14,
                weight: FontConstants.FONT_WEIGHT_400,
                family: CommonConstants.FAMILY_PingFANG
              })
              .fontColor(this.searchValue === item ? this.theme.mainColor
                : (NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : $r('app.string.color_black_88')))
            Image(item ===  this.searchValue?$r('app.media.hook'):'').width(20).height(20)
          }
          .padding({
            top: PaddingConstants.PADDING_12,
            bottom: PaddingConstants.PADDING_12,
            left:PaddingConstants.PADDING_20,
            right:PaddingConstants.PADDING_20
          })
          .width('100%')
          .height(40)
          .justifyContent(FlexAlign.SpaceBetween)
          .align(Alignment.Center)
          .onClick(() => {
            Haptics.tap();
            this.title = item
            this.searchValue = item
            this.isShown = false
          })
          if (index != BOOK_SEARCH_TYPE.length - 1) {
            Divider().height(10).width('80%').color(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.22)' : '#ccc')
          }
        }
      })
    }
    .padding(PaddingConstants.PADDING_4)
    .width(150)
  }
}