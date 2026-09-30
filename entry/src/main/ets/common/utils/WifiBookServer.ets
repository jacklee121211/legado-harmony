import { socket } from '@kit.NetworkKit'
import { wifiManager } from '@kit.ConnectivityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import booksUtil from './booksUtils'
import booksDao from '../../database/dao/BooksDao'
import { Books } from '../../database/entities/Books'

/**
 * wifi传书 / 电脑阅读 · 内置 HTTP 服务（2026-09-30 回填，端口 1122）。
 *
 * ── 为什么手写 HTTP ─────────────────────────────────────────────────────
 * 基座考古结论：基座的"Web服务"是纯空壳（假开关 + 写死的假地址），安卓原版的
 * NanoHTTPD 方案没有随移植带入；鸿蒙 Kit 也没有现成 HTTP Server 组件。
 * 官方可用底座 = `@ohos.net.socket` 的 TCPSocketServer（SDK d.ts 原文：
 * listen(NetAddress) / on('connect') / TCPSocketConnection.on('message')→
 * SocketMessageInfo.message: ArrayBuffer / send(TCPSendOptions)）⇒ 在其上实现
 * 最小 HTTP/1.1：GET /（传书页）+ GET /books + GET /book?id（电脑阅读，txt 浏览器
 * 直接打开）+ POST /upload（multipart 文件上传 → 导入书架）。
 *
 * ── 导入管线 ────────────────────────────────────────────────────────────
 * 上传字节写沙箱（filesDir/<文件名>）后走 `booksUtil.addBooks`（与
 * FileHandler.CopyFile 同款字段：isLocalBook=true, bookGroup=4）⇒ 直进书架。
 *
 * ── 会话级书目 ──────────────────────────────────────────────────────────
 * /books 列出**本服务会话内**导入/已知书目（零新增 DAO 面）；持久书目后续接 DB。
 */

const TAG: string = 'WifiBookServer'

/** 服务器会话内已知书目（电脑阅读列表用） */
interface ShelfEntry {
  id: number
  name: string
  path: string
  size: number
}

/** 电脑阅读·书库条目（实时查自书架 DB） */
interface LibraryEntry {
  id: number
  name: string
  url: string
  sizeKB: number
}

function bytesToUtf8(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8')
  return decoder.decodeToString(bytes)
}

function indexOfBytes(hay: Uint8Array, needle: Uint8Array, from: number): number {
  if (needle.length === 0 || hay.length < needle.length) {
    return -1
  }
  for (let i = from; i <= hay.length - needle.length; i++) {
    let hit = true
    for (let j = 0; j < needle.length; j++) {
      if (hay[i + j] !== needle[j]) {
        hit = false
        break
      }
    }
    if (hit) {
      return i
    }
  }
  return -1
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length)
  out.set(a, 0)
  out.set(b, a.length)
  return out
}

/**
 * 整数 IP → 点分十进制。
 * ⚠️ 换算口径以官方 FAQ 为准（faqs-connectivity-4 原文）：
 *   `(ipAddress >>> 24) + "." + (ipAddress >> 16 & 0xFF) + "." + (ipAddress >> 8 & 0xFF) + "." + (ipAddress & 0xFF)`
 * 即**大端序**（首字节在高位）。真机实证：小端序曾输出 241.3.168.192（倒序、不可访问），
 * 大端序输出 192.168.3.241（正确局域网段）。
 */
function ipNumberToDotted(ip: number): string {
  return `${(ip >>> 24) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 8) & 0xFF}.${ip & 0xFF}`
}

interface ParsedHttp {
  method: string
  /** 原始请求目标（含 query，如 /read?id=1）——id 类路由从这里取参 */
  target: string
  path: string
  headers: Record<string, string>
  body: Uint8Array
  /** 本次请求消费的字节数（head + content-length），keep-alive 粘包消费用 */
  consumed: number
}

export class WifiBookServer {
  private static server: socket.TCPSocketServer | null = null
  private static running: boolean = false
  private static port: number = 1122
  private static shelf: ShelfEntry[] = []
  private static nextId: number = 1
  /** 状态订阅者（传书对话框刷新用） */
  private static listeners: Array<() => void> = []

  static isRunning(): boolean {
    return WifiBookServer.running
  }

