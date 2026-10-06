/**
 * store.ts —— 本地持久化（按书 id 命名空间）
 * ============================================================================
 * v3 关键变更：**位置只存一个数 —— 书内绝对字符偏移 `offset`**。
 * 旧实现按模式各存各的（页模式 `p_ch`+`p_pg`、滚动模式 `p_scroll` 像素），
 * 两者从不换算 ⇒ 「切滚动后进度不对齐」（审计 B2）。现在任何模式都读写同一个 offset，
 * 页号/滚动像素都是它的**派生显示**。
 */
import type { Mode } from './reader.types.ts'

export type Theme = 'day' | 'sepia' | 'night'

export interface Settings {
  fontSize: number
  /** 行距倍率（三档：1.6 / 1.9 / 2.2） */
  lineHeight: number
  theme: Theme
  mode: Mode
}

export const LINE_HEIGHTS = [1.6, 1.9, 2.2] as const
export const FONT_MIN = 13
export const FONT_MAX = 34

export class Store {
  private readonly ns: string

  constructor(id: number | string) {
    this.ns = 'mr_' + String(id)
  }

  private get(k: string, d: string): string {
    try {
      const v = localStorage.getItem(this.ns + '_' + k)
      return v === null ? d : v
    } catch {
      return d
    }
  }

  private set(k: string, v: string): void {
    try {
      localStorage.setItem(this.ns + '_' + k, v)
    } catch {
      /* 隐私模式/配额满：静默降级（不阻断阅读） */
    }
  }

  settings(): Settings {
    const f = parseInt(this.get('f', '19'), 10)
    const lhIdx = parseInt(this.get('lh', '1'), 10)
    const th = this.get('th', 'day') as Theme
    const md = this.get('mode', 'scroll') as Mode
    return {
      fontSize: Number.isFinite(f) ? Math.max(FONT_MIN, Math.min(FONT_MAX, f)) : 19,
      lineHeight: LINE_HEIGHTS[lhIdx >= 0 && lhIdx < LINE_HEIGHTS.length ? lhIdx : 1]!,
      theme: th === 'sepia' || th === 'night' ? th : 'day',
      mode: md === 'page1' || md === 'page2' ? md : 'scroll'
    }
  }

  saveSettings(s: Settings): void {
    this.set('f', String(s.fontSize))
    this.set('lh', String(LINE_HEIGHTS.indexOf(s.lineHeight as 1.6)))
    this.set('th', s.theme)
    this.set('mode', s.mode)
  }

  /** **唯一位置**：书内绝对字符偏移；-1 = 还没读过（由调用方决定开场位置） */
  offset(): number {
    const v = parseInt(this.get('off', '-1'), 10)
    return Number.isFinite(v) ? v : -1
  }

  saveOffset(o: number): void {
    if (Number.isFinite(o) && o >= 0) this.set('off', String(Math.floor(o)))
  }

  /** 本浏览器在双端同步里的身份（多台电脑各一条槽，互不覆盖） */
  webId(): string {
    let v = this.get('webId', '')
    if (v === '') {
      v = 'w' + Math.random().toString(36).slice(2, 8) + Date.now().toString(36).slice(-3)
      this.set('webId', v)
    }
    return v
  }

  /**
   * 已消费的**手机槽序号水位**（按 webId 归属）。
   *
   * 2026-10-05 从"时间戳水位"改为"序号水位"：`seq` 由手机进程**全局单调**分配
   * ⇒ 跨写者可比、对两端时钟免疫（原先手机时钟快 10 分钟就会把电脑的新位置判成旧的，
   * 提示被静默吞掉）。
   * 兼容：升级前存的可能是时间戳（> 1e11）⇒ 当作"无水位"（最坏是多弹一次，无害）。
   */
  seenPhoneSeq(): number {
    const v = Number(this.get('seenSeq_' + this.webId(), '0'))
    return Number.isFinite(v) && v > 0 && v < 1e11 ? v : 0
  }

  setSeenPhoneSeq(seq: number): void {
    if (Number.isFinite(seq) && seq > 0) this.set('seenSeq_' + this.webId(), String(Math.floor(seq)))
  }
}
