/**
 * reader.ts —— 阅读引擎（v3 核心）
 * ============================================================================
 * 架构不变量（整个重构的地基）：
 *   ① **唯一位置 = 书内绝对字符偏移 `offset`**。页码/滚动像素/百分比/书签/同步锚
 *      全部由它**派生**；任何布局变化（字号、行距、主题、窗口、工具栏隐藏）只重排，
 *      位置不变 ⇒ 根治审计 B2「切滚动后进度不对齐」与 B3「持续翻页回跳」。
 *   ② **唯一翻页入口 = `turnPage(±1)`**。点击左右、方向键、滚轮、目录跳转全部走它，
 *      不再各写一份边界逻辑（旧实现 `next()` 混用旧 pageCount 与新 total() ⇒ 回跳）。
 *   ③ **位置锚是"段落下标"**（charOffset 的等价物），页号只是派生：布局变了就按段落
 *      反查新页号（见 `paging.ts`，有单测）。
 *
 * 与旧内嵌实现的关系：视觉/交互逐条保留（三版式、字号行距背景、目录、书签、搜索、
 * 同步提示条、全屏、进度），但**状态与边界逻辑全部重写**为上述不变量。
 */
import {
  splitParagraphs, splitChaptersByRegex, chaptersFromToc, paragraphAt,
  chapterIndexOfPara, posRatioInChapter, chapterRatio, findChapterByTitle
} from './model.ts'
import type { Chapter, Para } from './model.ts'
import { buildPageMap, pageOfPara, firstParaOfPage, snapPage, emptyPageMap } from './paging.ts'
import type { PageMap } from './paging.ts'
import { excerptKey, clampRatio } from './protocol.ts'
import type { SyncPos, TocEntry } from './protocol.types.ts'
import type { Mode } from './reader.types.ts'

export interface ReaderDeps {
  id: number
  webId: string
  /** 取得"我当前可见范围的首/末段"用于构造同步锚；由引擎自己实现，这里只注入设置读写 */
  onSettingsChanged?: () => void
}

export class Reader {
  readonly id: number
  readonly webId: string

  // ── 数据 ────────────────────────────────────────────────────────────────
  paras: Para[] = []
  chapters: Chapter[] = []
  /** 滚动模式已渲染到第几段（增量渲染，避免一次插几十万节点） */
  private rendered = 0
  /** 页模式当前渲染的是哪一章 + 该章段落副本（含偏移，供"段→页"换算） */
  private chapterParaFrom = 0
  private pgParas: Para[] = []
  private pageMap: PageMap = emptyPageMap()
  private pageIdx = 0
  private stride = 0

  // ── 状态 ────────────────────────────────────────────────────────────────
  /** **唯一位置**：书内绝对字符偏移（-1 = 未定，首帧落到第 0 段） */
  private offset = -1
  mode: Mode = 'scroll'
  fontSize = 19
  lineHeight = 1.9
  theme: 'day' | 'sepia' | 'night' = 'day'

  /** 最近一次 push 的时间与章标题（节流：换章即刻推、同章 5s 一推） */
  private lastPushAt = 0
  private lastPushedTitle = ''

  private readonly el: {
    sc: HTMLElement; si: HTMLElement; more: HTMLElement
    stg: HTMLElement; pg: HTMLElement
    pct: HTMLElement; modeTag: HTMLElement
  }

  constructor(deps: ReaderDeps) {
    this.id = deps.id
    this.webId = deps.webId
    const q = (s: string): HTMLElement => {
      const e = document.querySelector(s)
      if (!e) throw new Error('缺少 DOM 节点: ' + s)
      return e as HTMLElement
    }
    this.el = {
      sc: q('#scroll'), si: q('#sinner'), more: q('#more'),
      stg: q('#stage'), pg: q('#pages'),
      pct: q('#pct'), modeTag: q('#modeTag')
    }
  }

  // ── 装载 ────────────────────────────────────────────────────────────────
  /** 建立书模型：段落（带字符区间）+ 章节（优先手机端下发的单源目录，失败回退正则） */
  setBook(raw: string, toc: TocEntry[]): void {
    this.paras = splitParagraphs(raw)
    const fromToc = chaptersFromToc(this.paras, toc)
    this.chapters = fromToc ?? splitChaptersByRegex(this.paras)
    if (this.paras.length === 0) {
      this.chapters = []
    }
    this.rendered = 0
    this.offset = this.paras.length > 0 ? this.paras[0]!.charStart : 0
  }

