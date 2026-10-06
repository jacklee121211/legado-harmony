/**
 * main.ts —— 引导：取书 → 建模型（优先手机端单源目录）→ 恢复"唯一位置" → 渲染 → 绑定 UI
 * 位置模型见 reader.ts 头注释；目录见 model.ts `chaptersFromToc`。
 */
import './styles.css'
import { Store } from './store.ts'
import { Reader } from './reader.ts'
import { Ui } from './ui.ts'
import { fetchBook, fetchTocTitles, fetchTitle } from './api.ts'
import { locateToc } from './toc.ts'

function queryId(): number {
  const q = new URLSearchParams(location.search)
  const raw = q.get('id') ?? location.pathname.replace(/[^0-9]/g, '')
  const id = parseInt(raw, 10)
  return Number.isFinite(id) ? id : 1
}

async function boot(): Promise<void> {
  const id = queryId()
  const store = new Store(id)
  const settings = store.settings()

  const reader = new Reader({ id, webId: store.webId() })
  reader.fontSize = settings.fontSize
  reader.lineHeight = settings.lineHeight
  reader.theme = settings.theme

  // 正文、目录标题、书名并发取。
  // 单源目录（M3）：手机端只发布**标题**，字符区间**在这里**算 —— 用的就是下面这份正文
  // ⇒ 不存在"偏移算在一串、渲染另一串"的口径风险；失败/为空自动回退本地正则切分。
  const [raw, titles, title] = await Promise.all([fetchBook(id), fetchTocTitles(id), fetchTitle(id)])
  const toc = locateToc(raw, titles)
  reader.setBook(raw, toc)

  const ui = new Ui({ reader, store, title: title !== '' ? title : '未命名' })
  ui.bind()
  ui.setTocSource(toc.length > 0 ? 'phone' : 'local')

  /**
   * 目录"迟到"时的自动升级：手机端要**打开过这本书**才会发布标题快照，
   * 所以电脑先开页面时常常拿不到 ⇒ 页面先用本地切分（章号会与手机不一致，
   * 用户实测 58 vs 60 就是这个原因），拿到标题后**热替换章节并保持位置**。
   * 触发时机：开页后每 10s 试一次（最多 12 次）+ 页面重新可见时立刻试。
   */
  if (toc.length === 0) {
    let tries = 0
    const upgrade = async (): Promise<boolean> => {
      const t = locateToc(raw, await fetchTocTitles(id))
      if (t.length === 0) return false
      if (!reader.rechapter(t)) return false
      ui.setTocSource('phone')
      return true
    }
    const timer = window.setInterval(() => {
      tries++
      void upgrade().then((okUpgraded) => {
        if (okUpgraded || tries >= 12) window.clearInterval(timer)
      })
    }, 10000)
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) void upgrade().then((okUpgraded) => {
        if (okUpgraded) window.clearInterval(timer)
      })
    })
  }

  // 恢复唯一位置：store 里没有（-1）⇒ 从书首开始
  const saved = store.offset()
  reader.setMode(settings.mode, false)
  reader.goToOffset(saved >= 0 ? saved : 0)
  // ⚠️ 必须在 setMode **之后**再刷按钮文字：`ui.bind()` 早于 setMode，
  //    否则按钮停在兜底值（实测引擎 mode=page2、按钮却显示"滚动"，会误导用户）。
  ui.syncModeLabel()

  // 双端同步：5s 轮询手机位置（提示条）；位置驱动在引擎内（换章即刻推、同章 5s）
  const poll = (): void => {
    if (document.hidden) return
    void ui.poll()
  }
  poll()
  window.setInterval(poll, 5000)

  // 首帧可能因字体加载/列宽测量而未定 ⇒ 再锚定一次（只重排，不换位置）
  window.setTimeout(() => reader.reflow(), 120)

  /**
   * 调试/自检句柄：**仅在 `?probe=1` 时挂出**（正常阅读路径不创建、不暴露）。
   * 用途：无头浏览器（`scripts/probe-web-flip.mjs`）能把"当前页号 / 列几何 / 翻页落位"
   * 拿成**实际数字**，而不是靠肉眼看截图 ⇒ 几何类改动有可回归的硬证据。
   */
  if (new URLSearchParams(location.search).get('probe') === '1') {
    ;(window as unknown as Record<string, unknown>)['__reader'] = reader
  }

  document.title = (title !== '' ? title : '喵阅') + ' · 喵阅'
}

boot().catch((err: unknown) => {
  const msg = err instanceof Error ? err.message : String(err)
  const el = document.getElementById('bookTitle')
  if (el) el.textContent = '加载失败：' + msg
  document.body.insertAdjacentHTML(
    'beforeend',
    '<div style="position:fixed;left:16px;bottom:60px;z-index:99;background:#fff;padding:10px 14px;' +
      'border-radius:8px;box-shadow:0 4px 18px rgba(0,0,0,.15);font-size:13px">加载失败：' + msg + '</div>'
  )
})
