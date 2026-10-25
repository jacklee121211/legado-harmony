/**
 * 「阅读数据」详情页（2026-10-13 新建）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 信息架构（三级里的 L2）
 * ══════════════════════════════════════════════════════════════════════════
 *   L1 「我的」→ 阅读数据卡 + 阅读榜卡（只读总览）
 *   L2 本页：五档（日 / 月 / 年 / 总 / 自定义）× 三指标 × 趋势 × Top 榜
 *   L3 点榜单里的书 → 已有阅读页（**不新增页面**）
 *
 * ── 五档与一级的 5 项筛选**一一对应** ────────────────────────────────────────
 * 一级「阅读榜」的菜单是 本日/本月/本年/自定义时段/全部时段，
 * 本页的分段就是 日/月/年/自定义/总 —— 同名同序，用户不会看到两套筛选口径。
 *
 * ── 为什么顶部那个三指标卡里「单次最长」单独占一行 ──────────────────────────
 * 柱状图没有刻度（用户明确要求不画刻度），只靠柱子高度读不出绝对量。
 * 「单次最长 X 小时 Y 分」+「X 天 · N 次」两句话就把"这张图大概什么量级"补齐了。
 *
 * 数据全部来自 `readDaily`（时长）与 `books.finishedTime`（读完），
 * 书名列走 `bookNameDisplay()`、封面走 `resolveBookCover()` —— 与书架同一出口。
 */
import CommonConstants from '../../../common/constants/CommonConstants'
import MySetConstants from '../../../common/constants/MySetConstants'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { ThemeItem } from '../../../common/model/Theme'
import { Haptics } from '../../../common/utils/Haptics'
import UiMotion from '../../../common/utils/UiMotion'
import AppRouter, { RouteName, ReaderRouteParam, ReadStatsRouteParam } from '../../../common/router/AppRouter'
import ReadPeriodPicker from '../../../common/utils/ReadPeriodPicker'
import readDailyDao, { ReadBucketRow, ReadPeriod, ReadTotalRow } from '../../../database/dao/ReadDailyDao'
import BooksDao from '../../../database/dao/BooksDao'
import { Books } from '../../../database/entities/Books'
import { resolveBookCover, bookNameDisplay } from '../../../common/utils/CoverSource'
import {
  READ_MODE_DAY, READ_MODE_MONTH, READ_MODE_YEAR, READ_MODE_ALL, READ_MODE_CUSTOM,
  modeChar, fmtDuration, fmtShort, durationParts, DurationParts,
  periodOf, rangeBounded, periodLabel, weekdayOf, shiftAnchor, isCurrentPeriod,
  daysInMonth
} from '../../../common/utils/ReadStatsFmt'

/** 一根柱子（渲染单元；顺带带上刻度标签与高亮位） */
interface BarSlot {
  value: number
  label: string
  highlight: boolean
}

/** 榜单一行 */
interface TopRow {
  book: Books
  name: string
  progress: number
  seconds: number
  cover: ResourceStr
}

/** 五档顺序（与一级菜单同序：日/月/年/自定义/总） */
const SEG_MODES: string[] = [READ_MODE_DAY, READ_MODE_MONTH, READ_MODE_YEAR, READ_MODE_CUSTOM, READ_MODE_ALL]

@Component
export default struct ReadStatsPage {
  /** 由 `Index.appRoutes()` 注入（字段名不能叫 initParam —— 编译器会报 @Component 禁用该名） */
  routeParam: ReadStatsRouteParam = { mode: READ_MODE_MONTH, anchorMs: Date.now() }

  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @StorageLink(MySetConstants.SET_EXT_NAME) @Watch('onExtChanged') showExt: boolean = false
  @StorageLink(CommonConstants.BOOK_IS_BOOK_REFRESHING) @Watch('onDataTick') dataTick: number = 0
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0

