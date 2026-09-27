import bookHistoryDao from '../../../../database/dao/BookHistoryDao'
import { BookHistory } from '../../../../database/entities/BookHistory'
import BookHistoryInfo from './BookHistoryInfo'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'

@Component
export default struct BookHistoryContent {
  @State bookHistory:BookHistory[] = []
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  /** App 级夜间开关：只为触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @Prop searchValue:string
  @Prop @Watch('changeBookType')currentIndex: number
  //更新数据累加刷新数据页面
  @StorageLink('BOOK_IS_BOOK_HISTORY_REFRESHING') @Watch('getBookHistoryList') isBookHistoryRefreshing: number = 0
  aboutToAppear(): void {
    this.getBookHistoryList()
  }
  changeBookType(){
    this.getBookHistoryList()
    this.isBookHistoryRefreshing++
  }
  getBookHistoryList(){
    bookHistoryDao.search({
      type:this.currentIndex,
      sort:0
    }).then((val)=>{
      this.bookHistory = val
    })
  }

  build() {
    if (this.bookHistory.length === 0){
      Column() {
        Image($r('app.media.no_record')).width(200).height(200)
        Text('暂无浏览记录')
          .fontSize(12)
          .fontColor(ShelfColors.textSub())
          .fontWeight(500)
          .padding(5)
      }
      .margin({ top: 120 })
    } else {
      Column(
        {space:10}
      ){
        Column(
          { space: 10 }
        ) {
          ForEach(this.bookHistory, (item: BookHistory) => {
            BookHistoryInfo({
              bookHistory:item
            })
          }, (item: BookHistory): string => item.id !== undefined ? 'h' + item.id : item.bookUrl)
        }
        .backgroundColor(ShelfColors.card())
      }
    }
  }
}