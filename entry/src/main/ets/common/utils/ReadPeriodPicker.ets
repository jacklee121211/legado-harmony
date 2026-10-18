/**
 * 阅读数据的**周期选择器**（2026-10-13 新建）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么单独抽出来
 * ══════════════════════════════════════════════════════════════════════════
 * 「本日/本月/本年」这三档的选择器在**一级卡、阅读榜卡、详情页**三处都要弹。
 * 各写一份必然漂开（一处给了材质、一处忘了选中色）。⇒ 收口到这里。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么每档用的官方 API 不一样（都有 SDK 依据）
 * ══════════════════════════════════════════════════════════════════════════
 * · 日 → `DatePickerDialog` + `mode: DatePickerMode.DATE`（三列：年月日）
 * · 月 → **同一个 API** + `mode: DatePickerMode.YEAR_AND_MONTH`（两列：年+月）
 *    依据：`date_picker.d.ts` 原文 `YEAR_AND_MONTH = 1`（@since 18）、`mode?: DatePickerMode`
 * · 年 → `TextPickerDialog`（年份滚轮）
 *    原因：`DatePickerMode` 只有 `DATE / YEAR_AND_MONTH / MONTH_AND_DAY`，
 *          **没有"只选年"**；硬用 YEAR_AND_MONTH 会多出一列月，与「2026年」的展示格式矛盾。
 * · 自定义区间 → **串行两次** `DatePickerDialog`（先起始、再结束）
 *    原因：官方**没有区间选择器** —— `CalendarPickerDialog` 的 `selected` 只收单个 `Date`。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 两处"官方 API 与 SDK 副本不一致"的务实处理（务必保留注释）
 * ══════════════════════════════════════════════════════════════════════════
 * ① `DatePickerDialog.show` / `TextPickerDialog.show` 的 **全局静态形态在 SDK 里已废弃**：
 *    原文 `@deprecated since 18` + `@useinstead ohos.arkui.UIContext.UIContext#showDatePickerDialog`。
 *    这里**继续用全局形态**，原因是这是个**静态工具类**（没有 `getUIContext()`）；
 *    要迁到 UIContext 版，需要把 UIContext 从调用方一路传进来（三处调用点，改动面大于收益）。
 *    编译器只会给 severity 3 的废弃提示，不影响构建；将来若统一迁移，本文件只有 4 个调用点。
 *
 * ② `selectedColor` / `systemMaterial` 这两个 options 字段：
 *    在**本机静态检查解析到的 `date_picker.d.ts` 副本里不存在**（该副本比真机旧；
 *    真机 API 26 的 SDK 里二者都在，`systemMaterial` 标 `@since 26.0.0`）。
 *    ⇒ 用 `as` 断言把对象交给官方 options 类型：
 *      编译期不报"未知属性"（断言不做多余属性检查），运行期在 API 26 上照常生效。
 *    ⚠️ 若将来构建换成更老的 SDK 且**运行期**也不支持，这两个字段会被忽略 ——
 *      结果是"弹窗没有沉浸材质/选中色不跟主题"，不会崩。属可接受的降级。
 */
import ImmersiveMaterialUtil from './ImmersiveMaterialUtil'
import { dayKeyOf } from '../../database/dao/ReadDailyDao'
import { READ_MODE_DAY, READ_MODE_MONTH, READ_MODE_YEAR } from './ReadStatsFmt'

/** 日期选择结果的回调：年/月/日三档统一回传"锚点时间戳" */
export type AnchorPicked = (anchorMs: number) => void
/** 区间选择结果的回调：'YYYY-MM-DD' 起 / 止 */
export type RangePicked = (fromDay: string, toDay: string) => void

/** 两次弹窗之间的间隔（等前一个真正收起，避免叠层 / 吞掉点击）—— 需真机实测确认 */
const NEXT_DIALOG_DELAY_MS: number = 140

export class ReadPeriodPicker {
  /**
   * 按档位弹官方选择器。`mode` 为 `all` / `custom` 时**什么也不做**（由调用方决定）。
   * @param brand 主题主色（选中态）
   */
  static open(mode: string, anchorMs: number, brand: string, onPick: AnchorPicked): void {
    if (mode === READ_MODE_YEAR) {
      ReadPeriodPicker.openYear(anchorMs, brand, onPick)
      return
    }
    if (mode !== READ_MODE_DAY && mode !== READ_MODE_MONTH) {
      return
    }
    ReadPeriodPicker.openDate(anchorMs, mode === READ_MODE_MONTH, new Date(2000, 0, 1), brand,
      (picked: Date): void => {
        onPick(picked.getTime())
      })
  }