  get totalChars(): number {
    const last = this.paras[this.paras.length - 1]
    return last ? last.charEnd : 0
  }

  currentChapterIndex(): number {
    if (this.chapters.length === 0) return 0
    return chapterIndexOfPara(this.chapters, paragraphAt(this.paras, this.offset))
  }

  currentChapterTitle(): string {
    return this.chapters[this.currentChapterIndex()]?.title ?? ''
  }

  /** 章内位置比例（供同步用；与手机端 `posRatio` 同口径：本端段落粒度） */
  currentPosRatio(): number {
    if (this.paras.length === 0) return -1
    return posRatioInChapter(this.chapters, paragraphAt(this.paras, this.offset))
  }

  // ── 模式与排版（都只重排、不换位置）──────────────────────────────────────
  /**
   * 单源目录到位后**重建章节**，并保持当前阅读位置。
   *
   * 为什么需要它：目录是异步拿的（`GET /toc` 要手机端打开过这本书才会发布标题）。页面打开时
   * 拿不到就退回本地正则切分 ⇒ 电脑的章号会和手机差几章（**用户实测 58 vs 60 就是这个原因**）。
   * 所以策略是：先能读，**拿到目录后热替换**。位置保持靠 `charOffset` —— 换的是"章"的边界，
   * 段落偏移不变 ⇒ 直接重新锚定即可（这正是 v3 位置模型的收益）。
   * @returns 是否成功升级
   */
  rechapter(toc: TocEntry[]): boolean {
    const chs = chaptersFromToc(this.paras, toc)
    if (chs === null || chs.length === 0) {
      return false
    }
    const keep = this.offset
    this.chapters = chs
    if (this.mode === 'scroll') {
      this.updateProgress()
      return true
    }
    this.renderChapterForOffset(keep)
    this.relayoutAndAnchor()
    return true
  }

  setMode(m: Mode, scrollIntoView = true): void {
    const keep = this.offset
    this.mode = m
    const isPage = m !== 'scroll'
    this.el.sc.classList.toggle('on', !isPage)
    this.el.stg.classList.toggle('on', isPage)
    this.el.stg.classList.toggle('two', m === 'page2')
    this.el.stg.classList.toggle('shadow', m === 'page2')
    this.applyTypography()
    if (isPage) {
      this.renderChapterForOffset(keep)
      this.relayoutAndAnchor()
    } else {
      this.el.pg.style.transform = 'none'
      this.ensure(this.paragraphAt(keep) + 120)
      if (scrollIntoView) this.scrollToOffset(keep)
      this.updateProgress()
    }
  }

  applyTypography(): void {
    const root = document.documentElement
    root.style.setProperty('--page-font', this.fontSize + 'px')
    root.style.setProperty('--page-lh', String(this.lineHeight))
    const two = this.mode === 'page2'
    root.style.setProperty('--col-gap', (two ? 64 : 44) + 'px')
    document.body.className = this.theme + (document.body.classList.contains('hide') ? ' hide' : '')
  }

  /** 字号/行距/主题改变：重排 + **按偏移重新锚定**（旧实现这里会丢位置） */
  reflow(): void {
    this.applyTypography()
    if (this.mode === 'scroll') {
      this.scrollToOffset(this.offset)
      this.updateProgress()
    } else {
      this.relayoutAndAnchor()
    }
  }

  // ── 滚动模式 ────────────────────────────────────────────────────────────
  private paragraphAt(offset: number): number {
    return paragraphAt(this.paras, Math.max(0, offset))
  }

  /** 增量渲染到第 n 段（旧实现的 ensure(n) 同款，避免一次插入整本书） */
  ensure(n: number): void {
    const to = Math.max(0, Math.min(this.paras.length, n))
    if (to <= this.rendered) return
    let html = ''
    for (let i = this.rendered; i < to; i++) {
      html += '<p>' + escapeHtml(this.paras[i]!.text) + '</p>'
    }
    this.el.si.insertAdjacentHTML('beforeend', html)
    this.rendered = to
    this.el.more.style.display = this.rendered < this.paras.length ? 'block' : 'none'
  }

