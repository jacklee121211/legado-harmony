/**
 * dev/server.mjs —— 本地开发服务器（桌面浏览器直接跑，这是 v3 架构最大的收益）
 * ============================================================================
 * 做两件事：
 *   ① 静态服务 `dev/out/index.html`（`node build.mjs --watch` 的产物）
 *   ② **mock 手机端 HTTP 接口**：`/book`、`/toc`、`/marks*`、`/sync`
 *      ⇒ 不需要真机/局域网，就能在电脑上复现与调试阅读、翻页、书签、双端同步。
 *
 * 用法：
 *   终端 A： cd web && npm run dev            （= build --watch + 本服务器）
 *   浏览器： http://127.0.0.1:5599/?id=1
 *
 * mock 数据：`dev/mock-book.txt`（缺失时用内置的合成长文，含 200 章）。
 */
import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const PORT = Number(process.env.PORT ?? 5599)

// ── mock 状态（进程内存；重启即清空）─────────────────────────────────────────
const marks = []           // { time, chapterIndex, chapterName, bookText, content }
let phonePos = null        // 手机端位置槽（模拟手机在别处读）
let webSlotSeen = {}       // 仅用于日志观察
let mockSeq = 0            // mock 的全局序号（模拟手机进程分配）

function synthBook(chapters = 200, parasPerChapter = 12) {
  const out = []
  for (let c = 1; c <= chapters; c++) {
    out.push(`第${c}章 测试章节标题${c}`)
    out.push('')
    for (let p = 1; p <= parasPerChapter; p++) {
      out.push(`这是第${c}章的第${p}段正文。` + '喵阅电脑阅读端本地调试文本。'.repeat(3 + (p % 4)))
      out.push('')
    }
  }
  return out.join('\n')
}

async function bookText() {
  const f = join(here, 'mock-book.txt')
  try {
    const s = await stat(f)
    if (s.isFile()) return await readFile(f, 'utf8')
  } catch {
    /* 用合成文本 */
  }
  return synthBook()
}

function json(res, obj, code = 200) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8')
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length })
  res.end(body)
}

async function body(req) {
  const chunks = []
  for await (const c of req) chunks.push(c)
  return Buffer.concat(chunks).toString('utf8')
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://127.0.0.1')
  const path = url.pathname

  // ── mock 接口 ─────────────────────────────────────────────────────────
  if (path === '/book') {
    const text = await bookText()
    const buf = Buffer.from(text, 'utf8')
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': buf.length })
    res.end(buf)
    return
  }
  if (path === '/books') {
    // 书库列表（书库页 + 阅读页书名都用它）
    const text = await bookText()
    json(res, [{ id: 1, name: '本地调试样本（合成 200 章）', url: 'mock.txt', sizeKB: Math.round(Buffer.byteLength(text, 'utf8') / 1024) }])
    return
  }
  if (path === '/toc') {
    // 默认返回空 ⇒ 前端回退本地正则切分（这正是渐进上线的路径）。
    // 设 MOCK_TOC=1 可模拟"手机端已支持单源目录"：只回标题列表（与生产同形），
    // 字符区间由前端 locateToc 在它自己那份正文上算。
    if (process.env.MOCK_TOC === '1') {
      const text = await bookText()
      const titles = []
      const re = /^第\d+章 .*$/gm
      let m
      while ((m = re.exec(text)) !== null) titles.push(m[0].trim())
      json(res, { ok: true, titles })
      return
    }
    json(res, { ok: true, titles: [] })
    return
  }
  if (path === '/marks' && req.method === 'GET') {
    json(res, { ok: true, marks })
    return
  }
  if (path === '/marksadd' && req.method === 'POST') {
    const b = JSON.parse(await body(req))
    if (b.webKey && marks.some((m) => m.content === b.webKey)) {
      json(res, { ok: true, msg: 'exists' })
      return
    }
    marks.unshift({
      time: Date.now(),
      chapterIndex: Number(b.chapterIndex ?? -1),
      chapterName: String(b.chapterName ?? ''),
      bookText: String(b.bookText ?? ''),
      content: String(b.webKey ?? '')
    })
    json(res, { ok: true, msg: 'added' })
    return
  }
  if (path === '/marksdel' && req.method === 'POST') {
    const b = JSON.parse(await body(req))
    const i = marks.findIndex((m) => m.time === Number(b.time))
    if (i >= 0) marks.splice(i, 1)
    json(res, { ok: true, msg: 'removed' })
    return
  }
  if (path === '/sync' && req.method === 'GET') {
    if (!phonePos) {
      json(res, { ok: false })
      return
    }
    // seq 是"全局单调序号"（生产里由手机进程分配）；mock 里每次写入自增
    json(res, { ok: true, src: 'phone', latestWriter: 'phone', ...phonePos })
    return
  }
  if (path === '/sync' && req.method === 'POST') {
    const b = JSON.parse(await body(req))
    webSlotSeen[b.webId] = { title: b.chTitle, ts: Date.now() }
    console.log('[mock] web slot updated:', b.webId, b.chTitle)
    json(res, { ok: true, msg: 'synced' })
    return
  }
  // 调试接口：把"手机端位置"设成指定章（模拟手机在别处读到某章 ⇒ 电脑端应弹提示条）
  if (path === '/__setPhone') {
    const title = url.searchParams.get('title') ?? ''
    const text = await bookText()
    const at = text.indexOf(title)
    mockSeq++
    phonePos = {
      chTitle: title,
      topEx: at >= 0 ? text.slice(at + title.length, at + title.length + 40).trim() : '',
      botEx: at >= 0 ? text.slice(at + 200, at + 240).trim() : '',
      ts: Date.now(),
      seq: mockSeq,
      ratio: -1,
      posRatio: -1,
      chCount: 0
    }
    json(res, { ok: true, phonePos })
    return
  }

  // ── 静态：按生产的路径规则映射（与 WifiBookServer 的路由一致）──────────
  const pageMap = {
    '/': 'upload_v3.html',
    '/index.html': 'upload_v3.html',
    '/library': 'library_v3.html',
    '/read': 'reader_v3.html'
  }
  const safe = path.replace(/\.\./g, '')
  const file = pageMap[safe] ?? (safe === '/' ? 'upload_v3.html' : safe.replace(/^\//, ''))
  try {
    const buf = await readFile(join(here, 'out', file))
    const ct = file.endsWith('.html')
      ? 'text/html; charset=utf-8'
      : file.endsWith('.js')
        ? 'text/javascript; charset=utf-8'
        : file.endsWith('.css')
          ? 'text/css; charset=utf-8'
          : 'application/octet-stream'
    res.writeHead(200, { 'Content-Type': ct, 'Content-Length': buf.length })
    res.end(buf)
    return
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('404 ' + safe + '（先跑 node build.mjs --dev）')
  }
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[dev] 阅读页 http://127.0.0.1:${PORT}/read?id=1`)
  console.log(`[dev] 书库页 http://127.0.0.1:${PORT}/library   ·   传书页 http://127.0.0.1:${PORT}/`)
  console.log('[dev] 调试：/__setPhone?title=第5章 测试章节标题5  ⇒ 再刷新阅读页应弹"手机进度"提示条')
  console.log('[dev] MOCK_TOC=1 可模拟手机端已支持单源目录（/toc 返回标题列表 ⇒ 前端自己定位）')
})
