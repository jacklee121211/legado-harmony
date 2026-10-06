/**
 * ui.ts —— DOM 绑定（工具栏 / 目录 / 书签 / 搜索 / 同步提示条 / 手势）
 * ============================================================================
 * 与旧内嵌实现的区别（都是"少一类 bug"的来源）：
 *   · **不用内联 onclick**：全部 addEventListener ⇒ 有类型检查，不可能再出现
 *     "引用了不存在的变量导致 handler 第一行抛异常"（审计 B1：`if(flipping)return;`）。
 *   · **手势/键盘/滚轮/按钮全部调 `reader.turnPage(±1)`**：一份边界逻辑，
 *     不可能出现"点击一套、键盘一套、按钮又一套"的错位。
 */
import { Reader } from './reader.ts'
import { Store, LINE_HEIGHTS, FONT_MIN, FONT_MAX } from './store.ts'
import { excerptKey, pickPending } from './protocol.ts'
import type { SyncPos, MarkRow } from './protocol.types.ts'
import type { Mode } from './reader.types.ts'
import { fetchMarks, addMark, delMark, fetchPhoneSync, pushWebPos } from './api.ts'

function $(sel: string): HTMLElement {
  const e = document.querySelector(sel)
  if (!e) throw new Error('缺少 DOM 节点: ' + sel)
  return e as HTMLElement
}

const MODE_LABEL: Record<Mode, string> = { scroll: '滚动', page1: '单页', page2: '双页' }
const MODE_NEXT: Record<Mode, Mode> = { scroll: 'page1', page1: 'page2', page2: 'scroll' }

export interface UiDeps {
  reader: Reader
  store: Store
  title: string
}

export class Ui {
  private readonly r: Reader
  private readonly store: Store
  private readonly title: string
  /** 当前提示条指向的手机位置（点击按钮时消费它） */
  private pending: { id: string; pos: SyncPos } | null = null
  private lastTurnAt = 0
  private marks: MarkRow[] = []
  private saveTimer: number | null = null

  constructor(deps: UiDeps) {
    this.r = deps.reader
    this.store = deps.store
    this.title = deps.title
    $('#bookTitle').textContent = deps.title
  }

