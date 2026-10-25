/**
 * 「我的」页 · 阅读数据卡（卡1，2026-10-13 新建）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 它替代了什么
 * ══════════════════════════════════════════════════════════════════════════
 * 原先「我的」页顶部有一行三格 **读过 / 读完 / 书签**（`MyCenter.ets` 的 `head_list`）。
 * 用户拍板的改法：**那一行整行删掉**，把「读过 / 读完」的**入口**搬进本卡（书签不要了）。
 * ⇒ 本卡里的「读过 N ›」「读完 N ›」两个胶囊就是原来那两个入口，
 *   点击仍进 `readStatistics` 的 0/1 两个明细页（含管理/删除能力），入口没丢、只是换了位置。
 *
 * ── 数据口径 ──────────────────────────────────────────────────────────────
 * 三个量全部来自 `readDaily`（`ReadDailyDao`）：
 *   时长 = SUM(seconds)；读过 = COUNT(DISTINCT bookId)；单次最长 = MAX(maxSession)。
 * 「读完」不看时长表 —— 用 `books.finishedTime` 落在本周期内的本数（这个用现有表就准）。
 *
 * ⚠️ 只统计**前台停留**（`ReadTimeRecorder` 写入口径），切后台/熄屏的时间不计。
 */
import CommonConstants from '../../common/constants/CommonConstants'
import { NightMode, ShelfColors } from '../../common/utils/NightMode'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
import { Haptics } from '../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import ReadPeriodPicker from '../../common/utils/ReadPeriodPicker'
import readDailyDao, { ReadTotalRow, ReadBucketRow } from '../../database/dao/ReadDailyDao'
import BooksDao from '../../database/dao/BooksDao'
import {
  READ_MODE_DAY, READ_MODE_MONTH, READ_MODE_YEAR, READ_MODES_CARD,
  modeChar, durationParts, fmtDuration, periodOf, periodLabel, DurationParts,
  isCurrentPeriod, fillSlots
} from '../../common/utils/ReadStatsFmt'

@Component
export struct ReadDataCard {
  /** 点「查看详细数据」→ 进阅读数据详情页（带上当前档位与锚点，保证两处口径连续） */
  onOpenDetail: (mode: string, anchor: number) => void = (_m: string, _a: number): void => {
  }
  /** 点「读过 / 读完」→ 进原明细页（0 = 读过，1 = 读完） */
  onOpenReadList: (type: number) => void = (_t: number): void => {
  }

  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /**
   * 书架公共刷新信号：阅读器退出时会自增（`flushReadProgressThenNotifyShelf`），
   * 删书/改名/换封面也会自增 ⇒ 本卡必须跟着重查，否则读完书回到「我的」数字是旧的。
   */
  @StorageLink(CommonConstants.BOOK_IS_BOOK_REFRESHING) @Watch('onDataTick') dataTick: number = 0
  /** 「我的」页心跳：eadStatistics 删完记录返回时自增（本页原来那三格就是靠它刷新） */
  @StorageLink('myCenterTick') @Watch('onDataTick') centerTick: number = 0

  /** 当前档位：日 / 月 / 年（本卡不提供"总"，总在详情页） */
  @State mode: string = READ_MODE_MONTH
  /** 周期锚点（毫秒）—— 翻页/选择器都只改它 */
  @State anchor: number = Date.now()
  @State totals: ReadTotalRow = { seconds: 0, days: 0, books: 0, longest: 0, sessions: 0 }
  /** 柱状图槽位（定长：日 24 / 月 当月天数 / 年 12） */
  @State slots: number[] = []
  /** 「读完」本数（books.finishedTime 落在本周期内） */
  @State finishedCount: number = 0
  /** 标题行那个变量字的点击缩放（Q 弹三件套之一） */
  @State chipScale: number = 1

  aboutToAppear(): void {
    this.load()
  }

  onDataTick(): void {
    this.load()
  }

  /** 主题色兜底（主题未就绪时不能给出空字符串，否则 fontColor 无效） */
  private brand(): string {
    const c: string = this.theme.mainColor ?? ''
    return c.length > 0 ? c : '#FF6600'
  }

  private async load(): Promise<void> {
    try {
      const p = periodOf(this.mode, this.anchor)
      this.totals = await readDailyDao.totals(p)
      let rows: ReadBucketRow[] = []
      if (this.mode === READ_MODE_DAY) {
        rows = await readDailyDao.bucketsHourly(p)
      } else if (this.mode === READ_MODE_MONTH) {
        rows = await readDailyDao.bucketsDaily(p)
      } else {
        rows = await readDailyDao.bucketsMonthly(p)
      }
      this.slots = fillSlots(this.mode, this.anchor, rows)
      // 「读完」：用 books 表的 finishedTime 落在本周期内（不依赖时长表，历史数据也准）
      this.finishedCount = await BooksDao.countFinishedInRange(this.rangeStart(), this.rangeEnd())
    } catch (e) {
      console.error('ReadDataCard.load, Error, ' + JSON.stringify(e))
    }
  }

