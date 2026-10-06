/**
 * probe-pair-auth.mjs —— 配对鉴权（输码弹窗模式）端到端自检
 * ============================================================================
 * 为什么存在：ArkTS 服务端无法在 PC 上运行 ⇒ 用 mock 复现同一条 HTTP 契约，
 * 但**配对页 HTML 直接从 `WifiBookServer.ets` 的模板字面量里提取**（不手抄，
 * 模板一改这里就测到新版），`verifyPairCode` 按 `WebCredential.ets` 同款逻辑移植。
 * 服务端真机行为仍以真机验收为准；本脚本管住「页面 JS ⇄ 服务端 JSON/Cookie 契约」。
 *
 * 用法：node scripts/probe-pair-auth.mjs   （自带断言，全过退出码 0）
 */
import { createServer } from 'node:http'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const ets = readFileSync(join(here, '..', 'entry', 'src', 'main', 'ets', 'common', 'utils', 'WifiBookServer.ets'), 'utf8')

// ── 从 ArkTS 源码提取模板字面量（`...` 之间，含转义 ` 与 ${}）──────────────
function extractTemplate(name) {
  const at = ets.indexOf(`private static ${name}`)
  if (at < 0) throw new Error(`未找到 ${name}`)
  const bt = ets.indexOf('`', ets.indexOf('const inner', at))
  const end = ets.indexOf('`;', bt)
  if (bt < 0 || end < 0) throw new Error(`${name} 模板提取失败`)
  return ets.slice(bt + 1, end)
}
function extractPageShell() {
  const at = ets.indexOf('private static pageShell')
  const bt = ets.indexOf('return `', at) + 'return `'.length
  const end = ets.indexOf('`;', bt)
  return ets.slice(bt, end)
}
const inner = extractTemplate('pairPageBytes')
const shell = extractPageShell()
const pairPage = shell.replace('${title}', '喵阅 · 配对').replace('${inner}', inner)

// ── WebCredential.verifyPairCode 的忠实移植（常量同源：6位/10分钟/窗口10次）────
const PAIR_LEN = 6, TTL = 10 * 60 * 1000, WINDOW = 10 * 60 * 1000, WIN_MAX = 10
function makeCred(code) {
  return {
    code, expireAt: Date.now() + TTL, globalFails: [],
    verify(input) {
      if (this.code === '' || Date.now() > this.expireAt) return false
      const now = Date.now()
      this.globalFails = this.globalFails.filter((t) => now - t < WINDOW)
      if (this.globalFails.length >= WIN_MAX) return false
      const ok = input.length === PAIR_LEN && /^[0-9]{6}$/.test(input) && input === this.code
      if (!ok) { this.globalFails.push(now); return false }
      // TTL 内可重复使用（2026-10-06 复盘：一次性核销会在"响应丢失"时把用户锁死在门外）
      this.globalFails = []
      return true
    }
  }
}

