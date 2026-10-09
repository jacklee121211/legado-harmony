/**
 * @author 2008
 * @datetime 2024/7/23 12:18
 * @className: BookContentRefresh
 */
import { showMessage } from '../../../../componets/common/promptShow'
import RefreshComponent from '../../../../componets/common/RefreshComponent'
import BookFolder from '../BookFolder'
import WorksBookLists from '../Shelf/WorksBookLists'
import BookContent from './BookContent'

@Component
export default struct BookContentRefresh {
  @State @Watch('changeRefreshing')isRefreshing: boolean = false
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') isGroupRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_WORKS_BOOK_LIST') isWorksBookListRefreshing: number = 0
  /** 「分组 / 全部 / 未分组 / 本地」那一栏的**实测高度**（`GroupType` 上报）——用于给列表让位 */
  @StorageLink('shelfGroupRowH') shelfGroupRowH: number = 0
  @State counter: number = 0
  @State RefreshingTitle: string = '松开刷新'
  @Prop currentIndex: number = 0
  @Link EXHIBIT: string
  @Link GROUP: string
  @Prop searchValue: string
  @Link bookTypeNumber:number
  @State checkGroup:Record<number, boolean> = {}
  changeRefreshing(){
    if (this.isRefreshing) {
      switch (this.bookTypeNumber){
        case 1:
          this.isGroupRefreshing++
          break;
        case 5:
          this.isWorksBookListRefreshing++
          break;
        default:
          this.isBookRefreshing++
          break
      }
    }
  }
  build() {
    Refresh({ refreshing: $$this.isRefreshing, builder: this.refreshComponent }) {
      if (this.bookTypeNumber !== 5 && this.bookTypeNumber !== 1){
        BookContent({
          currentIndex:this.currentIndex,
          bookTypeNumber:this.bookTypeNumber,
          EXHIBIT: this.EXHIBIT,
          searchValue: this.searchValue
        })
      } else {
        Scroll() {
          Column() {
            if (this.bookTypeNumber === 5) {
              WorksBookLists({
                checkGroup: this.checkGroup,
                EXHIBIT: this.EXHIBIT,
                currentIndex:this.currentIndex,
                isShowCheck:false
              })
            } else {
              BookFolder({
                EXHIBIT: this.EXHIBIT,
                currentIndex:this.currentIndex
              })
            }
          }
          .padding({ left: 10, right: 10, bottom: 30 })
        }
        .scrollBar(BarState.Off)
      }
    }
    .height('100%')
    // ── 给「分组 / 全部 / 未分组 / 本地」那一栏让位（2026-09-23）──────────────────
    // 原来这里是写死的 `30`；分组栏加了胶囊外观后实际更高 ⇒ 会压住第一行书。
    // 现在按 `GroupType` 用 onAreaChange **实测上报**的高度算：`实测高度 + 4`（4 = 视觉间隙）；
    // 拿不到实测值时回落旧的 30。**只在这一处让位**（`BookBodyContent` 里那份叠加已删除）。
    // （2026-09-29 摘除「浏览历史」后不再有 0 让位的分支 —— 见 BookBodyContent 同日注释。）
    // ★ 2026-10-11：groupTypeComponent 改文档流（不再浮在 Tabs 上），
    //   不再需要让位 —— top 固定 0（让 BookContentRefresh 内容紧贴 groupTypeComponent 之下）。
    .margin({
      top: 0
    })
    .onStateChange((refreshStatus: RefreshStatus) => {
      if (refreshStatus === 1 || refreshStatus === 2) {
        this.RefreshingTitle = '松开刷新'
      } else {
        this.RefreshingTitle = '刷新中...'
      }
    })
    .onRefreshing(() => {
      setTimeout(() => {
        this.counter++
        this.isRefreshing = false
      }, 1000)
      showMessage('刷新成功')
    })
  }
  @Builder
  refreshComponent() {
    RefreshComponent({
      RefreshingTitle: this.RefreshingTitle,
    })
  }
}