  /** 年档：文本滚轮（2000 ~ 今年） */
  private static openYear(anchorMs: number, brand: string, onPick: AnchorPicked): void {
    const nowYear: number = new Date().getFullYear()
    const years: string[] = []
    for (let y = 2000; y <= nowYear; y++) {
      years.push(`${y}年`)
    }
    const cur: number = new Date(anchorMs).getFullYear()
    const idx: number = Math.max(0, Math.min(years.length - 1, cur - 2000))
    const opts = {
      range: years,
      selected: idx,
      selectedTextStyle: { color: brand },
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      onAccept: (value: TextPickerResult): void => {
        const picked: string[] = typeof value.value === 'string' ? [value.value] : value.value as string[]
        const year: number = parseInt(picked[0])
        if (year > 0) {
          onPick(new Date(year, 0, 1).getTime())
        }
      }
    } as TextPickerDialogOptions
    TextPickerDialog.show(opts)
  }

  /**
   * 自定义区间：先选起始日，再选结束日（两步）。
   * 第二步的 `start` 钉在已选起始日之后，避免选出 `止 < 起` 的非法区间。
   */
  static openRange(brand: string, fromDay: string, toDay: string, onPick: RangePicked): void {
    const nowMs: number = Date.now()
    const fromSelected: Date = ReadPeriodPicker.parseDay(fromDay, new Date(nowMs))
    const first = {
      start: new Date(2000, 0, 1),
      end: new Date(nowMs),
      selected: fromSelected,
      mode: DatePickerMode.DATE,
      selectedColor: brand,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      onDateAccept: (from: Date): void => {
        const fromDayKey: string = dayKeyOf(from.getTime())
        // 等第一个弹窗收起再弹第二个（官方 NOTE：动画播放期间页面不响应触摸）
        setTimeout((): void => {
          const toSelected: Date = ReadPeriodPicker.parseDay(toDay, from)
          const second = {
            start: from,
            end: new Date(Date.now()),
            selected: toSelected.getTime() >= from.getTime() ? toSelected : from,
            mode: DatePickerMode.DATE,
            selectedColor: brand,
            systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
            onDateAccept: (to: Date): void => {
              const toDayKey: string = dayKeyOf(to.getTime())
              // 兜底：止 < 起 时交换，绝不把非法区间传给 SQL
              if (toDayKey < fromDayKey) {
                onPick(toDayKey, fromDayKey)
              } else {
                onPick(fromDayKey, toDayKey)
              }
            }
          } as DatePickerDialogOptions
          DatePickerDialog.show(second)
        }, NEXT_DIALOG_DELAY_MS)
      }
    } as DatePickerDialogOptions
    DatePickerDialog.show(first)
  }

  /** 单个日期弹窗（日/月两档共用；`twoColumn` = 只选年月） */
  private static openDate(anchorMs: number, twoColumn: boolean, minDate: Date, brand: string,
    onPick: (d: Date) => void): void {
    const opts = {
      start: minDate,
      end: new Date(Date.now()),
      selected: new Date(anchorMs),
      mode: twoColumn ? DatePickerMode.YEAR_AND_MONTH : DatePickerMode.DATE,
      selectedColor: brand,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      onDateAccept: (value: Date): void => {
        onPick(value)
      }
    } as DatePickerDialogOptions
    DatePickerDialog.show(opts)
  }

  /** 'YYYY-MM-DD' → Date（解析失败就用兜底值） */
  private static parseDay(day: string, fallback: Date): Date {
    if (day === undefined || day === null || day.length < 10) {
      return fallback
    }
    const y: number = parseInt(day.substring(0, 4))
    const m: number = parseInt(day.substring(5, 7))
    const d: number = parseInt(day.substring(8, 10))
    if (!(y > 0) || !(m > 0) || !(d > 0)) {
      return fallback
    }
    return new Date(y, m - 1, d)
  }
}

export default ReadPeriodPicker
