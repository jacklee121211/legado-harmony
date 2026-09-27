import { Books } from '../../../../../database/entities/Books'
import { Haptics } from '../../../../../common/utils/Haptics';
import BooksDao from '../../../../../database/dao/BooksDao'
import BookInfoGrids from '../BookInfoGrids'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'

/**
 * 书架搜索浮窗（2026-09-22 新增）。
 *
 * ── 为什么要有它 ──────────────────────────────────────────────────────────
 * 用户报告：「书架顶部搜索是假的，进入之后是假的，直觉删除，保留搜索按钮，
 *            点击后直接出现浮窗搜索，可以搜索书名，支持拼音，首字母，汉字等多种搜索模式」。
 *
 * 原来的行为：书架右上角放大镜 → `AppRouter.push(RouteName.SEARCH)` →
 * `SearchBook.ets`。而那一页是**搜网络书源**的（`taskSearchBook` 在线搜索），
 * 对"找我自己书架上的书"来说确实是假的。
 *
 * 现行为：直接弹出本浮窗，在**本地库**里按书名/作者过滤。
 *
 * ── 搜索模式（用户已确认选 A：只做文字匹配）──────────────────────────────
 * 用户明确选择 **A：只做文字匹配**（汉字/字母 `includes`，大小写不敏感）。
 * 曾评估拼音/首字母方案，结论如下（**不要在无新证据时重开这个话题**）：
 *   · 参考项目 `catonlineSP2` 的 `utils/PinyinUtil.ets` 映射表**只有 153 条、
 *     几乎全是姓氏**（抽查章节常用字：第/章/话/一/二/三/上/下/天/地/人/神/战
 *     全部缺失，只有「龙」「王」等姓氏命中）⇒ 搬到章节/书名搜索上几乎全部落空。
 *   · 想免映射表用 `Intl.Collator('zh-Hans')` 推拼音也不可行 —— **SDK 里没有
 *     `Intl.Collator`**（只有 `Intl.Locale`，见 `@ohos.app.ability.Configuration.d.ts:197`、
 *     `@ohos.i18n.d.ts:264`）。
 *   ⇒ 拼音必须自建表或引三方库；用户已决定不做（A）。
 *
 * ── 数据源 ────────────────────────────────────────────────────────────────
 * 直接 `BooksDao.search({})` 查库，**不依赖书架的 `@ObjectLink` 数据流** ——
 * 这样它与书架的渲染管线解耦，改动不影响书架列表本身。
 *
 * ── 点击结果 ──────────────────────────────────────────────────────────────
 * 复用 `BookInfoGrids`：它内部已经 `AppRouter.push(RouteName.READER, …)`
 * ⇒ 点封面直接进阅读页，与书架上的行为一致，无需另写跳转。
 */
@CustomDialog
export struct ShelfSearchPanel {
  /** 由 `CustomDialogController` 注入（@CustomDialog 必需字段） */
  controller?: CustomDialogController
  /** 关闭浮窗（由父组件传入，把控制 `isShowShelfSearch` 的开关置 false） */
  onClose: () => void = () => {
  }

  @State keyword: string = ''
  @State results: Books[] = []
  /** 是否已完成首次加载（用于区分"还没搜"和"搜了但没结果"） */
  @State loaded: boolean = false

  aboutToAppear(): void {
    // 首次进入先展示全量（用户还没输入时也能看到书架内容，便于直接点）
    this.doSearch('')
  }

  /** 按关键词过滤：书名 或 作者，大小写不敏感 */
  async doSearch(kw: string): Promise<void> {
    const key = (kw ?? '').trim().toLowerCase()
    try {
      const all: Books[] = await BooksDao.search({})
      if (key === '') {
        this.results = all
      } else {
        this.results = all.filter((b: Books) => {
          const name = (b.bookName ?? '').toLowerCase()
          const author = (b.author ?? '').toLowerCase()
          return name.includes(key) || author.includes(key)
        })
      }
    } catch (e) {
      this.results = []
    }
    this.loaded = true
  }

  build() {
    Column() {
      // ── 搜索框 + 取消 ────────────────────────────────────────────────
      Row({ space: 8 }) {
        Search({ placeholder: '搜索书名或作者', value: this.keyword })
          .layoutWeight(1)
          .height(40)
          .onChange((v: string) => {
            this.keyword = v
            this.doSearch(v)
          })
        Text('取消')
          .fontSize(15)
          .fontColor('rgba(0, 125, 255, 1.00)')
          .onClick(() => {
            Haptics.tap();
            this.onClose()
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      // ── 结果 ────────────────────────────────────────────────────────
      if (this.results.length === 0) {
        Column() {
          Text(this.loaded ? '没有匹配的书籍' : '加载中…')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // ★ 一行三本（2026-09-22 用户要求）。
        //   用户原话：「这个新浮窗，最好按比例，**一行排三本书**，
        //             现在一排一本书，看起来很呆，**排列的顺序为默认顺序**」。
        //   ⇒ 用 `Grid` + `columnsTemplate('1fr 1fr 1fr')`（三等分），
        //     数据直接用 `BooksDao.search({})` 的返回顺序，**不再排序**。
        //   原实现是 `List` + `BookInfoGrids`（每项一整行 ⇒ 一行一本）。
        Grid() {
          ForEach(this.results, (item: Books) => {
            GridItem() {
              // onBookOpen：点书进阅读器前先关掉本浮窗（2026-09-24 需求第 4 项）——
              // 原来浮窗不随跳转关闭，从阅读器返回后它还挂在书架上面。
              BookInfoGrids({
                book: item,
                onBookOpen: () => {
                  this.onClose()
                }
              })
            }
          }, (item: Books): string => `${item.id ?? item.bookName}_${item.bookUrl ?? ''}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(12)
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    // 让出背景，由 CustomDialog 层承载沉浸光感材质（与长按弹窗/加入书单同款配方）
    .borderRadius(20)
    .attributeModifier(new MaterialColumnModifier(Color.White, true))
  }
}