  @State mode: string = READ_MODE_MONTH
  @State anchor: number = Date.now()
  @State rangeFrom: string = ''
  @State rangeTo: string = ''
  @State totals: ReadTotalRow = { seconds: 0, days: 0, books: 0, longest: 0, sessions: 0 }
  @State finishedCount: number = 0
  @State bars: BarSlot[] = []
  @State topRows: TopRow[] = []
  /** 榜单最大时长（算占比条宽度用） */
  @State topMax: number = 0


  aboutToAppear(): void {
    if (this.routeParam !== undefined && this.routeParam !== null) {
      const m: string = this.routeParam.mode ?? READ_MODE_MONTH
      this.mode = SEG_MODES.indexOf(m) >= 0 ? m : READ_MODE_MONTH
      const a: number = this.routeParam.anchorMs ?? Date.now()
      this.anchor = a > 0 ? a : Date.now()
    }
    // 自定义档进来时，区间默认"近 30 天"，用户再点周期行改
    const now: number = Date.now()
    this.rangeTo = dayKey(now)
    this.rangeFrom = dayKey(now - 29 * 86400000)
    this.load()
  }

  onDataTick(): void {
    this.load()
  }

  onExtChanged(): void {
    this.load()
  }

  private brand(): string {
    const c: string = this.theme.mainColor ?? ''
    return c.length > 0 ? c : '#FF6600'
  }

  private currentPeriod(): ReadPeriod {
    if (this.mode === READ_MODE_CUSTOM) {
      return rangeBounded(this.rangeFrom, this.rangeTo)
    }
    return periodOf(this.mode, this.anchor)
  }

  private async load(): Promise<void> {
    try {
      const p: ReadPeriod = this.currentPeriod()
      this.totals = await readDailyDao.totals(p)
      this.finishedCount = await BooksDao.countFinishedInRange(this.rangeStart(), this.rangeEnd())

      // 趋势：日→小时桶 / 月→逐日桶 / 年→逐月桶 / 总→逐月桶取最近 12 个 / 自定义→逐日桶
      let rows: ReadBucketRow[] = []
      if (this.mode === READ_MODE_DAY) {
        rows = await readDailyDao.bucketsHourly(p)
      } else if (this.mode === READ_MODE_MONTH || this.mode === READ_MODE_CUSTOM) {
        rows = await readDailyDao.bucketsDaily(p)
      } else {
        rows = await readDailyDao.bucketsMonthly(p)
      }
      this.bars = this.buildBars(rows)

      // Top 榜
      const top: ReadBucketRow[] = await readDailyDao.topBooks(p, 10)
      const all: Books[] = await BooksDao.search({})
      const byId: Map<number, Books> = new Map<number, Books>()
      for (let i = 0; i < all.length; i++) {
        byId.set(all[i].id ?? 0, all[i])
      }
      const disp = bookNameDisplay(this.showExt)
      const out: TopRow[] = []
      let maxSec: number = 0
      for (let i = 0; i < top.length; i++) {
        const book: Books | undefined = byId.get(parseInt(top[i].bucket))
        if (book === undefined) {
          continue
        }
        const sec: number = top[i].seconds ?? 0
        if (sec > maxSec) {
          maxSec = sec
        }
        const total: number = book.totalChapterNum ?? 0
        const cur: number = book.durChapterIndex ?? 0
        const pct: number = total > 0 ? Math.max(0, Math.min(100, Math.round((cur + 1) / total * 100))) : 0
        const item: TopRow = {
          book: book,
          name: disp.display(book.bookName ?? ''),
          progress: pct,
          seconds: sec,
          cover: resolveBookCover(book)
        }
        out.push(item)
      }
      this.topRows = out
      this.topMax = maxSec
    } catch (e) {
      console.error('ReadStatsPage.load, Error, ' + JSON.stringify(e))
    }
  }

