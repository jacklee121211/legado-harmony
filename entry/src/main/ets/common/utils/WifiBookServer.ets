import { socket } from '@kit.NetworkKit'
import { wifiManager } from '@kit.ConnectivityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { common, wantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import booksUtil from './booksUtils'
import booksDao from '../../database/dao/BooksDao'
import bookmarksDao from '../../database/dao/BookmarksDao'
import { Books } from '../../database/entities/Books'
import { PreferencesUtil, AppUtil } from '@pura/harmony-utils'
import { emitter } from '@kit.BasicServicesKit'
import syncConfig, { SyncPos, SYNC_V2_ENABLED, normEx } from './SyncConfig'
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
const TAG: string = 'WifiBookServer';
/**
 * 目录快照条目（`GET /toc` 的载荷）。
 * 字段名与网页端 `web/src/protocol.types.ts` 的 `TocEntry` **必须一致**（同一条契约）。
 */
/** 服务器会话内已知书目（电脑阅读列表用） */
interface ShelfEntry {
    id: number;
    name: string;
    path: string;
    size: number;
}
/** 电脑阅读·书库条目（实时查自书架 DB） */
interface LibraryEntry {
    id: number;
    name: string;
    url: string;
    sizeKB: number;
}
function bytesToUtf8(bytes: Uint8Array): string {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
}
function indexOfBytes(hay: Uint8Array, needle: Uint8Array, from: number): number {
    if (needle.length === 0 || hay.length < needle.length) {
        return -1;
    }
    for (let i = from; i <= hay.length - needle.length; i++) {
        let hit = true;
        for (let j = 0; j < needle.length; j++) {
            if (hay[i + j] !== needle[j]) {
                hit = false;
                break;
            }
        }
        if (hit) {
            return i;
        }
    }
    return -1;
}
function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
}
/**
 * 整数 IP → 点分十进制。
 * ⚠️ 换算口径以官方 FAQ 为准（faqs-connectivity-4 原文）：
 *   `(ipAddress >>> 24) + "." + (ipAddress >> 16 & 0xFF) + "." + (ipAddress >> 8 & 0xFF) + "." + (ipAddress & 0xFF)`
 * 即**大端序**（首字节在高位）。真机实证：小端序曾输出 241.3.168.192（倒序、不可访问），
 * 大端序输出 192.168.3.241（正确局域网段）。
 */