  static getPort(): number {
    return WifiBookServer.port
  }

  static address(): string {
    if (!WifiBookServer.running) {
      return ''
    }
    try {
      const ip: number = wifiManager.getIpInfo().ipAddress
      const dotted: string = ipNumberToDotted(ip)
      return dotted.length > 0 ? `http://${dotted}:${WifiBookServer.port}` : ''
    } catch (err) {
      console.error(`${TAG} getIpInfo failed: ${(err as Error).message}`)
      return ''
    }
  }

  /** 书目快照（对话框/页面渲染用） */
  static shelfList(): ShelfEntry[] {
    return WifiBookServer.shelf
  }

  static onChange(listener: () => void): void {
    WifiBookServer.listeners.push(listener)
  }

  static offChange(listener: () => void): void {
    const i = WifiBookServer.listeners.indexOf(listener)
    if (i >= 0) {
      WifiBookServer.listeners.splice(i, 1)
    }
  }

  private static notify(): void {
    WifiBookServer.listeners.forEach((fn: () => void) => fn())
  }

  static start(onResult?: (ok: boolean, msg: string) => void): void {
    if (WifiBookServer.running) {
      onResult?.(true, '')
      return
    }
    const server = socket.constructTCPSocketServerInstance()
    WifiBookServer.server = server
    server.on('connect', (client: socket.TCPSocketConnection) => {
      WifiBookServer.handleClient(client)
    })
    server.listen({ address: '0.0.0.0', port: WifiBookServer.port, family: 1 }, (err: Error | null) => {
      if (err) {
        WifiBookServer.running = false
        console.error(`${TAG} listen failed: ${err.message}`)
        onResult?.(false, `端口 ${WifiBookServer.port} 绑定失败：${err.message}`)
      } else {
        WifiBookServer.running = true
        console.info(`${TAG} listening on ${WifiBookServer.port}`)
        WifiBookServer.notify()
        onResult?.(true, '')
      }
    })
  }

  static stop(onResult?: (ok: boolean) => void): void {
    if (WifiBookServer.server === null || !WifiBookServer.running) {
      WifiBookServer.running = false
      WifiBookServer.notify()
      onResult?.(true)
      return
    }
    WifiBookServer.server.close()
      .then((): void => {
        WifiBookServer.running = false
        WifiBookServer.notify()
        onResult?.(true)
      })
      .catch((err: Error): void => {
        WifiBookServer.running = false
        WifiBookServer.notify()
        onResult?.(false)
        console.error(`${TAG} close failed: ${err.message}`)
      })
  }

  // ── 连接层 ────────────────────────────────────────────────────────────
  private static handleClient(client: socket.TCPSocketConnection): void {
    let buffer: Uint8Array = new Uint8Array(0)
    client.on('message', (info: socket.SocketMessageInfo) => {
      buffer = concatBytes(buffer, new Uint8Array(info.message))
      // 循环消费（keep-alive 下多个请求可能粘在一个 message 里）
      for (;;) {
        const parsed: ParsedHttp | null = WifiBookServer.tryParse(buffer)
        if (parsed === null) {
          break
        }
        buffer = buffer.slice(parsed.consumed)
        WifiBookServer.dispatch(client, parsed)
        if (buffer.length === 0) {
          break
        }
      }
    })
  }

  /** 头部完整且 body 收满时解析请求；否则返回 null（继续等） */
  private static tryParse(buffer: Uint8Array): ParsedHttp | null {
    const sep: Uint8Array = new Uint8Array([0x0D, 0x0A, 0x0D, 0x0A])
    const headEnd: number = indexOfBytes(buffer, sep, 0)
    if (headEnd < 0) {
      return null
    }
    const headText: string = bytesToUtf8(buffer.slice(0, headEnd))
    const lines: string[] = headText.split('\r\n')
    const requestLine: string = lines[0] ?? ''
    const parts: string[] = requestLine.split(' ')
    if (parts.length < 2) {
      return null
    }
    const headers: Record<string, string> = {}
    for (let i = 1; i < lines.length; i++) {
      const idx: number = lines[i].indexOf(':')
      if (idx > 0) {
        headers[lines[i].substring(0, idx).trim().toLowerCase()] = lines[i].substring(idx + 1).trim()
      }
    }
    const contentLength: number = Number(headers['content-length'] ?? '0') || 0
    const bodyStart: number = headEnd + 4
    if (buffer.length < bodyStart + contentLength) {
      return null
    }
    const body: Uint8Array = buffer.slice(bodyStart, bodyStart + contentLength)
    const path: string = parts[1].split('?')[0] ?? '/'
    return {
      method: (parts[0] ?? 'GET').toUpperCase(),
      target: parts[1] ?? '/',
      path: path,
      headers: headers,
      body: body,
      consumed: bodyStart + contentLength
    }
  }

