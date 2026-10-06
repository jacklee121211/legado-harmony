/**
 * model.ts —— 书模型：**字符偏移是唯一坐标**（v3 架构的脊柱）
 * ============================================================================
 * 解决的两个根因（见 docs/web-reader-v3-plan-2026-10-05.md §2 B2/B3）：
 *   B2「切换滚动后进度不对齐」—— 旧实现页模式存"章号+页号"、滚动模式存"像素偏移"，
 *      两者从不换算 ⇒ 切模式就丢位置。现在**任何模式都只读写"书内绝对字符偏移"**。
 *   B3「持续翻页回跳」—— 旧实现的位置锚是"页号"，而页号是**布局的函数**
 *      （字号/行距/窗口/工具栏一变，页数就变 ⇒ 页号指向的内容就变）。现在页号只是
 *      "偏移 → 页"的**派生结果**：布局变了就按偏移重新找页，位置本身不变。
 *
 * 段落切分与旧网页端**同口径**（空行分段 + 去首尾空白 + 丢空段），只是额外记录
 * 每段在原始文本里的 `charStart/charEnd`（这正是旧实现丢掉的东西）。
 */
import type { TocEntry } from './protocol.types.ts'

export interface Para {
  text: string
  charStart: number
  charEnd: number
}

export interface Chapter {
  title: string
  /** 段落下标区间 [paraFrom, paraTo) */
  paraFrom: number
  paraTo: number
  /** 字符偏移区间 [charStart, charEnd) */
  charStart: number
  charEnd: number
  /** 目录来源：'toc' = 手机端下发；'regex' = 本地正则兜底 */
  from: 'toc' | 'regex'
}

/** 旧网页端的章节识别正则（作为 M3 之前/失败的兜底；与 `WifiBookServer.ets` 内嵌 JS 同款） */
const CHAPTER_RE = /^(第[0-9零一二三四五六七八九十百千万两]+[章节卷回集部篇]|序章|楔子|引子|前言|后记|尾声|番外)/
/** 无标题时每 400 段算一章（与旧实现同款兜底） */
const FALLBACK_PARAS_PER_CHAPTER = 400

/**
 * 按空行切段，并记录每段的字符区间（**唯一坐标的来源**）。
 * 与旧实现 `txt.split(/\n\s*\n|\r\n\s*\r\n/)` 的语义等价：空行分段、trim、丢空段。
 */
export function splitParagraphs(raw: string): Para[] {
  const out: Para[] = []
  const re = /\r?\n\s*\r?\n/g
  const push = (s: number, e: number): void => {
    let a = s
    let b = e
    while (a < b && isSpace(raw.charCodeAt(a))) a++
    while (b > a && isSpace(raw.charCodeAt(b - 1))) b--
    if (b > a) out.push({ text: raw.slice(a, b), charStart: a, charEnd: b })
  }
  let m: RegExpExecArray | null
  let start = 0
  while ((m = re.exec(raw)) !== null) {
    push(start, m.index)
    start = m.index + m[0].length
  }
  push(start, raw.length)
  return out
}

function isSpace(c: number): boolean {
  return c === 32 || c === 9 || c === 10 || c === 13 || c === 12 || c === 11
}

/** 用旧正则从段落列表切章（兜底路径） */
export function splitChaptersByRegex(paras: Para[]): Chapter[] {
  const hits: number[] = []
  for (let i = 0; i < paras.length; i++) {
    const head = paras[i]!.text.slice(0, 24)
    if (CHAPTER_RE.test(head)) hits.push(i)
  }
  const out: Chapter[] = []
  if (hits.length > 0) {
    for (let k = 0; k < hits.length; k++) {
      const from = hits[k]!
      const to = k + 1 < hits.length ? hits[k + 1]! : paras.length
      out.push(makeChapter(paras, from, to, paras[from]!.text.slice(0, 30), 'regex'))
    }
    return out
  }
  for (let from = 0; from < paras.length; from += FALLBACK_PARAS_PER_CHAPTER) {
    const to = Math.min(from + FALLBACK_PARAS_PER_CHAPTER, paras.length)
    out.push(makeChapter(paras, from, to, paras[from]!.text.slice(0, 30), 'regex'))
  }
  return out
}

function makeChapter(paras: Para[], from: number, to: number, title: string, src: 'toc' | 'regex'): Chapter {
  const first = paras[from]
  const last = paras[to - 1]
  return {
    title,
    paraFrom: from,
    paraTo: to,
    charStart: first ? first.charStart : 0,
    charEnd: last ? last.charEnd : 0,
    from: src
  }
}

/**
 * 用手机端下发的目录（M3 单源目录）构造章节：`charStart/charEnd` 是**原始文本**偏移，
 * 这里把它们吸附到最近的段落边界上（网页按段落渲染 ⇒ 边界必须落在段上）。
 */
