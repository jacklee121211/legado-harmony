/**
 * 「我的」页 · 阅读榜卡（卡2，2026-10-13 新建）。
 *
 * ── 口径 ────────────────────────────────────────────────────────────────
 * 排名 = **该时段内的阅读时长**降序（`readDaily` 的 `SUM(seconds)` 按 `bookId` 分组）。
 * 时段有 5 档：本日 / 本月 / 本年 / 自定义时段 / 全部时段（用户 2026-10-13 要求）。
 * 右上角那个 `全部时段 ▾` 就是 5 项菜单入口（`bindMenu`，与书架右上 ⋯ 同一交互）。
 *
 * ── 三条必须遵守的显示契约 ─────────────────────────────────────────────────
 * ① **书名走 `bookNameDisplay()`**：与书架/听书迷你栏同一个「显示文件拓展名」开关，
 *    开关一变本卡立即跟着变（`@StorageLink('setExtName')` 驱动重绘）。
 *    ⚠️ 老统计页 `readStatisticsDataList.ets:79` 是直接 `Text(book.bookName)` ⇒
 *       那一页永远带 `.txt`，与书架不一致（本次一并修）。
 * ② **封面走 `resolveBookCover(book)`**（四层优先级 custom > builtin > coverUrl > alt），
 *    并且每次 `load()` 都**重新从库里取 Books 行**，绝不缓存 `ResourceStr` ——
 *    缓存就是"换封面必须重启才生效"的老坑（`BookContent.ets:256`）。
 * ③ 改名/换封面/删书都会自增 `BOOK_IS_BOOK_REFRESHING` ⇒ 本卡重查（`@Watch`）。
 *    因为 `readDaily` **只存 bookId 不存书名**，标题永远取最新值，不会被旧名字粘住。
 */
import CommonConstants from '../../common/constants/CommonConstants'
import MySetConstants from '../../common/constants/MySetConstants'
import { NightMode, ShelfColors } from '../../common/utils/NightMode'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
import { Haptics } from '../../common/utils/Haptics'
import UiMotion from '../../common/utils/UiMotion'
import ReadPeriodPicker from '../../common/utils/ReadPeriodPicker'
import readDailyDao, { ReadBucketRow, ReadPeriod } from '../../database/dao/ReadDailyDao'
import BooksDao from '../../database/dao/BooksDao'
import { Books } from '../../database/entities/Books'
import { resolveBookCover, bookNameDisplay } from '../../common/utils/CoverSource'
import {
  READ_MODE_DAY, READ_MODE_MONTH, READ_MODE_YEAR, READ_MODE_ALL, READ_MODE_CUSTOM,
  modeName, fmtDuration, fmtShort, periodOf, rangeBounded
} from '../../common/utils/ReadStatsFmt'

/** 榜单一行（渲染用；`book` 留着给"点书进阅读"用） */
interface RankRow {
  book: Books
  /** 已按「显示文件拓展名」开关处理过的书名 */
  name: string
  /** 读到百分比 0~100 */
  progress: number
  seconds: number
  cover: ResourceStr
}

@Component
export struct ReadRankCard {
  /** 点「查看详细数据」/底部累计行 → 进详情页 */
  onOpenDetail: (mode: string, anchor: number) => void = (_m: string, _a: number): void => {
  }
  /** 点某一本书 → 打开阅读页 */
  onOpenBook: (book: Books) => void = (_b: Books): void => {
  }

  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /** 「显示文件拓展名」开关（与书架同键同源，值一变本卡书名立即重算） */
  @StorageLink(MySetConstants.SET_EXT_NAME) @Watch('onExtChanged') showExt: boolean = false
  /** 书架公共刷新信号（阅读器退出 / 改名 / 换封面 / 删书都会自增） */
  @StorageLink(CommonConstants.BOOK_IS_BOOK_REFRESHING) @Watch('onDataTick') dataTick: number = 0
  /** 「我的」页心跳：eadStatistics 删完记录返回时自增（本页原来那三格就是靠它刷新） */
  @StorageLink('myCenterTick') @Watch('onDataTick') centerTick: number = 0

  /** 当前时段档：day / month / year / custom / all */
  @State filter: string = READ_MODE_ALL
  @State anchor: number = Date.now()
  /** 自定义区间（'YYYY-MM-DD'） */
  @State rangeFrom: string = ''
  @State rangeTo: string = ''
  @State rows: RankRow[] = []
  @State totalSec: number = 0
  @State totalDays: number = 0
  @State streak: number = 0

