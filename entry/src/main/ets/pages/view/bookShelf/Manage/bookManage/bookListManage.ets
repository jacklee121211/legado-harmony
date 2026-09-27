import BookInfoManage from './BookInfoManage'
import BookInfoGridManage from './BookInfoGridManage'
import { Books } from '../../../../../database/entities/Books'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'

@Component
export default struct bookListManage{
  @Prop EXHIBIT:string
  @Prop bookList:Books[]
  @Prop isManage:boolean = true
  @Link checkGroup:Record<number, boolean>
  @State delCache:boolean = false
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  onSelect:Function = () => {}
  build() {
    if (this.bookList === null || this.bookList.length === 0) {
      Column() {
        Image($r('app.media.no_record')).width(200).height(200)
        Text('暂无浏览记录').fontSize(12).fontColor(ShelfColors.textSub()).fontWeight(500).padding(5)
      }
      .margin({ top: 120 })

    } else {
      Column(
        {space:10}
      ){
        if (this.EXHIBIT === '宫格') {
         GridRow({
           columns: 3
         }){
           ForEach(this.bookList, (item: Books,index:number) => {
             GridCol(){
               BookInfoGridManage({
                 bookData:item,
                 isManage:this.isManage,
                 checkGroup:this.checkGroup,
                 onSelect: ()=>{
                   this.onSelect()
                 }
               })
             }
           }, (item: Books): string => item.id !== undefined ? 'b' + item.id : (item.bookUrl ?? item.bookName))
         }
        } else {
          Column({
            space: 10
          }) {
            ForEach(this.bookList, (item: Books,index:number) => {
              BookInfoManage({
                bookData:item,
                isManage:this.isManage,
                checkGroup:this.checkGroup,
                onSelect: ()=>{
                  this.onSelect()
                }
              })
            }, (item: Books): string => item.id !== undefined ? 'b' + item.id : (item.bookUrl ?? item.bookName))
          }
        }
      }

    }
  }
}