  /** 本周期起止（读完计数用） */
  private rangeStart(): number {
    if (this.mode === READ_MODE_CUSTOM) {
      return parseDayMs(this.rangeFrom, Date.now() - 29 * 86400000)
    }
    const d: Date = new Date(this.anchor)
    if (this.mode === READ_MODE_DAY) {
      return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
    }
    if (this.mode === READ_MODE_YEAR) {
      return new Date(d.getFullYear(), 0, 1).getTime()
    }
    if (this.mode === READ_MODE_ALL) {
      return 0
    }
    return new Date(d.getFullYear(), d.getMonth(), 1).getTime()
  }

  private rangeEnd(): number {
    if (this.mode === READ_MODE_CUSTOM) {
      return parseDayMs(this.rangeTo, Date.now()) + 86399999
    }
    const d: Date = new Date(this.anchor)
    if (this.mode === READ_MODE_DAY) {
      return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime() - 1
    }
    if (this.mode === READ_MODE_YEAR) {
      return new Date(d.getFullYear() + 1, 0, 1).getTime() - 1
    }
    if (this.mode === READ_MODE_ALL) {
      return Date.now()
    }
    return new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime() - 1
  }

  // ── 柱状图数据 ──────────────────────────────────────────────────────────

  private buildBars(rows: ReadBucketRow[]): BarSlot[] {
    const out: BarSlot[] = []
    const now: number = Date.now()
    if (this.mode === READ_MODE_DAY) {
      const nowHour: number = new Date().getHours()
      const cur: boolean = isCurrentPeriod(READ_MODE_DAY, this.anchor)
      for (let h = 0; h < 24; h++) {
        out.push({ value: 0, label: h % 6 === 0 ? `${h}点` : '', highlight: cur && h === nowHour })
      }
      for (let i = 0; i < rows.length; i++) {
        const idx: number = parseInt(rows[i].bucket)
        if (idx >= 0 && idx < 24) {
          out[idx].value = rows[i].seconds
        }
      }
      return out
    }
    if (this.mode === READ_MODE_MONTH || this.mode === READ_MODE_CUSTOM) {
      // 自定义区间按"逐日"铺，槽位 = 实际天数（最多 92 天，避免一根柱子宽不到 1px）
      const fromMs: number = this.mode === READ_MODE_CUSTOM
        ? parseDayMs(this.rangeFrom, now - 29 * 86400000)
        : new Date(new Date(this.anchor).getFullYear(), new Date(this.anchor).getMonth(), 1).getTime()
      const days: number = this.mode === READ_MODE_CUSTOM
        ? Math.max(1, Math.min(92, Math.round((parseDayMs(this.rangeTo, now) - fromMs) / 86400000) + 1))
        : daysInMonth(this.anchor)
      const dayMap: Map<string, number> = new Map<string, number>()
      for (let i = 0; i < rows.length; i++) {
        dayMap.set(rows[i].bucket, rows[i].seconds)
      }
      for (let i = 0; i < days; i++) {
        const key: string = dayKey(fromMs + i * 86400000)
        const label: string = (i === 0 || (i + 1) % 10 === 0 || i === days - 1) ? `${parseInt(key.substring(8))}日` : ''
        out.push({ value: dayMap.get(key) ?? 0, label: label, highlight: key === dayKey(now) })
      }
      return out
    }
    // 年 / 总 → 逐月
    if (this.mode === READ_MODE_YEAR) {
      for (let m = 0; m < 12; m++) {
        const label: string = (m + 1) % 3 === 1 ? `${m + 1}月` : ''
        const curM: boolean = isCurrentPeriod(READ_MODE_YEAR, this.anchor) && m === new Date().getMonth()
        out.push({ value: 0, label: label, highlight: curM })
      }
      for (let i = 0; i < rows.length; i++) {
        const mon: number = parseInt(rows[i].bucket.substring(5))
        if (mon >= 1 && mon <= 12) {
          out[mon - 1].value = rows[i].seconds
        }
      }
      return out
    }
    // 总：取最近 12 个月（按 bucket 升序的最后 12 条）
    const tail: ReadBucketRow[] = rows.length > 12 ? rows.slice(rows.length - 12, rows.length) : rows
    for (let i = 0; i < tail.length; i++) {
      const b: string = tail[i].bucket       // 'YYYY-MM'
      out.push({ value: tail[i].seconds, label: `${parseInt(b.substring(5))}月`, highlight: false })
    }
    return out
  }