  aboutToAppear(): void {
    this.load()
  }

  onDataTick(): void {
    this.load()
  }

  onExtChanged(): void {
    // 开关只影响"显示名"，但重算要走同一套 load()（保证与封面/进度同一份数据）
    this.load()
  }

  private brand(): string {
    const c: string = this.theme.mainColor ?? ''
    return c.length > 0 ? c : '#FF6600'
  }

  /** 当前时段 → DAO 的周期描述 */
  private currentPeriod(): ReadPeriod {
    if (this.filter === READ_MODE_CUSTOM && this.rangeFrom.length >= 10 && this.rangeTo.length >= 10) {
      return rangeBounded(this.rangeFrom, this.rangeTo)
    }
    if (this.filter === READ_MODE_CUSTOM) {
      // 还没选过区间 ⇒ 先按"全部"兜底，避免空查询
      return periodOf(READ_MODE_ALL, this.anchor)
    }
    return periodOf(this.filter, this.anchor)
  }

  private async load(): Promise<void> {
    try {
      const p: ReadPeriod = this.currentPeriod()
      const top: ReadBucketRow[] = await readDailyDao.topBooks(p, 4)
      const totals = await readDailyDao.totals(p)
      this.totalSec = totals.seconds
      this.totalDays = totals.days
      this.streak = await readDailyDao.streakDays()

      // 每次都从库里取最新 Books 行（封面/书名/进度都要最新 → 不缓存）
      const all: Books[] = await BooksDao.search({})
      const byId: Map<number, Books> = new Map<number, Books>()
      for (let i = 0; i < all.length; i++) {
        const b: Books = all[i]
        byId.set(b.id ?? 0, b)
      }
      const disp = bookNameDisplay(this.showExt)
      const out: RankRow[] = []
      for (let i = 0; i < top.length; i++) {
        const row: ReadBucketRow = top[i]
        const id: number = parseInt(row.bucket)
        const book: Books | undefined = byId.get(id)
        if (book === undefined) {
          continue // 书已被删 ⇒ readDaily 里的孤儿行不显示
        }
        const total: number = book.totalChapterNum ?? 0
        const cur: number = book.durChapterIndex ?? 0
        const pct: number = total > 0 ? Math.max(0, Math.min(100, Math.round((cur + 1) / total * 100))) : 0
        const item: RankRow = {
          book: book,
          name: disp.display(book.bookName ?? ''),
          progress: pct,
          seconds: row.seconds ?? 0,
          cover: resolveBookCover(book)
        }
        out.push(item)
      }
      this.rows = out
    } catch (e) {
      console.error('ReadRankCard.load, Error, ' + JSON.stringify(e))
    }
  }

  /** 菜单选中一档 */
  private pickFilter(mode: string): void {
    Haptics.tap()
    if (mode === READ_MODE_CUSTOM) {
      ReadPeriodPicker.openRange(this.brand(), this.rangeFrom, this.rangeTo,
        (from: string, to: string): void => {
          this.rangeFrom = from
          this.rangeTo = to
          this.filter = READ_MODE_CUSTOM
          this.load()
        })
      return
    }
    this.filter = mode
    // 日/月/年 一律取"当前"周期，具体某一天去详情页翻
    this.anchor = Date.now()
    this.load()
  }

  /** 右上角筛选文案 */
  private filterLabel(): string {
    if (this.filter === READ_MODE_CUSTOM) {
      if (this.rangeFrom.length >= 10 && this.rangeTo.length >= 10) {
        return `${this.rangeFrom.substring(5)} ~ ${this.rangeTo.substring(5)}`
      }
      return modeName(READ_MODE_CUSTOM)
    }
    return modeName(this.filter)
  }

  /** 5 项菜单（官方 `bindMenu` 的数组形态；与书架右上 ⋯ 同款） */
  private menuItems(): MenuElement[] {
    const items: MenuElement[] = []
    const defs: string[] = [READ_MODE_DAY, READ_MODE_MONTH, READ_MODE_YEAR, READ_MODE_CUSTOM, READ_MODE_ALL]
    for (let i = 0; i < defs.length; i++) {
      const m: string = defs[i]
      const e: MenuElement = {
        value: modeName(m),
        action: (): void => {
          this.pickFilter(m)
        }
      }
      items.push(e)
    }
    return items
  }

