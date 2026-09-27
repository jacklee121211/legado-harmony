/**
 * 上次阅读弹窗
 */
import booksUtil from '../../common/utils/booksUtils'
import bookHistoryDao from '../../database/dao/BookHistoryDao'
import { BookHistory } from '../../database/entities/BookHistory'
import { Books } from '../../database/entities/Books'
import { router } from '@kit.ArkUI'
import AppRouter, { RouteName } from '../../common/router/AppRouter'
import clickUtil from '../../common/utils/ClickUtils'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'

@Component
export default struct ReadShow {
  @Link showReadShow:boolean
  @State bookHistory:BookHistory[] = []
  @State book:Books = new Books()

  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  aboutToAppear(): void {
    this.getBookHistoryList()
  }
  async getBookHistoryList(){
   this.bookHistory =  await bookHistoryDao.searchLimit()
    if (this.bookHistory.length >= 1 && this.bookHistory[0].id) {
      let bookInfo = await booksUtil.getBookByIds(this.bookHistory[0].id)
      if (bookInfo && bookInfo[0]) {
        this.book = bookInfo[0]
      }
    }
  }
  build() {
    if (this.bookHistory[0] && this.book){
      Column(){
        Flex(
          {
            alignItems:ItemAlign.Center,
            alignContent:FlexAlign.SpaceBetween
          }
        ) {
          Image(this.bookHistory[0].coverUrl??'')
            .draggable(false)
            .alt($r('app.media.icon_book_default_cover_one')).width(40).height(52)
          Column({
            space:24
          })
          {
            Text(this.bookHistory[0].bookName)
              .fontSize(12)
              .fontColor(Color.White)
            Column(){
              Text(this.bookHistory[0].durChapterTitle).fontSize(12).fontColor(Color.White)
                .textOverflow({
                  overflow:TextOverflow.Ellipsis
                })
                .ellipsisMode(EllipsisMode.END)
                .fontWeight(500)
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .padding({left:15})
          Column(){
            Text('继续阅读')
              .fontSize(12)
              .fontWeight(600)
              .padding(10)
              .borderRadius(20)
              .fontColor(this.theme.mainColor)
              .backgroundColor(Color.White)
          }
          .padding({left:55,right:30})
          .onClick(()=>{
            clickUtil.preventClick(()=>{
              // 迁 Navigation 第 2 期：详情页已改为 NavDestination，改走路由门面
              AppRouter.push(RouteName.BOOK_DETAIL, this.book)
            })
          })

          Image($r("app.media.outlined")).width(15).height(15)
            .onClick(() => {
              this.showReadShow = !this.showReadShow
              console.log(this.showReadShow + '')
            })
        }
        .borderRadius(10)
      }
      .alignItems(HorizontalAlign.Start)
      .borderRadius(10)
      .padding(10)
      .width('95%')
      .backgroundColor('rgb(182,134,102)')
      // 入场 / 退场过渡（2026-09-21）。原来这张"上次阅读"卡片是**硬出现、硬消失**的
      // （`Index.ets` 里 `if (this.showReadShow)` 直接挂载/卸载）。
      // 官方 `transition` 的正确用法是进入与退出分别声明、各自带 `.animation()`，
      // 本工程 `readStatistics.ets` / `readStatisticsDataList.ets` 已有同款可用的先例写法。
      // 这里：进场 = 淡入 + 自下方 12vp 上浮（300ms EaseOut）；退场 = 淡出 + 下移 8vp（220ms EaseIn）。
      // 纯增量的 `.transition()` 属性，不动任何布局/状态 ⇒ 零回归风险；
      // 不想要这个动效时删掉这一整段即可。
      .transition(
        TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: 12 }).animation({ duration: 300, curve: Curve.EaseOut })),
          TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseIn })
            .combine(TransitionEffect.translate({ y: 8 }).animation({ duration: 220, curve: Curve.EaseIn }))
        )
      )
    }
  }
}