  private barMax(): number {
    let m: number = 0
    for (let i = 0; i < this.bars.length; i++) {
      if (this.bars[i].value > m) {
        m = this.bars[i].value
      }
    }
    return m
  }

  private barH(v: number): number {
    const m: number = this.barMax()
    if (m <= 0 || v <= 0) {
      return 2
    }
    return Math.max(2, Math.round(v / m * 44))
  }

  private barOpacity(slot: BarSlot): number {
    if (slot.value <= 0) {
      return 0.10
    }
    return slot.highlight ? 1 : 0.30
  }

  // ── 交互 ────────────────────────────────────────────────────────────────

  private pickMode(mode: string): void {
    Haptics.tap()
    if (mode === READ_MODE_CUSTOM) {
      this.mode = READ_MODE_CUSTOM
      // 切到自定义时立刻弹区间选择（否则用户会看到一个空图不知怎么改）
      this.pickRange()
      return
    }
    this.mode = mode
    if (mode !== READ_MODE_ALL) {
      this.anchor = Date.now()
    }
    this.load()
  }

  private pickRange(): void {
    ReadPeriodPicker.openRange(this.brand(), this.rangeFrom, this.rangeTo,
      (from: string, to: string): void => {
        this.rangeFrom = from
        this.rangeTo = to
        this.mode = READ_MODE_CUSTOM
        this.load()
      })
  }

  /** 点周期文案：按档位开官方选择器（自定义 → 区间选择，总 → 无周期可改） */
  private pickPeriod(): void {
    Haptics.tap()
    if (this.mode === READ_MODE_ALL) {
      return
    }
    if (this.mode === READ_MODE_CUSTOM) {
      this.pickRange()
      return
    }
    ReadPeriodPicker.open(this.mode, this.anchor, this.brand(), (anchorMs: number): void => {
      this.anchor = anchorMs
      this.load()
    })
  }

  private step(delta: number): void {
    if (this.mode === READ_MODE_ALL || this.mode === READ_MODE_CUSTOM) {
      return
    }
    if (delta > 0 && isCurrentPeriod(this.mode, this.anchor)) {
      return
    }
    Haptics.tap()
    this.anchor = shiftAnchor(this.mode, this.anchor, delta)
    this.load()
  }

  private canForward(): boolean {
    if (this.mode === READ_MODE_ALL || this.mode === READ_MODE_CUSTOM) {
      return false
    }
    return !isCurrentPeriod(this.mode, this.anchor)
  }

  private periodText(): string {
    if (this.mode === READ_MODE_CUSTOM) {
      return `${this.rangeFrom} ~ ${this.rangeTo.substring(5)}`
    }
    if (this.mode === READ_MODE_ALL) {
      return '全部时段'
    }
    const base: string = periodLabel(this.mode, this.anchor)
    return this.mode === READ_MODE_DAY ? `${base} ${weekdayOf(this.anchor)}` : base
  }

  private durationLabel(): string {
    if (this.mode === READ_MODE_DAY) {
      return '当日阅读时长'
    }
    if (this.mode === READ_MODE_MONTH) {
      return '当月阅读时长'
    }
    if (this.mode === READ_MODE_YEAR) {
      return '当年阅读时长'
    }
    if (this.mode === READ_MODE_CUSTOM) {
      return '该时段阅读时长'
    }
    return '累计阅读时长'
  }

  // ── UI ─────────────────────────────────────────────────────────────────

