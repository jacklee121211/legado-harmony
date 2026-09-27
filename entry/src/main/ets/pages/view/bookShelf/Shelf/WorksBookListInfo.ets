/**
 * 书单信息
 */
import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { Haptics } from '../../../../common/utils/Haptics';
import { ThemeItem } from '../../../../common/model/Theme'
import BookOverlay from '../../../../componets/bookDetail/BookOverlay'
import { WorksLists } from '../../../../database/entities/WorksLists'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'


@Component
export default struct WorksBookListInfo{
  @Link checkGroup:Record<number, boolean>
  @Prop work:WorksLists
  @Prop isShowCheck:boolean
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
        Column(){
          BookOverlay({
            bookImage:this.work.worksCoverUrl,
            isTop:false,
            isShow:this.isShowCheck
          })
        }
        Column({
          space:24
        })
        {
          Text(this.work.worksName)
            .fontWeight(700)
          Column(){
            Text(`共${this.work.worksBookNum}本`).fontSize(12).fontColor(ShelfColors.textSub())
              .textOverflow({
                overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(400)
              .maxLines(1)
              .lineHeight(20)
            Text(this.work.worksDescribe)
              .fontSize(12).fontColor(ShelfColors.textSub())
              .fontSize(12)
              .fontWeight(400)
              .textOverflow({
                overflow:TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .maxLines(2)
              .lineHeight(20)
          }
          .width('60%')
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
      if (this.isShowCheck){
        Row() {
          Checkbox()
            .selectedColor(this.theme.mainColor)
            .select(this.work.worksId?this.checkGroup[this.work.worksId] ?? false:false)
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
        .padding({ left: 15, right: 15, bottom: 5, top: 5 })
      }

    }
    .padding(10)
    .borderRadius(10)
  }

}