  private scrollToOffset(offset: number): void {
    const i = this.paragraphAt(offset)
    this.ensure(i + 120)
    const node = this.el.si.children[i] as HTMLElement | undefined
    if (node) {
      this.el.sc.scrollTop = Math.max(0, node.offsetTop - 20)
    }
    this.offset = i < this.paras.length ? this.paras[i]!.charStart : this.offset
  }

  /** 滚动时把"顶部可见段"回写成唯一位置（节流后由 UI 调用） */
  syncOffsetFromScroll(): void {
    if (this.mode !== 'scroll') return
    const top = this.el.sc.scrollTop + 24
    const kids = this.el.si.children
    let i = this.rendered - 1
    for (let k = 0; k < kids.length; k++) {
      const e = kids[k] as HTMLElement
      if (e.offsetTop >= top) {
        i = k
        break
      }
    }
    // 接近底部 ⇒ 继续加载
    if (this.el.sc.scrollTop + this.el.sc.clientHeight > this.el.sc.scrollHeight - 700) {
      this.ensure(this.rendered + 300)
    }
    if (i >= 0 && i < this.paras.length) {
      this.offset = this.paras[i]!.charStart
    }
    this.updateProgress()
  }

  onScroll(): void {
    if (this.mode !== 'scroll') return
    this.syncOffsetFromScroll()
    this.maybePush()
  }

  // ── 分页模式 ────────────────────────────────────────────────────────────
  private renderChapterForOffset(offset: number): void {
    if (this.chapters.length === 0) return
    const pi = this.paragraphAt(offset)
    const k = chapterIndexOfPara(this.chapters, pi)
    this.renderChapter(k)
  }

  private renderChapter(k: number): void {
    if (this.chapters.length === 0) return
    const idx = Math.max(0, Math.min(this.chapters.length - 1, k))
    const c = this.chapters[idx]!
    this.chapterParaFrom = c.paraFrom
    this.pgParas = this.paras.slice(c.paraFrom, c.paraTo)
    let html = ''
    for (const p of this.pgParas) {
      html += '<p>' + escapeHtml(p.text) + '</p>'
    }
    this.el.pg.innerHTML = html
  }

  /** 列宽/步长 + 页映射 + **按偏移重新锚定**（B3 的根治点） */
  private relayoutAndAnchor(): void {
    if (this.mode === 'scroll') return
    this.layoutColumns()
    const kids = this.el.pg.children
    const lefts: number[] = []
    for (let i = 0; i < kids.length; i++) {
      lefts.push((kids[i] as HTMLElement).offsetLeft)
    }
    this.pageMap = buildPageMap(lefts, this.stride, this.pgParas.length)
    const localPara = this.paragraphAt(this.offset) - this.chapterParaFrom
    const target = localPara >= 0 && localPara < this.pgParas.length ? localPara : 0
    this.applyPage(pageOfPara(this.pageMap, target))
  }

  private layoutColumns(): void {
    const two = this.mode === 'page2'
    const gap = two ? 64 : 44
    const per = two ? 2 : 1
    const width = Math.max(120, Math.floor((this.el.stg.clientWidth - 68 - gap * (per - 1)) / per))
    this.el.pg.style.columnGap = gap + 'px'
    this.el.pg.style.columnWidth = width + 'px'
    this.stride = width + gap
  }

  private applyPage(page: number): void {
    const two = this.mode === 'page2'
    this.pageIdx = snapPage(Math.max(0, Math.min(this.pageMap.pageCount - 1, page)), two)
    if (two && this.pageIdx >= this.pageMap.pageCount) {
      this.pageIdx = snapPage(this.pageMap.pageCount - 1, true)
    }
    this.el.pg.style.transform = 'translateX(-' + this.pageIdx * this.stride + 'px)'
    // 位置 = 当前页首段的字符偏移（页号只是派生 ⇒ 布局变了也不会漂）
    const firstPara = firstParaOfPage(this.pageMap, this.pageIdx)
    const p = this.pgParas[firstPara]
    if (p) this.offset = p.charStart
    this.updateProgress()
  }