  @Builder
  head() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([ShelfColors.icon()])
          .onClick(() => {
            Haptics.tap()
            AppRouter.back()
          })
      }.width('33%')

      Row() {
        Text('阅读数据')
          .fontSize(16).fontWeight(600)
          .fontColor(ShelfColors.textMain())
      }.width('33%').justifyContent(FlexAlign.Center)

      // 右侧留空：管理/删除仍在原来的「读过 / 读完」明细页，本页只读
      Row().width('33%')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  segments() {
    Row({ space: 4 }) {
      ForEach(SEG_MODES, (m: string) => {
        Text(m === READ_MODE_CUSTOM ? '自定义' : (m === READ_MODE_ALL ? '总' : modeChar(m)))
          .fontSize(14)
          .fontWeight(this.mode === m ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.mode === m ? this.brand() : ShelfColors.textSub())
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.mode === m ? ShelfColors.card() : Color.Transparent)
          .onClick(() => {
            this.pickMode(m)
          })
      }, (m: string) => m)
    }
    .width('100%')
    .padding(4)
    .borderRadius(21)
    .backgroundColor(ShelfColors.chip())
  }

  @Builder
  periodRow() {
    // ★ 2026-10-25 用户反馈「时间左右两个箭头太小，点击不便」⇒ 放大图标 + 撑满点击热区。
    //   改动前：`SymbolGlyph.fontSize(14)` 且箭头**自身就是热区**（约 14vp×14vp），
    //   远低于官方 UX 标准 2.1.3.3「触屏可点击热区需 ≥40vp×40vp（必须），≥48vp 推荐」。
    //   改法：图标 14→20vp，外面各包一个 44vp×44vp 的 Row 承载点击（视觉不变、热区达标）；
    //   间隔由原来的 `space: 18` 收成 2 —— 44vp 盒子里图标居中后左右各留 12vp，
    //   视觉间距 = 12 + 2 + 12 ≈ 26vp，比原来的 18vp 只略宽，不会把日期挤瘦。
    Row({ space: 2 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([this.mode === READ_MODE_ALL || this.mode === READ_MODE_CUSTOM
            ? ShelfColors.textSub() : ShelfColors.icon()])
          .opacity(this.mode === READ_MODE_ALL || this.mode === READ_MODE_CUSTOM ? 0.3 : 0.5)
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.step(-1)
      })
      Text(this.periodText())
        .fontSize(15).fontWeight(600)
        .fontColor(ShelfColors.textMain())
        .onClick(() => {
          this.pickPeriod()
        })
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20)
          .fontColor([ShelfColors.icon()])
          .opacity(this.canForward() ? 0.5 : 0.15)
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.step(1)
      })
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .margin({ top: 6 })
  }

  @Builder
  metricCard() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Row() {
            ForEach(this.timeParts(), (p: TimePart, _i: number) => {
              if (p.unit) {
                Text(p.text)
                  .fontSize(12).fontColor(ShelfColors.textSub())
                  .margin({ left: 2, right: 4 })
              } else {
                Text(p.text)
                  .fontSize(26).fontWeight(600)
                  .fontColor(ShelfColors.textMain())
              }
            }, (p: TimePart, i: number) => `${i}:${p.text}`)
          }
          .alignItems(VerticalAlign.Bottom)
          Text(this.durationLabel())
            .fontSize(11).fontColor(ShelfColors.textSub())
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Row({ space: 18 }) {
          Column({ space: 2 }) {
            Text(`${this.totals.books}`).fontSize(16).fontWeight(600).fontColor(ShelfColors.textMain())
            Text('读过').fontSize(10).fontColor(ShelfColors.textSub())
          }
          Column({ space: 2 }) {
            Text(`${this.finishedCount}`).fontSize(16).fontWeight(600).fontColor(ShelfColors.textMain())
            Text('读完').fontSize(10).fontColor(ShelfColors.textSub())
          }
        }
      }
      .width('100%')

      Divider()
        .strokeWidth(1).color(ShelfColors.line()).opacity(0.25)
        .margin({ top: 12, bottom: 10 })

      // 柱状图没有刻度 ⇒ 用两句话把绝对量说清楚（用户要求）
      Row() {
        Text(`单次最长 ${fmtDuration(this.totals.longest)}`)
          .fontSize(12).fontColor(ShelfColors.textSub())
        Blank()
        Text(`${this.totals.days} 天 · ${this.totals.sessions} 次`)
          .fontSize(12).fontColor(ShelfColors.textSub())
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ShelfColors.card())
    .borderRadius(10)
    .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
  }

  private timeParts(): TimePart[] {
    const d: DurationParts = durationParts(this.totals.seconds)
    const out: TimePart[] = []
    if (d.hours > 0) {
      out.push({ text: `${d.hours}`, unit: false })
      out.push({ text: '小时', unit: true })
    }
    out.push({ text: `${d.minutes}`, unit: false })
    out.push({ text: '分', unit: true })
    return out
  }

  @Builder
  chartCard() {
    Column() {
      Row() {
        Text(this.mode === READ_MODE_DAY ? '每小时阅读时长' : '每日阅读时长')
          .fontSize(13).fontWeight(600).fontColor(ShelfColors.textMain())
        Blank()
        Text(this.barMax() > 0 ? `最高 ${fmtDuration(this.barMax())}` : '暂无数据')
          .fontSize(10).fontColor(ShelfColors.textSub())
      }
      .width('100%')

      Row({ space: 2 }) {
        ForEach(this.bars, (slot: BarSlot, _i: number) => {
          Column() {
            Row()
              .width('100%')
              .height(this.barH(slot.value))
              .borderRadius(2)
              .backgroundColor(this.brand())
              .opacity(this.barOpacity(slot))
          }
          .layoutWeight(1)
          .height(44)
          .justifyContent(FlexAlign.End)
        }, (slot: BarSlot, i: number) => `s${i}:${slot.value}`)
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 12 })

      // 刻度标签：均匀铺在同一行（柱数多时不逐个标，避免糊成一团）
      Row() {
        ForEach(this.bars, (slot: BarSlot, _i: number) => {
          Text(slot.label)
            .fontSize(9)
            .fontColor(ShelfColors.textSub())
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .maxLines(1)
        }, (slot: BarSlot, i: number) => `l${i}:${slot.label}`)
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ShelfColors.card())
    .borderRadius(10)
    .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
    .margin({ top: 12 })
  }

  @Builder
  topRow(row: TopRow, idx: number) {
    Row({ space: 10 }) {
      Text(`${idx + 1}`)
        .fontSize(15).fontWeight(700)
        .fontColor(idx < 3 ? this.brand() : ShelfColors.textSub())
        .width(16)
        .textAlign(TextAlign.Center)
      Image(row.cover)
        .alt($r('app.media.icon_book_default_cover_one'))
        .width(32).height(42)
        .borderRadius(4)
        .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.18)', offsetX: 0, offsetY: 3 })
      Column({ space: 3 }) {
        Text(row.name)
          .fontSize(13).fontWeight(500)
          .fontColor(ShelfColors.textMain())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`读到 ${row.progress}%`)
          .fontSize(10).fontColor(ShelfColors.textSub())
        // 占比条：让"第一名比第二名多多少"一眼可比
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%').height(3).borderRadius(2)
            .backgroundColor(ShelfColors.line()).opacity(0.25)
          Row()
            .width(`${this.ratioOf(row.seconds)}%`).height(3).borderRadius(2)
            .backgroundColor(this.brand())
        }
        .width('100%')
        .height(3)
        .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(fmtShort(row.seconds))
        .fontSize(12).fontWeight(600)
        .fontColor(ShelfColors.textMain())
    }
    .width('100%')
    .margin({ top: 14 })
    .onClick(() => {
      Haptics.tap()
      AppRouter.push(RouteName.READER, { bookData: row.book } as ReaderRouteParam)
    })
    .clickEffect(UiMotion.CLICK)
  }

  private ratioOf(sec: number): number {
    if (this.topMax <= 0) {
      return 0
    }
    return Math.max(2, Math.round(sec / this.topMax * 100))
  }

  build() {
    Column() {
      this.head()

      // 整页可滚动：Top 榜最多 10 行，矮屏 / 大字号下必然超一屏。
      // ⚠️ 底部让位加在**滚动内容末尾**（不是给 Scroll 盒子加 padding）——
      //    给盒子加等于把可视区截短，最后一行照样被手势条压住
      //    （工程结论见 `docs/底部手势区贯通-排查记录.md:47,94`）。
      Scroll() {
        Column() {
          this.segments()
          this.periodRow()
          this.metricCard()
          this.chartCard()

          Row() {
            Text(this.mode === READ_MODE_DAY ? '当日时长 Top' : '阅读时长 Top')
              .fontSize(14).fontWeight(600).fontColor(ShelfColors.textMain())
            Blank()
            Text(`共 ${this.topRows.length} 本`)
              .fontSize(12).fontColor(ShelfColors.textSub())
          }
          .width('100%')
          .margin({ top: 18 })

          if (this.topRows.length === 0) {
            Column({ space: 6 }) {
              Text('这个时段还没有阅读记录')
                .fontSize(14).fontWeight(600).fontColor(ShelfColors.textMain())
              Text('读几页就会出现在这里；时长只统计前台阅读时间')
                .fontSize(12).fontColor(ShelfColors.textSub())
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(20)
            .margin({ top: 12 })
            .backgroundColor(ShelfColors.card())
            .borderRadius(10)
          } else {
            ForEach(this.topRows, (row: TopRow, idx: number) => {
              this.topRow(row, idx)
            }, (row: TopRow) => `${row.book.id ?? 0}:${row.seconds}:${row.name}:${row.progress}`)
          }

          Row().height(this.bottomRectHeight + 24)
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // 回弹手感与书架一致（`scroll.d.ts` 默认是 None，List 默认是 Spring ⇒ 必须显式给）
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // ★ 2026-10-25 用户反馈「整页是居中对齐的，应该顶部对齐，否则切换月份整页乱跳」。
      //   根因：`align` 是**通用属性**（`common.d.ts`「Sets the alignment mode of the component
      //   content in the drawing area … Default value: **Alignment.Center**」）⇒ 本 `Scroll`
      //   只写了 `layoutWeight(1)`（高度确定）却没写 `align`，当内容不足一屏时**内容块被
      //   垂直居中**；切换日/月/年后柱状图与 Top 榜行数变化 ⇒ 内容高度变化 ⇒ 整块上下位移
      //   （用户看到的"乱跳"）。与 `TtsControlPanel.ets`（`.align(Alignment.Top)`）、
      //   `readStatisticsDataList.ets`（`.align(Alignment.TopStart)`）是同一个坑、同一种修法。
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topRectHeight })
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: ShelfColors.pageGradient(this.theme.mainColor ?? '#ff6600', this.theme.secondColor ?? '#ffece0')
    })
  }
}

/** 时间分段渲染单元 */
interface TimePart {
  text: string
  unit: boolean
}


function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString()
}

function pad4(n: number): string {
  const s: string = n.toString()
  return s.length >= 4 ? s : '0' + s
}

/** 时间戳 → 'YYYY-MM-DD'（本地时区，口径与 DAO 的 dayKeyOf 一致） */
function dayKey(ts: number): string {
  const d: Date = new Date(ts)
  return `${pad4(d.getFullYear())}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`
}

/** 'YYYY-MM-DD' → 当天 00:00 毫秒（解析失败回退） */
function parseDayMs(day: string, fallback: number): number {
  if (day === undefined || day === null || day.length < 10) {
    return fallback
  }
  const y: number = parseInt(day.substring(0, 4))
  const m: number = parseInt(day.substring(5, 7))
  const d: number = parseInt(day.substring(8, 10))
  if (!(y > 0) || !(m > 0) || !(d > 0)) {
    return fallback
  }
  return new Date(y, m - 1, d).getTime()
}