// ── mock 服务端：门禁语义与 dispatchAsync 前置闸门一致 ─────────────────────
const cred = makeCred('246810')
const pairedTokens = new Set()  // 真实服务端设备表支持多台设备并存
const deviceTokens = new Map()  // (ip|ua) -> token，同设备去重（pairDevice 同语义）
/** 三通道凭证（与 hasValidCredential 同语义）：Cookie / URL dt / 请求头 */
function credOk(req, url) {
  const ck = (req.headers.cookie ?? '').split(';').map((s) => s.trim()).find((c) => c.startsWith('mr_dev='))
  if (ck !== undefined && pairedTokens.has(ck.substring('mr_dev='.length))) return true
  const dt = new URL(url, 'http://x').searchParams.get('dt')
  if (dt !== null && pairedTokens.has(dt)) return true
  const hd = req.headers['x-device-token']
  if (hd !== undefined && pairedTokens.has(String(hd))) return true
  return false
}
const server = createServer((req, res) => {
  const paired = credOk(req, req.url)
  const path = req.url.split('?')[0]
  // /session：门禁之前放行（已配对/未配对都答）
  if (req.method === 'GET' && path === '/session') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' })
    res.end(JSON.stringify({ ok: true, msg: paired ? 'paired' : 'unpaired' }))
    return
  }
  if (!paired) {
    if (req.method === 'GET' && ['/', '/index.html', '/library'].includes(path) || (req.method === 'GET' && path.startsWith('/read'))) {
      // serveRoot：?k= 自动配对，否则配对页
      const k = new URL(req.url, 'http://x').searchParams.get('k')
      if (k !== null) {
        if (cred.verify(k)) {
          const t = Array.from({length: 16}, () => Math.floor(Math.random() * 16).toString(16)).join('')
          pairedTokens.add(t)
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Set-Cookie': `mr_dev=${t}; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000` })
          res.end('<div class="ok">ok</div>')
        } else {
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
          res.end('<div class="bad">bad</div>')
        }
        return
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
      res.end(pairPage)
      return
    }
    if (req.method === 'POST' && path === '/pair') {
      let body = ''
      req.on('data', (c) => { body += c })
      req.on('end', () => {
        let code = ''
        try { code = String(JSON.parse(body).code ?? '').trim() } catch { }
        if (cred.verify(code)) {
          // 同设备去重（与 pairDevice 同语义）：同 ip+ua 复用原令牌
          const ip = req.socket.remoteAddress ?? '未知'
          const ua = req.headers['user-agent'] ?? ''
          const key = ip + '|' + ua
          let t = deviceTokens.get(key)
          if (t === undefined) {
            t = Array.from({length: 16}, () => Math.floor(Math.random() * 16).toString(16)).join('')
            deviceTokens.set(key, t)
          }
          pairedTokens.add(t)
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Set-Cookie': `mr_dev=${t}; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000` })
          res.end(JSON.stringify({ ok: true, msg: 'paired', token: t }))
        } else {
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' })
          res.end(JSON.stringify({ ok: false, msg: '配对码不正确或已过期（码为一次性，手机端可刷新）' }))
        }
      })
      return
    }
    res.writeHead(401, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('未配对：请打开手机端显示的地址，输入 6 位配对码')
    return
  }
  if (req.method === 'POST' && path === '/pair') {
    // 已配对设备 POST /pair：真实服务端路由表里没有该路由 ⇒ 404（与 dispatchAsync 一致）
    res.writeHead(404)
    res.end('not found')
    return
  }
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' })
  res.end(`PAIRED_CONTENT ${path}`)
})

// ── 断言跑批 ───────────────────────────────────────────────────────────────
const PORT = 5611
await new Promise((r) => server.listen(PORT, r))
const base = `http://127.0.0.1:${PORT}`
let pass = 0, fail = 0
function assert(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  ✓ ${name}`) }
  else { fail++; console.log(`  ✗ ${name} ${extra}`) }
}
async function req(path, opts = {}) {
  const r = await fetch(base + path, opts)
  return { status: r.status, text: await r.text(), setCookie: r.headers.get('set-cookie') ?? '' }
}

console.log('── 输码弹窗模式 ──')
{
  const r = await req('/library')
  assert('未配对 GET /library ⇒ 200 配对页（非 401 纯文本）', r.status === 200 && r.text.includes('id="code"') && r.text.includes('配对到手机'))
  assert('配对页含 POST /pair 提交逻辑', r.text.includes("x.open('POST','/pair')"))
  assert('配对页成功后保存令牌并带 dt 跳回原地址（无 Cookie 化主流程）', pairPage.includes('saveTok(j.token)') && pairPage.includes('location.replace(withDt(location.href,j.token))'))
  assert('配对页提交目标为 POST /pair（输码弹窗）', pairPage.includes("x.open('POST','/pair')"))
  // 路由顺序回归（2026-10-06 真机复盘）：`/books` 必须先于 `startsWith('/book')` 判断，
  // 否则书库列表被遮蔽成"读一本书" ⇒ 纯文本 "book not found" ⇒ 网页 JSON 解析炸。
  const booksAt = ets.indexOf("req.path === '/books'")
  const bookAt = ets.indexOf("req.path.startsWith('/book')")
  assert('/books 路由先于 /book 前缀判断（防遮蔽回归）', booksAt > 0 && bookAt > booksAt)
}
{
  const r = await req('/read?id=3')
  assert('未配对 GET /read?id=3 ⇒ 200 配对页', r.status === 200 && r.text.includes('id="code"'))
}
{
  const r = await req('/books')
  assert('未配对 GET /books ⇒ 401（数据接口仍锁死）', r.status === 401)
  const s0 = await req('/session')
  assert('未配对 GET /session ⇒ 200 unpaired（自诊探针）', s0.status === 200 && JSON.parse(s0.text).msg === 'unpaired')
}
{
  const r = await req('/upload', { method: 'POST', body: 'x' })
  assert('未配对 POST /upload ⇒ 401', r.status === 401)
}
{
  // 配对页 <script> 语法自检（提取出来 new Function 编译一遍）
  const m = pairPage.match(/<script>([\s\S]*?)<\/script>/)
  let ok = false
  try { new Function(m[1]); ok = true } catch (e) { ok = false; console.log('   script 语法错误:', e.message) }
  assert('配对页内联 JS 语法合法', ok)
  assert('配对页含无 Cookie 自愈脚本（localStorage mr_dt + dt 跳转）', pairPage.includes("localStorage.setItem('mr_dt'") && pairPage.includes("'dt='+t"))
}
console.log('── 配对码裁决（与 WebCredential 同款语义）──')
{
  for (let i = 0; i < 9; i++) {
    const r = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: '000000' }) })
    const j = JSON.parse(r.text)
    if (j.ok !== false) { assert(`第 ${i + 1} 次错码应拒绝`, false); break }
    if (i === 8) assert('连续 9 次错码均拒绝且返回 ok:false', true)
  }
  const r10 = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: '000000' }) })
  assert('第 10 次错码仍拒绝（窗口恰好 10 上限）', JSON.parse(r10.text).ok === false)
  const r11 = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: '246810' }) })
  assert('第 11 次（即便码正确）被全局窗口拦下 ⇒ 防穷举生效', JSON.parse(r11.text).ok === false)
}
{
  // 新码重置窗口（模拟手机端"刷新配对码"）
  cred.code = '246810'; cred.expireAt = Date.now() + TTL; cred.globalFails = []
  const r = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: '246810' }) })
  const j = JSON.parse(r.text)
  assert('正确码 ⇒ ok:true + 响应体带 token + 下发 HttpOnly Cookie',
    j.ok === true && typeof j.token === 'string' && j.token.length >= 16
    && /mr_dev=[0-9a-f]+; Path=\/; HttpOnly/.test(r.setCookie))
  const token = j.token
  const cookie = r.setCookie.split(';')[0]
  // 2026-10-06 复盘：码在 TTL 内**可重复使用**——"响应丢失/换台设备"重输同一码必须成功
  const r2 = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: '246810' }) })
  assert('同一码第二次提交仍成功（TTL 内可重复，抗响应丢失）', JSON.parse(r2.text).ok === true && r2.setCookie.includes('mr_dev='))
  // ── 无 Cookie 化三通道（2026-10-06 主改造）──
  const rq = await req('/library?dt=' + token)
  assert('URL query dt=<token> ⇒ 放行（主通道，不依赖 Cookie）', rq.status === 200 && rq.text.startsWith('PAIRED_CONTENT /library'))
  const rh = await req('/books', { headers: { 'X-Device-Token': token } })
  assert('请求头 X-Device-Token ⇒ 放行（预留通道）', rh.status === 200)
  const r3 = await req('/library', { headers: { Cookie: cookie } })
  assert('带 Cookie 访问 /library ⇒ 放行（兼容通道）', r3.status === 200 && r3.text.startsWith('PAIRED_CONTENT /library'))
  const r4 = await req('/', { headers: { Cookie: cookie } })
  assert('带 Cookie 访问 / ⇒ 放行传书页', r4.status === 200 && r4.text.startsWith('PAIRED_CONTENT /'))
  const r2b = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0 ProbeTest' }, body: JSON.stringify({ code: '246810' }) })
  const r2c = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0 ProbeTest' }, body: JSON.stringify({ code: '246810' }) })
  assert('同设备两次配对 ⇒ 同一令牌（设备列表不累计）', JSON.parse(r2b.text).ok === true && JSON.parse(r2c.text).ok === true
    && JSON.parse(r2b.text).token === JSON.parse(r2c.text).token)
  const s1 = await req('/session', { headers: { Cookie: cookie } })
  assert('带 Cookie GET /session ⇒ paired', JSON.parse(s1.text).msg === 'paired')
  const s2 = await req('/session?dt=' + token)
  assert('带 dt GET /session ⇒ paired（无 Cookie 也能确认）', JSON.parse(s2.text).msg === 'paired')
  const r5 = await req('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: cookie }, body: JSON.stringify({ code: '246810' }) })
  assert('已配对设备 POST /pair ⇒ 404（真实服务端路由表无此路由）', r5.status === 404)
}
console.log('── ?k= 自动配对（二维码路径）──')
{
  cred.code = '135790'; cred.expireAt = Date.now() + TTL; cred.globalFails = []
  const r = await req('/?k=135790')
  assert('GET /?k=正确码 ⇒ 200 成功页 + Cookie', r.status === 200 && r.text.includes('ok') && r.setCookie.includes('mr_dev='))
  const r2 = await req('/?k=999999')
  assert('GET /?k=错码 ⇒ 200 失败页（非 401）', r2.status === 200 && r2.text.includes('bad'))
}

server.close()
console.log(`\n结果：${pass} 通过 / ${fail} 失败`)
process.exit(fail > 0 ? 1 : 0)
