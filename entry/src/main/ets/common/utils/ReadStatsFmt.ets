/**
 * 阅读数据的**口径与格式化工具**（2026-10-13 新建）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么单独抽一个文件
 * ══════════════════════════════════════════════════════════════════════════
 * 「本月 / 2026年10月 / 12小时40分」这三类换算，在**一级卡、阅读榜卡、详情页**
 * 三处都要用。各写一份必然慢慢漂开（时长一处写「12小时40分」、一处写「12h40m」，
 * 周期一处"本周"一处"近7天"），用户看到的就是"前后口径不一致"。
 * ⇒ 唯一真源放这里，三处只调函数。
 *
 * ⚠️ 「日」的时间边界必须是**本地时区**：统一走 `ReadDailyDao` 导出的 `dayKeyOf()`，
 *    不要在别处写 `toISOString()`（那是 UTC，东八区晚 8 点后会算到第二天）。
 */
import { ReadPeriod, dayKeyOf, pad2, pad4 } from '../../database/dao/ReadDailyDao'

/** 档位常量（与 `ReadPeriod.mode` 同一套字符串，避免各处手写） */
export const READ_MODE_DAY: string = 'day'
export const READ_MODE_MONTH: string = 'month'
export const READ_MODE_YEAR: string = 'year'
export const READ_MODE_ALL: string = 'all'
export const READ_MODE_CUSTOM: string = 'custom'

/** 一级卡可循环的三档（不含总/自定义） */
export const READ_MODES_CARD: string[] = [READ_MODE_DAY, READ_MODE_MONTH, READ_MODE_YEAR]

/** 「本日阅读 / 本月阅读 / 本年阅读」里的那个变量字 */
export function modeChar(mode: string): string {
  if (mode === READ_MODE_DAY) {
    return '日'
  }
  if (mode === READ_MODE_YEAR) {
    return '年'
  }
  return '月'
}

/** 档位 → 一句人话（菜单/空态用） */
export function modeName(mode: string): string {
  if (mode === READ_MODE_DAY) {
    return '本日'
  }
  if (mode === READ_MODE_MONTH) {
    return '本月'
  }
  if (mode === READ_MODE_YEAR) {
    return '本年'
  }
  if (mode === READ_MODE_CUSTOM) {
    return '自定义时段'
  }
  return '全部时段'
}

/**
 * 秒 → 「12小时40分」；不足 1 小时只给分（「42分」）；0 → 「0分」。
 * 口径与「读过」页「读到 50%」同族：数字大、单位小，由调用方各自排版。
 */
export function fmtDuration(sec: number): string {
  const s: number = Math.max(0, Math.floor(sec ?? 0))
  const h: number = Math.floor(s / 3600)
  const m: number = Math.floor((s % 3600) / 60)
  if (h <= 0) {
    return `${m}分`
  }
  return m <= 0 ? `${h}小时` : `${h}小时${m}分`
}

/** 秒 → 拆成 [时, 分]（给"数字大 + 单位小"的两种字号排版用） */
export interface DurationParts {
  hours: number
  minutes: number
}

export function durationParts(sec: number): DurationParts {
  const s: number = Math.max(0, Math.floor(sec ?? 0))
  const r: DurationParts = { hours: Math.floor(s / 3600), minutes: Math.floor((s % 3600) / 60) }
  return r
}

/**
 * 秒 → 列表右端的紧凑写法：「8h12m」/「42m」/「3h」。
 * 榜单 4~10 行并排时，长写法会把书名挤到只剩两三个字，故用紧凑档。
 */
export function fmtShort(sec: number): string {
  const s: number = Math.max(0, Math.floor(sec ?? 0))
  const h: number = Math.floor(s / 3600)
  const m: number = Math.floor((s % 3600) / 60)
  if (h <= 0) {
    return `${m}m`
  }
  return m <= 0 ? `${h}h` : `${h}h${m}m`
}

/** 锚点时间戳 + 档位 → 周期（直接喂 `ReadDailyDao` 的查询） */
export function periodOf(mode: string, anchorMs: number): ReadPeriod {
  const d: Date = new Date(anchorMs)
  if (mode === READ_MODE_DAY) {
    const p: ReadPeriod = { mode: READ_MODE_DAY, from: dayKeyOf(anchorMs), to: '' }
    return p
  }
  if (mode === READ_MODE_MONTH) {
    const p: ReadPeriod = { mode: READ_MODE_MONTH, from: `${pad4(d.getFullYear())}-${pad2(d.getMonth() + 1)}`, to: '' }
    return p
  }
  if (mode === READ_MODE_YEAR) {
    const p: ReadPeriod = { mode: READ_MODE_YEAR, from: `${pad4(d.getFullYear())}`, to: '' }
    return p
  }
  const p: ReadPeriod = { mode: READ_MODE_ALL, from: '', to: '' }
  return p
}