  bind(): void {
    // ── 工具栏 ────────────────────────────────────────────────────────────
    $('#btnToc').addEventListener('click', () => this.toggleToc())
    $('#btnTocClose').addEventListener('click', () => this.toggleToc(false))
    $('#mask').addEventListener('click', () => this.toggleToc(false))
    $('#btnFind').addEventListener('click', () => $('#find').classList.toggle('open'))
    $('#btnMark').addEventListener('click', () => void this.addBookmark())
    $('#btnFontDown').addEventListener('click', () => this.changeFont(-1))
    $('#btnFontUp').addEventListener('click', () => this.changeFont(1))
    $('#btnLineHeight').addEventListener('click', () => this.cycleLineHeight())
    $('#btnTheme').addEventListener('click', () => this.cycleTheme())
    $('#btnMode').addEventListener('click', () => this.cycleMode())
    $('#exit').addEventListener('click', () => this.toggleFullscreen())
    $('#tabChapters').addEventListener('click', () => this.switchTab('chapters'))
    $('#tabBookmarks').addEventListener('click', () => this.switchTab('bookmarks'))
    $('#tq').addEventListener('input', () => this.filterChapters())

    const fq = $('#fq') as HTMLInputElement
    fq.addEventListener('keydown', (e: KeyboardEvent) => {
      if (e.key !== 'Enter') return
      const i = this.r.findNext(fq.value)
      if (i < 0) {
        this.tip('没有找到：' + fq.value)
        return
      }
      this.r.goToOffset(this.r.paras[i]!.charStart)
    })

    // ── 翻页手势（点击左右三分区 / 中间切工具栏）────────────────────────────
    const stage = $('#stage')
    stage.addEventListener('click', (e: MouseEvent) => {
      const third = window.innerWidth / 3
      if (e.clientX < third) this.turn(-1)
      else if (e.clientX > third * 2) this.turn(1)
      else this.toggleFullscreen()
    })
    const scroll = $('#scroll')
    scroll.addEventListener('click', (e: MouseEvent) => {
      const h = window.innerHeight
      if (e.clientY < h * 0.1 || e.clientY > h * 0.9) this.toggleFullscreen()
    })

    // ── 键盘 ──────────────────────────────────────────────────────────────
    window.addEventListener('keydown', (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement) return
      if (e.key === 'ArrowLeft' || e.key === 'PageUp') {
        this.turn(-1)
      } else if (e.key === 'ArrowRight' || e.key === 'PageDown') {
        this.turn(1)
      } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        this.r.scrollStep(e.key === 'ArrowUp' ? -0.86 : 0.86)
      } else if (e.key === 'Escape') {
        this.toggleToc(false)
      }
    })

    // ── 滚轮（PC 主要交互；旧实现没有 ⇒ 一次滚动跳过整章）──────────────────
    window.addEventListener(
      'wheel',
      (e: WheelEvent) => {
        if (this.r.mode === 'scroll') {
          if (e.target instanceof HTMLInputElement) return
          this.r.scrollStep(e.deltaY > 0 ? 0.86 : -0.86)
          return
        }
        if (e.target instanceof HTMLInputElement) return
        const now = Date.now()
        if (now - this.lastTurnAt < 260) return
        this.lastTurnAt = now
        this.turn(e.deltaY > 0 ? 1 : -1)
      },
      { passive: true }
    )

    // ── 滚动同步位置 + 窗口变化重排（都是"只重排不换位置"）─────────────────
    $('#scroll').addEventListener('scroll', () => this.r.onScroll(), { passive: true })
    window.addEventListener('resize', () => this.r.reflow())
    window.addEventListener('beforeunload', () => this.saveNow())

    // ── 同步提示条 ────────────────────────────────────────────────────────
    $('#btnJumpTop').addEventListener('click', () => this.jumpPending('top'))
    $('#btnJumpBot').addEventListener('click', () => this.jumpPending('bot'))
    $('#btnIgnore').addEventListener('click', () => this.ignorePending())

    // 发位置给手机（引擎只回调，不直接依赖网络）
    this.r.onPush = (pos: SyncPos): void => {
      void pushWebPos(this.r.id, this.r.webId, pos)
    }

    // 位置定期落盘（唯一位置 = charOffset）
    this.saveTimer = window.setInterval(() => this.saveNow(), 3000)
    this.applyModeLabel()
  }

  // ── 翻页（唯一入口）──────────────────────────────────────────────────────
  private turn(delta: number): void {
    this.r.turnPage(delta)
    this.saveNow()
  }

  private saveNow(): void {
    this.store.saveOffset(this.r.currentOffset)
  }

  // ── 排版 ────────────────────────────────────────────────────────────────
  private changeFont(d: number): void {
    const f = Math.max(FONT_MIN, Math.min(FONT_MAX, this.r.fontSize + d))
    if (f === this.r.fontSize) return
    this.r.fontSize = f
    this.r.reflow()
    this.saveSettings()
  }

  private cycleLineHeight(): void {
    const i = LINE_HEIGHTS.indexOf(this.r.lineHeight as 1.6)
    this.r.lineHeight = LINE_HEIGHTS[(i + 1) % LINE_HEIGHTS.length]!
    this.r.reflow()
    this.saveSettings()
  }

  private cycleTheme(): void {
    const next = { day: 'sepia', sepia: 'night', night: 'day' } as const
    this.r.theme = next[this.r.theme]
    this.r.applyTypography()
    this.saveSettings()
  }

  private cycleMode(): void {
    const m = MODE_NEXT[this.r.mode]
    this.r.setMode(m)
    this.applyModeLabel()
    this.saveSettings()
    this.saveNow()
  }

  private applyModeLabel(): void {
    $('#btnMode').textContent = MODE_LABEL[this.r.mode]
    $('#tabChapters').classList.toggle('on', true)
  }

  private saveSettings(): void {
    this.store.saveSettings({
      fontSize: this.r.fontSize,
      lineHeight: this.r.lineHeight,
      theme: this.r.theme,
      mode: this.r.mode
    })
  }

  private toggleFullscreen(): void {
    document.body.classList.toggle('hide')
    this.r.reflow()
  }

  // ── 目录 / 书签抽屉 ─────────────────────────────────────────────────────
  private toggleToc(open?: boolean): void {
    const el = $('#toc')
    const want = open === undefined ? !el.classList.contains('open') : open
    el.classList.toggle('open', want)
    $('#mask').classList.toggle('open', want)
    if (want) {
      this.renderChapterList()
      void this.reloadMarks()
    }
  }

  private switchTab(which: 'chapters' | 'bookmarks'): void {
    const isCh = which === 'chapters'
    $('#tabChapters').classList.toggle('on', isCh)
    $('#tabBookmarks').classList.toggle('on', !isCh)
    $('#chapterList').style.display = isCh ? 'block' : 'none'
    $('#bookmarkList').style.display = isCh ? 'none' : 'block'
    if (!isCh) void this.reloadMarks()
  }

  private renderChapterList(filter = ''): void {
    const list = $('#chapterList')
    const f = filter.trim()
    let html = ''
    for (let i = 0; i < this.r.chapters.length; i++) {
      const c = this.r.chapters[i]!
      if (f !== '' && c.title.indexOf(f) < 0) continue
      const cur = i === this.r.currentChapterIndex() ? ' style="color:#0A84FF;font-weight:700"' : ''
      html += '<div class="ch" data-ch="' + i + '"' + cur + '>' + escape(c.title) + '</div>'
    }
    list.innerHTML = html || '<div class="ch">（无匹配章节）</div>'
    list.querySelectorAll('.ch').forEach((el) => {
      el.addEventListener('click', () => {
        const k = Number((el as HTMLElement).dataset['ch'] ?? '-1')
        if (k >= 0) {
          this.r.goToChapter(k)
          this.saveNow()
          this.toggleToc(false)
        }
      })
    })
  }

  private filterChapters(): void {
    this.renderChapterList(($('#tq') as HTMLInputElement).value)
  }

  private async reloadMarks(): Promise<void> {
    this.marks = await fetchMarks(this.r.id)
    const list = $('#bookmarkList')
    if (this.marks.length === 0) {
      list.innerHTML = '<div class="ch">（还没有书签）</div>'
      return
    }
    let html = ''
    for (const m of this.marks) {
      const head = String(m.chapterName || m.content || '').slice(0, 22)
      const sub = String(m.bookText || '').slice(0, 24)
      html +=
        '<div class="ch" data-time="' + m.time + '"><span>' + escape(head) +
        '</span><span class="sub">' + escape(sub) + '</span>' +
        '<button class="del" data-del="' + m.time + '">删</button></div>'
    }
    list.innerHTML = html
    list.querySelectorAll<HTMLElement>('.ch').forEach((row) => {
      row.addEventListener('click', (e) => {
        if ((e.target as HTMLElement).dataset['del'] !== undefined) return
        const t = Number(row.dataset['time'] ?? '0')
        const m = this.marks.find((x) => x.time === t)
        if (!m) return
        this.jumpToMark(m)
        this.toggleToc(false)
      })
    })
    list.querySelectorAll<HTMLElement>('.del').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        const t = Number(btn.dataset['del'] ?? '0')
        void delMark(t).then(() => this.reloadMarks())
      })
    })
  }

  /** 书签跳转：网页书签用 webKey（含段号）精确定位；手机书签用 bookText 文本锚 */
  private jumpToMark(m: MarkRow): void {
    const ck = m.content
    if (ck !== '') {
      const parts = ck.split('#')
      const title = parts[0] ?? ''
      const key = excerptKey(parts[2] ?? m.bookText, 20)
      const k = this.r.chapters.findIndex((c) => c.title === title)
      if (k >= 0 && key !== '') {
        const c = this.r.chapters[k]!
        for (let i = c.paraFrom; i < c.paraTo; i++) {
          if (this.r.paras[i]!.text.replace(/\s+/g, '').indexOf(key) >= 0) {
            this.r.goToOffset(this.r.paras[i]!.charStart)
            this.saveNow()
            return
          }
        }
        this.r.goToChapter(k)
        this.saveNow()
        return
      }
    }
    const r = this.r.jumpToRemote({
      v: 1, seq: 0, chTitle: m.chapterName, chIndex: -1, chCount: 0, ratio: -1,
      topEx: m.bookText, botEx: '', posRatio: -1, ts: 1, writer: 'bookmark'
    })
    if (!r.ok) this.tip('该章节未匹配到')
    this.saveNow()
  }

  private async addBookmark(): Promise<void> {
    const pos = this.r.currentPos()
    const paraIdx = this.r.paragraphAtOffset()
    const webKey = pos.chTitle + '#' + paraIdx + '#' + (pos.topEx.slice(0, 10))
    const res = await addMark({
      id: this.r.id,
      webKey,
      chapterName: pos.chTitle,
      bookText: pos.topEx.slice(0, 10),
      chTitle: pos.chTitle,
      posRatio: pos.posRatio
    })
    this.tip(res.msg === 'exists' ? '该位置已有书签' : res.ok ? '书签已添加（手机同步）' : '添加失败')
    if (this.tocOpen()) void this.reloadMarks()
  }

  private tocOpen(): boolean {
    return $('#toc').classList.contains('open')
  }

  // ── 同步提示条 ──────────────────────────────────────────────────────────
  /**
   * 轮询手机位置：值得提示才弹条。三条规则都在 `protocol.pickPending`（有单测）：
   *   R1 中继站——最新进度不在手机 ⇒ 不弹（"谁最新谁不弹"）；
   *   R2 序号水位——我已消费过的不再弹；
   *   R3 同章阈值——同一页附近不打扰，只推进水位。
   */
  async poll(): Promise<void> {
    const { pos, latestWriter } = await fetchPhoneSync(this.r.id)
    if (!pos) return
    const seen = this.store.seenPhoneSeq()
    const pending = pickPending(
      { phone: pos },
      { phone: seen },
      this.r.currentChapterTitle(),
      this.r.currentPosRatio(),
      Date.now(),
      latestWriter,
      // 这里比较的是**另一台设备（手机）的时钟**：手机快十几分钟是常见情况，而排序早已改用
      // seq（与时钟无关）⇒ 这个上限只用来拦真正的坏数据，故放宽到 24h。
      // （手机端检查的是被服务端盖过章的位置，ts 就是手机自己的时钟 ⇒ 那边保留 5 分钟。）
      24 * 60 * 60 * 1000
    )
    if (!pending) return
    this.pending = pending
    const top = excerptKey(pos.topEx, 14)
    const bot = excerptKey(pos.botEx, 14)
    const who = latestWriter === 'phone' ? '（最新进度：手机）' : ''
    $('#synctxt').innerHTML = '手机进度' + who + '：<br>① ' + escape(top) + '<br>② ' + escape(bot)
    $('#btnJumpTop').style.display = pos.topEx !== '' ? 'block' : 'none'
    $('#btnJumpBot').style.display = pos.botEx !== '' ? 'block' : 'none'
    $('#syncbar').classList.add('show')
  }

  private jumpPending(which: 'top' | 'bot'): void {
    const p = this.pending
    if (!p) return
    const pos: SyncPos = which === 'top'
      ? p.pos
      : { ...p.pos, topEx: p.pos.botEx, posRatio: -1 }
    const r = this.r.jumpToRemote(pos)
    this.store.setSeenPhoneSeq(p.pos.seq)
    this.pending = null
    $('#syncbar').classList.remove('show')
    if (!r.ok) this.tip('未能定位该进度')
    this.saveNow()
  }

  private ignorePending(): void {
    const p = this.pending
    // 忽略 = 消费这一版（水位推进到它的 seq）。语义（用户确认）：
    // 对方**再有新的**进展会重新提示 —— 否则电脑永远不知道手机后来读到哪，同步等于失效。
    if (p) this.store.setSeenPhoneSeq(p.pos.seq)
    this.pending = null
    $('#syncbar').classList.remove('show')
  }

  /** 目录来源指示（手机单源目录 / 本地正则回退）—— "58 vs 60" 那类问题一眼可见 */
  setTocSource(src: 'phone' | 'local'): void {
    const el = document.getElementById('tocTag')
    if (!el) return
    el.textContent = src === 'phone' ? '目录：手机同步' : '目录：本地切分'
    el.style.color = src === 'phone' ? '#24B277' : '#E0A020'
    console.info('[toc] source =', src)
  }

  tip(text: string): void {
    $('#synctxt').textContent = text
    $('#btnJumpTop').style.display = 'none'
    $('#btnJumpBot').style.display = 'none'
    $('#syncbar').classList.add('show')
    window.setTimeout(() => $('#syncbar').classList.remove('show'), 2200)
  }

  dispose(): void {
    if (this.saveTimer !== null) window.clearInterval(this.saveTimer)
    this.saveNow()
  }
}

function escape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