  /** 本周期起止时间戳（读完计数用） */
  private rangeStart(): number {
    const d: Date = new Date(this.anchor)
    if (this.mode === READ_MODE_DAY) {
      return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
    }
    if (this.mode === READ_MODE_YEAR) {
      return new Date(d.getFullYear(), 0, 1).getTime()
    }
    return new Date(d.getFullYear(), d.getMonth(), 1).getTime()
  }

  private rangeEnd(): number {
    const d: Date = new Date(this.anchor)
    if (this.mode === READ_MODE_DAY) {
      return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime() - 1
    }
    if (this.mode === READ_MODE_YEAR) {
      return new Date(d.getFullYear() + 1, 0, 1).getTime() - 1
    }
    return new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime() - 1
  }

  /** 点标题里的「日/月/年」：三档循环（日 → 月 → 年 → 日） */
  private cycleMode(): void {
    const at: number = READ_MODES_CARD.indexOf(this.mode)
    this.mode = READ_MODES_CARD[(at + 1) % READ_MODES_CARD.length]
    // 换档时锚点回到"现在"，避免从"2024 年"切到"日"档却停在 2024 年某天
    this.anchor = Date.now()
    this.load()
  }

  /**
   * 点右侧周期时间：按档位开**官方**选择器。
   *  · 日 → `DatePickerDialog`（三列：年月日）
   *  · 月 → 同一个 API + `mode: YEAR_AND_MONTH`（两列：年+月，@since 18）
   *  · 年 → `TextPickerDialog`（官方 DatePicker **没有"只选年"模式**）
   * 三者都喂同一个 `sheetMaterial()` + 主题色选中态 ⇒ 与全应用弹窗材质一致。
   */
  private openPicker(): void {
    // 三档（日/月/年）的官方选择器差异与依据统一收口在 `ReadPeriodPicker`，此处只接线
    ReadPeriodPicker.open(this.mode, this.anchor, this.brand(), (anchorMs: number): void => {
      this.anchor = anchorMs
      this.load()
    })
  }


  // ── 渲染辅助 ────────────────────────────────────────────────────────────

  private maxSlot(): number {
    let m: number = 0
    for (let i = 0; i < this.slots.length; i++) {
      if (this.slots[i] > m) {
        m = this.slots[i]
      }
    }
    return m
  }

  /** 柱高（2~28vp）*/
  private barH(v: number): number {
    const m: number = this.maxSlot()
    if (m <= 0 || v <= 0) {
      return 2
    }
    return Math.max(2, Math.round(v / m * 28))
  }

  /** 当前时刻所在的槽位（高亮用；不是当期则返回 -1） */
  private nowSlot(): number {
    if (!isCurrentPeriod(this.mode, this.anchor)) {
      return -1
    }
    const now: Date = new Date()
    if (this.mode === READ_MODE_DAY) {
      return now.getHours()
    }
    if (this.mode === READ_MODE_MONTH) {
      return now.getDate() - 1
    }
    return now.getMonth()
  }

  private barOpacity(i: number, v: number): number {
    if (v <= 0) {
      return 0.10
    }
    return i === this.nowSlot() ? 1 : 0.35
  }

  @Builder
  titleRow() {
    Row() {
      // 「本 + [日/月/年] + 阅读」：变量字用主题色 + 下划线 = 可点的视觉语言
      Row() {
        Text('本')
          .fontSize(14).fontWeight(600).fontColor(ShelfColors.textMain())
        Text(modeChar(this.mode))
          .fontSize(14).fontWeight(600)
          .fontColor(this.brand())
          .decoration({ type: TextDecorationType.Underline, color: this.brand() })
          .scale({ x: this.chipScale, y: this.chipScale })
        Text('阅读')
          .fontSize(14).fontWeight(600).fontColor(ShelfColors.textMain())
      }
      .onClick(() => {
        Haptics.tap()
        runJellyClick((v: number) => {
          this.chipScale = v
        })
        this.cycleMode()
      })
      .clickEffect(UiMotion.CLICK)

      Blank()

      // 周期时间：格式随档位变（本日=年月日 / 本月=年月 / 本年=年），点击开官方选择器
      Row({ space: 4 }) {
        Text(periodLabel(this.mode, this.anchor))
          .fontSize(13).fontColor(ShelfColors.textSub())
        SymbolGlyph($r('sys.symbol.chevron_right'))
          // ★ 2026-10-25 官方 UX 自检 2.1.4.3.2「界面图标大小」修复：11 → **16vp**。
          //   为什么不是 12（deveco 那轮改成 12 仍不达标，真机实测）：
          //   自检判定用的是**实际绘制尺寸**，不是 fontSize 声明值。报告原文
          //   （`capture_20261025134618476.bmp`）：「控件类型：[SymbolGlyph]的实际尺寸为 5*9vp」
          //   ⇒ 拿 fontSize 反推，chevron 的**墨迹宽 ≈ 0.52 × fontSize**。
          //   两台真机 dump 实测（2026-10-25）：
          //     手机 Mate 80 / API26：fontSize 12 → 21×40px ÷ 密度 3.35 = **6.3 × 11.9vp**
          //     平板 MRO-W00 / API24：fontSize 12 → 14×27px ÷ 密度 2.25 = **6.2 × 12.0vp**
          //   ⇒ 12vp 只有 ~6.3vp 宽，仍 < 8vp「必须」下限。
          //   16vp ⇒ 16 × 0.52 ≈ **8.3vp**，两台设备同时达标（与机型/API/HDS 无关）。
          .fontSize(16)
          .fontColor([ShelfColors.textSub()])
      }
      .onClick(() => {
        Haptics.tap()
        this.openPicker()
      })
      .clickEffect(UiMotion.CLICK)
    }
    .width('100%')
    .height(20)
  }