/** 自定义区间 → 周期 */
export function rangeBounded(fromDay: string, toDay: string): ReadPeriod {
  const p: ReadPeriod = { mode: READ_MODE_CUSTOM, from: fromDay, to: toDay }
  return p
}

const WEEK_CN: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

/** 周期展示文案：本日=`2026年10月23日`、本月=`2026年10月`、本年=`2026年`、总=`全部时段` */
export function periodLabel(mode: string, anchorMs: number): string {
  const d: Date = new Date(anchorMs)
  if (mode === READ_MODE_DAY) {
    return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`
  }
  if (mode === READ_MODE_MONTH) {
    return `${d.getFullYear()}年${d.getMonth() + 1}月`
  }
  if (mode === READ_MODE_YEAR) {
    return `${d.getFullYear()}年`
  }
  return '全部时段'
}

/** 星期几（只给日档的副标题用） */
export function weekdayOf(anchorMs: number): string {
  return WEEK_CN[new Date(anchorMs).getDay()]
}

/**
 * 周期翻页：`delta = -1` 上一格、`+1` 下一格。
 * 月/年一定要按「1 号/1 月」重建日期，否则 10 月 31 日 +1 月会溢出成 12 月 1 日。
 */
export function shiftAnchor(mode: string, anchorMs: number, delta: number): number {
  const d: Date = new Date(anchorMs)
  if (mode === READ_MODE_DAY) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + delta).getTime()
  }
  if (mode === READ_MODE_MONTH) {
    return new Date(d.getFullYear(), d.getMonth() + delta, 1).getTime()
  }
  if (mode === READ_MODE_YEAR) {
    return new Date(d.getFullYear() + delta, 0, 1).getTime()
  }
  return anchorMs
}

/** 是否已经是"当前周期"（决定 › 是否可点：不允许翻到未来） */
export function isCurrentPeriod(mode: string, anchorMs: number): boolean {
  const now: Date = new Date()
  const d: Date = new Date(anchorMs)
  if (mode === READ_MODE_DAY) {
    return dayKeyOf(anchorMs) === dayKeyOf(now.getTime())
  }
  if (mode === READ_MODE_MONTH) {
    return d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()
  }
  if (mode === READ_MODE_YEAR) {
    return d.getFullYear() === now.getFullYear()
  }
  return true
}

/** 该月天数（柱状图槽位数量用；闰年 2 月正确） */
export function daysInMonth(anchorMs: number): number {
  const d: Date = new Date(anchorMs)
  return new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate()
}

/**
 * 把「桶行」铺成**定长槽位数组**（缺的桶补 0）。
 *
 * 为什么不直接拿桶行渲染：数据库只返回**有数据的桶**，
 * 若直接 `ForEach(rows)`，某天没读就会少一根柱子、整张图比例失真。
 * ⇒ 先按时间轴铺满（日=24 槽 / 月=当月天数 / 年=12 槽），再渲染。
 */
export function fillSlots(mode: string, anchorMs: number, rows: ReadBucketRowLike[]): number[] {
  let n: number = 12
  if (mode === READ_MODE_DAY) {
    n = 24
  } else if (mode === READ_MODE_MONTH) {
    n = daysInMonth(anchorMs)
  }
  const out: number[] = []
  for (let i = 0; i < n; i++) {
    out.push(0)
  }
  for (let i = 0; i < rows.length; i++) {
    const r: ReadBucketRowLike = rows[i]
    let idx: number = -1
    if (mode === READ_MODE_DAY) {
      idx = parseInt(r.bucket)              // '0'~'23'
    } else if (mode === READ_MODE_MONTH) {
      idx = parseInt(r.bucket.substring(8)) - 1   // 'YYYY-MM-DD' → 日 - 1
    } else {
      idx = parseInt(r.bucket.substring(5)) - 1   // 'YYYY-MM' → 月 - 1
    }
    if (idx >= 0 && idx < n) {
      out[idx] = r.seconds
    }
  }
  return out
}

/** `fillSlots` 的入参形状（与 `ReadBucketRow` 结构一致；避免循环 import 直接复用其字段） */
export interface ReadBucketRowLike {
  bucket: string
  seconds: number
}
