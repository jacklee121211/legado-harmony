/**
 * protocol.ts —— 双端同步/位置协议的**唯一定义处**（前端侧）
 * ============================================================================
 * 与手机端 `entry/src/main/ets/common/utils/SyncConfig.ets` **一一对应**：
 *   · 位置结构 SyncPos、槽键名、水位键名、判定规则（水位 R2 + 同章阈值 R3）、
 *     比例换算 ratioToIndex/indexToRatio —— 两侧必须改一起改（同一条契约）。
 *   · 这里只放**纯函数**（不碰 DOM、不碰 localStorage、不碰网络）⇒ 可被单测覆盖，
 *     这是 v3 架构的核心目的之一：位置算法第一次变得**可验证**。
 *
 * 为什么把"位置"定义成"章标题 + 章进度比例 + 章内比例 + 文本摘录"而不是页码/像素：
 *   电脑端与手机端的**章节切分口径不同**（网页按空行+标题正则；手机端是 ReaderKit），
 *   页码/索引/像素都不可迁移；比例与文本可迁移（文本优先、比例兜底）。
 */
import type { SyncPos } from './protocol.types.ts'

export type { SyncPos }

/** 水位数：某个 web 槽已被手机消费到的时间戳 */
export type WatermarkMap = Record<string, number>
/** 网页侧所有槽（多台电脑各一条） */
export type WebSlotMap = Record<string, SyncPos>

/** 同章且章内位置差小于该值 ⇒ 视为"同一页附近"，不打扰（与手机端一致） */
export const SAME_CHAPTER_RATIO_EPS = 0.1

/** 文本规整：去掉**所有**空白（两端同口径；网页端旧实现是 slice(0,14) 后再比，见 v3 说明） */
export function normEx(s: string | null | undefined): string {
  return String(s ?? '').replace(/\s+/g, '')
}

/**
 * 摘录匹配键：规整化后取前 N 字。
 * 2026-10-05：14 → **20**（旧实现键太短，重复句子会命中错处；显示仍用短摘录）。
 */
export function excerptKey(s: string | null | undefined, len = 20): string {
  return normEx(s).slice(0, len)
}

/** 0~1 夹取；非法值按 0 */
export function clampRatio(r: unknown): number {
  const n = Number(r)
  if (!Number.isFinite(n)) return 0
  return n <= 0 ? 0 : n >= 1 ? 1 : n
}

/** 比例 → 下标（clamp 到 [0, count-1]；count<=0 返回 0） */
export function ratioToIndex(ratio: unknown, count: number): number {
  if (!(count > 0)) return 0
  return Math.max(0, Math.min(count - 1, Math.round(clampRatio(ratio) * (count - 1))))
}

/** 下标 → 比例（count<=1 时返回 0） */
export function indexToRatio(i: number, count: number): number {
  if (!(count > 1)) return 0
  return clampRatio(i / (count - 1))
}

/** 是否视为"同一处"（R3 阈值）：同章且章内位置足够近 */
export function isNearSamePlace(ownChTitle: string, ownPosRatio: number, pos: SyncPos): boolean {
  if (!pos.chTitle || !ownChTitle || pos.chTitle !== ownChTitle) return false
  if (!(pos.posRatio >= 0) || !(ownPosRatio >= 0)) return false
  return Math.abs(pos.posRatio - ownPosRatio) < SAME_CHAPTER_RATIO_EPS
}

/** 一个槽是否有可用的锚（全空视为无数据） */
export function hasAnchor(pos: SyncPos): boolean {
  return !(pos.topEx === '' && pos.botEx === '' && pos.chTitle === '')
}

export interface Pending {
  id: string
  pos: SyncPos
}

/**
 * 挑出**值得提示**的槽（R1 中继站 + R2 水位 + R3 阈值）。
 *
 * R1 **中继站规则（本次新增，"谁最新谁不弹"）**：`latestWriter` 表示全局最新一次写入的写者。
 *    网页侧只关心"手机"，所以 `latestWriter !== 'phone'`（即最新是某台电脑）⇒ 不提示。
 *    例：电脑在 60 章、手机刚读到 60 并写槽 ⇒ 手机是最新 ⇒ 电脑不该问"要不要跳到 59"。
 *    `latestWriter === ''` 表示服务端没给（旧版本）⇒ 退回只看水位。
 * R2 槽的 `seq`（**全局单调，不是时间戳**）必须大于"我已消费的水位"；
 * R3 同章且章内位置足够近 ⇒ 视为同一处，不打扰（调用方负责把水位推进）。
 *
 * @returns `{id, pos}` 或 null
 */
export function pickPending(
  slots: WebSlotMap,
  marks: WatermarkMap,
  ownChTitle: string,
  ownPosRatio: number,
  now: number,
  latestWriter = '',
  maxSkewMs = 5 * 60 * 1000
): Pending | null {
  // R1：最新进度不在手机 ⇒ 我（电脑）就是最新的一端 ⇒ 不弹
  if (latestWriter !== '' && latestWriter !== 'phone') {
    return null
  }
  let best: SyncPos | null = null
  let bestId = ''
  for (const id of Object.keys(slots)) {
    const p = slots[id]
    if (!p) continue
    const seen = marks[id] ?? 0
    if (!(p.seq > seen)) continue
    if (p.ts - now > maxSkewMs) continue
    if (!hasAnchor(p)) continue
    if (best === null || p.seq > best.seq) {
      best = p
      bestId = id
    }
  }
  if (best === null) return null
  if (isNearSamePlace(ownChTitle, ownPosRatio, best)) return null
  return { id: bestId, pos: best }
}

/** 把 v1 老键（`WebSync_<书名>` 的 JSON）解析成 SyncPos；解析失败返回 null */
export function parseLegacyPos(raw: string | null | undefined): SyncPos | null {
  if (typeof raw !== 'string' || raw.length === 0) return null
  try {
    const o = JSON.parse(raw) as Record<string, unknown>
    const ts = Number(o['ts'] ?? 0)
    if (!(ts > 0)) return null
    if (String(o['src'] ?? '') === 'phone') return null
    return {
      v: 1,
      seq: 0,
      chTitle: String(o['title'] ?? ''),
      chIndex: -1,
      chCount: 0,
      ratio: -1,
      topEx: normEx(String(o['topEx'] ?? '')),
      botEx: normEx(String(o['botEx'] ?? '')),
      posRatio: -1,
      ts,
      writer: 'web:v1'
    }
  } catch {
    return null
  }
}
