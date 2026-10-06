/**
 * toc.ts —— 单源目录的**定位算法**（纯函数，可单测）
 * ============================================================================
 * 为什么放在前端（2026-10-05 调整）：
 *   手机端只发布目录**标题**（ReaderPage3.publishBookToc，零成本），字符区间由
 *   **拿着正文的那一端**算 —— 也就是这里。这样"偏移算在一串文本、网页收到另一串"
 *   这个最致命的口径风险**从结构上消失**（探针报告 §5 把它列为第一风险）。
 *   附带好处：算法是纯函数 ⇒ 首次能被单测覆盖（旧方案把它放在 ArkTS，本地无法验证）。
 *
 * 定位规则（逐条都有对应测试）：
 *   ① **顺序定位**：每个标题从"上一个命中位置之后"开始找 ⇒ 同名/重复标题不会全挤到一处；
 *   ② **要求行首**：命中点必须在 `\n`（或正文开头）之后 ⇒ 避免把正文里的提及当章节；
 *   ③ **标题容错**：整串找不到时，退化用前 8 字再找一次（应对截断/空白差异）；
 *   ④ **书首目录块陷阱**：真实 txt 常在开头列一份目录 ⇒ 前几个标题会挤在开头一小段里。
 *      检测到"前几个起点挤在开头 cluster"就跳过该 cluster 重找一次；
 *   ⑤ **合理性校验**：命中率 <50%、条数 <3、或平均章长 <120 字符 ⇒ 判定不可靠，返回空数组
 *      （调用方 `model.chaptersFromToc` 拿到空数组会回退到本地正则切分，绝不白屏）。
 */
import type { TocEntry } from './protocol.types.ts'

/** 平均章长下限：低于它基本可以断定"命中的是书首目录块"而不是真正的章节 */
const MIN_AVG_SPAN = 120
/** 命中率下限 */
const MIN_HIT_RATIO = 0.5
/** 最少条数 */
const MIN_ENTRIES = 3

export function locateToc(text: string, titles: string[]): TocEntry[] {
  const cleaned = titles.map((t) => String(t ?? '').trim())
  const first = locateOnce(text, cleaned, 0)
  // ⚠️ 陷阱检查必须**先做**：书首目录块里的标题同样"在行首、顺序、命中率高"，
  //    光看 ok 是分辨不出来的（单测 `书首目录块陷阱` 就是钉这一条）。
  const clusterEnd = first.starts.length > 0 ? clusterGuess(text, first.starts) : 0
  if (clusterEnd > 0) {
    const second = locateOnce(text, cleaned, clusterEnd)
    if (second.ok) {
      return buildEntries(text, cleaned, second.starts)
    }
    return first.ok ? buildEntries(text, cleaned, first.starts) : []
  }
  return first.ok ? buildEntries(text, cleaned, first.starts) : []
}

interface LocatePass {
  ok: boolean
  starts: number[]
  hit: number
}

function locateOnce(text: string, titles: string[], fromStart: number): LocatePass {
  const starts: number[] = []
  let from = fromStart
  let hit = 0
  for (const title of titles) {
    if (title === '') {
      starts.push(-1)
      continue
    }
    let at = findAtLineStart(text, title, from)
    if (at < 0) {
      const key = title.slice(0, 8)
      at = key === '' ? -1 : findAtLineStart(text, key, from)
    }
    if (at >= 0) {
      hit++
      from = at + 1
    }
    starts.push(at)
  }
  const minHits = Math.max(MIN_ENTRIES, Math.floor(titles.length * MIN_HIT_RATIO))
  if (hit < minHits || titles.length < MIN_ENTRIES) {
    return { ok: false, starts, hit }
  }
  const located = starts.filter((s) => s >= 0).length
  if (located < MIN_ENTRIES) {
    return { ok: false, starts, hit }
  }
  if (Math.floor(text.length / located) < MIN_AVG_SPAN) {
    return { ok: false, starts, hit }
  }
  return { ok: true, starts, hit }
}

/** 命中点必须位于行首（正文最开头也算） */
export function findAtLineStart(text: string, needle: string, from: number): number {
  let at = text.indexOf(needle, Math.max(0, from))
  while (at >= 0) {
    if (at === 0 || text.charCodeAt(at - 1) === 10 /* \n */ || text.charCodeAt(at - 1) === 13) {
      return at
    }
    at = text.indexOf(needle, at + 1)
  }
  return -1
}

/**
 * 猜"书首目录块"的结束位置：若前 5 个命中点都落在文本开头的一小段内，返回该段末尾。
 * 返回 0 表示"不像目录块"。
 */
function clusterGuess(text: string, starts: number[]): number {
  const found = starts.filter((s) => s >= 0).slice(0, 5)
  if (found.length < 3) return 0
  const window = Math.max(400, Math.min(4000, Math.floor(text.length / 50)))
  const first = found[0]!
  if (first > window) return 0
  const last = found[found.length - 1]!
  if (last - first > window) return 0
  // 跳到该 cluster 之后（下一个换行后），避免第二次又从目录块里匹配
  const nl = text.indexOf('\n', last)
  return nl >= 0 ? nl + 1 : last + 1
}

function buildEntries(text: string, titles: string[], starts: number[]): TocEntry[] {
  const out: TocEntry[] = []
  for (let i = 0; i < titles.length; i++) {
    const s = starts[i]!
    if (s < 0) continue
    let e = text.length
    for (let j = i + 1; j < titles.length; j++) {
      const sj = starts[j]!
      if (sj >= 0) {
        e = sj
        break
      }
    }
    out.push({ title: titles[i]!, charStart: s, charEnd: Math.max(s + 1, e) })
  }
  return out
}