  @Builder
  head() {
    Row() {
      Text('阅读榜')
        .fontSize(14).fontWeight(600).fontColor(ShelfColors.textMain())
      Blank()
      Row({ space: 4 }) {
        Text(this.filterLabel())
          .fontSize(12).fontColor(ShelfColors.textSub())
        SymbolGlyph($r('sys.symbol.chevron_down'))
          // ★ 2026-10-25 官方 UX 自检 2.1.4.3.2「界面图标大小」修复：10 → **16vp**。
          //   判定依据是**实际绘制尺寸**：chevron 墨迹宽 ≈ 0.52 × fontSize
          //   （手机 API26 实测 12→6.3vp；平板 API24 实测 12→6.2vp）
          //   ⇒ 12vp 仍 < 8vp「必须」下限；16vp ⇒ ≈8.3vp 两台设备同时达标。
          .fontSize(16)
          .fontColor([ShelfColors.textSub()])
      }
      .bindMenu(this.menuItems())
    }
    .width('100%')
    .height(20)
  }

  @Builder
  rankRow(row: RankRow, idx: number) {
    Row({ space: 10 }) {
      Text(`${idx + 1}`)
        .fontSize(15).fontWeight(700)
        .fontColor(idx < 3 ? this.brand() : ShelfColors.textSub())
        .width(14)
        .textAlign(TextAlign.Center)
      Image(row.cover)
        .alt($r('app.media.icon_book_default_cover_one'))
        .width(22).height(29)
        .borderRadius(4)
        .shadow({ radius: 6, color: 'rgba(0, 0, 0, 0.16)', offsetX: 0, offsetY: 2 })
      Column({ space: 2 }) {
        Text(row.name)
          .fontSize(13).fontWeight(500)
          .fontColor(ShelfColors.textMain())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`读到 ${row.progress}%`)
          .fontSize(10)
          .fontColor(ShelfColors.textSub())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(fmtShort(row.seconds))
        .fontSize(13).fontWeight(600)
        .fontColor(ShelfColors.textMain())
    }
    .width('100%')
    .margin({ top: 12 })
    .onClick(() => {
      Haptics.tap()
      this.onOpenBook(row.book)
    })
    .clickEffect(UiMotion.CLICK)
  }

  build() {
    Column() {
      this.head()

      if (this.rows.length === 0) {
        Text(this.filter === READ_MODE_ALL ? '还没有阅读记录' : `${this.filterLabel()}没有阅读记录`)
          .fontSize(12)
          .fontColor(ShelfColors.textSub())
          .width('100%')
          .margin({ top: 16 })
      } else {
        ForEach(this.rows, (row: RankRow, idx: number) => {
          this.rankRow(row, idx)
        }, (row: RankRow) => `${row.book.id ?? 0}:${row.seconds}:${row.name}:${row.progress}`)
      }

      // 累计行：同时是"进详情页"的入口（整行可点）
      Row() {
        Text(this.totalSec > 0
          ? `累计 ${fmtDuration(this.totalSec)} · 阅读 ${this.totalDays} 天 · 连续 ${this.streak} 天`
          : '读完任意一页即开始统计')
          .fontSize(11)
          .fontColor(ShelfColors.textSub())
        Blank()
        SymbolGlyph($r('sys.symbol.chevron_right'))
          // ★ 2026-10-25 官方 UX 自检 2.1.4.3.2「界面图标大小」修复：10 → **16vp**。
          //   判定依据是**实际绘制尺寸**（chevron 墨迹宽 ≈ 0.52 × fontSize）：
          //   12vp 实测只有 6.3vp（手机 API26）/ 6.2vp（平板 API24），仍 < 8vp 必须下限；
          //   16vp ⇒ ≈8.3vp 两台设备同时达标。
          .fontSize(16)
          .fontColor([ShelfColors.textSub()])
      }
      .width('100%')
      .margin({ top: 14 })
      .onClick(() => {
        Haptics.tap()
        this.onOpenDetail(this.filter, this.anchor)
      })
      .clickEffect(UiMotion.CLICK)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ShelfColors.card())
    .borderRadius(10)
    .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
  }
}
