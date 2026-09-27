import FontConstants from '../../../../../common/constants/FontConstants'
import { Haptics } from '../../../../../common/utils/Haptics';
import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { ThemeItem } from '../../../../../common/model/Theme'
import { Books } from '../../../../../database/entities/Books'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'

@Component


export default struct BookInfoManage{
  @Prop isManage:boolean
  @Prop bookData:Books
  @Link checkGroup:Record<number, boolean>
  onSelect:Function = () => {}
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
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
            if (this.bookData.isTop){
              Text('置顶').fontColor(Color.White).fontWeight(FontConstants.FONT_WEIGHT_400).fontSize(9).padding(3).borderRadius(5)
                .backgroundColor('rgba(0, 0, 0, 0.45)').zIndex(1)
            }
            Image(this.bookData.coverUrl)
              .draggable(false)
              .alt($r('app.media.icon_book_default_cover_one'))
              .width(60)
              .height(80)
          }
          .alignContent(Alignment.BottomStart)
        }
        .alignContent(Alignment.TopEnd)

        Column({
          space:24
        })
        {
          Text(this.bookData.bookName)
            .fontWeight(700)
          Column(){
            Text(this.bookData.intro).fontSize(12).fontColor(ShelfColors.textSub())
              .textOverflow({
                overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(500)
              .maxLines(1)
            Text(this.bookData.durChapterTitle).fontSize(12).fontColor(ShelfColors.textSub())
              .textOverflow({
                overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(500)
              .maxLines(1)
          }
          .width('40%')
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
      if (this.isManage){
        Row() {
          Checkbox({
            name: JSON.stringify(this.bookData.id)
          })
            .onClick(()=>{
              Haptics.tap(); this.onSelect()
            })
            .select(this.bookData.id?this.checkGroup[this.bookData.id] ?? false:false)
            .onChange((val:boolean)=>{
              if (this.bookData.id) {
                this.checkGroup[this.bookData.id] = val
              }
            })
            .selectedColor(this.theme.mainColor)
            .unselectedColor(ShelfColors.checkboxIdle())
        }
        .padding({ left: 15, right: 15, bottom: 5, top: 5 })
      }
    }
    .padding(10)
    .borderRadius(10)
  }
}