function ipNumberToDotted(ip: number): string {
    return `${(ip >>> 24) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 8) & 0xFF}.${ip & 0xFF}`;
}
interface ParsedHttp {
    method: string;
    /** 原始请求目标（含 query，如 /read?id=1）——id 类路由从这里取参 */
    target: string;
    path: string;
    headers: Record<string, string>;
    body: Uint8Array;
    /** 本次请求消费的字节数（head + content-length），keep-alive 粘包消费用 */
    consumed: number;
}
export class WifiBookServer {
    private static server: socket.TCPSocketServer | null = null;
    private static running: boolean = false;
    private static port: number = 1122;
    private static shelf: ShelfEntry[] = [];
    private static nextId: number = 1;
    /** 状态订阅者（传书对话框刷新用） */
    private static listeners: Array<() => void> = [];
    static isRunning(): boolean {
        return WifiBookServer.running;
    }
    static getPort(): number {
        return WifiBookServer.port;
    }
    static address(): string {
        if (!WifiBookServer.running) {
            return '';
        }
        try {
            const ip: number = wifiManager.getIpInfo().ipAddress;
            const dotted: string = ipNumberToDotted(ip);
            return dotted.length > 0 ? `http://${dotted}:${WifiBookServer.port}` : '';
        }
        catch (err) {
            console.error(`${TAG} getIpInfo failed: ${(err as Error).message}`);
            return '';
        }
    }
    /** 书目快照（对话框/页面渲染用） */
    static shelfList(): ShelfEntry[] {
        return WifiBookServer.shelf;
    }
    static onChange(listener: () => void): void {
        WifiBookServer.listeners.push(listener);
    }
    static offChange(listener: () => void): void {
        const i = WifiBookServer.listeners.indexOf(listener);
        if (i >= 0) {
            WifiBookServer.listeners.splice(i, 1);
        }
    }
    private static notify(): void {
        WifiBookServer.listeners.forEach((fn: () => void) => fn());
    }
    static start(context: common.UIAbilityContext, onResult?: (ok: boolean, msg: string) => void): void {
        if (WifiBookServer.running) {
            onResult?.(true, '');
            return;
        }
        const server = socket.constructTCPSocketServerInstance();
        WifiBookServer.server = server;
        server.on('connect', (client: socket.TCPSocketConnection) => {
            WifiBookServer.handleClient(client);
        });
        server.listen({ address: '0.0.0.0', port: WifiBookServer.port, family: 1 }, (err: Error | null) => {
            if (err) {
                WifiBookServer.running = false;
                console.error(`${TAG} listen failed: ${err.message}`);
                onResult?.(false, `端口 ${WifiBookServer.port} 绑定失败：${err.message}`);
            }
            else {
                WifiBookServer.running = true;
                console.info(`${TAG} listening on ${WifiBookServer.port}`);
                WifiBookServer.notify();
                onResult?.(true, '');
                // 锁屏后台保活：DATA_TRANSFER 长时任务（后台任务 Kit 官方 API）。
                // 语义匹配：wifi传书 = 数据传输；官方约束"进度 10 分钟不更新会取消任务"
                // 对传书场景天然满足。锁屏后 TCPServer 不再被挂起 ⇒ 电脑阅读不掉线。
                const agentInfo: wantAgent.WantAgentInfo = {
                    wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
                    actionType: wantAgent.OperationType.START_ABILITY,
                    requestCode: 0
                };
                wantAgent.getWantAgent(agentInfo)
                    .then((agent: object) => {
                    backgroundTaskManager.startBackgroundRunning(context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent)
                        .then((): void => console.info(`${TAG} background running ok`))
                        .catch((e: BusinessError): void => console.error(`${TAG} bg start failed: ${e.code} ${e.message}`));
                })
                    .catch((e: BusinessError): void => console.error(`${TAG} wantAgent failed: ${e.message}`));
            }
        });
    }
    static stop(context: common.UIAbilityContext, onResult?: (ok: boolean) => void): void {
        if (WifiBookServer.server === null || !WifiBookServer.running) {
            WifiBookServer.running = false;
            WifiBookServer.notify();
            onResult?.(true);
            return;
        }
        // 先撤长时任务再关端口（顺序保证锁屏期间关闭也生效）
        backgroundTaskManager.stopBackgroundRunning(context)
            .catch((e: BusinessError): void => console.error(`${TAG} bg stop failed: ${e.code} ${e.message}`));
        WifiBookServer.server.close()
            .then((): void => {
            WifiBookServer.running = false;
            WifiBookServer.notify();
            onResult?.(true);
        })
            .catch((err: Error): void => {
            WifiBookServer.running = false;
            WifiBookServer.notify();
            onResult?.(false);
            console.error(`${TAG} close failed: ${err.message}`);
        });
    }
    // ── 连接层 ────────────────────────────────────────────────────────────
    private static handleClient(client: socket.TCPSocketConnection): void {
        let buffer: Uint8Array = new Uint8Array(0);
        client.on('message', (info: socket.SocketMessageInfo) => {
            buffer = concatBytes(buffer, new Uint8Array(info.message));
            // 循环消费（keep-alive 下多个请求可能粘在一个 message 里）
            for (;;) {
                const parsed: ParsedHttp | null = WifiBookServer.tryParse(buffer);
                if (parsed === null) {
                    break;
                }
                buffer = buffer.slice(parsed.consumed);
                WifiBookServer.dispatch(client, parsed);
                if (buffer.length === 0) {
                    break;
                }
            }
        });
    }
    /** 头部完整且 body 收满时解析请求；否则返回 null（继续等） */
    private static tryParse(buffer: Uint8Array): ParsedHttp | null {
        const sep: Uint8Array = new Uint8Array([0x0D, 0x0A, 0x0D, 0x0A]);
        const headEnd: number = indexOfBytes(buffer, sep, 0);
        if (headEnd < 0) {
            return null;
        }
        const headText: string = bytesToUtf8(buffer.slice(0, headEnd));
        const lines: string[] = headText.split('\r\n');
        const requestLine: string = lines[0] ?? '';
        const parts: string[] = requestLine.split(' ');
        if (parts.length < 2) {
            return null;
        }
        const headers: Record<string, string> = {};
        for (let i = 1; i < lines.length; i++) {
            const idx: number = lines[i].indexOf(':');
            if (idx > 0) {
                headers[lines[i].substring(0, idx).trim().toLowerCase()] = lines[i].substring(idx + 1).trim();
            }
        }
        const contentLength: number = Number(headers['content-length'] ?? '0') || 0;
        const bodyStart: number = headEnd + 4;
        if (buffer.length < bodyStart + contentLength) {
            return null;
        }
        const body: Uint8Array = buffer.slice(bodyStart, bodyStart + contentLength);
        const path: string = parts[1].split('?')[0] ?? '/';
        return {
            method: (parts[0] ?? 'GET').toUpperCase(),
            target: parts[1] ?? '/',
            path: path,
            headers: headers,
            body: body,
            consumed: bodyStart + contentLength
        };
    }
    // ── 分发 ──────────────────────────────────────────────────────────────
    private static dispatch(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        // DB 查询是异步的 ⇒ 实际处理挪进 async（fire-and-forget，respond 自带错误兜底）
        WifiBookServer.dispatchAsync(client, req);
    }
    private static async dispatchAsync(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
        try {
            if (req.method === 'GET' && (req.path === '/' || req.path === '/index.html')) {
                const v3 = WifiBookServer.readV3PageBytes('upload_v3.html');
                WifiBookServer.respond(client, 200, 'text/html; charset=utf-8',
                    v3 !== null ? v3 : WifiBookServer.uploadPageBytes());
            }
            else if (req.method === 'GET' && req.path === '/library') {
                // 电脑阅读·书库页：v3 是静态单文件（列表由页面自己 fetch /books）；失败回退旧内嵌页
                const v3 = WifiBookServer.readV3PageBytes('library_v3.html');
                if (v3 !== null) {
                    WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', v3);
                } else {
                    // 电脑阅读·书库页：实时查书架全部本地书（searchPage bookGroup=4 = 本地 or isLocalBook）
                    const entries: LibraryEntry[] = await WifiBookServer.libraryEntries();
                    WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', WifiBookServer.libraryPageBytes(entries));
                }
            }
            else if (req.method === 'GET' && req.path === '/books') {
                // JSON API（保留）：书目列表
                const entries: LibraryEntry[] = await WifiBookServer.libraryEntries();
                WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify(entries)));
            }
            else if (req.method === 'GET' && req.path.startsWith('/read')) {
                // 电脑阅读·阅读器页（⚠️ id 从 target 取——tryParse 的 path 已剥掉 query）
                const book: Books | null = await WifiBookServer.bookById(WifiBookServer.queryId(req.target));
                if (book === null) {
                    WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8', WifiBookServer.textBytes('book not found'));
                    return;
                }
                WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', WifiBookServer.readPageBytes(book.id ?? 0, book.bookName ?? '未命名'));
            }
            else if (req.method === 'GET' && req.path.startsWith('/download')) {
                // v3.14：强制下载（书库页"下载"按钮走这里，浏览器弹保存而非内联打开）
                await WifiBookServer.serveDownload(client, WifiBookServer.queryId(req.target));
            }
            else if (req.method === 'GET' && req.path.startsWith('/book')) {
                await WifiBookServer.serveBookFile(client, WifiBookServer.queryId(req.target));
            }
            else if (req.method === 'GET' && req.path.startsWith('/toc')) {
                // 单源目录（M3）：把手机端目录标题在**正在下发的同一串文本**上定位成字符区间
                await WifiBookServer.handleTocGet(client, WifiBookServer.queryId(req.target));
            }
            else if (req.method === 'GET' && req.path.startsWith('/marks')) {
                // 书签双向同步（2026-10-01）：web 书签直接读写手机 bookmarks 表
                await WifiBookServer.handleMarksGet(client, WifiBookServer.queryId(req.target));
            }
            else if (req.method === 'POST' && req.path === '/marksadd') {
                await WifiBookServer.handleMarksAdd(client, req);
            }
            else if (req.method === 'POST' && req.path === '/marksdel') {
                await WifiBookServer.handleMarksDel(client, req);
            }
            else if (req.method === 'GET' && req.path.startsWith('/sync')) {
                // 进度同步 v1（章节级，2026-10-01 专项）：web 打开时取手机端阅读位置
                await WifiBookServer.handleSyncGet(client, WifiBookServer.queryId(req.target));
            }
            else if (req.method === 'POST' && req.path === '/sync') {
                // web 阅读位置写回（手机端打开书时据此提示跳转）
                WifiBookServer.handleSyncPost(client, req);
            }
            else if (req.method === 'POST' && req.path === '/upload') {
                WifiBookServer.handleUpload(client, req);
            }
            else {
                WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8', WifiBookServer.textBytes('not found'));
            }
        }
        catch (err) {
            console.error(`${TAG} dispatch error: ${(err as Error).message}`);
        }
    }
    /** 从请求目标取 id（/read?id=N / /book?id=N） */
    private static queryId(target: string): number {
        const m: RegExpMatchArray | null = target.match(/id=(\d+)/);
        if (m !== null) {
            return Number(m[1]);
        }
        const digits: string = target.replace(/[^0-9]/g, '');
        return Number(digits === '' ? '-1' : digits);
    }
    /** 书架全部本地书（searchPage bookGroup=4 ⇒ 本地分组 or isLocalBook，pageSize 0 = 全量） */
    private static async libraryEntries(): Promise<LibraryEntry[]> {
        const books: Books[] = await booksDao.searchPage({ bookGroup: 4 }, 1, 0);
        const out: LibraryEntry[] = [];
        books.forEach((b: Books) => {
            if (b.bookUrl && b.bookUrl.length > 0) {
                out.push({
                    id: b.id ?? 0,
                    name: b.bookName ?? '未命名',
                    url: b.bookUrl,
                    sizeKB: WifiBookServer.fileSizeKB(b.bookUrl)
                });
            }
        });
        return out;
    }
    private static async bookById(id: number): Promise<Books | null> {
        if (id < 0) {
            return null;
        }
        const arr: Books[] = await booksDao.getBookByIds([id]);
        return arr.length > 0 ? arr[0] : null;
    }
    private static fileSizeKB(path: string): number {
        try {
            return Math.round(fs.statSync(path).size / 1024);
        }
        catch (err) {
            return 0;
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
<p class="nav">想在电脑上阅读？<a href="/library">打开书库 →</a> · <span style="color:#c2c6cf">喵阅 Web v3.14</span></p>
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
    d.querySelector('.x').onclick=function(){var k=files.indexOf(it);if(k>=0){files.splice(k,1);render()}};
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
    if(i>=pend.length){btn.disabled=false;return}
    var it=pend[i];var card=[].slice.call(list.children).find(function(c){
      return c.querySelector('.name').textContent===it.f.name});
    var st=card?card.querySelector('.st'):null;var bar=card?card.querySelector('.bar i'):null;
    if(st){st.textContent='连接中…';st.className='st wait'}
    if(bar){bar.style.width='0%'}
    var fd=new FormData();fd.append('file',it.f);
    var xhr=new XMLHttpRequest();
    xhr.open('POST','/upload');
    xhr.upload.onloadstart=function(){if(st){st.textContent='发送 0%'}};
    if(bar){xhr.upload.onprogress=function(e){if(e.lengthComputable){
      var p=Math.round(e.loaded/e.total*100);
      bar.style.width=p+'%';
      if(st){st.textContent='发送 '+p+'%'}
    }}}
    xhr.upload.onload=function(){
      if(bar){bar.style.width='100%'}
      if(st){st.textContent='手机处理中…'}
    };
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
</script></body></html>`;
        return WifiBookServer.textBytes(html);
    }
    /**
     * 电脑阅读·书库页（v3.11，用户需求"真正好用实用的电脑阅读"；功能形态借鉴
     * gedoor/legado 内置 Web 服务：书架浏览 + 阅读页设置[字号/行距/背景/全屏]）。
     */
    private static libraryPageBytes(entries: LibraryEntry[]): Uint8Array {
        let rows: string = '';
        entries.forEach((e: LibraryEntry) => {
            const isTxt: boolean = e.url.endsWith('.txt');
            // 书名 HTML 转义（防文件名里的 <> 破坏列表结构）
            const safeName: string = e.name.replace(/[&<>"]/g, (c: string): string => {
                if (c === '&') {
                    return '&amp;';
                }
                if (c === '<') {
                    return '&lt;';
                }
                if (c === '>') {
                    return '&gt;';
                }
                return '&quot;';
            });
            const action: string = isTxt
                ? `<a class="rd" href="/read?id=${e.id}">阅读</a><a class="dl" href="/download?id=${e.id}">下载</a>`
                : `<a class="dl only" href="/download?id=${e.id}">下载 epub</a>`;
            rows += `<div class="it"><div class="ico">${isTxt ? 'TXT' : 'EPUB'}</div>` +
                `<div class="meta"><div class="nm">${safeName}</div><div class="sz">${e.sizeKB} KB</div></div>${action}</div>`;
        });
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
<p class="nav"><a href="/">← 返回传书</a> · <span style="color:#c2c6cf">喵阅 Web v3.14</span></p>
</div></body></html>`;
        return WifiBookServer.textBytes(html);
    }
    /**
     * 电脑阅读·阅读器页（v3.11；阅读设置对齐 legado web：字号/行距/背景色/全屏
     * 隐藏工具栏；进度按书 id 记 localStorage，重开续读）。
     */
    /**
     * 电脑阅读·阅读器页 v3.19（用户三反馈的修正版）：
     * ① **章跟踪修复**（v3.18 的真 bug）：滚动模式下 curCh 从未更新（恒 0）⇒ 书签
     *    恒落错章、同步恒推错章。现在滚动节流回调里按**视口顶所在段**反查当前章；
     *    分页在每次落定后同步。书签/进度的章节从此与真实阅读位置一致。
     * ② **同步触发补全**：v3.18 只在滚动时 push（分页翻页不推）⇒ 电脑翻章手机无感。
     *    现在：滚动节流 push + 分页落定 push（章变化强制，5s 节流只限同章连翻）；
     *    web 端 10s 轮询 /sync 保留。
     * ③ **双页回退平移方案**（用户拍板"越简单越好，直接平移也行，只要保证 AB 页"）：
     *    v3.18 显式页栈重构崩溃且波及其它模式 ⇒ 整体移除；回到 v3.17 验证过的
     *    columns+translate 平移，仅保留"一张纸=两列"步长与偶对齐（AB→BC 语义正确）。
     * ④ 书签直连手机 bookmarks 表（/marks 三路由）、数字优先章节匹配、系统字体栈、
     *    抽屉搜索/书签双 Tab——均自 v3.16~v3.18 保留。
     */
    /**
     * 阅读页字节。
     *
     * **v3（2026-10-05 起默认）**：直接把 `web/` 真前端工程的构建产物
     * `rawfile/reader_v3.html` 原样发出去（自带 CSS/JS，运行时用 `?id=` 自己取数）。
     * 这么做的好处（对比旧实现把整页 HTML/JS 塞进 ArkTS 模板字符串）：
     *   · 61 个前端函数第一次能被 lint / 类型检查 / 单测（`web/test`）/ 浏览器断点；
     *   · 服务端**零字符串拼接**（我曾在注释里打反引号截断模板字符串，编译直接失败）；
     *   · 前端可离线本地跑（`web/dev/server.mjs` + mock）。
     * 失败（资源缺失/读取异常）⇒ 自动回退旧内嵌页，绝不让阅读不可用。
     * 回退开关：把 `USE_V3_READER` 置 false。
     */
    private static readonly USE_V3_READER: boolean = true;
    private static readerHtmlCache: Uint8Array | null = null;

    /**
     * 读取 `web/` 构建产物（rawfile 下的 `*_v3.html`）并缓存；失败返回 null，调用方回退旧内嵌页。
     * @param file rawfile 内的文件名：'reader_v3.html' / 'library_v3.html' / 'upload_v3.html'
     */
    private static readV3PageBytes(file: string): Uint8Array | null {
        if (!WifiBookServer.USE_V3_READER) {
            return null;
        }
        if (file === 'reader_v3.html' && WifiBookServer.readerHtmlCache !== null) {
            return WifiBookServer.readerHtmlCache;
        }
        try {
            // ⚠️ 上下文走 AppUtil（EntryAbility.onCreate 已 init ⇒ 确定性；
            //    `getContext()` 在异步链里链路回溯不可靠，见 FileHandler 文件头注释）
            const ctx = AppUtil.getContext() as common.Context;
            const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(file);
            if (bytes === undefined || bytes.byteLength === 0) {
                console.error(`${TAG} ${file} 为空`);
                return null;
            }
            if (file === 'reader_v3.html') {
                WifiBookServer.readerHtmlCache = bytes;
            }
            return bytes;
        }
        catch (err) {
            console.error(`${TAG} 读取 ${file} 失败: ${(err as Error).message}`);
            return null;
        }
    }

    private static readV3ReaderBytes(): Uint8Array | null {
        return WifiBookServer.readV3PageBytes('reader_v3.html');
    }
    private static readPageBytes(id: number, title: string): Uint8Array {
        if (WifiBookServer.USE_V3_READER) {
            const v3 = WifiBookServer.readV3ReaderBytes();
            if (v3 !== null) {
                return v3;
            }
            console.warn(`${TAG} 新版阅读页不可用，回退旧内嵌页`);
        }
        const safeTitle: string = title.replace(/[<>&"]/g, '');
        const html: string = `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${safeTitle} · 喵阅</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'HarmonyOS Sans SC','PingFang SC','Microsoft YaHei',sans-serif;transition:background .25s,color .25s;overflow:hidden}
body.day{background:#F7F5EF;color:#2b2b2b}
body.sepia{background:#E8E1D3;color:#3d3527}
body.night{background:#17181C;color:#A8A9AD}
#bar{position:fixed;top:0;left:0;right:0;display:flex;align-items:center;gap:6px;padding:10px 14px;
background:rgba(255,255,255,.94);backdrop-filter:blur(10px);box-shadow:0 1px 6px rgba(0,0,0,.06);z-index:20;transition:.25s}
body.night #bar{background:rgba(28,29,33,.94)}
body.hide #bar{transform:translateY(-64px)}
#bar b{font-size:14px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#bar button{border:0;background:#F0F1F5;border-radius:8px;padding:7px 10px;font-size:13px;cursor:pointer;font-weight:600;color:#333}
body.night #bar button{background:#2A2B30;color:#ccc}
a.bk{text-decoration:none;color:#333;font-size:14px;font-weight:600;background:#F0F1F5;border-radius:8px;padding:7px 11px}
body.night a.bk{background:#2A2B30;color:#ccc}
#scroll{position:fixed;top:52px;bottom:36px;left:0;right:0;overflow-y:auto;display:none}
#scroll.on{display:block}
#scroll .inner{max-width:720px;margin:0 auto;padding:20px 26px 60px;font-size:19px;line-height:1.9;text-indent:2em}
#scroll p{margin:0 0 1em}
#more{padding:14px;text-align:center;color:#a5abb5;font-size:13px}
#stage{position:fixed;top:52px;bottom:36px;left:0;right:0;display:none;overflow:hidden}
#stage.on{display:block}
#pages{height:100%;column-fill:auto;column-gap:64px;padding:0 34px;transition:transform .25s ease;
font-size:19px;line-height:1.9;text-indent:2em}
#pages p{margin:0 0 1em}
#spine{display:none;position:absolute;top:0;bottom:0;left:50%;width:64px;transform:translateX(-50%);
background:linear-gradient(90deg,rgba(0,0,0,0) 0%,rgba(0,0,0,.10) 42%,rgba(0,0,0,.16) 50%,rgba(0,0,0,.10) 58%,rgba(0,0,0,0) 100%);pointer-events:none}
#stage.two #spine{display:block}
#stage.shadow #pages{box-shadow:inset 14px 0 22px -18px rgba(0,0,0,.28),inset -14px 0 22px -18px rgba(0,0,0,.28)}
body.night #spine{background:linear-gradient(90deg,rgba(0,0,0,0),rgba(0,0,0,.5) 50%,rgba(0,0,0,0))}
#exit{position:fixed;right:16px;bottom:52px;z-index:30;display:none;border:0;width:42px;height:42px;
border-radius:50%;background:rgba(20,20,22,.55);color:#fff;font-size:17px;cursor:pointer;backdrop-filter:blur(6px)}
body.hide #exit{display:block}
#prog{position:fixed;bottom:0;left:0;right:0;padding:8px 14px;font:12px -apple-system,sans-serif;color:#8a8f99;
display:flex;justify-content:space-between;background:rgba(255,255,255,.94);backdrop-filter:blur(10px);z-index:20;transition:.25s}
body.night #prog{background:rgba(28,29,33,.94)}
body.hide #prog{transform:translateY(50px)}
#toc{position:fixed;top:0;bottom:0;left:0;width:320px;background:#fff;z-index:40;transform:translateX(-105%);
transition:.25s;box-shadow:4px 0 20px rgba(0,0,0,.12);display:flex;flex-direction:column}
body.night #toc{background:#1E1F24}
#toc.open{transform:none}
#toc header{padding:12px 14px 8px;font-weight:700;font-size:15px;display:flex;justify-content:space-between;align-items:center}
body.night #toc header{color:#eee}
#toc input{margin:0 14px 8px;border:1px solid #D8DBE2;border-radius:8px;padding:8px 10px;font-size:13px;outline:none}
body.night #toc input{background:#2A2B30;border-color:#3A3B40;color:#ddd}
#toc .tabs{display:flex;gap:6px;padding:0 14px 8px}
#toc .tabs button{flex:1;border:0;background:#F0F1F5;border-radius:8px;padding:7px 0;font-size:13px;cursor:pointer;font-weight:600;color:#555}
body.night #toc .tabs button{background:#2A2B30;color:#bbb}
#toc .tabs button.on{background:#0A84FF;color:#fff}
#toc .lst{flex:1;overflow-y:auto;padding:6px 0}
#toc .ch{padding:11px 18px;font-size:13.5px;color:#444;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:flex;align-items:center;gap:8px}
#toc .ch:hover{background:#F5F6F9;color:#0A84FF}
body.night #toc .ch{color:#bbb}
body.night #toc .ch:hover{background:#26272C;color:#5AB0FF}
#toc .ch .del{margin-left:auto;border:0;background:none;color:#c2c6cf;font-size:13px;cursor:pointer;flex-shrink:0}
#mask{position:fixed;inset:0;background:rgba(0,0,0,.25);z-index:35;display:none}
#mask.open{display:block}
#find{position:fixed;top:52px;right:14px;z-index:25;display:none;gap:6px}
#find.open{display:flex}
#find input{border:1px solid #D8DBE2;border-radius:8px;padding:7px 10px;font-size:13px;width:180px;outline:none}
body.night #find input{background:#2A2B30;border-color:#3A3B40;color:#ddd}
#syncbar{position:fixed;top:52px;left:50%;transform:translateX(-50%) translateY(-12px);z-index:26;
opacity:0;visibility:hidden;pointer-events:none;
display:flex;align-items:center;gap:10px;padding:8px 8px 8px 14px;border-radius:12px;font-size:13px;
background:rgba(255,255,255,.97);box-shadow:0 4px 18px rgba(0,0,0,.14);transition:.3s;max-width:86%}
body.night #syncbar{background:#26272C;color:#ddd}
#syncbar.show{opacity:1;visibility:visible;pointer-events:auto;transform:translateX(-50%) translateY(0)}
#syncbar button{border:0;background:#0A84FF;color:#fff;border-radius:8px;padding:6px 12px;font-size:12px;cursor:pointer;font-weight:600}
#syncbar .ig{background:#F0F1F5;color:#888}
</style></head><body class="day">
<div id="bar">
  <a class="bk" href="/library">← 书库</a>
  <b>${safeTitle}</b>
  <button onclick="toc()">目录</button>
  <button onclick="findToggle()">搜索</button>
  <button onclick="addMark()">＋签</button>
  <button onclick="fs(-1)">A-</button><button onclick="fs(1)">A+</button>
  <button onclick="ls()">行距</button><button onclick="bg()">背景</button>
  <button id="modeBtn" onclick="cycleMode()">滚动</button>
</div>
<div id="syncbar" style="flex-direction:column;align-items:stretch"><div id="synctxt" style="margin-bottom:6px"></div><div style="display:flex;gap:6px"><button onclick="syncJump(0)">跳到①</button><button onclick="syncJump(1)">跳到②</button><button class="ig" onclick="syncHide()">忽略</button></div></div>
<div id="find"><input id="fq" placeholder="查找内容…" onkeydown="if(event.key==='Enter')doFind()"></div>
<div id="scroll"><div class="inner" id="sinner"></div><div id="more" style="display:none">上滑加载更多…</div></div>
<div id="stage"><div id="pages"></div><div id="spine"></div></div>
<button id="exit" onclick="full()" title="退出全屏">⤢</button>
<div id="prog"><span id="pct">0%</span><span id="modeTag">滚动模式 · v3.19</span></div>
<div id="mask" onclick="toc()"></div>
<div id="toc"><header><span>目录与书签</span><button onclick="toc()" style="border:0;background:none;font-size:16px;cursor:pointer">✕</button></header>
<input id="tq" placeholder="检索章节…" oninput="filterCh()">
<div class="tabs"><button id="tabc" class="on" onclick="tab('c')">目录</button><button id="tabb" onclick="tab('b')">书签</button></div>
<div class="lst" id="chl"></div><div class="lst" id="bml" style="display:none"></div></div>
<script>
var id='${id}';
var mode='scroll';
var paras=[];
var rendered=0;
var curCh=0,pageIdx=0,pageCount=1,stride=0;
var sc=document.getElementById('scroll'),si=document.getElementById('sinner');
var stg=document.getElementById('stage'),pg=document.getElementById('pages');
function L(k,d){var v=localStorage.getItem('mr_'+k+'_'+id);return v===null?d:v}
function S(k,v){localStorage.setItem('mr_'+k+'_'+id,v)}
var st={f:parseInt(L('f','19')),lh:[1.6,1.9,2.2][parseInt(L('lh','1'))],th:L('th','day'),mode:L('mode','scroll')};
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function phtml(a,b){var h='';for(var i=a;i<b;i++){h+='<p>'+esc(paras[i])+'</p>'}return h}
function chTitle(k){var b=chBounds(k);return paras[b[0]].slice(0,30)}
/* ── 装载 ── */
var normParas=[];   // dual-anchor index
function render(txt){
  paras=txt.split(/\\n\\s*\\n|\\r\\n\\s*\\r\\n/).map(function(x){return x.trim()}).filter(function(x){return x.length>0});
  normParas=paras.map(function(x){return x.replace(/\s+/g,'')});
  buildToc();apply();renderMarks();
  if(st.mode==='scroll'){enterMode('scroll')}
  else{enterMode(st.mode)}
  syncCheck();
  setInterval(syncPoll,5000);   // v3.21：10s → 5s（实时感）
}
/* ── 滚动增量 ── */
function ensure(n){
  if(rendered>=n&&rendered>0)return;
  var to=Math.min(Math.max(n,0),paras.length);
  if(to>rendered){si.insertAdjacentHTML('beforeend',phtml(rendered,to));rendered=to}
  document.getElementById('more').style.display=(rendered<paras.length)?'block':'none';
}
sc.addEventListener('scroll',function(){
  if(mode!=='scroll')return;
  if(sc.scrollTop+sc.clientHeight>si.scrollHeight-700){ensure(rendered+300)}
  if(pt)return;pt=setTimeout(function(){pt=null;
    trackChByScroll();S('p_scroll',sc.scrollTop);updPct();syncPush(false);
  },200);
});
var pt=null;
/* v3.19 核心：滚动模式按"视口顶所在段"反查当前章（旧版 curCh 恒 0 ⇒ 书签/同步全错） */
function trackChByScroll(){
  if(chIdx.length===0){curCh=Math.min(chTotal()-1,Math.floor(sc.scrollTop/26000));return}
  var top=sc.scrollTop+80;var k=0;
  for(var i=0;i<si.children.length;i++){
    if(si.children[i].offsetTop>top)break;
    k=i;
  }
  var ck=0;
  for(var j=0;j<chIdx.length;j++){if(chIdx[j]<=k)ck=j;else break}
  curCh=ck;
}
/* ── 章节 ── */
var chIdx=[];
function buildToc(){
  var re=/^(第[0-9零一二三四五六七八九十百千万两]+[章节卷回集部篇]|序章|楔子|引子|前言|后记|尾声|番外)/;
  chIdx=[];
  for(var i=0;i<paras.length;i++){if(re.test(paras[i].slice(0,24))){chIdx.push(i)}}
  renderChList('');
}
function renderChList(q){
  var box=document.getElementById('chl');box.innerHTML='';
  if(chIdx.length===0){box.innerHTML='<div class="ch" style="color:#aaa">未识别到章节，已按块分页</div>';return}
  var shown=0;
  chIdx.forEach(function(pi,k){
    var t=paras[pi].slice(0,40);
    if(q&&t.indexOf(q)<0)return;
    var d=document.createElement('div');d.className='ch';
    d.textContent=(k+1)+'. '+t;
    d.onclick=function(){jumpTo(pi);toc()};
    box.appendChild(d);shown++;
  });
  if(!shown){box.innerHTML='<div class="ch" style="color:#aaa">没有匹配的章节</div>'}
}
function filterCh(){renderChList(document.getElementById('tq').value.trim())}
function tab(w){
  document.getElementById('chl').style.display=(w==='c')?'block':'none';
  document.getElementById('bml').style.display=(w==='b')?'block':'none';
  document.getElementById('tabc').classList.toggle('on',w==='c');
  document.getElementById('tabb').classList.toggle('on',w==='b');
  if(w==='b'){renderMarks()}
}
function chTotal(){return chIdx.length>0?chIdx.length:Math.ceil(paras.length/400)}
function chBounds(k){
  if(chIdx.length>0){var a=chIdx[k];var b=(k+1<chIdx.length)?chIdx[k+1]:paras.length;return[a,b]}
  return[k*400,Math.min((k+1)*400,paras.length)];
}
/* 段落 index → 所在章（书签落章用） */
function chOfPara(pi){
  var k=0;
  if(chIdx.length>0){for(var j=0;j<chIdx.length;j++){if(chIdx[j]<=pi)k=j;else break}}
  else{k=Math.floor(pi/400)}
  return k;
}
/* ── 书签（直连手机 bookmarks 表，双向）── */
function marksGet(cb){fetch('/marks?id='+id).then(function(r){return r.json()}).then(function(j){
  cb(j&&j.ok?(j.marks||[]):[])})}
function renderMarks(){
  marksGet(function(list){
    var box=document.getElementById('bml');box.innerHTML='';
    if(!list.length){box.innerHTML='<div class="ch" style="color:#aaa">暂无书签，点工具栏「＋签」添加（与手机同步）</div>';return}
    list.forEach(function(m){
      var d=document.createElement('div');d.className='ch';
      var s=document.createElement('span');s.style.flex='1';s.style.minWidth='0';
      s.style.overflow='hidden';s.style.textOverflow='ellipsis';
      s.textContent='🔖 '+(m.chapterName||m.bookText||'书签');
      var x=document.createElement('button');x.className='del';x.textContent='✕';
      x.onclick=function(ev){ev.stopPropagation();
        fetch('/marksdel',{method:'POST',headers:{'Content-Type':'application/json'},
          body:JSON.stringify({time:m.time})}).then(function(){renderMarks()})};
      d.appendChild(s);d.appendChild(x);
      d.title=m.bookText||'';
      d.onclick=function(){jumpMark(m);toc()};
      box.appendChild(d);
    });
  });
}
function addMark(){
  var pi=curTopPara();if(pi<0)return;
  var k=chOfPara(pi);
  var chapterName=(chIdx.length>0)?paras[chIdx[k]].slice(0,30):('位置 '+pi);
  // 网页书签的**稳定身份**（2026-10-05 去重）：章标题#段号#段首10字
  // 服务端存进 bookmarks.content，同一处再点只回 exists（不再插重复行）。
  var webKey=chTitle(k)+'#'+pi+'#'+paras[pi].slice(0,10);
  fetch('/marksadd',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id:Number(id),chapterIndex:k,chTitle:chTitle(k),chapterName:chapterName,
      bookText:paras[pi].slice(0,10),posRatio:(chBounds(k)[1]>chBounds(k)[0])?((pi-chBounds(k)[0])/(chBounds(k)[1]-chBounds(k)[0])):0,
      webKey:webKey})
  }).then(function(r){return r.json()}).then(function(j){
    renderMarks();
    showTip((j&&j.msg==='exists')?'该位置已有书签':'书签已添加（手机同步）');
  }).catch(function(){renderMarks();showTip('书签已添加（手机同步）')});
}
function jumpMark(m){
  // ① 网页自己加的书签：content 里存着 webKey（章标题#段号#段首10字）⇒ 直接精确落段
  var ck=String(m.content||'');
  if(ck!==''){
    var parts=ck.split('#');
    var pi0=parseInt(parts[1]);
    if(isFinite(pi0)&&pi0>=0&&pi0<paras.length){jumpTo(pi0);return}
  }
  // ② 手机加的书签：先把章定位到（标题匹配），再用它的 bookText（手机侧"当页首行前 10 字"）
  //    在本章里做文本锚匹配 ⇒ 比"跳到章首"精确得多（找不到就落章首）
  var k=findChByTitle(m.chapterName||'');
  if(k<0&&ck===''&&typeof m.chapterIndex==='number'&&m.chapterIndex>=0&&m.chapterIndex<chTotal()){k=m.chapterIndex}
  if(k<0){showTip('书签章节未能匹配');return}
  var b=chBounds(k);
  var pi=findParaByExNear(m.bookText||'',b[0],b[1]);
  if(pi<0){pi=b[0]}
  if(mode==='scroll'){jumpTo(pi);return}
  renderChapter(k);goPage(0,true);
}
function curTopPara(){
  if(mode==='scroll'){
    var top=sc.scrollTop+80;
    for(var i=0;i<si.children.length;i++){if(si.children[i].offsetTop>=top)return i}
    return rendered-1;
  }
  return chBounds(curCh)[0];
}
function showTip(t){var b=document.getElementById('syncbar');
  document.getElementById('synctxt').textContent=t;
  b.querySelector('button').style.display='none';
  b.querySelector('.ig').textContent='知道了';
  b.classList.add('show');setTimeout(function(){b.classList.remove('show')},2200)}
/* ── 模式 ── */
function apply(){
  si.style.fontSize=st.f+'px';si.style.lineHeight=st.lh;
  pg.style.fontSize=st.f+'px';pg.style.lineHeight=st.lh;
  document.body.className=st.th+(document.body.classList.contains('hide')?' hide':'');
  document.getElementById('modeBtn').textContent={scroll:'滚动',page1:'单页',page2:'双页'}[mode];
}
function cycleMode(){
  // v3.20：模式顺序 = 滚动 → 双页 → 单页（用户指定）
  mode={scroll:'page2',page2:'page1',page1:'scroll'}[mode];
  S('mode',mode);enterMode(mode);
}
function enterMode(m){
  mode=m;apply();
  var isPage=(m!=='scroll');
  sc.classList.toggle('on',!isPage);stg.classList.toggle('on',isPage);
  stg.classList.toggle('two',m==='page2');
  stg.classList.toggle('shadow',m==='page2');
  if(isPage){
    curCh=parseInt(L('p_ch','0'));if(isNaN(curCh))curCh=0;
    renderChapter(curCh);
    var p=parseInt(L('p_pg','0'));goPage(isNaN(p)?0:p,true);
  }else{
    pg.style.transform='none';
    ensure(rendered>0?rendered:300);
    var sp=parseInt(L('p_scroll','0'));sc.scrollTop=sp>0?sp:0;updPct();
  }
}
/* ── 分页（columns 平移，双页步长=一张纸；v3.19 回退稳定方案）── */
function renderChapter(k){
  curCh=Math.max(0,Math.min(chTotal()-1,k));
  var b=chBounds(curCh);
  pg.innerHTML=phtml(b[0],b[1]);
  layoutCols();
}
function layoutCols(){
  var gap=(mode==='page2')?64:44;
  pg.style.columnGap=gap+'px';
  pg.style.columnWidth=Math.floor((stg.clientWidth-68-gap)/((mode==='page2')?2:1))+'px';
  stride=colWStride();
}
function colWStride(){
  var gap=(mode==='page2')?64:44;
  var per=(mode==='page2')?2:1;
  return (stg.clientWidth-68-gap*(per-1))/per+gap;
}
function total(){return Math.max(1,Math.round((pg.scrollWidth-stg.clientWidth+68)/stride))}
function goPage(n,silent){
  pageCount=total();
  if(mode==='page2'){n=n-(Math.abs(n)%2)}
  pageIdx=Math.max(0,Math.min(pageCount-1,n));
  pg.style.transform='translateX(-'+(pageIdx*stride)+'px)';
  S('p_ch',curCh);S('p_pg',pageIdx);
  if(!silent){updPct();syncPush(true)}
}
function next(d){
  if(mode==='scroll'){sc.scrollBy({top:d*sc.clientHeight*0.86,behavior:'smooth'});return}
  var stp=(mode==='page2')?2:1;
  var t=total();var np=pageIdx+d*stp;
  var last=pageCount-1;
  if(mode==='page2'){last=last-(last%2)}
  if(np>last&&curCh>=chTotal()-1){goPage(last);return}
  if(np<0&&curCh<=0){goPage(0);return}
  if(np>=t){renderChapter(curCh+1);goPage(0)}
  else if(np<0){renderChapter(curCh-1);goPage(total()-1)}
  else{goPage(np)}
}
addEventListener('keydown',function(e){
  if(mode!=='scroll'&&(e.key==='ArrowLeft'||e.key==='PageUp')){next(-1)}
  else if(mode!=='scroll'&&(e.key==='ArrowRight'||e.key==='PageDown')){next(1)}
});
/* v3.20：补回点击翻页（v3.19 重写时丢失）——双页/单页左右分区翻页，中间唤出工具栏 */
stg.onclick=function(e){
  // 2026-10-05：删掉这里的 if(flipping)return; —— flipping 全文件只有这一处**读取**，
  // 没有任何声明/赋值（v3.19 重写时丢失的残留）⇒ 浏览器执行到该行抛 ReferenceError，
  // 点击处理函数第一行就中断 ⇒ 用户实测"点击左右两侧不翻页"。删掉即可恢复。
  if(e.clientX<innerWidth/3){next(-1)}
  else if(e.clientX>innerWidth*2/3){next(1)}
  else{full()}
};
sc.onclick=function(e){if(e.clientY<innerHeight*0.1||e.clientY>innerHeight*0.9){full()}};
addEventListener('resize',function(){if(mode!=='scroll'){layoutCols();goPage(pageIdx,true)}});
var pt=null;
function updPct(){
  var txt='';
  if(mode==='scroll'){
    var h=si.scrollHeight-sc.clientHeight;
    document.getElementById('pct').textContent=(h>0?Math.round(sc.scrollTop/h*100):100)+'%';
    txt=(chIdx.length>0?'第 '+(curCh+1)+'/'+chTotal()+' 章 · ':'')+'滚动模式 · v3.19';
  }else{
    var frac=chTotal()>1?(curCh+pageIdx/Math.max(total()-1,1))/chTotal():1;
    document.getElementById('pct').textContent=Math.round(frac*100)+'%';
    txt='第 '+(curCh+1)+'/'+chTotal()+' 章 · 页 '+(pageIdx+1)+'/'+total()+' · v3.19';
  }
  document.getElementById('modeTag').textContent=txt;
}
/* ── 工具 ── */
function fs(d){st.f=Math.max(13,Math.min(34,st.f+d));S('f',st.f);apply();
  if(mode!=='scroll'){layoutCols();goPage(pageIdx,true)}}
function ls(){var i=[1.6,1.9,2.2].indexOf(st.lh);st.lh=[1.6,1.9,2.2][(i+1)%3];
  S('lh',[1.6,1.9,2.2].indexOf(st.lh));apply();
  if(mode!=='scroll'){layoutCols();goPage(pageIdx,true)}}
function bg(){st.th={day:'sepia',sepia:'night',night:'day'}[st.th];S('th',st.th);apply()}
function full(){document.body.classList.toggle('hide')}
function jumpTo(pi){
  if(mode==='scroll'){
    ensure(Math.min(pi+80,paras.length));
    var node=si.children[pi];
    if(node){sc.scrollTop=node.offsetTop-20}
    trackChByScroll();S('p_scroll',sc.scrollTop);updPct();syncPush(true);return;
  }
  var k=chOfPara(pi);
  renderChapter(k);
  // 找目标段所在列
  var tgt=0;var kids=pg.children;var ti=pi-chBounds(k)[0];
  if(kids[ti]){tgt=Math.round(kids[ti].offsetLeft/(stride||1))}
  goPage(tgt,true);
}
function toc(){document.getElementById('toc').classList.toggle('open');
  document.getElementById('mask').classList.toggle('open')}
function findToggle(){document.getElementById('find').classList.toggle('open');
  document.getElementById('fq').focus()}
function doFind(){var q=document.getElementById('fq').value;if(q&&window.find){window.find(q,false,false,true,true,false)}}
/* ── 进度同步 v1（章跟踪修复 + 分页落定 push）── */
var lastSync=0;
var lastPushedTitle='';
var seenTitle='';
/* v3.20 双锚提取：滚动=视口顶段+底段；单页=当前列首末段；双页=左页首段+右页末段 */
function pageAnchors(){
  var a,b;
  if(mode==='scroll'){
    a=curTopPara();if(a<0)a=0;
    var bottomY=sc.scrollTop+sc.clientHeight-100;b=rendered-1;
    for(var i=0;i<si.children.length;i++){if(si.children[i].offsetTop>=bottomY){b=i;break}}
  }else{
    var first=pageIdx;
    var last=(mode==='page2')?pageIdx+1:pageIdx;
    var fFound=-1,lFound=-1;
    for(var j=0;j<pg.children.length;j++){
      var col=Math.round(pg.children[j].offsetLeft/(stride||1));
      if(col===first&&fFound<0)fFound=j;
      if(col===last)lFound=j;
    }
    if(fFound<0)fFound=0; if(lFound<0)lFound=fFound;
    a=fFound;b=lFound;
  }
  var top=paras[Math.min(a,paras.length-1)]||'';
  var bot=paras[Math.min(b,paras.length-1)]||'';
  return [top.slice(0,40),bot.slice(Math.max(0,bot.length-40))];
}
/* ── 双端同步 v2（2026-10-05，用户确认的结构化方案；设计见
   docs/dual-end-sync-v2-design-2026-10-05.md）───────────────────────────────
   · 各写各的槽：本页只写 SyncPos_web_<书名> 里属于 webId 的那一条，
     手机的位置在 SyncPos_phone_<书名> —— **永不互相覆盖**（v1 的一槽两用是 H1 根因）
   · 水位：localStorage['mr_seenPhoneTs_<书id>'] = 已消费的手机槽 ts（按 ts 判新，
     不再按章节标题去重 ⇒ 同章内的位移也能联动）
   · 不打扰（R3）：同章且章内位置差 < 0.1 ⇒ 只推进水位、不弹条
   · 跳转优先级（R4）：① topEx/botEx 文本锚 → ② ratio 定位章 → ③ posRatio 定位章内段 */
var webId=(function(){try{var k='mr_webId';var v=localStorage.getItem(k);
  if(!v){v='w'+Math.random().toString(36).slice(2,8);localStorage.setItem(k,v)}return v}catch(e){return 'w0'}})();
function seenPhoneTs(){try{return Number(localStorage.getItem('mr_seenPhoneTs_'+id)||0)}catch(e){return 0}}
function setSeenPhoneTs(ts){try{localStorage.setItem('mr_seenPhoneTs_'+id,String(ts))}catch(e){}}
function curPosRatio(){
  var cb=chBounds(curCh);var span=Math.max(1,cb[1]-cb[0]);
  if(mode==='scroll'){var a=curTopPara();if(a<0)a=cb[0];
    return Math.max(0,Math.min(1,(a-cb[0])/span))}
  var pc=(typeof pageCount==='number'&&pageCount>1)?pageCount:1;
  return Math.max(0,Math.min(1,(pageIdx||0)/Math.max(1,pc-1)));
}
function syncPush(force){
  var now=Date.now();
  var t=chTitle(curCh);
  var chChanged=(t!==lastPushedTitle);
  if(!force&&!chChanged&&now-lastSync<5000)return;
  lastSync=now;lastPushedTitle=t;
  var an=pageAnchors();
  var total=chTotal();
  fetch('/sync',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id:Number(id),webId:webId,title:t,chTitle:t,
      chIndex:curCh,chCount:total,ratio:total>0?curCh/total:-1,
      topEx:an[0],botEx:an[1],posRatio:curPosRatio(),baseTs:phoneTs})
  }).catch(function(){});
}
var phoneTs=0;          // 最近见到的手机槽 ts（仅用于日志/诊断）
function syncPoll(){
  if(document.hidden)return;
  fetch('/sync?id='+id).then(function(r){return r.json()}).then(function(j){
    if(!j||!j.ok)return;
    var ts=Number(j.ts||0);
    if(ts<=0)return;
    phoneTs=ts;
    if(ts<=seenPhoneTs())return;                 // 这个槽已经消费过
    var t=String(j.chTitle||j.title||'');
    var topEx=String(j.topEx||'');var botEx=String(j.botEx||'');
    if(topEx===''&&botEx===''&&t==='')return;
    var pr=Number(j.posRatio);if(!isFinite(pr))pr=-1;
    // R3：同章且差得不多 ⇒ 同一处，只推进水位
    if(t!==''&&t===chTitle(curCh)&&pr>=0&&Math.abs(pr-curPosRatio())<0.1){setSeenPhoneTs(ts);return}
    var b=document.getElementById('syncbar');
    document.getElementById('synctxt').innerHTML='手机进度：<br>① '+normEx(topEx)+'<br>② '+normEx(botEx);
    b.dataset.topEx=topEx;b.dataset.botEx=botEx;b.dataset.chTitle=t;
    var rr=Number(j.ratio);b.dataset.ratio=String(isFinite(rr)?rr:-1);
    b.dataset.posRatio=String(pr);b.dataset.ts=String(ts);
    b.querySelector('button').style.display='block';
    b.querySelectorAll('button')[1].style.display='block';
    b.querySelector('.ig').textContent='忽略';
    b.classList.add('show');
  }).catch(function(){});
}
function syncCheck(){syncPoll()}
function findChByTitle(t){
  if(chIdx.length===0)return -1;
  var m=t.match(/第(\\d+)[章节回卷]/);
  if(m){var num=parseInt(m[1]);
    for(var k=0;k<chIdx.length;k++){var mm=paras[chIdx[k]].match(/第(\\d+)[章节回卷]/);
      if(mm&&parseInt(mm[1])===num)return k}
  }
  var key=t.replace(/^\\s+|\\s+$/g,'').slice(0,8);
  if(key==='')return -1;
  for(var k2=0;k2<chIdx.length;k2++){if(paras[chIdx[k2]].indexOf(key)>=0)return k2}
  return -1;
}
function normEx(s){return String(s).replace(/\s+/g,'').slice(0,14)}
/* 匹配键：2026-10-05 从 14 字提到 **20 字**（首命中错位的主要原因是键太短 ⇒ 重复句子命中错处），
   显示仍然用 14 字的 normEx。 */
function matchKey(s){return String(s).replace(/\s+/g,'').slice(0,20)}
/**
 * 摘录 → 段号。**优先在给定区间内找**（nearLo..nearHi = 目标章的范围），
 * 找不到才退回全文首命中（2026-10-05：旧实现一律全文首命中 ⇒ 重复句子会跳到错误位置）。
 */
function findParaByExNear(ex, nearLo, nearHi){
  if(!ex)return -1;
  var key=matchKey(ex);
  if(key==='')return -1;
  var lo=(typeof nearLo==='number'&&nearLo>=0)?nearLo:0;
  var hi=(typeof nearHi==='number'&&nearHi>lo)?Math.min(nearHi,normParas.length):normParas.length;
  for(var i=lo;i<hi;i++){if(normParas[i].indexOf(key)>=0)return i}
  return findParaByEx(ex);
}
function findParaByEx(ex){
  if(!ex)return -1;
  var key=matchKey(ex);if(key==='')return -1;
  for(var i=0;i<normParas.length;i++){if(normParas[i].indexOf(key)>=0)return i}
  return -1;
}
function ratioToIndex(ratio,count){
  if(!(count>0))return 0;
  var r=Math.max(0,Math.min(1,Number(ratio)||0));
  return Math.max(0,Math.min(count-1,Math.round(r*(count-1))));
}
function syncJump(which){
  var b=document.getElementById('syncbar');
  var ex=String(which==='1'?b.dataset.botEx:(b.dataset.topEx||''));
  var ratio=Number(b.dataset.ratio),posRatio=Number(b.dataset.posRatio),ts=Number(b.dataset.ts||0);
  b.classList.remove('show');
  if(ts>0)setSeenPhoneTs(ts);                    // 消费该槽
  // 先定章：① 标题匹配 → ② 跨端比例（两端切分不同，索引不可用，比例可换算）
  var title=String(b.dataset.chTitle||'');
  var k=findChByTitle(title);
  if(k<0){
    var total=chTotal();
    if(isFinite(ratio)&&ratio>=0&&total>0){k=ratioToIndex(ratio,total)}
  }
  var pi=-1;
  if(k>=0){
    var cb=chBounds(k);
    // ③ 章内：文本锚**限定在本章内**匹配（2026-10-05 收紧；旧实现全文首命中易错位）
    pi=findParaByExNear(ex,cb[0],cb[1]);
    if(pi<0){
      // ④ 文本锚全章找不到 ⇒ 用跨端章内比例落段
      var pr=(isFinite(posRatio)&&posRatio>=0)?Math.max(0,Math.min(1,posRatio)):0;
      pi=cb[0]+Math.round(pr*Math.max(1,cb[1]-cb[0]));
      if(pi>cb[1]-1)pi=cb[1]-1;
    }
  }else{
    pi=findParaByEx(ex);                          // 章都定不了 ⇒ 退回全文首命中
    if(pi<0){showTip('未能定位该进度');return}
    k=chOfPara(pi);
  }
  if(mode==='scroll'){jumpTo(pi);return}
  renderChapter(k);
  var tgt=0;var kids=pg.children;var ti=pi-chBounds(k)[0];
  if(kids[ti]){tgt=Math.round(kids[ti].offsetLeft/(stride||1))}
  goPage(tgt,true);
}
function syncHide(){
  var b=document.getElementById('syncbar');
  var ts=Number(b.dataset.ts||0);
  if(ts>0)setSeenPhoneTs(ts);                    // 「忽略」= 消费该槽（修 PC 端"忽略不生效"）
  b.classList.remove('show');
}
fetch('/book?id='+id).then(function(r){return r.text()}).then(render);
</script></body></html>`;
        return WifiBookServer.textBytes(html);
    }
    /**
     * 强制下载（v3.14，用户反馈"web书架点下载直接进入内容了"）：无论 txt/epub 一律
     * `application/octet-stream` + `attachment` ⇒ 浏览器弹下载而非内联打开。
     * 在线阅读走 `/book?id=`（text/plain），两条路由语义分离。
     */
    private static async serveDownload(client: socket.TCPSocketConnection, id: number): Promise<void> {
        const book: Books | null = await WifiBookServer.bookById(id);
        if (book === null || !book.bookUrl) {
            WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8', WifiBookServer.textBytes('book not found'));
            return;
        }
        try {
            const file = fs.openSync(book.bookUrl, fs.OpenMode.READ_ONLY);
            const size: number = fs.statSync(book.bookUrl).size;
            const buffer: ArrayBuffer = new ArrayBuffer(size);
            fs.readSync(file.fd, buffer);
            fs.closeSync(file);
            const ext: string = book.bookUrl.endsWith('.epub') ? 'epub' : 'txt';
            const name: string = (book.bookName ?? 'book').replace(/["\\]/g, '');
            WifiBookServer.respond(client, 200, 'application/octet-stream', new Uint8Array(buffer), `attachment; filename="${name}.${ext}"`);
        }
        catch (err) {
            WifiBookServer.respond(client, 500, 'text/plain; charset=utf-8', WifiBookServer.textBytes('read failed'));
        }
    }
    /**
     * UTF-8 合法性扫描（O(n) 字节状态机）：无 BOM 文件的编码裁决依据。
     * 合法 ⇒ 原样发（浏览器按 UTF-8 解）；非法 ⇒ 按 GB18030 解码转 UTF-8 再发。
     * （GBK/GB2312 是 GB18030 子集，一个 decoder 覆盖全部中文 ANSI 变体；
     * overlong/surrogate 边缘字节按非法处理 ⇒ 回退 GB18030，工程上足够稳。）
     */
    private static isStrictUtf8(bytes: Uint8Array): boolean {
        let i = 0;
        const n = bytes.length;
        while (i < n) {
            const b = bytes[i];
            if (b < 0x80) {
                i++;
                continue;
            }
            let seq = 0;
            if (b >= 0xC2 && b <= 0xDF) {
                seq = 1;
            }
            else if (b >= 0xE0 && b <= 0xEF) {
                seq = 2;
            }
            else if (b >= 0xF0 && b <= 0xF4) {
                seq = 3;
            }
            else {
                return false;
            }
            if (i + seq >= n) {
                return false;
            }
            for (let k = 1; k <= seq; k++) {
                const c = bytes[i + k];
                if (c < 0x80 || c > 0xBF) {
                    return false;
                }
            }
            i += seq + 1;
        }
        return true;
    }
    /**
     * 读书文件并裁决编码，返回 UTF-8 字节（v3.15，治"web 阅读大 txt 全是乱码"）。
     * 根因：中文 txt 常见 GBK/GB18030（Windows 记事本 ANSI），旧版原样发字节 +
     * 浏览器按 UTF-8 解 ⇒ 乱码；手机端正常是因为 ReaderKit 自己探测 charset
     * （真机日志：`Open normal txt with cache, the charset: <private>`）。
     * 裁决顺序：BOM（utf-8/utf-16le/be）→ 严格 UTF-8 扫描 → GB18030 兜底。
     * 编码支持官方依据：SDK `@ohos.util.d.ts:289-293`（TextDecoder 支持
     * gbk/gb18030/big5/utf-16be/utf-16le 等全表原文）。
     */
    private static readBookBytes(path: string): Uint8Array {
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        try {
            const size: number = fs.statSync(path).size;
            const buffer: ArrayBuffer = new ArrayBuffer(size);
            fs.readSync(file.fd, buffer);
            let bytes = new Uint8Array(buffer);
            // BOM 裁决
            if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
                return bytes.slice(3); // utf-8 BOM：剥掉原样发
            }
            if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
                bytes = bytes.slice(2);
                return WifiBookServer.textBytes(util.TextDecoder.create('utf-16le').decodeToString(bytes));
            }
            if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
                bytes = bytes.slice(2);
                return WifiBookServer.textBytes(util.TextDecoder.create('utf-16be').decodeToString(bytes));
            }
            // 无 BOM：严格 UTF-8 扫描
            if (WifiBookServer.isStrictUtf8(bytes)) {
                return bytes;
            }
            // GB18030 兜底（GBK/GB2312 超集）→ 解码成串 → 编回 UTF-8
            const text: string = util.TextDecoder.create('gb18030').decodeToString(bytes);
            return WifiBookServer.textBytes(text);
        }
        finally {
            fs.closeSync(file);
        }
    }
    /**
     * 单源目录（M3，2026-10-05）：`GET /toc?id=` **只回目录标题**（手机端发布的快照）。
     *
     * ## 为什么字符区间不在这里算（重要，来自只读探针结论）
     * ReaderKit **不提供任何字符偏移**（`CatalogItem` 只有 catalogId/catalogName/href/
     * resourceFile 等，见 SDK `@hms.core.readerservice.bookParser.d.ts:197-268`）；若在服务端
     * 算，就必须保证"算偏移用的那串文本"与"网页收到的那串"逐字一致，否则偏移全错。
     * ⇒ 改成：手机端只发布**标题**（它已有，零成本；`ReaderPage3.publishBookToc`），
     *   **字符区间由前端在它手里那份正文上算** —— `web/src/toc.ts` 的 `locateToc`，
     *   纯函数、有单测（含"书首目录块"陷阱与三种放弃条件）。风险从结构上消失，
     *   算法也第一次能被本地验证。
     *
     * ## 降级
     * 没有标题快照（书没在手机端打开过）⇒ `{ok:true,titles:[]}` ⇒ 网页回退本地正则切分。
     */
    private static async handleTocGet(client: socket.TCPSocketConnection, id: number): Promise<void> {
        try {
            const book: Books | null = await WifiBookServer.bookById(id);
            const name: string = book?.bookName ?? '';
            let titles: string[] = [];
            if (name !== '') {
                try {
                    const raw = PreferencesUtil.getSync(`BookToc_${name}`, '') as string;
                    if (typeof raw === 'string' && raw.length > 0) {
                        titles = JSON.parse(raw) as string[];
                    }
                }
                catch (err) {
                    titles = [];
                }
            }
            const list: string[] = Array.isArray(titles) ? titles : [];
            WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: true, titles: list })));
        }
        catch (err) {
            console.error(`${TAG} toc failed: ${(err as Error).message}`);
            WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: true, titles: [] })));
        }
    }
    /**
     * 书签双向（2026-10-01）：web 抽屉书签 Tab 直接读写手机 `bookmarks` 表
     * （BookmarksDao.list/add/remove，表结构含 chapterIndex/chapterName/content）。
     * 跳转坐标：chapterName（标题）——web 侧按标题匹配正则章（章级精度，同进度 v1）。
     */
    private static async handleMarksGet(client: socket.TCPSocketConnection, id: number): Promise<void> {
        const book: Books | null = await WifiBookServer.bookById(id);
        if (book === null) {
            WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: false })));
            return;
        }
        const all = await bookmarksDao.list();
        const mine: Array<Record<string, number | string>> = [];
        all.forEach((m) => {
            if (m.bookName === book.bookName) {
                mine.push({
                    'time': m.time,
                    'chapterIndex': m.chapterIndex,
                    'chapterName': m.chapterName,
                    'bookText': m.bookText,
                    // 2026-10-05：把行内容（网页书签的稳定身份 webKey）一并给网页，
                    // `jumpMark` 据此精确落到原段（手机加的书签该列为空 ⇒ 走标题+bookText 锚匹配）。
                    'content': m.content
                });
            }
        });
        WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: true, marks: mine })));
    }
    private static async handleMarksAdd(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, number | string>;
            const book: Books | null = await WifiBookServer.bookById(Number(body['id'] ?? -1));
            if (book === null) {
                WifiBookServer.respondJson(client, false, 'book not found');
                return;
            }
            // ── 坐标系隔离（2026-10-05 修"手机会删掉电脑加的书签"，审计 H3/H6/P0-2）──────
            // 手机端 `bookmarks.chapterIndex` = **目录数组下标**、`chapterPos` = **页首块节点号**
            // （`ReaderPage3.ets:472-475`、`:3583-3588`）；网页端的 chapterIndex 是它**自己**
            // 按空行分段 + 标题正则切出来的章下标（`WifiBookServer.ets:723-727`），`chapterPos`
            // 在网页里**根本不存在**。旧实现把网页章号原样写进这一列、`chapterPos` 写死 0 ⇒
            //   ① 手机按 (bookName, chapterIndex, chapterPos) 查/删（`BookmarksDao.ets:91-118`）
            //      会在"该章第一页"误删/误判电脑加的书签；
            //   ② 手机 `jumpToBookmark` 拿网页章号当目录下标 ⇒ **跳到错误的章**甚至越界
            //      （`ReaderPage3.ets:6313-6315`）。
            // ⇒ 统一写 **-1 = 「电脑端书签，坐标系未知」**：删除/图标判定永不误命中；跳转改由
            //    `jumpToBookmark` 用 `chapterName`（网页传的是该章首段正文，即标题行）走标题匹配。
            // ── 网页端书签去重（2026-10-05 补）：按 `content` 里的稳定身份 webKey ──────────
            // 网页"＋签"原来每次点击都插一行（连点 N 次 = N 条同位置书签）。`content` 列原先
            // 没有任何消费者，现在存 `webKey = 章标题#段号#段首10字`，同一处再点就只回 exists。
            const webKey = String(body['webKey'] ?? '');
            if (webKey !== '' && await bookmarksDao.existsByContent(book.bookName ?? '', webKey)) {
                WifiBookServer.respondJson(client, true, 'exists');
                return;
            }
            await bookmarksDao.add(book.bookName ?? '', book.author ?? '暂无', -1, -1, String(body['chapterName'] ?? ''), String(body['bookText'] ?? '').slice(0, 60), false, webKey);
            WifiBookServer.respondJson(client, true, 'added');
        }
        catch (err) {
            WifiBookServer.respondJson(client, false, 'bad json');
        }
    }
    private static async handleMarksDel(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, number>;
            const ok: boolean = await bookmarksDao.remove(Number(body['time'] ?? 0));
            WifiBookServer.respondJson(client, ok, ok ? 'removed' : 'not found');
        }
        catch (err) {
            WifiBookServer.respondJson(client, false, 'bad json');
        }
    }
    /**
     * 进度同步 GET：把**手机的位置槽**给网页（网页据此弹「手机进度」提示条）。
     *
     * v2（2026-10-05）：手机的位置在 `SyncPos_phone_<书名>`，**与网页槽彻底分开**
     * （v1 一槽两用是 H1 根因）。返回字段同时给新旧两套字段名（`title`/`chTitle`），
     * 老网页 JS 也能读。v1 老键作为兜底（手机还没升到 v2 时）。
     */
    private static handleSyncGet(client: socket.TCPSocketConnection, id: number): void {
        booksDao.getBookByIds([id]).then((arr: Books[]): void => {
            if (arr.length === 0) {
                WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: false })));
                return;
            }
            const name: string = arr[0].bookName ?? '';
            // v2 手机槽；没有（ts<=0）则回退读 v1 老键里"手机写的那份"
            let pos: SyncPos = syncConfig.readPhonePos(name);
            if (pos.ts <= 0) {
                pos = syncConfig.readLegacyPhonePos(name);
            }
            // 中继站（2026-10-05）：把"最新写者"一并下发给网页，让网页判断
            // "现在最新进度是不是我" ⇒ 只有落后的一端才提示（用户要的"谁最新谁不弹"）。
            const latest: SyncPos | null = syncConfig.readLatest(name);
            WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({
                ok: true,
                src: 'phone',
                title: pos.chTitle,
                chTitle: pos.chTitle,
                topEx: pos.topEx,
                botEx: pos.botEx,
                ts: pos.ts,
                seq: pos.seq,
                ratio: pos.ratio,
                posRatio: pos.posRatio,
                chCount: pos.chCount,
                latestWriter: latest === null ? '' : latest.writer,
                latestSeq: latest === null ? 0 : latest.seq
            })));
        });
    }
    /**
     * 进度同步 POST：把**网页自己的位置**写进 `SyncPos_web_<书名>` 里属于它的那条
     * （`webId` 由网页在 localStorage 里生成 ⇒ 多台电脑各占一条，互不覆盖）。
     *
     * v2 起不再需要冲突检测：各写各的槽，网页写它自己的那份永远不会顶掉手机的位置
     * （v1 的 `baseTs` 冲突判定因此废弃；字段仍然接收，老 JS 不受影响）。
     */
    private static handleSyncPost(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, number | string>;
            const bid = Number(body['id'] ?? -1);
            const webId = String(body['webId'] ?? '') === '' ? 'v1' : String(body['webId']);
            const title = String(body['chTitle'] ?? body['title'] ?? '');
            const topEx = String(body['topEx'] ?? '');
            const botEx = String(body['botEx'] ?? '');
            if (bid < 0 || (title === '' && topEx === '' && botEx === '')) {
                WifiBookServer.respondJson(client, false, 'bad params');
                return;
            }
            booksDao.getBookByIds([bid]).then((arr: Books[]): void => {
                if (arr.length === 0) {
                    WifiBookServer.respondJson(client, false, 'book not found');
                    return;
                }
                const name: string = arr[0].bookName ?? '';
                if (name === '') {
                    WifiBookServer.respondJson(client, false, 'book not found');
                    return;
                }
                const pos: SyncPos = {
                    v: 2,
                    // seq 由 `syncConfig.writeWebSlot` → `stamp()` 统一分配（手机进程是唯一共享点
                    // ⇒ 全局单调、对两端时钟免疫）；这里给 0 当占位
                    seq: 0,
                    chTitle: title,
                    // 网页自己的章序/总章数：仅供它自己用（手机端不读网页槽的 chIndex —— 两端切分不同）
                    chIndex: Number(body['chIndex'] ?? -1),
                    chCount: Number(body['chCount'] ?? 0),
                    ratio: Number(body['ratio'] ?? -1),
                    topEx: normEx(topEx),
                    botEx: normEx(botEx),
                    posRatio: Number(body['posRatio'] ?? -1),
                    ts: Date.now(),
                    writer: 'web:' + webId
                };
                if (SYNC_V2_ENABLED) {
                    syncConfig.writeWebSlot(name, webId, pos);
                }
                else {
                    // 回退路径：保持 v1 单槽行为
                    const payload: Record<string, number | string> = {
                        'title': title,
                        'topEx': topEx,
                        'botEx': botEx,
                        'ts': pos.ts,
                        'src': 'web'
                    };
                    PreferencesUtil.putSync(`WebSync_${name}`, JSON.stringify(payload));
                }
                // 同进程事件：手机正开着这本书时即时知会（不打断；开书场景走锚点弹窗）
                const data: emitter.EventData = {
                    data: { 'name': name, 'title': title }
                };
                emitter.emit({ eventId: 20261001 }, data);
                WifiBookServer.respondJson(client, true, 'synced');
            });
        }
        catch (err) {
            WifiBookServer.respondJson(client, false, 'bad json');
        }
    }
    private static async serveBookFile(client: socket.TCPSocketConnection, id: number): Promise<void> {
        const book: Books | null = await WifiBookServer.bookById(id);
        if (book === null || !book.bookUrl) {
            WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8', WifiBookServer.textBytes('book not found'));
            return;
        }
        const entryPath: string = book.bookUrl;
        const entryName: string = book.bookName ?? 'book';
        try {
            const bytes: Uint8Array = WifiBookServer.readBookBytes(entryPath);
            const isTxt: boolean = entryPath.endsWith('.txt');
            WifiBookServer.respond(client, 200, isTxt ? 'text/plain; charset=utf-8' : 'application/octet-stream', bytes, isTxt ? undefined : `attachment; filename="${entryName}.epub"`);
        }
        catch (err) {
            WifiBookServer.respond(client, 500, 'text/plain; charset=utf-8', WifiBookServer.textBytes('read failed'));
        }
    }
    private static handleUpload(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        const contentType: string = req.headers['content-type'] ?? '';
        const bIdx: number = contentType.indexOf('boundary=');
        if (bIdx < 0) {
            WifiBookServer.respondJson(client, false, '不是有效的文件上传请求');
            return;
        }
        const boundary: string = '--' + contentType.substring(bIdx + 9).trim().replace(/"/g, '');
        const boundBytes: Uint8Array = WifiBookServer.textBytes(boundary);
        // 结构：--b\r\n头\r\n\r\n内容\r\n--b\r\n…\r\n--b--\r\n
        const crlf: Uint8Array = new Uint8Array([0x0D, 0x0A]);
        let imported: number = 0;
        let failed: number = 0;
        let cursor: number = indexOfBytes(req.body, boundBytes, 0);
        while (cursor >= 0) {
            const partStart: number = cursor + boundBytes.length;
            const next: number = indexOfBytes(req.body, boundBytes, partStart);
            if (next < 0) {
                break;
            }
            // 段内容（剥掉结尾 \r\n）
            let seg: Uint8Array = req.body.slice(partStart, next);
            if (seg.length >= 2 && seg[seg.length - 2] === 0x0D && seg[seg.length - 1] === 0x0A) {
                seg = seg.slice(0, seg.length - 2);
            }
            // 段头与段体
            const headEnd: number = indexOfBytes(seg, new Uint8Array([0x0D, 0x0A, 0x0D, 0x0A]), 0);
            if (headEnd >= 0) {
                const segHead: string = bytesToUtf8(seg.slice(0, headEnd));
                const segBody: Uint8Array = seg.slice(headEnd + 4);
                const nameMatch: RegExpMatchArray | null = segHead.match(/filename="([^"]*)"/);
                const fileName: string = (nameMatch !== null && nameMatch[1] !== '') ? nameMatch[1] :
                    `导入书籍_${Date.now()}.txt`;
                if (segBody.length > 0 && WifiBookServer.saveAndImport(fileName, segBody)) {
                    imported++;
                }
                else {
                    failed++;
                }
            }
            cursor = next;
        }
        WifiBookServer.respondJson(client, imported > 0, imported > 0 ? `已导入 ${imported} 本${failed > 0 ? `，失败 ${failed} 本` : ''}` : '没有可导入的文件');
    }
    /** 写沙箱 + 入库（与 FileHandler.CopyFile 同款字段），返回书目条目 */
    private static saveAndImport(fileName: string, content: Uint8Array): boolean {
        try {
            const ctx = getContext() as common.Context;
            const safeName: string = fileName.replace(/[\/\\:*?"<>|]/g, '_');
            const dst: string = ctx.filesDir + '/' + safeName;
            const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, content.slice().buffer as ArrayBuffer);
            fs.closeSync(file);
            const book: Books = {
                bookName: safeName,
                bookUrl: dst,
                author: '暂无',
                bookGroup: 3,
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
            };
            booksUtil.addBooks(book);
            WifiBookServer.shelf.push({ id: WifiBookServer.nextId++, name: safeName, path: dst, size: content.length });
            WifiBookServer.notify();
            console.info(`${TAG} imported: ${safeName} (${content.length} bytes)`);
            return true;
        }
        catch (err) {
            console.error(`${TAG} saveAndImport failed: ${(err as Error).message}`);
            return false;
        }
    }
    // ── HTTP 基础设施 ──────────────────────────────────────────────────────
    private static textBytes(text: string): Uint8Array {
        const encoder = util.TextEncoder.create('utf-8');
        return encoder.encodeInto(text);
    }
    private static respond(client: socket.TCPSocketConnection, status: number, contentType: string, body: Uint8Array, disposition?: string): void {
        const statusText: string = status === 200 ? 'OK' : (status === 404 ? 'Not Found' : 'Error');
        let head: string = `HTTP/1.1 ${status} ${statusText}\r\n` +
            `Content-Type: ${contentType}\r\n` +
            `Content-Length: ${body.length}\r\n` +
            `Connection: close\r\n`;
        if (disposition !== undefined) {
            head += `Content-Disposition: ${disposition}\r\n`;
        }
        head += '\r\n';
        const out: Uint8Array = concatBytes(WifiBookServer.textBytes(head), body);
        client.send({ data: out.slice().buffer as ArrayBuffer }).catch((err: Error) => {
            console.error(`${TAG} send failed: ${err.message}`);
        });
    }
    private static respondJson(client: socket.TCPSocketConnection, ok: boolean, msg: string): void {
        WifiBookServer.respond(client, ok ? 200 : 400, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: ok, msg: msg })));
    }
}