export function chaptersFromToc(paras: Para[], toc: TocEntry[]): Chapter[] | null {
  if (!Array.isArray(toc) || toc.length === 0) return null
  const out: Chapter[] = []
  for (let k = 0; k < toc.length; k++) {
    const entry = toc[k]!
    const from = paragraphAt(paras, entry.charStart)
    let to = k + 1 < toc.length
      ? paragraphAt(paras, toc[k + 1]!.charStart)
      : paras.length
    if (to <= from) to = Math.min(paras.length, from + 1)
    const title = entry.title && entry.title.length > 0 ? entry.title : (paras[from]?.text.slice(0, 30) ?? '')
    out.push(makeChapter(paras, from, to, title, 'toc'))
  }
  return out.length > 0 ? out : null
}

/** 字符偏移 → 段落下标（二分查找；返回**包含或紧邻其后**的段） */
export function paragraphAt(paras: Para[], offset: number): number {
  if (paras.length === 0) return 0
  if (offset <= paras[0]!.charStart) return 0
  let lo = 0
  let hi = paras.length - 1
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (paras[mid]!.charStart <= offset) lo = mid
    else hi = mid - 1
  }
  return lo
}

/** 段落下标 → 该书章下标 */
export function chapterIndexOfPara(chapters: Chapter[], paraIndex: number): number {
  if (chapters.length === 0) return 0
  let lo = 0
  let hi = chapters.length - 1
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (chapters[mid]!.paraFrom <= paraIndex) lo = mid
    else hi = mid - 1
  }
  return lo
}

/** 章内位置比例（段落级）：用于跨端对齐（手机端用块节点号，粒度等价） */
export function posRatioInChapter(chapters: Chapter[], paraIndex: number): number {
  const k = chapterIndexOfPara(chapters, paraIndex)
  const c = chapters[k]!
  const span = c.paraTo - c.paraFrom
  if (span <= 0) return 0
  const rel = (paraIndex - c.paraFrom) / span
  return rel <= 0 ? 0 : rel >= 1 ? 1 : rel
}

/** 章进度比例（整书级）：跨端可换算 */
export function chapterRatio(chapters: Chapter[], chapterIndex: number): number {
  if (chapters.length <= 0) return -1
  const i = Math.max(0, Math.min(chapters.length - 1, chapterIndex))
  return chapters.length > 1 ? i / (chapters.length - 1) : 0
}

/**
 * 按标题在本端目录里找章（数字优先 "第N章"；前 8 字互含兜底）。
 * 与手机端 `ReaderPage3.catalogIndexByTitle()` **同口径**（同一算法两端各实现一次，
 * 单测保证行为一致；M3 之后两端共用同一份目录，这条主要用于兜底）。
 */
export function findChapterByTitle(chapters: Chapter[], title: string, searchFrom = 0): number {
  const t0 = (title ?? '').trim()
  if (t0 === '' || chapters.length === 0) return -1
  const num = numOfChapterTitle(t0)
  if (num >= 0) {
    for (let i = 0; i < chapters.length; i++) {
      if (numOfChapterTitle(chapters[i]!.title) === num) return i
    }
  }
  const key = t0.slice(0, 8)
  for (let i = 0; i < chapters.length; i++) {
    const t = chapters[i]!.title
    if (t !== '' && (t.indexOf(key) >= 0 || key.indexOf(t.slice(0, 8)) >= 0)) return i
  }
  return -1
}

/** 从标题里取出"第N章"的 N（中文数字也认）；取不到返回 -1 */
export function numOfChapterTitle(title: string): number {
  const m = title.match(/第\s*([0-9零一二三四五六七八九十百千万两]+)\s*[章节回卷]/)
  if (!m) return -1
  const raw = m[1]!
  if (/^[0-9]+$/.test(raw)) return parseInt(raw, 10)
  return cnToNum(raw)
}

const CN_DIGITS: Record<string, number> = {
  零: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9
}

/** 中文数字 → 数值（支持"十/十二/二十/一百零三"这类常见写法；不认识返回 -1） */
export function cnToNum(s: string): number {
  if (s === '') return -1
  if (/^[0-9]+$/.test(s)) return parseInt(s, 10)
  let total = 0
  let section = 0
  let number = 0
  for (const ch of s) {
    const d = CN_DIGITS[ch]
    if (d !== undefined) {
      number = d
      continue
    }
    if (ch === '十') {
      section += (number === 0 ? 1 : number) * 10
      number = 0
    } else if (ch === '百') {
      section += (number === 0 ? 1 : number) * 100
      number = 0
    } else if (ch === '千') {
      section += (number === 0 ? 1 : number) * 1000
      number = 0
    } else if (ch === '万') {
      total += (section + number) * 10000
      section = 0
      number = 0
    } else {
      return -1
    }
  }
  return total + section + number
}