  /** **统一翻页入口**：点击左右 / 方向键 / 滚轮 / 按钮全部走这里 */
  turnPage(delta: number): void {
    if (this.paras.length === 0) return
    if (this.mode === 'scroll') {
      this.el.sc.scrollBy({ top: delta * this.el.sc.clientHeight * 0.86, behavior: 'smooth' })
      return
    }
    const step = this.mode === 'page2' ? 2 : 1
    const target = this.pageIdx + delta * step
    if (target >= 0 && target < this.pageMap.pageCount) {
      this.applyPage(target)
      this.maybePush()
      return
    }
    // 跨章：按**字符偏移**落到下一章首 / 上一章末（不再用"第 0 页 / 最后一页"这种布局相关写法）
    const k = this.currentChapterIndex()
    if (delta > 0) {
      const next = this.chapters[k + 1]
      if (next) this.goToOffset(next.charStart)
      else this.applyPage(this.pageMap.pageCount - 1)
    } else {
      const prev = this.chapters[k - 1]
      if (prev) this.goToOffset(Math.max(0, prev.charEnd - 1))
      else this.applyPage(0)
    }
    this.maybePush()
  }

  /** 跳到指定字符偏移（唯一入口；跨章会自动换渲染章） */
  goToOffset(offset: number): void {
    if (this.paras.length === 0) return
    const off = Math.max(0, Math.min(this.totalChars, Math.floor(offset)))
    // ⚠️ 必须**先**记住"当前渲染的是哪一章"，再改 offset —— 否则 `currentChapterIndex()`
    //    已经是新章，跨章判断恒为 false ⇒ 永不重渲染（自审发现，旧内嵌实现也有同类毛病）。
    const prevChapter = this.chapters.length > 0
      ? chapterIndexOfPara(this.chapters, this.paragraphAt(this.offset))
      : 0
    this.offset = off
    if (this.mode === 'scroll') {
      this.scrollToOffset(off)
      this.updateProgress()
      return
    }
    const wantChapter = chapterIndexOfPara(this.chapters, this.paragraphAt(off))
    if (wantChapter !== prevChapter) {
      this.renderChapter(wantChapter)
    }
    this.relayoutAndAnchor()
    this.maybePush()
  }

  /** 跳到某章（目录/搜索用） */
  goToChapter(k: number): void {
    const c = this.chapters[Math.max(0, Math.min(this.chapters.length - 1, k))]
    if (c) this.goToOffset(c.charStart)
  }

  // ── 进度显示 ────────────────────────────────────────────────────────────
  updateProgress(): void {
    const total = this.totalChars
    const pct = total > 0 ? Math.round((this.offset / total) * 100) : 0
    this.el.pct.textContent = Math.max(0, Math.min(100, pct)) + '%'
    const k = this.currentChapterIndex()
    const chLabel = this.chapters.length > 0 ? '第 ' + (k + 1) + '/' + this.chapters.length + ' 章 · ' : ''
    if (this.mode === 'scroll') {
      this.el.modeTag.textContent = chLabel + '滚动模式'
    } else {
      const totalPages = Math.max(1, this.pageMap.pageCount)
      const cur = this.mode === 'page2' ? Math.min(totalPages, this.pageIdx + 2) : this.pageIdx + 1
      this.el.modeTag.textContent = chLabel + '页 ' + cur + '/' + totalPages + (this.mode === 'page2' ? '（双页）' : '')
    }
  }

  // ── 同步载荷 ────────────────────────────────────────────────────────────
  /** 当前可见范围的首/末段（页模式=当前跨页；滚动=视口顶/底） */
  private visibleParas(): { top: Para | null; bot: Para | null } {
    if (this.paras.length === 0) return { top: null, bot: null }
    if (this.mode === 'scroll') {
      const top = this.paragraphAt(this.offset)
      const bot = Math.min(this.paras.length - 1, top + 8)
      return { top: this.paras[top] ?? null, bot: this.paras[bot] ?? null }
    }
    const per = this.mode === 'page2' ? 2 : 1
    const from = firstParaOfPage(this.pageMap, this.pageIdx)
    const nextSpread = this.pageIdx + per
    const to = nextSpread < this.pageMap.pageCount
      ? firstParaOfPage(this.pageMap, nextSpread)
      : this.pgParas.length
    const top = this.pgParas[from] ?? null
    const bot = this.pgParas[Math.max(from, to - 1)] ?? null
    return { top, bot }
  }

  currentPos(): SyncPos {
    const v = this.visibleParas()
    const top = v.top
    const bot = v.bot
    const k = this.currentChapterIndex()
    return {
      v: 2,
      // seq 由手机端 `stamp()` 统一分配（手机进程是唯一共享点）；这里给 0 当占位
      seq: 0,
      chTitle: this.currentChapterTitle(),
      chIndex: k,
      chCount: this.chapters.length,
      ratio: chapterRatio(this.chapters, k),
      topEx: top ? top.text.slice(0, 40) : '',
      botEx: bot ? bot.text.slice(-40) : '',
      posRatio: this.currentPosRatio(),
      ts: Date.now(),
      writer: 'web:' + this.webId
    }
  }

