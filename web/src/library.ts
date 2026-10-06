/**
 * library.ts —— 电脑阅读·书库页（从旧内嵌页搬迁，行为不变）
 * 数据来自手机端 `GET /books`（书库列表）⇒ 服务端不再拼字符串。
 * 2026-10-06 无 Cookie 化：请求与页面内链接都带 `dt=<token>`（localStorage 里的设备令牌），
 * 纯导航（阅读/下载）不带请求头 ⇒ 令牌必须走 URL。
 */
import './pages.css'
import { authed, deviceToken } from './api.ts'

interface BookRow {
  id: number
  name: string
  /**
   * 是否 txt。
   * ⚠️ 2026-10-06：服务端不再下发沙箱绝对路径（`url`）——那是内部路径泄露（审计 P2）
   * ⇒ 现在优先看新字段 `isTxt`；老服务端仍会给 `url`，这里做兼容判断。
   */
  isTxt?: boolean
  url?: string
  sizeKB: number
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

async function load(): Promise<void> {
  const list = document.getElementById('list')
  const sub = document.getElementById('sub')
  if (!list) return
  try {
    const r = await fetch(authed('/books'))
    const raw = (await r.json()) as BookRow[]
    const books = Array.isArray(raw) ? raw.filter((b) => b && typeof b.name === 'string') : []
    if (sub) sub.textContent = `手机书架上的本地书（${books.length} 本）— txt 可直接阅读`
    if (books.length === 0) {
      list.innerHTML = '<div class="empty">书架还没有本地书籍，先去 <a href="/">传书</a></div>'
      return
    }
    const dt = deviceToken()
    const qs = dt !== '' ? '&dt=' + dt : ''
    list.innerHTML = books
      .map((b) => {
        const isTxt = typeof b.isTxt === 'boolean' ? b.isTxt : String(b.url ?? '').toLowerCase().endsWith('.txt')
        const action = isTxt
          ? `<a class="rd" href="/read?id=${b.id}${qs}">阅读</a><a class="dl" href="/download?id=${b.id}${qs}">下载</a>`
          : `<a class="dl" href="/download?id=${b.id}${qs}">下载 epub</a>`
        return (
          `<div class="it"><div class="ico">${isTxt ? 'TXT' : 'EPUB'}</div>` +
          `<div class="meta"><div class="nm">${esc(b.name)}</div><div class="sz">${b.sizeKB} KB</div></div>` +
          `${action}</div>`
        )
      })
      .join('')
  } catch (err) {
    list.innerHTML = '<div class="empty">读取书库失败：' + esc(String(err)) + '（手机端 Web 服务可能已停止）</div>'
  }
}

void load()
