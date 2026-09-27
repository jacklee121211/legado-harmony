import ReadShow from '../../componets/common/ReadShow'
import IndexShelf from './bookShelf/IndexShelf'

@Component
export default struct BookShelf {
  @State bookShelf: string = '书架'
  build(){
    Column(){
      IndexShelf()
    }
    .backgroundColor($r('app.color.page_bg'))
  }
}