  /** 换章即刻推、同章 5s 一推（与旧实现同节奏） */
  maybePush(force = false): void {
    const now = Date.now()
    const title = this.currentChapterTitle()
    const changed = title !== this.lastPushedTitle
    if (!force && !changed && now - this.lastPushAt < 5000) return
    this.lastPushAt = now
    this.lastPushedTitle = title
    this.onPush?.(this.currentPos())
  }

  /** 由 UI 注入（发 HTTP）；引擎不直接依赖网络，便于测试 */
  onPush: ((pos: SyncPos) => void) | null = null

  // ── 远端定位（四级：标题 → 比例 → 文本 → 章内比例）──────────────────────
  jumpToRemote(pos: SyncPos): { by: string; ok: boolean } {
    if (this.paras.length === 0) return { by: 'none', ok: false }
    let k = findChapterByTitle(this.chapters, pos.chTitle)
    let by = 'title'
    if (k < 0 && pos.ratio >= 0 && this.chapters.length > 0) {
      k = Math.max(0, Math.min(this.chapters.length - 1, Math.round(clampRatio(pos.ratio) * (this.chapters.length - 1))))
      by = 'ratio'
    }
    if (k < 0) return { by: 'none', ok: false }
    const c = this.chapters[k]!
    // 文本锚优先（限定在本章内找；多个命中取离"章内比例推算位置"最近的）
    const key = excerptKey(pos.topEx)
    const targetLocal = pos.posRatio >= 0
      ? Math.round(clampRatio(pos.posRatio) * Math.max(0, c.paraTo - c.paraFrom - 1))
      : -1
    if (key !== '') {
      let best = -1
      let bestDist = -1
      for (let i = c.paraFrom; i < c.paraTo; i++) {
        const hit = this.paras[i]!.text.replace(/\s+/g, '').indexOf(key)
        if (hit < 0) continue
        const dist = targetLocal >= 0 ? Math.abs((i - c.paraFrom) - targetLocal) : 0
        if (best < 0 || dist < bestDist) {
          best = i
          bestDist = dist
          if (targetLocal >= 0 && dist === 0) break
        }
      }
      if (best >= 0) {
        this.goToOffset(this.paras[best]!.charStart)
        return { by: 'text', ok: true }
      }
    }
    if (targetLocal >= 0) {
      const i = Math.min(c.paraTo - 1, c.paraFrom + targetLocal)
      this.goToOffset(this.paras[i]!.charStart)
      return { by: 'posRatio', ok: true }
    }
    this.goToOffset(c.charStart)
    return { by, ok: true }
  }

  /** 搜索：从当前位置往后找第一处命中（跨章），找不到返回 -1 */
  findNext(query: string): number {
    const q = query.replace(/\s+/g, '')
    if (q === '') return -1
    const start = this.paragraphAt(this.offset) + 1
    for (let i = start; i < this.paras.length; i++) {
      if (this.paras[i]!.text.replace(/\s+/g, '').indexOf(q) >= 0) return i
    }
    return -1
  }

  /** 供 UI/测试查询 */
  get currentOffset(): number {
    return this.offset
  }

  get paragraphCount(): number {
    return this.paras.length
  }

  get chapterCount(): number {
    return this.chapters.length
  }

  get currentPageIndex(): number {
    return this.pageIdx
  }

  get currentPageCount(): number {
    return this.pageMap.pageCount
  }

  /** 当前偏移所在的段落下标（书签 webKey、搜索、测试都用它） */
  paragraphAtOffset(offset = this.offset): number {
    return this.paragraphAt(offset)
  }

  /** 滚动一屏的百分比（键盘/滚轮共用；分页模式则转成翻页） */
  scrollStep(factor: number): void {
    if (this.mode !== 'scroll') {
      this.turnPage(factor > 0 ? 1 : -1)
      return
    }
    this.el.sc.scrollBy({ top: factor * this.el.sc.clientHeight * 0.86, behavior: 'smooth' })
  }

  /** 供 UI 判断是否需要"上滑加载更多" */
  get renderedCount(): number {
    return this.rendered
  }
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