  @Builder
  bigTime() {
    Row() {
      // 数字大、单位小（与「读过」页「读到 50%」同族的排版）
      ForEach(this.timeParts(), (p: TimePart, i: number) => {
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
  }

  /** 把时长拆成「数字 / 单位」交错的分段，避免"12小时40分"整串同字号 */
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
  chip(label: string, num: number, type: number) {
    // 这就是原来那一行三格里的「读过 / 读完」入口，搬进本卡
    Row({ space: 5 }) {
      Text(label)
        .fontSize(11).fontColor(ShelfColors.textSub())
      Text(`${num}`)
        .fontSize(14).fontWeight(600).fontColor(ShelfColors.textMain())
      SymbolGlyph($r('sys.symbol.chevron_right'))
        // ★ 2026-10-25 官方 UX 自检 2.1.4.3.2「界面图标大小」修复：10 → **16vp**。
        //   判定依据是**实际绘制尺寸**（chevron 墨迹宽 ≈ 0.52 × fontSize）：
        //   12vp 实测只有 6.3vp（手机 API26）/ 6.2vp（平板 API24），仍 < 8vp 必须下限；
        //   16vp ⇒ ≈8.3vp 两台设备同时达标。
        .fontSize(16)
        .fontColor([ShelfColors.textSub()])
    }
    .height(30)
    .padding({ left: 12, right: 12 })
    .borderRadius(15)
    .backgroundColor(ShelfColors.chip())
    .onClick(() => {
      Haptics.tap()
      this.onOpenReadList(type)
    })
    .clickEffect(UiMotion.CLICK)
  }

  @Builder
  barsRow() {
    Row({ space: 2 }) {
      ForEach(this.slots, (v: number, i: number) => {
        Column() {
          Row()
            .width('100%')
            .height(this.barH(v))
            .borderRadius(2)
            .backgroundColor(this.brand())
            .opacity(this.barOpacity(i, v))
        }
        .layoutWeight(1)
        .height(28)
        .justifyContent(FlexAlign.End)
      }, (v: number, i: number) => `b${i}:${v}`)
    }
    .width('100%')
    .height(28)
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  footRow() {
    Row() {
      // 柱状图没有刻度 ⇒ 用一句话补上绝对量（用户 2026-10-13 要求）
      Text(this.totals.sessions > 0 ? `单次最长 ${fmtDuration(this.totals.longest)}` : '还没有阅读记录')
        .fontSize(12).fontColor(ShelfColors.textSub())
      Blank()
      Text(`${this.totals.days} 天 · ${this.totals.sessions} 次`)
        .fontSize(12).fontColor(ShelfColors.textSub())
    }
    .width('100%')
    .margin({ top: 10 })
  }

  build() {
    Column() {
      this.titleRow()

      Row() {
        this.bigTime()
        Blank()
        Row({ space: 8 }) {
          this.chip('读过', this.totals.books, 0)
          this.chip('读完', this.finishedCount, 1)
        }
      }
      .width('100%')
      .margin({ top: 10 })

      Column() {
        this.barsRow()
      }
      .width('100%')
      .margin({ top: 14 })

      this.footRow()

      Divider()
        .strokeWidth(1)
        .color(ShelfColors.line())
        .opacity(0.25)
        .margin({ top: 12, bottom: 10 })

      Text('查看详细数据 ›')
        .fontSize(12)
        .fontColor(ShelfColors.textSub())
        .width('100%')
        .textAlign(TextAlign.End)
        .onClick(() => {
          Haptics.tap()
          this.onOpenDetail(this.mode, this.anchor)
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

/** 时间分段的渲染单元（ArkTS 禁匿名对象字面量 ⇒ 必须显式 interface） */
interface TimePart {
  text: string
  unit: boolean
}