  // ── 分发 ──────────────────────────────────────────────────────────────
  private static dispatch(client: socket.TCPSocketConnection, req: ParsedHttp): void {
    // DB 查询是异步的 ⇒ 实际处理挪进 async（fire-and-forget，respond 自带错误兜底）
    WifiBookServer.dispatchAsync(client, req)
  }

  private static async dispatchAsync(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
    try {
      if (req.method === 'GET' && (req.path === '/' || req.path === '/index.html')) {
        WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', WifiBookServer.uploadPageBytes())
      } else if (req.method === 'GET' && req.path === '/library') {
        // 电脑阅读·书库页：实时查书架全部本地书（searchPage bookGroup=4 = 本地 or isLocalBook）
        const entries: LibraryEntry[] = await WifiBookServer.libraryEntries()
        WifiBookServer.respond(client, 200, 'text/html; charset=utf-8',
          WifiBookServer.libraryPageBytes(entries))
      } else if (req.method === 'GET' && req.path === '/books') {
        // JSON API（保留）：书目列表
        const entries: LibraryEntry[] = await WifiBookServer.libraryEntries()
        WifiBookServer.respond(client, 200, 'application/json; charset=utf-8',
          WifiBookServer.textBytes(JSON.stringify(entries)))
      } else if (req.method === 'GET' && req.path.startsWith('/read')) {
        // 电脑阅读·阅读器页（⚠️ id 从 target 取——tryParse 的 path 已剥掉 query）
        const book: Books | null = await WifiBookServer.bookById(WifiBookServer.queryId(req.target))
        if (book === null) {
          WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8',
            WifiBookServer.textBytes('book not found'))
          return
        }
        WifiBookServer.respond(client, 200, 'text/html; charset=utf-8',
          WifiBookServer.readPageBytes(book.id ?? 0, book.bookName ?? '未命名'))
      } else if (req.method === 'GET' && req.path.startsWith('/book')) {
        await WifiBookServer.serveBookFile(client, WifiBookServer.queryId(req.target))
      } else if (req.method === 'POST' && req.path === '/upload') {
        WifiBookServer.handleUpload(client, req)
      } else {
        WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8', WifiBookServer.textBytes('not found'))
      }
    } catch (err) {
      console.error(`${TAG} dispatch error: ${(err as Error).message}`)
    }
  }

  /** 从请求目标取 id（/read?id=N / /book?id=N） */
  private static queryId(target: string): number {
    const m: RegExpMatchArray | null = target.match(/id=(\d+)/)
    if (m !== null) {
      return Number(m[1])
    }
    const digits: string = target.replace(/[^0-9]/g, '')
    return Number(digits === '' ? '-1' : digits)
  }

  /** 书架全部本地书（searchPage bookGroup=4 ⇒ 本地分组 or isLocalBook，pageSize 0 = 全量） */
  private static async libraryEntries(): Promise<LibraryEntry[]> {
    const books: Books[] = await booksDao.searchPage({ bookGroup: 4 }, 1, 0)
    const out: LibraryEntry[] = []
    books.forEach((b: Books) => {
      if (b.bookUrl && b.bookUrl.length > 0) {
        out.push({
          id: b.id ?? 0,
          name: b.bookName ?? '未命名',
          url: b.bookUrl,
          sizeKB: WifiBookServer.fileSizeKB(b.bookUrl)
        })
      }
    })
    return out
  }

  private static async bookById(id: number): Promise<Books | null> {
    if (id < 0) {
      return null
    }
    const arr: Books[] = await booksDao.getBookByIds([id])
    return arr.length > 0 ? arr[0] : null
  }

  private static fileSizeKB(path: string): number {
    try {
      return Math.round(fs.statSync(path).size / 1024)
    } catch (err) {
      return 0
    }
  }

  // ── 处理器 ────────────────────────────────────────────────────────────
  /**
   * 传书页（v3.11 现代化重写，用户需求："不够现代化精简化，选定多文件没有预览
   * list、无法删除/新增"）。功能：点击/拖放选文件 → 文件列表预览（名/大小/删除）→
   * XHR 逐文件上传（真实进度条）→ 状态徽章（成功/失败）。风格对齐 legado web 的
   * 精简现代感：卡片+圆角+系统字体+蓝 accent。
   */
  private static uploadPageBytes(): Uint8Array {
    const html: string = `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>喵阅 · WiFi传书</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'PingFang SC',sans-serif;background:#F2F3F7;min-height:100vh;color:#1a1a1a}
.wrap{max-width:560px;margin:0 auto;padding:28px 20px 48px}
h1{font-size:22px;font-weight:700;letter-spacing:.5px}
.sub{color:#8a8f99;font-size:13px;margin:6px 0 20px}
.card{background:#fff;border-radius:16px;box-shadow:0 2px 12px rgba(0,0,0,.05);overflow:hidden}
.drop{padding:34px 20px;text-align:center;border:1.5px dashed #d5d9e0;border-radius:14px;margin:16px;color:#8a8f99;font-size:14px;cursor:pointer;transition:.2s}
.drop.on{border-color:#0A84FF;background:#F0F7FF;color:#0A84FF}
.drop b{display:block;font-size:15px;color:#1a1a1a;margin-bottom:4px}
.list{padding:0 16px}
.item{display:flex;align-items:center;gap:12px;padding:12px 4px;border-bottom:1px solid #F2F3F7}
.item:last-child{border-bottom:0}
.ico{width:38px;height:38px;border-radius:10px;background:#F0F7FF;color:#0A84FF;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;flex-shrink:0}
.meta{flex:1;min-width:0}
.name{font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.size{font-size:12px;color:#8a8f99;margin-top:2px}
.bar{height:3px;background:#EEF1F5;border-radius:2px;margin-top:6px;overflow:hidden}
.bar i{display:block;height:100%;background:#0A84FF;border-radius:2px;width:0;transition:width .2s}
.st{font-size:12px;font-weight:600;flex-shrink:0}
.st.ok{color:#24B277}.st.err{color:#EF4444}.st.wait{color:#8a8f99}
.x{width:26px;height:26px;border:0;background:#F2F3F7;border-radius:50%;color:#8a8f99;font-size:14px;cursor:pointer;flex-shrink:0}
.foot{padding:16px}
.btn{width:100%;height:46px;border:0;border-radius:12px;background:#0A84FF;color:#fff;font-size:16px;font-weight:600;cursor:pointer}
.btn:disabled{background:#C9CDD4}
.empty{padding:8px 4px 20px;text-align:center;color:#c2c6cf;font-size:13px}
.nav{margin-top:18px;text-align:center;font-size:14px}
.nav a{color:#0A84FF;text-decoration:none;font-weight:600}
</style></head><body><div class="wrap">
<h1>WiFi 传书</h1>
<p class="sub">选择书籍文件（.txt / .epub），上传后直接进入手机书架</p>
<div class="card">
  <div class="drop" id="drop"><b>点击选择，或拖放文件到此处</b>支持多选 · txt / epub</div>
  <input id="f" type="file" multiple accept=".txt,.epub" hidden>
  <div class="list" id="list"></div>
  <div class="empty" id="empty">还没有添加文件</div>
  <div class="foot"><button class="btn" id="up" disabled>开始上传</button></div>
</div>
<p class="nav">想在电脑上阅读？<a href="/library">打开书库 →</a></p>
</div>
<script>
var files=[];var drop=document.getElementById('drop');var fi=document.getElementById('f');
var list=document.getElementById('list');var empty=document.getElementById('empty');
var btn=document.getElementById('up');
function fmt(n){return n>1048576?(n/1048576).toFixed(1)+' MB':(n/1024).toFixed(0)+' KB'}
function render(){
  list.innerHTML='';
  files.forEach(function(it,i){
    var d=document.createElement('div');d.className='item';
    var ext=it.f.name.split('.').pop().toUpperCase().slice(0,4);
    d.innerHTML='<div class="ico">'+ext+'</div><div class="meta"><div class="name"></div>'+
      '<div class="size">'+fmt(it.f.size)+'</div><div class="bar"><i></i></div></div>'+
      '<div class="st wait">待传</div><button class="x">✕</button>';
    d.querySelector('.name').textContent=it.f.name;
    d.querySelector('.x').onclick=function(){if(!it.done){files.splice(i,1);render()}};
    list.appendChild(d);
  });
  empty.style.display=files.length?'none':'block';
  btn.disabled=!files.some(function(x){return !x.done});
}
function add(fl){for(var i=0;i<fl.length;i++){files.push({f:fl[i],done:false});}render()}
drop.onclick=function(){fi.click()};
drop.ondragover=function(e){e.preventDefault();drop.classList.add('on')};
drop.ondragleave=function(){drop.classList.remove('on')};
drop.ondrop=function(e){e.preventDefault();drop.classList.remove('on');add(e.dataTransfer.files)};
fi.onchange=function(){add(fi.files);fi.value=''};
btn.onclick=function(){
  var pend=files.filter(function(x){return !x.done});
  var i=0;
  (function next(){
    if(i>=pend.length){render();return}
    var it=pend[i];var card=[].slice.call(list.children).find(function(c){
      return c.querySelector('.name').textContent===it.f.name});
    var st=card?card.querySelector('.st'):null;var bar=card?card.querySelector('.bar i'):null;
    if(st){st.textContent='传中…';st.className='st wait'}
    var fd=new FormData();fd.append('file',it.f);
    var xhr=new XMLHttpRequest();
    xhr.open('POST','/upload');
    if(bar){xhr.upload.onprogress=function(e){if(e.lengthComputable){bar.style.width=(e.loaded/e.total*100)+'%'}}}
    xhr.onload=function(){
      it.done=true;
      if(st){try{var j=JSON.parse(xhr.responseText);
        st.textContent=j.ok?'已入架':'失败';st.className='st '+(j.ok?'ok':'err');
      }catch(e){st.textContent='失败';st.className='st err'}}
      i++;next();
    };
    xhr.onerror=function(){it.done=true;if(st){st.textContent='失败';st.className='st err'}i++;next()};
    xhr.send(fd);
  })();
};
</script></body></html>`
    return WifiBookServer.textBytes(html)
  }

  /**
   * 电脑阅读·书库页（v3.11，用户需求"真正好用实用的电脑阅读"；功能形态借鉴
   * gedoor/legado 内置 Web 服务：书架浏览 + 阅读页设置[字号/行距/背景/全屏]）。
   */
  private static libraryPageBytes(entries: LibraryEntry[]): Uint8Array {
    let rows: string = ''
    entries.forEach((e: LibraryEntry) => {
      const isTxt: boolean = e.url.endsWith('.txt')
      // 书名 HTML 转义（防文件名里的 <> 破坏列表结构）
      const safeName: string = e.name.replace(/[&<>"]/g, (c: string): string => {
        if (c === '&') {
          return '&amp;'
        }
        if (c === '<') {
          return '&lt;'
        }
        if (c === '>') {
          return '&gt;'
        }
        return '&quot;'
      })
      const action: string = isTxt
        ? `<a class="rd" href="/read?id=${e.id}">阅读</a><a class="dl" href="/book?id=${e.id}">下载</a>`
        : `<a class="dl only" href="/book?id=${e.id}">下载 epub</a>`
      rows += `<div class="it"><div class="ico">${isTxt ? 'TXT' : 'EPUB'}</div>` +
        `<div class="meta"><div class="nm">${safeName}</div><div class="sz">${e.sizeKB} KB</div></div>${action}</div>`
    })
    const html: string = `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>喵阅 · 书库</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'PingFang SC',sans-serif;background:#F2F3F7;min-height:100vh;color:#1a1a1a}
.wrap{max-width:640px;margin:0 auto;padding:28px 20px 48px}
h1{font-size:22px;font-weight:700}
.sub{color:#8a8f99;font-size:13px;margin:6px 0 20px}
.card{background:#fff;border-radius:16px;box-shadow:0 2px 12px rgba(0,0,0,.05);padding:6px 16px}
.it{display:flex;align-items:center;gap:12px;padding:14px 4px;border-bottom:1px solid #F2F3F7}
.it:last-child{border-bottom:0}
.ico{width:40px;height:40px;border-radius:10px;background:#F0F7FF;color:#0A84FF;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;flex-shrink:0}
.meta{flex:1;min-width:0}
.nm{font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sz{font-size:12px;color:#8a8f99;margin-top:2px}
a{font-size:13px;font-weight:600;text-decoration:none;padding:7px 14px;border-radius:9px}
.rd{background:#0A84FF;color:#fff}
.dl{background:#F0F7FF;color:#0A84FF}
.empty{padding:28px;text-align:center;color:#c2c6cf;font-size:13px}
.nav{margin-top:18px;text-align:center;font-size:14px}
.nav a{color:#0A84FF;text-decoration:none;font-weight:600;padding:0}
</style></head><body><div class="wrap">
<h1>书库</h1>
<p class="sub">手机书架上的本地书（${entries.length} 本）— txt 可直接阅读</p>
<div class="card">${entries.length > 0 ? rows : '<div class="empty">书架还没有本地书籍，先去 <a href="/" style="color:#0A84FF">传书</a></div>'}</div>
<p class="nav"><a href="/">← 返回传书</a></p>
</div></body></html>`
    return WifiBookServer.textBytes(html)
  }

  /**
   * 电脑阅读·阅读器页（v3.11；阅读设置对齐 legado web：字号/行距/背景色/全屏
   * 隐藏工具栏；进度按书 id 记 localStorage，重开续读）。
   */
  private static readPageBytes(id: number, title: string): Uint8Array {
    const safeTitle: string = title.replace(/[<>&"]/g, '')
    const html: string = `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${safeTitle} · 喵阅</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
html{scroll-behavior:smooth}
body{font-family:Georgia,'Songti SC','SimSun',serif;transition:background .25s,color .25s}
body.day{background:#F7F5EF;color:#2b2b2b}
body.sepia{background:#E8E1D3;color:#3d3527}
body.night{background:#17181C;color:#A8A9AD}
#bar{position:fixed;top:0;left:0;right:0;display:flex;align-items:center;gap:8px;padding:10px 14px;
background:rgba(255,255,255,.92);backdrop-filter:blur(10px);box-shadow:0 1px 6px rgba(0,0,0,.06);z-index:9;transition:.25s}
body.night #bar{background:rgba(28,29,33,.92)}
body.hide #bar{transform:translateY(-60px)}
#bar b{font-size:14px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-family:-apple-system,sans-serif}
#bar button{border:0;background:#F0F1F5;border-radius:8px;padding:7px 11px;font-size:13px;cursor:pointer;font-weight:600;color:#333}
body.night #bar button{background:#2A2B30;color:#ccc}
a.bk{text-decoration:none;color:#333;font-size:14px;font-weight:600;background:#F0F1F5;border-radius:8px;padding:7px 11px;font-family:-apple-system,sans-serif}
body.night a.bk{background:#2A2B30;color:#ccc}
#content{max-width:720px;margin:0 auto;padding:86px 26px 90px;font-size:19px;line-height:1.9;text-indent:2em}
#content p{margin:0 0 1em}
#prog{position:fixed;bottom:0;left:0;right:0;padding:8px 14px;font:12px -apple-system,sans-serif;color:#8a8f99;
display:flex;justify-content:space-between;background:rgba(255,255,255,.92);backdrop-filter:blur(10px);z-index:9;transition:.25s}
body.night #prog{background:rgba(28,29,33,.92)}
body.hide #prog{transform:translateY(50px)}
</style></head><body class="day">
<div id="bar">
  <a class="bk" href="/library">← 书库</a>
  <b>${safeTitle}</b>
  <button onclick="fs(-1)">A-</button><button onclick="fs(1)">A+</button>
  <button onclick="ls()">行距</button><button onclick="bg()">背景</button>
  <button onclick="full()">全屏</button>
</div>
<div id="content">加载中…</div>
<div id="prog"><span id="pct">0%</span><span>${safeTitle}</span></div>
<script>
var id='${id}';
var el=document.getElementById('content');
var st={
  f: parseInt(localStorage.getItem('mr_f_'+id)||'19'),
  lh:[1.6,1.9,2.2][parseInt(localStorage.getItem('mr_lh_'+id)||'1')],
  th: localStorage.getItem('mr_th_'+id)||'day'
};
function apply(){el.style.fontSize=st.f+'px';el.style.lineHeight=st.lh;
  document.body.className=st.th+(document.body.classList.contains('hide')?' hide':'')}
function fs(d){st.f=Math.max(13,Math.min(34,st.f+d));localStorage.setItem('mr_f_'+id,st.f);apply()}
function ls(){var i=[1.6,1.9,2.2].indexOf(st.lh);st.lh=[1.6,1.9,2.2][(i+1)%3];
  localStorage.setItem('mr_lh_'+id,[1.6,1.9,2.2].indexOf(st.lh));apply()}
function bg(){st.th={day:'sepia',sepia:'night',night:'day'}[st.th];
  localStorage.setItem('mr_th_'+id,st.th);apply()}
function full(){document.body.classList.toggle('hide')}
function pct(){var h=el.scrollHeight-innerHeight;var p=h>0?Math.round(scrollY/h*100):100;
  document.getElementById('pct').textContent=p+'%';
  localStorage.setItem('mr_p_'+id,scrollY)}
var t=null;
addEventListener('scroll',function(){if(t)return;t=setTimeout(function(){t=null;pct()},200)});
el.onclick=function(e){if(e.clientY<innerHeight*0.12||e.clientY>innerHeight*0.88){full()}};
fetch('/book?id='+id).then(function(r){return r.text()}).then(function(txt){
  el.innerHTML=txt.split(/\\n\\s*\\n|\\r\\n\\s*\\r\\n/).map(function(p){
    return '<p>'+(p||'&nbsp;').replace(/</g,'&lt;')+'</p>'}).join('');
  var saved=parseInt(localStorage.getItem('mr_p_'+id)||'0');
  if(saved>0){setTimeout(function(){scrollTo(0,saved)},50)}
  pct();
});
apply();
</script></body></html>`
    return WifiBookServer.textBytes(html)
  }

  private static async serveBookFile(client: socket.TCPSocketConnection, id: number): Promise<void> {
    const book: Books | null = await WifiBookServer.bookById(id)
    if (book === null || !book.bookUrl) {
      WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8', WifiBookServer.textBytes('book not found'))
      return
    }
    const entryPath: string = book.bookUrl
    const entryName: string = book.bookName ?? 'book'
    try {
      const file = fs.openSync(entryPath, fs.OpenMode.READ_ONLY)
      const size: number = fs.statSync(entryPath).size
      const buffer: ArrayBuffer = new ArrayBuffer(size)
      fs.readSync(file.fd, buffer)
      fs.closeSync(file)
      const isTxt: boolean = entryPath.endsWith('.txt')
      WifiBookServer.respond(client, 200,
        isTxt ? 'text/plain; charset=utf-8' : 'application/octet-stream',
        new Uint8Array(buffer), isTxt ? undefined : `attachment; filename="${entryName}.epub"`)
    } catch (err) {
      WifiBookServer.respond(client, 500, 'text/plain; charset=utf-8', WifiBookServer.textBytes('read failed'))
    }
  }

  private static handleUpload(client: socket.TCPSocketConnection, req: ParsedHttp): void {
    const contentType: string = req.headers['content-type'] ?? ''
    const bIdx: number = contentType.indexOf('boundary=')
    if (bIdx < 0) {
      WifiBookServer.respondJson(client, false, '不是有效的文件上传请求')
      return
    }
    const boundary: string = '--' + contentType.substring(bIdx + 9).trim().replace(/"/g, '')
    const boundBytes: Uint8Array = WifiBookServer.textBytes(boundary)
    // 结构：--b\r\n头\r\n\r\n内容\r\n--b\r\n…\r\n--b--\r\n
    const crlf: Uint8Array = new Uint8Array([0x0D, 0x0A])
    let imported: number = 0
    let failed: number = 0
    let cursor: number = indexOfBytes(req.body, boundBytes, 0)
    while (cursor >= 0) {
      const partStart: number = cursor + boundBytes.length
      const next: number = indexOfBytes(req.body, boundBytes, partStart)
      if (next < 0) {
        break
      }
      // 段内容（剥掉结尾 \r\n）
      let seg: Uint8Array = req.body.slice(partStart, next)
      if (seg.length >= 2 && seg[seg.length - 2] === 0x0D && seg[seg.length - 1] === 0x0A) {
        seg = seg.slice(0, seg.length - 2)
      }
      // 段头与段体
      const headEnd: number = indexOfBytes(seg, new Uint8Array([0x0D, 0x0A, 0x0D, 0x0A]), 0)
      if (headEnd >= 0) {
        const segHead: string = bytesToUtf8(seg.slice(0, headEnd))
        const segBody: Uint8Array = seg.slice(headEnd + 4)
        const nameMatch: RegExpMatchArray | null = segHead.match(/filename="([^"]*)"/)
        const fileName: string = (nameMatch !== null && nameMatch[1] !== '') ? nameMatch[1] :
          `导入书籍_${Date.now()}.txt`
        if (segBody.length > 0 && WifiBookServer.saveAndImport(fileName, segBody)) {
          imported++
        } else {
          failed++
        }
      }
      cursor = next
    }
    WifiBookServer.respondJson(client, imported > 0,
      imported > 0 ? `已导入 ${imported} 本${failed > 0 ? `，失败 ${failed} 本` : ''}` : '没有可导入的文件')
  }

  /** 写沙箱 + 入库（与 FileHandler.CopyFile 同款字段），返回书目条目 */
  private static saveAndImport(fileName: string, content: Uint8Array): boolean {
    try {
      const ctx = getContext() as common.Context
      const safeName: string = fileName.replace(/[\/\\:*?"<>|]/g, '_')
      const dst: string = ctx.filesDir + '/' + safeName
      const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, content.slice().buffer as ArrayBuffer)
      fs.closeSync(file)
      const book: Books = {
        bookName: safeName,
        bookUrl: dst,
        author: '暂无',
        bookGroup: 4,
        latestChapterTime: 0,
        totalChapterNum: 0,
        durChapterIndex: 0,
        durChapterPos: 0,
        durChapterTime: 0,
        canUpdate: false,
        sort: 0,
        originOrder: 0,
        syncTime: 0,
        bookType: 0,
        isTop: false,
        isJoin: true,
        isLocalBook: true
      }
      booksUtil.addBooks(book)
      WifiBookServer.shelf.push({ id: WifiBookServer.nextId++, name: safeName, path: dst, size: content.length })
      WifiBookServer.notify()
      console.info(`${TAG} imported: ${safeName} (${content.length} bytes)`)
      return true
    } catch (err) {
      console.error(`${TAG} saveAndImport failed: ${(err as Error).message}`)
      return false
    }
  }

  // ── HTTP 基础设施 ──────────────────────────────────────────────────────
  private static textBytes(text: string): Uint8Array {
    const encoder = util.TextEncoder.create('utf-8')
    return encoder.encodeInto(text)
  }

  private static respond(client: socket.TCPSocketConnection, status: number,
    contentType: string, body: Uint8Array, disposition?: string): void {
    const statusText: string = status === 200 ? 'OK' : (status === 404 ? 'Not Found' : 'Error')
    let head: string = `HTTP/1.1 ${status} ${statusText}\r\n` +
      `Content-Type: ${contentType}\r\n` +
      `Content-Length: ${body.length}\r\n` +
      `Connection: close\r\n`
    if (disposition !== undefined) {
      head += `Content-Disposition: ${disposition}\r\n`
    }
    head += '\r\n'
    const out: Uint8Array = concatBytes(WifiBookServer.textBytes(head), body)
    client.send({ data: out.slice().buffer as ArrayBuffer }).catch((err: Error) => {
      console.error(`${TAG} send failed: ${err.message}`)
    })
  }

  private static respondJson(client: socket.TCPSocketConnection, ok: boolean, msg: string): void {
    WifiBookServer.respond(client, ok ? 200 : 400, 'application/json; charset=utf-8',
      WifiBookServer.textBytes(JSON.stringify({ ok: ok, msg: msg })))
  }
}
