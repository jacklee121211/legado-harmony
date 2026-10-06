/**
 * api.ts —— 与手机端 HTTP 服务的唯一交互点（薄封装，便于 mock 与替换）
 * 端点（与 `WifiBookServer.ets` 的路由一一对应）：
 *   GET  /book?id=        正文（UTF-8 文本）
 *   GET  /toc?id=         目录快照（M3 单源目录；服务端未实现时返回 []）
 *   GET  /marks?id=       书签列表
 *   POST /marksadd        {id, webKey, chapterName, bookText, ...}
 *   POST /marksdel        {time}
 *   GET  /sync?id=        手机端位置槽
 *   POST /sync            {id, webId, chTitle, chIndex, chCount, ratio, topEx, botEx, posRatio}
 */
import { parseLegacyPos } from './protocol.ts'
import type { MarkRow, SyncGetResponse, SyncPos, TocEntry } from './protocol.types.ts'

async function getText(url: string): Promise<string> {
  const r = await fetch(url)
  if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + url)
  return await r.text()
}

async function getJson<T>(url: string): Promise<T | null> {
  try {
    const r = await fetch(url)
    if (!r.ok) return null
    return (await r.json()) as T
  } catch {
    return null
  }
}

async function postJson(url: string, body: unknown): Promise<{ ok: boolean; msg: string }> {
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    })
    const j = (await r.json()) as { ok?: boolean; msg?: string }
    return { ok: j?.ok === true, msg: String(j?.msg ?? '') }
  } catch {
    return { ok: false, msg: 'network' }
  }
}

export async function fetchBook(id: number): Promise<string> {
  return await getText('/book?id=' + id)
}

/**
 * 取书名：复用手机端已有的 `/books`（书库列表）而不是让服务端往 HTML 里注入字符串
 * ⇒ 服务端只需把构建产物**原样**发出去（架构原则：不拼接）。
 */
export async function fetchTitle(id: number): Promise<string> {
  const list = await getJson<Array<{ id?: number; name?: string }>>('/books')
  if (!Array.isArray(list)) return ''
  const hit = list.find((b) => Number(b?.id) === id)
  return String(hit?.name ?? '')
}

/**
 * 取目录**标题**列表（M3 单源目录）。
 *
 * 分工：手机端只发布标题（`ReaderPage3.publishBookToc`，零成本）；**字符区间由前端自己算**
 * ——（`toc.locateToc`）在它手里那份正文上定位 ⇒ "偏移算在一串、渲染另一串"的口径风险
 * 从结构上消失，而且算法是纯函数、可单测。
 *
 * 兼容两种服务端响应：`{titles:[...]}`（v3）与 `{toc:[{title,...}]}`（过渡期）。
 * 返回空数组 ⇒ 调用方回退本地正则切分。
 */
export async function fetchTocTitles(id: number): Promise<string[]> {
  const j = await getJson<{ ok?: boolean; titles?: string[]; toc?: TocEntry[] }>('/toc?id=' + id)
  if (!j) return []
  if (Array.isArray(j.titles)) {
    return j.titles.map((t) => String(t ?? '')).filter((t) => t.length > 0)
  }
  if (Array.isArray(j.toc)) {
    return j.toc.map((e) => String(e?.title ?? '')).filter((t) => t.length > 0)
  }
  return []
}

export async function fetchMarks(id: number): Promise<MarkRow[]> {
  const j = await getJson<{ ok?: boolean; marks?: MarkRow[] }>('/marks?id=' + id)
  const rows = j?.marks
  if (!Array.isArray(rows)) return []
  const out: MarkRow[] = []
  for (const m of rows) {
    if (!m) continue
    const t = Number(m.time)
    if (!Number.isFinite(t)) continue
    out.push({
      time: t,
      chapterIndex: Number(m.chapterIndex ?? -1),
      chapterName: String(m.chapterName ?? ''),
      bookText: String(m.bookText ?? ''),
      content: String(m.content ?? '')
    })
  }
  out.sort((a, b) => b.time - a.time)
  return out
}

export async function addMark(payload: {
  id: number
  webKey: string
  chapterName: string
  bookText: string
  chTitle: string
  posRatio: number
}): Promise<{ ok: boolean; msg: string }> {
  return await postJson('/marksadd', {
    id: payload.id,
    webKey: payload.webKey,
    chapterName: payload.chapterName,
    bookText: payload.bookText,
    chTitle: payload.chTitle,
    posRatio: payload.posRatio
  })
}

export async function delMark(time: number): Promise<void> {
  await postJson('/marksdel', { time })
}

/** `/sync` 的读取结果：手机槽 + 中继站(最新写者) */
export interface PhoneSync {
  pos: SyncPos | null
  /** 全局最新一次写入的写者（'phone' / 'web:<id>'）；'' = 服务端未提供 */
  latestWriter: string
}

/**
 * 读取"手机端位置槽" + 中继站的"最新写者"。
 * 服务端 v2 返回 `{ok, src:'phone', seq, chTitle/ratio/posRatio/ts, latestWriter, ...}`；
 * 若服务端还是老版本（只有 `title` 与 `src`），用 `parseLegacyPos` 兜底。
 */
export async function fetchPhoneSync(id: number): Promise<PhoneSync> {
  const j = await getJson<SyncGetResponse>('/sync?id=' + id)
  const latestWriter = String(j?.latestWriter ?? '')
  if (!j || j.ok !== true) return { pos: null, latestWriter }
  const ts = Number(j.ts ?? 0)
  if (!(ts > 0)) return { pos: null, latestWriter }
  const chTitle = String(j.chTitle ?? j.title ?? '')
  const topEx = String(j.topEx ?? '')
  const botEx = String(j.botEx ?? '')
  if (chTitle === '' && topEx === '' && botEx === '') return { pos: null, latestWriter }
  if (j.ratio === undefined && j.posRatio === undefined && j.seq === undefined) {
    // 老服务端：没有比例/序号字段 ⇒ 当 v1 处理（只用文本锚，seq=0 会导致"永不提示"，
    // 因此这里给 seq=1 让它至少能提示一次）
    const legacy = parseLegacyPos(
      JSON.stringify({ title: chTitle, topEx, botEx, ts, src: String(j.src ?? 'web') })
    )
    if (legacy) legacy.seq = 1
    return { pos: legacy, latestWriter }
  }
  return {
    pos: {
      v: 2,
      seq: Number(j.seq ?? 0),
      chTitle,
      chIndex: -1,
      chCount: Number(j.chCount ?? 0),
      ratio: Number(j.ratio ?? -1),
      topEx,
      botEx,
      posRatio: Number(j.posRatio ?? -1),
      ts,
      writer: String(j.src ?? 'phone')
    },
    latestWriter
  }
}

/** 把网页当前位置写进**属于本浏览器的那条槽**（服务端按 webId 分条，不会覆盖手机或其它电脑） */
export async function pushWebPos(id: number, webId: string, pos: SyncPos): Promise<void> {
  await postJson('/sync', {
    id,
    webId,
    title: pos.chTitle,
    chTitle: pos.chTitle,
    chIndex: pos.chIndex,
    chCount: pos.chCount,
    ratio: pos.ratio,
    topEx: pos.topEx,
    botEx: pos.botEx,
    posRatio: pos.posRatio
  })
}
