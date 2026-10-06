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
import webCredential, { DevToken, DEVICE_COOKIE, PAIR_QUERY_KEY } from './WebCredential'
import uploadSessions, { UploadInitResult, UploadSessionMeta, MAX_FILE_BYTES } from './UploadSession'
import CommonConstants from '../../common/constants/CommonConstants'
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
 * FileHandler.CopyFile 同款字段：isLocalBook=true, bookGroup=3）⇒ 直进书架。
 *
 * ── v2（2026-10-06 全量审计后重写）三项安全/稳定性根治 ──────────────────
 *  ① **配对鉴权**（`WebCredential.ets`）：手机端显示一次性 6 位配对码，电脑打开地址
 *     后在**配对页输入弹窗**里输码即配对（POST /pair；2026-10-06 用户拍板，嫌带码链接
 *     麻烦），`?k=` 整链自动配对仍保留（二维码用）；之后靠 HttpOnly Cookie 长期有效
 *     （跨服务重启持久化）。防穷举是**全局滑动窗口**限流（连接层拿不到对端 IP，
 *     按连接/IP 计数都拦不住换连接的脚本，见 `WebCredential` 头注释）。
 *     可在手机端查看"已配对设备"并单个清除 / 全部清除 / 换口令。
 *     旧实现 `0.0.0.0:1122` + **零校验** ⇒ 同局域网任何人可下载全部书、
 *     按 time 删任意书签、传任意文件进书架。
 *  ② **连接生命周期**：每个请求都有终态（响应后 `client.close()` + 超时兜底）。
 *     SDK 原文（`@ohos.net.socket.d.ts:3324-3326`）：「This API does not close
 *     existing connections. To close connections, call the close API of
 *     TCPSocketConnection.」——旧实现从不关连接 ⇒ 句柄只增不减。
 *  ③ **资源限额**：单请求体 100 MB、并发连接 16、单请求超时 60 s；
 *     接收缓冲改为预分配 + 偏移写入（旧实现每个 TCP 分片整份复制 ⇒ O(n²)）。
 */
const TAG: string = 'WifiBookServer';

/**
 * 模块级空回调（`respondRaw` 的 `onDone` 是必填形参 —— 可选函数形参在本工程 ArkTS 下
 * 会让"函数实参"被误判为 string，实测 `check` 报 2345；改成必填 + 显式空实现即可）。
 */
function noopClose(_c: socket.TCPSocketConnection): void {
}

/** 超限被拒的连接：响应发完就关掉（不放进连接表，否则永远不释放） */
function closeRejected(c: socket.TCPSocketConnection): void {
    c.close()
        .then((): void => {})
        .catch((err: Error): void => console.error(`${TAG} reject close failed: ${err.message}`));
}
/**
 * 目录快照条目（`GET /toc` 的载荷）。
 * 字段名与网页端 `web/src/protocol.types.ts` 的 `TocEntry` **必须一致**（同一条契约）。
 */
/** 电脑阅读·书库条目（实时查自书架 DB）。**刻意不下发沙箱绝对路径**（旧实现泄漏内部路径）。 */
interface LibraryEntry {
    id: number;
    name: string;
    /** 是否 txt（前端据此决定给"阅读"还是只给"下载"）；不再下发真实路径 */
    isTxt: boolean;
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
/** 单次上传的结果（区分失败原因，供网页精确提示 / 弹窗） */
interface ImportResult {
    ok: boolean;
    /** 'ok' | 'dup'（同名） | 'ext'（扩展名不允许） | 'oversize' | 'io' */
    reason: string;
    msg: string;
    /** 撞名时已存在书的 id（供"改名 / 拒绝"弹窗展示） */
    existingId: number;
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
    /** 声明超体量上限而被提前拒绝（>0 时 dispatch 直接回 413，不再等 body） */
    rejectedBodyBytes: number;
    /**
     * 对端真实 IP（取自 `SocketMessageInfo.remoteInfo.address`，SDK `@ohos.net.socket.d.ts`
     * :4437/:4453，since 11）。**2026-10-06 贯通**：旧实现拿不到它 ⇒ 用 `c<连接id>` 顶着，
     * 每条连接都不同 ⇒ "已配对设备"列表把同一台电脑登记成 N 条（用户实测）。空串 = 未知。
     */
    peerIp: string;
}
export class WifiBookServer {
    // ── 回退开关（工程规范第 3 条：每个新机制都可一键关回旧行为）───────────────
    /** 配对鉴权总开关。`false` = 旧行为（零校验，**仅用于排障**） */
    private static readonly WEB_AUTH_ENABLED: boolean = true;
    /** 资源限额总开关。`false` = 旧行为（不限制请求体/连接数/超时） */
    private static readonly WEB_LIMITS_ENABLED: boolean = true;
    /**
     * 保活心跳（用户拍板 C2 方案 a：**有流量才刷新**，系统取消就如实停、不重申请）。
     * `false` = 旧行为（只在启动时申请一次长时任务，从不更新进度）。
     */
    private static readonly WEB_KEEPALIVE_HEARTBEAT: boolean = true;

    /** 单请求体上限（用户拍板 B1 = 100 MB；分块上传后单块远小于此值） */
    private static readonly MAX_BODY_BYTES: number = 100 * 1024 * 1024;
    /** 并发连接上限（用户拍板 B3 = 16；浏览器同域默认 6 并发 ⇒ 够 2~3 台设备） */
    private static readonly MAX_CONNECTIONS: number = 32;
    /**
     * 单请求超时（用户拍板 B2 = 300 秒，**分档**落地；避免"普通接口卡住 5 分钟不报错"）：
     *  · `TIMEOUT_INTERACTIVE` = 100 MB **以下**的请求（`/sync`、`/marks*`、`/toc`、页面/JSON）
     *  · `TIMEOUT_TRANSFER`    = 请求体 ≥ `TIMEOUT_BULK_BYTES`（`/up/chunk` 的 4 MB 块、`/upload` 大文件）
     *  · `TIMEOUT_SERVE`       = 服务器**要下发** ≥ `TIMEOUT_BULK_BYTES` 的正文（`/book`、`/download`）
     *    —— 这一档在 `respondRaw` 里**重新计时**（那时才知道响应体多大），
     *       否则慢速客户端读一本 100 MB 的书会在中途被 408 掐断。
     */
    private static readonly TIMEOUT_INTERACTIVE: number = 15 * 1000;
    private static readonly TIMEOUT_TRANSFER: number = 300 * 1000;
    private static readonly TIMEOUT_SERVE: number = 300 * 1000;
    /** 分档阈值（1 MB）：超过它按"数据传输"档处理 */
    private static readonly TIMEOUT_BULK_BYTES: number = 1024 * 1024;
    /** 长时任务进度心跳间隔；官方口径「首次更新超过 10 分钟未更新即取消」⇒ 取 5 分钟留余量 */
    private static readonly KEEPALIVE_HEARTBEAT_MS: number = 5 * 60 * 1000;
    /** 每连接的"重新计时"句柄（`respondRaw` 下发大正文时要换更宽的档） */
    private static timerByClient: Map<number, (ms: number) => void> = new Map<number, (ms: number) => void>();
    /** 响应结束后延迟再真正 close 的时长：避开网络栈"延迟关 fd"与 OS fd 编号复用的竞态
     *  （真机日志定案，见 `finish` 内注释）。期间 fd 仍占用 ⇒ 不会被新连接复用编号。 */
    private static readonly CLOSE_DELAY_MS: number = 2000;
    /**
     * 每连接的**收尾**句柄（2026-10-06 真机复盘新增）。
     * 旧时序：`dispatchAsync.then(finish)` 可能在 `client.send()` 尚未完成时就 `close()`
     * ⇒ 响应还在路上连接被掐（间歇性"网络失败"）。现在 `respondRaw` 在 **send 落定之后**
     * 调这里登记的 finish ⇒ 关连接永远发生在响应发出之后。finish 幂等，双保险无害。
     */
    private static finishByClient: Map<number, () => void> = new Map<number, () => void>();

    private static server: socket.TCPSocketServer | null = null;
    private static running: boolean = false;
    private static port: number = 1122;
    /** 绑定的地址（未鉴权时只给局域网 IP；配对后给出的完整地址带配对码） */
    private static lastAddress: string = '';
    /** 当前长时任务通知 id（0 = 无；进度心跳要用它） */
    private static bgNotificationId: number = 0;
    /** 最近一次后台心跳时刻（毫秒） */
    private static lastHeartbeatAt: number = 0;
    /** 系统是否已取消长时任务（取消后**不重申请**，如实告知用户 —— 合规口径） */
    private static bgCancelled: boolean = false;
    /** 长时任务取消监听是否已注册（防重复注册） */
    private static bgCancelHookOn: boolean = false;
    /**
     * UIAbilityContext —— 由 `start()` 传入并持有。
     * 用途：`saveAndImport` 在 **异步回调链**里需要 `filesDir`，而官方明确
     * 「`getContext()` 在异步回调里可能回溯不到、返回 undefined」
     * （SDK `ets/component/common.d.ts:1352-1353`，且 `@deprecated since 18`）
     * ⇒ 这里保存**确定性**的 context，不再在异步链里取。
     */
    private static abilityContext: common.UIAbilityContext | null = null;
    /** 在途连接表（key = clientId）—— `stop()` 时逐个 close，避免句柄泄漏 */
    private static conns: Map<number, socket.TCPSocketConnection> = new Map<number, socket.TCPSocketConnection>();
    private static listeners: Array<() => void> = [];

    static isRunning(): boolean {
        return WifiBookServer.running;
    }

    static getPort(): number {
        return WifiBookServer.port;
    }

    /** 历史设备数（手机端对话框显示"已配对 N 台"） */
    static pairedDeviceCount(): number {
        return webCredential.deviceCount();
    }

    /** 已配对设备列表（手机端"历史设备"管理用） */
    static pairedDevices(): DevToken[] {
        return webCredential.listDevices();
    }

    /** 移除一台已配对设备（立刻失效） */
    static removeDevice(token: string): boolean {
        return webCredential.removeDevice(token);
    }

    /** 清除全部已配对设备（所有电脑都要重新配对） */
    static clearDevices(): void {
        webCredential.clearDevices();
        WifiBookServer.notify();
    }

    /** 换口令：作废旧码 + 全部设备，并立刻生成新配对码（用户要求的能力） */
    static rotatePairingCode(): string {
        const code: string = webCredential.rotatePairing();
        WifiBookServer.notify();
        return code;
    }

    /** 当前有效配对码（''=已过期，对话框提示"刷新"） */
    static currentPairCode(): string {
        return webCredential.currentPairCode();
    }

    /** 配对码剩余秒数（对话框倒计时） */
    static pairCodeSecondsLeft(): number {
        return webCredential.pairCodeSecondsLeft();
    }

    /** 配对码是否过期（过期时地址不能再用来配对） */
    static pairCodeExpired(): boolean {
        return webCredential.currentPairCode() === '';
    }

    /**
     * 配对码"临期自动续新"（对话框每秒调用）：剩余 <60s 就换新码。
     * ⚠️ 为什么必须有：旧实现过期后对话框仍显示旧 6 位数（`pairCode` 是 @State 快照，
     * ticker 只更新倒计时）⇒ 用户照着"已死"的码输入必然失败（真机复盘：用户实测
     * "输入就过期/刷新后还不行"的成因之一）。续新后屏幕上的码**永远有效 ≥60s**，
     * 读码+输码绰绰有余。只换码、不清设备（区别于手动"换口令"rotatePairing）。
     */
    static ensureFreshPairCode(): void {
        if (!WifiBookServer.WEB_AUTH_ENABLED || !WifiBookServer.running) {
            return;
        }
        const left: number = webCredential.pairCodeSecondsLeft();
        // ⚠️ 含 left===0（已过期）：旧守卫 `left > 0` 会让"过期态"永远卡住不再续，
        // 对话框一直显示死码 ⇒ 用户照输必败（2026-10-06 真机"输码没反应"复盘修正）。
        if (left < 60) {
            webCredential.newPairCode();
            console.info(`${TAG} pair code auto-renewed (was expiring in ${left}s)`);
            WifiBookServer.notify();
        }
    }

    /** 当前是否处于"纸面"运行但长时任务已被系统取消（对话框据此如实提示用户） */
    static keepAliveCancelled(): boolean {
        return WifiBookServer.bgCancelled;
    }

    static address(): string {
        return WifiBookServer.lastAddress;
    }

    /**
     * 带配对码的完整地址（显示/复制给用户的那个）。
     * 配对码无效时返回空串 ⇒ 调用方提示用户"刷新配对码"。
     */
    static pairAddress(): string {
        if (!WifiBookServer.running || WifiBookServer.lastAddress === '') {
            return '';
        }
        const code: string = webCredential.currentPairCode();
        if (code === '' || !WifiBookServer.WEB_AUTH_ENABLED) {
            return WifiBookServer.lastAddress;
        }
        return `${WifiBookServer.lastAddress}/?${PAIR_QUERY_KEY}=${code}`;
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
        // 每次启动都刷新配对码（一次性；关掉服务即作废）
        if (WifiBookServer.WEB_AUTH_ENABLED) {
            webCredential.newPairCode();
        }
        WifiBookServer.abilityContext = context;
        WifiBookServer.bgCancelled = false;
        WifiBookServer.lastHeartbeatAt = 0;
        WifiBookServer.bgNotificationId = 0;
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
                WifiBookServer.lastAddress = WifiBookServer.computeAddress();
                console.info(`${TAG} listening on ${WifiBookServer.port}, address=${WifiBookServer.lastAddress}`);
                WifiBookServer.notify();
                onResult?.(true, '');
                WifiBookServer.startBackgroundKeepAlive(context);
            }
        });
    }

    /** 局域网地址（大端序，口径见 `ipNumberToDotted` 注释） */
    private static computeAddress(): string {
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

    // ── 锁屏保活（用户拍板方案 a：有流量才刷心跳；系统取消就如实停）─────────────
    /**
     * 申请 DATA_TRANSFER 长时任务并注册**取消监听**。
     *
     * 官方依据（原文）：
     *  · 开发指南《长时任务(ArkTS)》：「在数据传输时，应用**需要更新进度**，如果进度长时间
     *    （**首次更新超过 10 分钟**）未更新，数据传输的长时任务**会被取消**。更新进度的
     *    通知类型必须为实况窗」——实况窗对普通应用为 Beta、需企业账号且场景准入
     *    （《实况窗有哪些支持对接的场景》：「支持对接的场景主要有出行打车、即时配送、
     *    运动锻炼、导航等」）⇒ 我们**申请不到实况窗**，因此只做「按需刷新」的心跳。
     *  · 接入规范《Background_Tasks_Kit接入规范》：「应用不得通过后台任务恶意"保活"」
     *    ⇒ 无流量时不空刷心跳（这正是方案 a 的由来）。
     *
     * 用 `string[]` 重载（SDK `:771`）而不是 `BackgroundMode` 枚举重载（`:734`），
     * 因为只有前者**返回 `ContinuousTaskNotification`（含 notificationId）**，
     * 没有 id 就无法更新进度/无法按 id 停止。
     */
    private static startBackgroundKeepAlive(context: common.UIAbilityContext): void {
        WifiBookServer.registerBgCancelHook();
        const agentInfo: wantAgent.WantAgentInfo = {
            wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
            actionType: wantAgent.OperationType.START_ABILITY,
            requestCode: 0
        };
        wantAgent.getWantAgent(agentInfo)
            .then((agent: object) => {
            backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent)
                .then((res: backgroundTaskManager.ContinuousTaskNotification): void => {
                WifiBookServer.bgNotificationId = res.notificationId;
                WifiBookServer.lastHeartbeatAt = new Date().getTime();
                console.info(`${TAG} background running ok, notificationId=${res.notificationId}`);
            })
                .catch((e: BusinessError): void => {
                    // 9800005 = 本应用已有长时任务在运行（如听书的 AUDIO_PLAYBACK）⇒ 应用
                    // 本就被保活着，不算故障（真机日志 12:58 实证），降级为 info 防误判。
                    if (e.code === 9800005) {
                        console.info(`${TAG} bg start skipped: a continuous task already exists (app already kept alive)`);
                        return;
                    }
                    console.error(`${TAG} bg start failed: ${e.code} ${e.message}`);
                });
        })
            .catch((e: BusinessError): void => console.error(`${TAG} wantAgent failed: ${e.message}`));
    }

    /** 注册长时任务取消监听（幂等；@since 15，SDK `@ohos.resourceschedule.backgroundTaskManager.d.ts:1027`） */
    private static registerBgCancelHook(): void {
        if (WifiBookServer.bgCancelHookOn) {
            return;
        }
        WifiBookServer.bgCancelHookOn = true;
        try {
            backgroundTaskManager.on('continuousTaskCancel',
                (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
                    WifiBookServer.bgCancelled = true;
                    WifiBookServer.bgNotificationId = 0;
                    // 如实记录，不再自动重申请（合规：系统取消后不得立即再申请）
                    console.error(`${TAG} continuous task cancelled: id=${info.id} reason=${info.reason}`);
                    WifiBookServer.notify();
                });
        }
        catch (err) {
            console.error(`${TAG} register cancel hook failed: ${(err as Error).message}`);
        }
    }

    /**
     * 长时任务进度心跳（**有流量才刷**）。
     * 每处理一个请求就调一次；距上次心跳不足 `KEEPALIVE_HEARTBEAT_MS` 时直接返回
     * （既避免频繁调用系统接口，也保证"10 分钟未更新"的计时器被可靠的实时流量重置）。
     *
     * @param bytes 本次请求/响应的大致字节数（>0 才算"有流量"）
     */
    private static noteTraffic(bytes: number): void {
        if (!WifiBookServer.WEB_KEEPALIVE_HEARTBEAT || !WifiBookServer.running) {
            return;
        }
        if (bytes <= 0 || WifiBookServer.bgCancelled) {
            return;
        }
        const now: number = new Date().getTime();
        if (now - WifiBookServer.lastHeartbeatAt < WifiBookServer.KEEPALIVE_HEARTBEAT_MS) {
            return;
        }
        const ctx: common.UIAbilityContext | null = WifiBookServer.abilityContext;
        if (ctx === null) {
            return;
        }
        WifiBookServer.lastHeartbeatAt = now;
        backgroundTaskManager.updateBackgroundRunning(ctx, ['dataTransfer'])
            .then((): void => console.info(`${TAG} keepalive heartbeat ok`))
            .catch((e: BusinessError): void => {
            console.error(`${TAG} keepalive heartbeat failed: ${e.code} ${e.message}`);
        });
    }

    static stop(context: common.UIAbilityContext, onResult?: (ok: boolean) => void): void {
        if (WifiBookServer.server === null) {
            WifiBookServer.finishStop();
            onResult?.(true);
            return;
        }
        // ⚠️ 状态必须先落：`set` 与开关两处都按同步返回的 running 渲染，若等异步 close
        //    完成再改，用户会看到"关了还是开"（真实体验问题）。
        WifiBookServer.running = false;
        WifiBookServer.notify();
        webCredential.invalidatePairCode();
        const id: number = WifiBookServer.bgNotificationId;
        WifiBookServer.bgNotificationId = 0;
        WifiBookServer.abilityContext = null;
        try {
            if (id > 0) {
                // 按 id 停止（SDK `stopBackgroundRunning(context, continuousTaskId)`）
                backgroundTaskManager.stopBackgroundRunning(context, id)
                    .catch((e: BusinessError): void => console.error(`${TAG} bg stop(id) failed: ${e.code} ${e.message}`));
            }
            else {
                backgroundTaskManager.stopBackgroundRunning(context)
                    .catch((e: BusinessError): void => console.error(`${TAG} bg stop failed: ${e.code} ${e.message}`));
            }
        }
        catch (err) {
            console.error(`${TAG} bg stop threw: ${(err as Error).message}`);
        }
        // 关掉全部在途连接：SDK 原文明确 server.close() **不关**已有连接
        // （`@ohos.net.socket.d.ts:3324-3326`「This API does not close existing connections.
        //   To close connections, call the close API of TCPSocketConnection.」）
        WifiBookServer.closeAllConnections();
        const server: socket.TCPSocketServer = WifiBookServer.server;
        server.close()
            .then((): void => {
            WifiBookServer.finishStop();
            onResult?.(true);
        })
            .catch((err: Error): void => {
            WifiBookServer.finishStop();
            onResult?.(false);
            console.error(`${TAG} close failed: ${err.message}`);
        });
    }

    /** 停止后的统一收尾（幂等） */
    private static finishStop(): void {
        WifiBookServer.running = false;
        WifiBookServer.server = null;
        WifiBookServer.lastAddress = '';
        WifiBookServer.notify();
    }

    /** 逐个关闭在途连接（句柄泄漏的根治点） */
    private static closeAllConnections(): void {
        WifiBookServer.conns.forEach((c: socket.TCPSocketConnection) => {
            c.close()
                .then((): void => {})
                .catch((err: Error): void => console.error(`${TAG} conn close failed: ${err.message}`));
        });
        WifiBookServer.conns.clear();
    }
    // ── 连接层 ────────────────────────────────────────────────────────────
    /**
     * 单个连接的生命周期。**v2（2026-10-06 审计 P0-2/P1-1）三项根治**：
     *  ① 缓冲区改为 **`cbuf` + `clen` 预分配 + 偏移写入**：旧实现每收到一个 TCP 分片就
     *     `concatBytes(buffer, chunk)`（整份复制）⇒ 传 100 MB 按 64 KB 分片要搬运约
     *     Σn ≈ O(n²) 字节，全在请求回调里同步做（主线程）。现在只在容量不足时按
     *     1.5 倍扩容，摊还 O(n)。
     *  ② **每个请求都有终态**：定时器兜底 + 出错必回响应 + 处理完 `close()`
     *     （SDK 原文：server.close 不关已有连接，必须自己关）。
     *  ③ 连接数上限 + 单请求体上限 + 单请求超时（上限 32：连接在响应后延迟 2s 才真正
     *     close —— 避开网络栈延迟关 fd 与 fd 编号复用的竞态，见 `finish` 注释 ——
     *     故上限比旧值 16 翻倍留余量；请求体 100 MB；交互请求超时 15 s）。
     */
    private static handleClient(client: socket.TCPSocketConnection): void {
        if (WifiBookServer.WEB_LIMITS_ENABLED && WifiBookServer.conns.size >= WifiBookServer.MAX_CONNECTIONS) {
            console.error(`${TAG} too many connections (${WifiBookServer.conns.size}), rejecting client ${client.clientId}`);
            WifiBookServer.respondRaw(client, 503, 'text/plain; charset=utf-8',
                WifiBookServer.textBytes('服务繁忙：连接数已达上限，请稍后重试'), closeRejected);
            return;
        }
        WifiBookServer.conns.set(client.clientId, client);
        let buf: Uint8Array = new Uint8Array(0);
        let end: number = 0;
        let closed: boolean = false;
        let timeoutId: number = -1;
        /** 对端真实 IP（首条 message 时从 remoteInfo 取；取不到留空，回退 `c<id>`） */
        let peerIp: string = '';

        const finish = (): void => {
            if (closed) {
                return;
            }
            closed = true;
            if (timeoutId >= 0) {
                clearTimeout(timeoutId);
                timeoutId = -1;
            }
            WifiBookServer.timerByClient.delete(client.clientId);
            WifiBookServer.finishByClient.delete(client.clientId);
            WifiBookServer.conns.delete(client.clientId);
            // ⚠️ **延迟 2s 再真正 close**（2026-10-12 真机日志定案）：send 的 Promise 结束
            // ≠ 字节已落内核（日志：send 后 1ms close，网络栈打 "not close should close"
            // 表示延迟关 fd），此时 OS 可能把同一 fd 编号立刻分给下一条 accept 的连接，
            // 网络栈的延迟关 fd 就会把**新连接**关掉 ⇒ send EPIPE / Network is down ⇒
            // 浏览器下一请求必挂（"配对成功但进不去"真凶）。延迟关闭期间 fd 仍被占用，
            // OS 不会复用编号 ⇒ 竞态窗口消失。浏览器侧本就按 Connection: close 自行关闭。
            setTimeout((): void => {
                client.close()
                    .then((): void => {})
                    // ⚠️ 预期内的空操作：浏览器按 Connection: close 会先自行关闭，
                    //    网络栈随之清理 ⇒ 我们延迟的 close 扑空（"not find clientId"）。
                    //    **不是错误**（真机 13:10 日志逐条核对过），只记 info 防止误导排查。
                    .catch((err: Error): void => console.info(`${TAG} conn close skipped (peer already gone): ${err.message}`));
            }, WifiBookServer.CLOSE_DELAY_MS);
        };
        WifiBookServer.finishByClient.set(client.clientId, finish);
        /** 按给定档位重新计时（`respondRaw` 下发大正文时会用更宽的档再调一次） */
        const armWith = (ms: number): void => {
            if (!WifiBookServer.WEB_LIMITS_ENABLED) {
                return;
            }
            if (timeoutId >= 0) {
                clearTimeout(timeoutId);
            }
            timeoutId = setTimeout((): void => {
                // ⚠️ 空闲连接（一个字节都没来，典型 = 浏览器预连接）**静默关闭**，
                //    绝不回 408：2026-10-06 真机复盘——浏览器连接池复用这条连接的瞬间，
                //    恰好收到服务端硬塞的 408 ⇒ 被当成它自己请求的响应 ⇒ 前端报"网络失败"
                //    （表现：配对成功后紧接着的下一个请求必挂）。有数据在途才按 408 处理。
                if (end === 0) {
                    console.info(`${TAG} idle preconnect closed silently, client ${client.clientId}`);
                    finish();
                    return;
                }
                console.error(`${TAG} request timeout on client ${client.clientId}`);
                WifiBookServer.respondRaw(client, 408, 'text/plain; charset=utf-8',
                    WifiBookServer.textBytes('请求超时'), finish);
            }, ms);
        };
        WifiBookServer.timerByClient.set(client.clientId, armWith);
        const armTimeout = (): void => {
            armWith(WifiBookServer.TIMEOUT_INTERACTIVE);
        };

        client.on('message', (info: socket.SocketMessageInfo) => {
            try {
                if (closed) {
                    return;
                }
                // 对端真实 IP（SDK `SocketMessageInfo.remoteInfo.address`，since 11）：
                // 同一条连接上所有请求共用，配对登记/设备去重/限流都以它为准
                if (peerIp === '' && info.remoteInfo !== undefined) {
                    peerIp = info.remoteInfo.address ?? '';
                }
                const chunk: Uint8Array = new Uint8Array(info.message);
                if (chunk.length > 0) {
                    if (end + chunk.length > buf.length) {
                        let cap: number = buf.length === 0 ? Math.max(4096, chunk.length) : buf.length;
                        while (cap < end + chunk.length) {
                            cap = Math.floor(cap * 1.5) + 1024;
                        }
                        const nb: Uint8Array = new Uint8Array(cap);
                        if (end > 0) {
                            nb.set(buf.subarray(0, end), 0);
                        }
                        buf = nb;
                    }
                    buf.set(chunk, end);
                    end += chunk.length;
                }
                armTimeout();
                // 循环消费（pipelining / 粘包）
                for (;;) {
                    const parsed: ParsedHttp | null = WifiBookServer.tryParse(buf, end, peerIp);
                    if (parsed === null) {
                        break;
                    }
                    const rest: number = end - parsed.consumed;
                    if (rest > 0) {
                        buf.copyWithin(0, parsed.consumed, end);
                    }
                    end = rest;
                    WifiBookServer.noteTraffic(parsed.consumed);
                    // 分档（用户拍板 B2）：请求体 ≥ 1 MB（分块块 / 整文件 multipart）走
                    // "数据传输"档 300 s；其余交互类请求 15 s（旧实现统一 60 s ⇒ 小接口
                    // 卡住要等整整一分钟才有响应）。服务器**下发**的大正文在 `respondRaw`
                    // 里会再换到 300 s（那时才知道响应体多大）。
                    armWith(parsed.consumed >= WifiBookServer.TIMEOUT_BULK_BYTES
                        ? WifiBookServer.TIMEOUT_TRANSFER
                        : WifiBookServer.TIMEOUT_INTERACTIVE);
                    WifiBookServer.dispatchAsync(client, parsed)
                        .then((): void => finish())
                        .catch((e: Error): void => {
                        console.error(`${TAG} dispatch failed: ${e.message}`);
                        WifiBookServer.respondRaw(client, 500, 'text/plain; charset=utf-8',
                            WifiBookServer.textBytes('internal error'), finish);
                    });
                    // 我们的响应一律 `Connection: close` ⇒ 一个连接只服务一个请求
                    return;
                }
            }
            catch (err) {
                console.error(`${TAG} message handler error: ${(err as Error).message}`);
                WifiBookServer.respondRaw(client, 400, 'text/plain; charset=utf-8',
                    WifiBookServer.textBytes('bad request'), finish);
            }
        });
        armTimeout();
    }

    /**
     * 头部完整且 body 收满时解析请求；否则返回 null（继续等）。
     * @param len 有效字节数（`buf` 的容量可能大于它）
     * @param peerIp 对端真实 IP（`SocketMessageInfo.remoteInfo.address`，透传进 ParsedHttp）
     */
    private static tryParse(buf: Uint8Array, len: number, peerIp: string): ParsedHttp | null {
        const view: Uint8Array = buf.subarray(0, len);
        const sep: Uint8Array = new Uint8Array([0x0D, 0x0A, 0x0D, 0x0A]);
        const headEnd: number = indexOfBytes(view, sep, 0);
        if (headEnd < 0) {
            if (WifiBookServer.WEB_LIMITS_ENABLED && len > 64 * 1024) {
                console.error(`${TAG} request header too large: ${len} bytes`);
            }
            return null;
        }
        const headText: string = bytesToUtf8(view.slice(0, headEnd));
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
        if (WifiBookServer.WEB_LIMITS_ENABLED
            && (contentLength < 0 || contentLength > WifiBookServer.MAX_BODY_BYTES)) {
            // 明确拒绝（旧实现会一直等这个 body ⇒ 内存无上限增长）
            console.error(`${TAG} request body too large: ${contentLength} bytes`);
            return {
                method: (parts[0] ?? 'GET').toUpperCase(),
                target: parts[1] ?? '/',
                path: parts[1]?.split('?')[0] ?? '/',
                headers: headers,
                body: new Uint8Array(0),
                consumed: headEnd + 4,
                rejectedBodyBytes: contentLength,
                peerIp: peerIp
            };
        }
        const bodyStart: number = headEnd + 4;
        if (len < bodyStart + contentLength) {
            return null;
        }
        const body: Uint8Array = view.slice(bodyStart, bodyStart + contentLength);
        const path: string = parts[1].split('?')[0] ?? '/';
        return {
            method: (parts[0] ?? 'GET').toUpperCase(),
            target: parts[1] ?? '/',
            path: path,
            headers: headers,
            body: body,
            consumed: bodyStart + contentLength,
            rejectedBodyBytes: 0,
            peerIp: peerIp
        };
    }
    // ── 分发 ──────────────────────────────────────────────────────────────
    /**
     * 路由分发（`handleClient` 直接 await 它，保证"每个请求都有终态"）。
     *
     * v2 新增两道**前置闸门**（都在真正的路由之前）：
     *  ① 超体量声明 ⇒ 立刻 413，不再等 body（旧实现会一直等到内存爆）
     *  ② 配对鉴权 ⇒ 未配对设备只允许看到"配对页"，其余一律 401
     */
    /**
     * 设备凭证**三通道**（2026-10-06 无 Cookie 化改造）——任一命中即视为已配对：
     *  ① HttpOnly Cookie `mr_dev`（原有通道，保留兼容）
     *  ② URL query `dt=<token>`（**主通道**）：配对成功的响应体直接带 token，页面存
     *     localStorage 后附加到每个请求/导航。真机日志复盘：该用户的浏览器不回传
     *     Set-Cookie ⇒ "配对成功却进不去"，Cookie 机制对用户不可见、不可控 ⇒ 弃为核心。
     *  ③ 请求头 `X-Device-Token`（预留）
     */
    private static hasValidCredential(req: ParsedHttp): boolean {
        const cookie: string = WifiBookServer.cookieValue(req, DEVICE_COOKIE);
        if (cookie !== '' && webCredential.verifyToken(cookie) !== null) {
            return true;
        }
        const dt: string = WifiBookServer.queryParam(req.target, 'dt');
        if (dt !== '' && webCredential.verifyToken(dt) !== null) {
            return true;
        }
        const hdr: string = req.headers['x-device-token'] ?? '';
        if (hdr !== '' && webCredential.verifyToken(hdr) !== null) {
            return true;
        }
        return false;
    }

    private static async dispatchAsync(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
        if (req.rejectedBodyBytes > 0) {
            WifiBookServer.respond(client, 413, 'text/plain; charset=utf-8',
                WifiBookServer.textBytes(`文件过大：上限 ${Math.floor(WifiBookServer.MAX_BODY_BYTES / 1024 / 1024)} MB`));
            return;
        }
        // 防御纵深：即使 `WEB_LIMITS_ENABLED` 被关掉（回退排障），**这里仍拒绝**超大请求体。
        // 旧实现没有任何一处限制 JSON 体（`/sync`、`/marksadd` 都能塞任意大）⇒ 内存不安全。
        if (req.body.length > WifiBookServer.MAX_BODY_BYTES) {
            console.error(`${TAG} body over hard cap: ${req.body.length}`);
            WifiBookServer.respond(client, 413, 'text/plain; charset=utf-8',
                WifiBookServer.textBytes('请求体过大'));
            return;
        }
        // 配对状态查询（门禁之前放行）：三通道凭证任一命中即 paired
        if (req.method === 'GET' && req.path === '/session') {
            WifiBookServer.respondJsonCode(client, 200, true,
                (WifiBookServer.WEB_AUTH_ENABLED && WifiBookServer.hasValidCredential(req)) ? 'paired' : 'unpaired', '');
            return;
        }
        const paired: boolean = !WifiBookServer.WEB_AUTH_ENABLED || WifiBookServer.hasValidCredential(req);
        if (!paired) {
            // 未配对（2026-10-06 用户拍板"输码弹窗"模式）放行三类入口：
            //   ① GET 页面壳（/、/library、/read）⇒ 一律渲染配对页（六位码输入框）；
            //      配对成功后页面自行 reload 原地址 ⇒ 书签/历史记录直达，不再依赖带码链接；
            //   ② POST /pair ⇒ 提交配对码换设备令牌（HttpOnly Cookie）；
            //   ③ GET / 带 ?k= ⇒ 保留"整链自动配对"（二维码仍走这条路）。
            // 其余数据接口一律 401。
            if (req.method === 'GET' && (req.path === '/' || req.path === '/index.html'
                || req.path === '/library' || req.path.startsWith('/read'))) {
                WifiBookServer.serveRoot(client, req);
                return;
            }
            if (req.method === 'POST' && req.path === '/pair') {
                WifiBookServer.handlePairPost(client, req);
                return;
            }
            WifiBookServer.respond(client, 401, 'text/plain; charset=utf-8',
                WifiBookServer.textBytes('未配对：请打开手机端显示的地址，输入 6 位配对码'));
            return;
        }
        try {
            // ⚠️ `/books` 必须排在 `startsWith('/book')` **之前**（2026-10-06 真机复盘）：
            //    否则"书库列表"被当成本本书匹配 ⇒ queryId=-1 ⇒ 回纯文本 "book not found"
            //    ⇒ 网页 JSON.parse 抛 "Unexpected token 'b'" ⇒ 电脑书库永远加载失败。
            if (req.method === 'GET' && req.path === '/books') {
                // JSON API（保留）：书目列表
                const entries: LibraryEntry[] = await WifiBookServer.libraryEntries();
                WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify(entries)));
            }
            else if (req.method === 'GET' && req.path.startsWith('/book')) {
                await WifiBookServer.serveBookFile(client, WifiBookServer.queryId(req.target));
            }
            else if (req.method === 'GET' && req.path.startsWith('/download')) {
                // v3.14：强制下载（书库页"下载"按钮走这里，浏览器弹保存而非内联打开）
                await WifiBookServer.serveDownload(client, WifiBookServer.queryId(req.target));
            }
            else if (req.method === 'GET' && req.path === '/library') {
                await WifiBookServer.serveLibraryPage(client);
            }
            else if (req.method === 'GET' && (req.path === '/' || req.path === '/index.html')) {
                WifiBookServer.serveUploadPage(client);
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
                await WifiBookServer.handleUpload(client, req);
            }
            else if (req.method === 'POST' && req.path === '/up/init') {
                WifiBookServer.handleUpInit(client, req);
            }
            else if (req.method === 'POST' && req.path === '/up/chunk') {
                WifiBookServer.handleUpChunk(client, req);
            }
            else if (req.method === 'POST' && req.path === '/up/done') {
                await WifiBookServer.handleUpDone(client, req);
            }
            else if (req.method === 'POST' && req.path === '/up/abort') {
                WifiBookServer.handleUpAbort(client, req);
            }
            else {
                WifiBookServer.respond(client, 404, 'text/plain; charset=utf-8', WifiBookServer.textBytes('not found'));
            }
        }
        catch (err) {
            console.error(`${TAG} dispatch error: ${(err as Error).message}`);
            // ⚠️ 出错也必须有响应：旧实现这里只打日志 ⇒ 浏览器干等（审计 P2）
            WifiBookServer.respond(client, 500, 'text/plain; charset=utf-8', WifiBookServer.textBytes('internal error'));
        }
    }

    // ── 鉴权基础设施 ──────────────────────────────────────────────────────
    /** 取某个 Cookie 的值（自写 HTTP 解析器，需要自己解析 Cookie 头） */
    private static cookieValue(req: ParsedHttp, name: string): string {
        const raw: string = req.headers['cookie'] ?? '';
        if (raw === '') {
            return '';
        }
        const parts: string[] = raw.split(';');
        for (let i = 0; i < parts.length; i++) {
            const one: string = parts[i].trim();
            const eq: number = one.indexOf('=');
            if (eq > 0 && one.substring(0, eq) === name) {
                return one.substring(eq + 1).trim();
            }
        }
        return '';
    }

    /** 取 URL query 参数（自写解析器；只解析第一处） */
    private static queryParam(target: string, key: string): string {
        const q: number = target.indexOf('?');
        if (q < 0) {
            return '';
        }
        const segs: string[] = target.substring(q + 1).split('&');
        for (let i = 0; i < segs.length; i++) {
            const eq: number = segs[i].indexOf('=');
            if (eq > 0 && segs[i].substring(0, eq) === key) {
                return segs[i].substring(eq + 1);
            }
        }
        return '';
    }

    /**
     * 限流/登记用的"来源"标识（**回退值**）。
     * 2026-10-06 起对端真实 IP 已从 `SocketMessageInfo.remoteInfo.address` 贯通进
     * `ParsedHttp.peerIp`（同一条连接所有请求共用），配对登记/设备去重都优先用它；
     * 仅当 remoteInfo 取不到时才回退到 `c<连接id>`（每连接唯一 ⇒ 只用于限流兜底）。
     */
    private static clientIp(client: socket.TCPSocketConnection): string {
        return `c${client.clientId}`;
    }

    /** 根路径/页面壳（未配对时）：带正确 `?k=` ⇒ 下发令牌并展示成功页；否则渲染输码配对页 */
    private static serveRoot(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        const code: string = WifiBookServer.queryParam(req.target, PAIR_QUERY_KEY);
        if (WifiBookServer.WEB_AUTH_ENABLED && code !== '') {
            // 对端真实 IP 优先（remoteInfo 贯通后必有）；取不到才回退 `c<连接id>`
            const ip: string = req.peerIp !== '' ? req.peerIp : WifiBookServer.clientIp(client);
            const ua: string = req.headers['user-agent'] ?? '';
            if (webCredential.verifyPairCode(code, ip)) {
                const token: string = webCredential.pairDevice(ip, ua);
                console.info(`${TAG} device paired, total=${webCredential.deviceCount()}`);
                WifiBookServer.notify();
                // 令牌只经 Cookie 下发（HttpOnly ⇒ 页面脚本读不到，降低 XSS 影响）
                WifiBookServer.respondRaw(client, 200, 'text/html; charset=utf-8',
                    WifiBookServer.pairOkPageBytes(token), noopClose,
                    `Set-Cookie: ${DEVICE_COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000`);
                return;
            }
            console.error(`${TAG} pair code rejected from ${ip}`);
            WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', WifiBookServer.pairFailPageBytes());
            return;
        }
        WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', WifiBookServer.pairPageBytes());
    }

    /**
     * POST /pair —— 配对页弹窗提交 6 位配对码（2026-10-06 用户拍板：手输地址 + 页面输码，
     * 不再强制"带码完整链接"）。成功 ⇒ `Set-Cookie` 下发设备令牌 + `{ok:true}`（页面自行
     * reload 原地址，Cookie 随下一跳生效）；失败 ⇒ 200 + `{ok:false,msg}`（页面展示文案；
     * 用 200 是为了让错误文案区分"码不对"与"尝试过多"，页面按 `ok` 字段裁决）。
     * 与 `?k=` 自动配对共用同一套限流/核销/设备登记（`webCredential.verifyPairCode`）。
     */
    private static handlePairPost(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        if (!WifiBookServer.WEB_AUTH_ENABLED) {
            WifiBookServer.respondJsonCode(client, 200, false, '服务端未启用配对', '');
            return;
        }
        let code: string = '';
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, string>;
            code = String(body['code'] ?? '').trim();
        }
        catch (err) {
            WifiBookServer.respondJsonCode(client, 200, false, '请求格式错误', '');
            return;
        }
        const ip: string = req.peerIp !== '' ? req.peerIp : WifiBookServer.clientIp(client);
        const ua: string = req.headers['user-agent'] ?? '';
        if (webCredential.verifyPairCode(code, ip)) {
            const token: string = webCredential.pairDevice(ip, ua);
            console.info(`${TAG} device paired (dialog), ip=${ip}, total=${webCredential.deviceCount()}`);
            WifiBookServer.notify();
            // **无 Cookie 化（2026-10-06）**：令牌直接放进响应体（页面存 localStorage 并附到
            // 每个请求）——Set-Cookie 仍下发作为兼容冗余，但不再依赖它（真机实证有浏览器
            // 不回传 Cookie ⇒ "配对成功却进不去"）。
            WifiBookServer.respondRaw(client, 200, 'application/json; charset=utf-8',
                WifiBookServer.textBytes(JSON.stringify({ ok: true, msg: 'paired', token: token })), noopClose,
                `Set-Cookie: ${DEVICE_COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000`);
            return;
        }
        console.error(`${TAG} pair code rejected from ${ip}`);
        const msg: string = webCredential.isLocked(ip)
            ? '尝试次数过多，请稍后再试，或在手机端点「刷新配对码」'
            : '配对码不正确或已过期（码为一次性，手机端可刷新）';
        WifiBookServer.respondJsonCode(client, 200, false, msg, '');
    }

    /** 传书页（v3 构建产物，失败回退旧内嵌页） */
    private static serveUploadPage(client: socket.TCPSocketConnection): void {
        const v3 = WifiBookServer.readV3PageBytes('upload_v3.html');
        WifiBookServer.respond(client, 200, 'text/html; charset=utf-8',
            v3 !== null ? v3 : WifiBookServer.uploadPageBytes());
    }

    /** 电脑阅读·书库页（v3 静态单文件，列表由页面自己 fetch /books；失败回退旧内嵌页） */
    private static async serveLibraryPage(client: socket.TCPSocketConnection): Promise<void> {
        const v3 = WifiBookServer.readV3PageBytes('library_v3.html');
        if (v3 !== null) {
            WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', v3);
            return;
        }
        const entries: LibraryEntry[] = await WifiBookServer.libraryEntries();
        WifiBookServer.respond(client, 200, 'text/html; charset=utf-8', WifiBookServer.libraryPageBytes(entries));
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
    /**
     * 书架全部本地书（`searchPage bookGroup=4` ⇒ 本地分组 or `isLocalBook`，pageSize 0 = 全量）。
     * **不下发沙箱绝对路径**（旧实现把 `bookUrl` 原样给网页 ⇒ 泄漏手机内部路径，审计 P2）。
     */
    private static async libraryEntries(): Promise<LibraryEntry[]> {
        const books: Books[] = await booksDao.searchPage({ bookGroup: 4 }, 1, 0);
        const out: LibraryEntry[] = [];
        books.forEach((b: Books) => {
            if (b.bookUrl && b.bookUrl.length > 0) {
                out.push({
                    id: b.id ?? 0,
                    name: b.bookName ?? '未命名',
                    isTxt: b.bookUrl.toLowerCase().endsWith('.txt'),
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
            const isTxt: boolean = e.isTxt;
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
        fetch('/marksdel?id='+id,{method:'POST',headers:{'Content-Type':'application/json'},
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
    document.getElementById('synctxt').innerHTML='手机进度：<br>① '+esc(normEx(topEx))+'<br>② '+esc(normEx(botEx));
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
    /**
     * 强制下载（v3.14："web书架点下载直接进入内容了"）：无论 txt/epub 一律
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
            try {
                fs.readSync(file.fd, buffer);
            }
            finally {
                fs.closeSync(file);
            }
            const ext: string = book.bookUrl.toLowerCase().endsWith('.epub') ? 'epub' : 'txt';
            // `respondRaw` 内部统一做头部净化（旧实现只过滤 " 和 \，书名里的换行可注入响应头）
            const name: string = WifiBookServer.safeFileName(book.bookName ?? 'book');
            WifiBookServer.noteTraffic(size);
            WifiBookServer.respond(client, 200, 'application/octet-stream', new Uint8Array(buffer),
                `attachment; filename="${name}.${ext}"`);
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
        try {
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
        catch (err) {
            // 旧实现没有 catch ⇒ DAO 抛错时浏览器干等（审计 P2）
            console.error(`${TAG} marks get failed: ${(err as Error).message}`);
            WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: false, marks: [] })));
        }
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
            const time: number = Number(body['time'] ?? 0);
            if (!(time > 0)) {
                WifiBookServer.respondJson(client, false, 'bad params');
                return;
            }
            // ── 越权删除的根治（2026-10-06 审计 P2）─────────────────────────────
            // 旧实现直接 `bookmarksDao.remove(time)`，**按 time 删、不校验书**
            // ⇒ 局域网里任何人可以按毫秒时间戳逐条删掉手机上任意一本书的书签。
            // 现在：先按 time 反查该行，确认它属于请求里声明的那本书，才允许删。
            const bid: number = WifiBookServer.queryId(req.target);
            const book: Books | null = await WifiBookServer.bookById(bid);
            if (book === null) {
                WifiBookServer.respondJson(client, false, 'book not found');
                return;
            }
            const all = await bookmarksDao.list();
            let owned: boolean = false;
            all.forEach((m) => {
                if (m.time === time && m.bookName === book.bookName) {
                    owned = true;
                }
            });
            if (!owned) {
                console.error(`${TAG} marksdel rejected: time=${time} not in book=${book.bookName}`);
                WifiBookServer.respondJson(client, false, 'not found');
                return;
            }
            const ok: boolean = await bookmarksDao.remove(time);
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
    private static async handleSyncGet(client: socket.TCPSocketConnection, id: number): Promise<void> {
        try {
            const arr: Books[] = await booksDao.getBookByIds([id]);
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
        }
        catch (err) {
            // ⚠️ 旧实现这条 then 链**没有 catch** ⇒ 数据库抛错时浏览器干等到超时（审计 P2）
            console.error(`${TAG} sync get failed: ${(err as Error).message}`);
            WifiBookServer.respond(client, 500, 'application/json; charset=utf-8', WifiBookServer.textBytes(JSON.stringify({ ok: false })));
        }
    }
    /**
     * 进度同步 POST：把**网页自己的位置**写进 `SyncPos_web_<书名>` 里属于它的那条
     * （`webId` 由网页在 localStorage 里生成 ⇒ 多台电脑各占一条，互不覆盖）。
     *
     * v2 起不再需要冲突检测：各写各的槽，网页写它自己的那份永远不会顶掉手机的位置
     * （v1 的 `baseTs` 冲突判定因此废弃；字段仍然接收，老 JS 不受影响）。
     */
    private static async handleSyncPost(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, number | string>;
            const bid = Number(body['id'] ?? -1);
            // webId 收敛（审计 P2：旧实现接受任意长度/任意内容的 webId，且
            // `SyncConfig.writeWebSlot` 会按它无限新增槽位 ⇒ 恶意刷写能把偏好存储撑爆）
            let webId = String(body['webId'] ?? '');
            if (webId === '') {
                webId = 'v1';
            }
            webId = webId.replace(/[^A-Za-z0-9_-]/g, '').substring(0, 24);
            if (webId === '') {
                webId = 'v1';
            }
            const title = String(body['chTitle'] ?? body['title'] ?? '').substring(0, 200);
            const topEx = String(body['topEx'] ?? '').substring(0, 200);
            const botEx = String(body['botEx'] ?? '').substring(0, 200);
            if (bid < 0 || (title === '' && topEx === '' && botEx === '')) {
                WifiBookServer.respondJson(client, false, 'bad params');
                return;
            }
            const arr: Books[] = await booksDao.getBookByIds([bid]);
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
        }
        catch (err) {
            // ⚠️ 旧实现这条 then 链**没有 catch** ⇒ 数据库抛错时浏览器干等（审计 P2）
            console.error(`${TAG} sync post failed: ${(err as Error).message}`);
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
        const entryName: string = WifiBookServer.safeFileName(book.bookName ?? 'book');
        try {
            const bytes: Uint8Array = WifiBookServer.readBookBytes(entryPath);
            const isTxt: boolean = entryPath.toLowerCase().endsWith('.txt');
            WifiBookServer.noteTraffic(bytes.length);
            WifiBookServer.respond(client, 200, isTxt ? 'text/plain; charset=utf-8' : 'application/octet-stream', bytes, isTxt ? undefined : `attachment; filename="${entryName}.epub"`);
        }
        catch (err) {
            WifiBookServer.respond(client, 500, 'text/plain; charset=utf-8', WifiBookServer.textBytes('read failed'));
        }
    }
    private static async handleUpload(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
        const contentType: string = req.headers['content-type'] ?? '';
        const bIdx: number = contentType.indexOf('boundary=');
        if (bIdx < 0) {
            WifiBookServer.respondJson(client, false, '不是有效的文件上传请求');
            return;
        }
        const boundary: string = '--' + contentType.substring(bIdx + 9).trim().replace(/"/g, '');
        const boundBytes: Uint8Array = WifiBookServer.textBytes(boundary);
        // 结构：--b\r\n头\r\n\r\n内容\r\n--b\r\n…\r\n--b--\r\n
        let imported: number = 0;
        let failed: number = 0;
        let conflicts: number = 0;
        let oversize: number = 0;
        let firstConflictId: number = -1;
        let errors: string[] = [];
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
                if (segBody.length === 0) {
                    // 空段是 multipart 的收尾段，不算失败
                    cursor = next;
                    continue;
                }
                const r: ImportResult = await WifiBookServer.saveAndImport(fileName, segBody);
                if (r.ok) {
                    imported++;
                }
                else {
                    failed++;
                    if (r.reason === 'dup') {
                        conflicts++;
                        if (firstConflictId < 0) {
                            firstConflictId = r.existingId;
                        }
                    }
                    else if (r.reason === 'oversize') {
                        oversize++;
                    }
                    if (r.msg !== '') {
                        errors.push(r.msg);
                    }
                }
            }
            cursor = next;
        }
        if (conflicts > 0 && imported === 0) {
            // 全部撞名 ⇒ 让网页弹"改名 / 拒绝"（用户拍板 C1）
            WifiBookServer.respondJsonCode(client, 409, false, '同名书籍已存在',
                `,"existingId":${firstConflictId}`);
            return;
        }
        if (oversize > 0 && imported === 0) {
            WifiBookServer.respondJsonCode(client, 413, false, `超过单文件上限 ${Math.floor(WifiBookServer.MAX_BODY_BYTES / 1024 / 1024)} MB`, '');
            return;
        }
        if (imported === 0) {
            WifiBookServer.respondJsonCode(client, 400, false, errors.length > 0 ? errors[0] : '没有可导入的文件', '');
            return;
        }
        const extra: string = failed > 0 ? `，失败 ${failed} 本` : '';
        WifiBookServer.respondJsonCode(client, 200, true, `已导入 ${imported} 本${extra}`, '');
    }

    /**
     * 写沙箱 + 入库。
     *
     * 相对旧实现修的四件事（审计 P1/P2）：
     *  ① **扩展名白名单**：旧实现"网页只让选 txt/epub"只是表单 accept，服务端什么都不校验
     *     ⇒ 局域网里可以塞任意文件进沙箱并直接进书架。现在只接受 `.txt` / `.epub`。
     *  ② **同名检测**：旧实现按文件名 TRUNC 覆盖 ⇒ 旧书内容被悄悄替换、书架还多一条重复记录。
     *     现在查 `BooksDao.isExistBooks`，撞名**不落盘**并回报冲突（供网页弹窗）。
     *  ③ **`await` 入库**：`booksUtil.addBooks` 是 async，旧实现没 await ⇒ 网页显示"已入架"
     *     而数据库里可能没有（假成功）。
     *  ④ **context 走确定性取值**：不再在异步回调里调已废弃的 `getContext()`
     *     （官方原文：异步回调里可能回溯不到、返回 undefined；`@deprecated since 18`）。
     */
    private static async saveAndImport(fileName: string, content: Uint8Array): Promise<ImportResult> {
        try {
            if (WifiBookServer.WEB_LIMITS_ENABLED && content.length > WifiBookServer.MAX_BODY_BYTES) {
                return { ok: false, reason: 'oversize', msg: `${fileName} 超过上限`, existingId: -1 };
            }
            const safeName: string = WifiBookServer.safeFileName(fileName);
            const lower: string = safeName.toLowerCase();
            if (!lower.endsWith('.txt') && !lower.endsWith('.epub')) {
                return { ok: false, reason: 'ext', msg: `${safeName} 不是 txt/epub`, existingId: -1 };
            }
            const ctx: common.UIAbilityContext | null = WifiBookServer.abilityContext;
            if (ctx === null) {
                return { ok: false, reason: 'io', msg: '服务未就绪', existingId: -1 };
            }
            // 同名检测（在**落盘之前**）：撞名一律不覆盖
            const dup: Books[] = await booksDao.isExistBooks(undefined, safeName);
            if (dup.length > 0) {
                console.info(`${TAG} duplicate upload rejected: ${safeName}`);
                return { ok: false, reason: 'dup', msg: `${safeName} 已存在`, existingId: dup[0].id ?? -1 };
            }
            const dst: string = ctx.filesDir + '/' + safeName;
            const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            try {
                fs.writeSync(file.fd, content.slice().buffer as ArrayBuffer);
            }
            finally {
                fs.closeSync(file);
            }
            return await WifiBookServer.registerImportedBook(safeName, dst, content.length);
        }
        catch (err) {
            console.error(`${TAG} saveAndImport failed: ${(err as Error).message}`);
            return { ok: false, reason: 'io', msg: (err as Error).message, existingId: -1 };
        }
    }

    /**
     * 只做"入库登记"（文件已在 `dst`）：分块上传的 `done` 与旧 multipart 上传**共用同一段字段**，
     * 避免两条路径的字段漂移。
     */
    private static async registerImportedBook(safeName: string, dst: string, size: number): Promise<ImportResult> {
        try {
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
            await booksUtil.addBooks(book);
            // 传书入库后**广播书架刷新**（2026-10-06 用户反馈"传完要手下滑才刷新"）：
            // `BOOK_IS_BOOK_REFRESHING` 是书架全组件的公共刷新信号（BookContent
            // `@StorageLink+@Watch` ⇒ 重查数据库）。与 BookInfos 改名广播同款语义：自增。
            const refreshTick: number = (AppStorage.get<number>(CommonConstants.BOOK_IS_BOOK_REFRESHING) ?? 0) + 1;
            AppStorage.setOrCreate(CommonConstants.BOOK_IS_BOOK_REFRESHING, refreshTick);
            WifiBookServer.notify();
            console.info(`${TAG} imported: ${safeName} (${size} bytes), shelfRefresh=${refreshTick}`);
            return { ok: true, reason: 'ok', msg: '', existingId: -1 };
        }
        catch (err) {
            console.error(`${TAG} registerImportedBook failed: ${(err as Error).message}`);
            return { ok: false, reason: 'io', msg: (err as Error).message, existingId: -1 };
        }
    }

    /**
     * 文件名净化：去掉路径分隔符与 Windows 非法字符，并**去掉换行**。
     * 旧实现只过滤 `[\/\\:*?"<>|]`，书名字符串里的 `\r\n` 会被原样拼进
     * `Content-Disposition` 响应头（HTTP 响应头注入，审计 P1-5）⇒ 这里一并剥掉。
     */
    private static safeFileName(fileName: string): string {
        let s: string = fileName.replace(/[\/\\:*?"<>|\r\n\t]/g, '_');
        s = s.replace(/^\.+/, '');
        if (s.length > 120) {
            s = s.substring(s.length - 120);
        }
        return s === '' ? `导入书籍_${Date.now()}.txt` : s;
    }

    // ── 分块上传 / 断点续传（用户明确要求「WiFi 传书应具备断点续传能力」）──────────
    /**
     * 开始（或复用）上传会话。
     * body: `{"name":"书名.txt","size":123456}`
     * resp: `{"ok":true,"sid":"u...","chunk":4194304,"have":[0,1,3]}`
     */
    private static handleUpInit(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, string | number>;
            const name: string = WifiBookServer.safeFileName(String(body['name'] ?? ''));
            const lower: string = name.toLowerCase();
            if (!lower.endsWith('.txt') && !lower.endsWith('.epub')) {
                WifiBookServer.respondJsonCode(client, 400, false, '只支持 txt / epub', '');
                return;
            }
            const size: number = Number(body['size'] ?? 0);
            const r: UploadInitResult = uploadSessions.init(name, isFinite(size) ? size : 0);
            if (!r.ok) {
                WifiBookServer.respondJsonCode(client, 413, false,
                    `超过单文件上限 ${Math.floor(MAX_FILE_BYTES / 1024 / 1024)} MB`, '');
                return;
            }
            const json: string = `{"ok":true,"msg":"","sid":"${r.sid}","chunk":${r.chunk},"have":${JSON.stringify(r.have)}}`;
            WifiBookServer.respond(client, 200, 'application/json; charset=utf-8', WifiBookServer.textBytes(json));
        }
        catch (err) {
            WifiBookServer.respondJsonCode(client, 400, false, 'bad json', '');
        }
    }

    /**
     * 收一块（**原始二进制体**，不是 multipart —— 自写解析器下这样最省内存也最不易出错）。
     * `POST /up/chunk?sid=xxx&i=3`
     */
    private static handleUpChunk(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        const sid: string = WifiBookServer.queryParam(req.target, 'sid');
        const idx: number = Number(WifiBookServer.queryParam(req.target, 'i'));
        if (sid === '' || !isFinite(idx) || idx < 0 || idx > 100000) {
            WifiBookServer.respondJsonCode(client, 400, false, 'bad params', '');
            return;
        }
        if (req.body.length === 0) {
            WifiBookServer.respondJsonCode(client, 400, false, 'empty chunk', '');
            return;
        }
        const received: number = uploadSessions.putChunk(sid, idx, req.body.slice());
        if (received === -1) {
            WifiBookServer.respondJsonCode(client, 410, false, 'session expired', '');
            return;
        }
        if (received === -2) {
            WifiBookServer.respondJsonCode(client, 413, false,
                `超过单文件上限 ${Math.floor(MAX_FILE_BYTES / 1024 / 1024)} MB`, '');
            return;
        }
        WifiBookServer.noteTraffic(req.body.length);
        WifiBookServer.respondJsonCode(client, 200, true, `received ${received}`, `,"received":${received}`);
    }

    /**
     * 收尾：拼装 → 同名检测 → 落盘 → 入库。
     * body: `{"sid":"u...","name":"书名.txt"}`（name 仅作兜底，以 init 时登记的名字为准）
     */
    private static async handleUpDone(client: socket.TCPSocketConnection, req: ParsedHttp): Promise<void> {
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, string>;
            const sid: string = String(body['sid'] ?? '');
            const meta: UploadSessionMeta | null = uploadSessions.meta(sid);
            if (meta === null) {
                WifiBookServer.respondJsonCode(client, 410, false, 'session expired', '');
                return;
            }
            const bytes: Uint8Array | null = uploadSessions.assemble(sid);
            if (bytes === null || bytes.length === 0) {
                WifiBookServer.respondJsonCode(client, 400, false, '上传不完整，请重试', '');
                return;
            }
            const ctx: common.UIAbilityContext | null = WifiBookServer.abilityContext;
            if (ctx === null) {
                WifiBookServer.respondJsonCode(client, 400, false, '服务未就绪', '');
                return;
            }
            // 同名检测先做（撞名时**不落盘**，交由网页弹"改名 / 拒绝"）
            const dup: Books[] = await booksDao.isExistBooks(undefined, meta.name);
            if (dup.length > 0) {
                console.info(`${TAG} chunked upload conflict: ${meta.name}`);
                WifiBookServer.respondJsonCode(client, 409, false, '同名书籍已存在', `,"existingId":${dup[0].id ?? -1}`);
                return;
            }
            const dst: string = uploadSessions.flushToFile(sid, ctx.filesDir);
            if (dst === '') {
                WifiBookServer.respondJsonCode(client, 400, false, '上传不完整，请重试', '');
                return;
            }
            const r: ImportResult = await WifiBookServer.registerImportedBook(meta.name, dst, bytes.length);
            uploadSessions.drop(sid);
            if (!r.ok) {
                WifiBookServer.respondJsonCode(client, 400, false, r.msg, '');
                return;
            }
            WifiBookServer.respondJsonCode(client, 200, true, `已导入 1 本`, '');
        }
        catch (err) {
            console.error(`${TAG} up/done failed: ${(err as Error).message}`);
            WifiBookServer.respondJsonCode(client, 400, false, 'bad json', '');
        }
    }

    /** 放弃本次上传（撞名时用户选"拒绝"、或客户端主动取消） */
    private static handleUpAbort(client: socket.TCPSocketConnection, req: ParsedHttp): void {
        try {
            const body = JSON.parse(bytesToUtf8(req.body)) as Record<string, string>;
            const sid: string = String(body['sid'] ?? '');
            uploadSessions.drop(sid);
            WifiBookServer.respondJsonCode(client, 200, true, '已放弃', '');
        }
        catch (err) {
            WifiBookServer.respondJsonCode(client, 400, false, 'bad json', '');
        }
    }
    // ── HTTP 基础设施 ──────────────────────────────────────────────────────
    private static textBytes(text: string): Uint8Array {
        const encoder = util.TextEncoder.create('utf-8');
        return encoder.encodeInto(text);
    }
    /** HTTP 头部值净化：剥掉 CR/LF 与引号（防响应头注入，审计 P1-5） */
    private static headerSafe(v: string): string {
        return v.replace(/[\r\n]/g, ' ').replace(/["\\]/g, '');
    }

    /** HTTP 状态短语（旧实现只有 OK/Not Found/Error ⇒ 413/408/401/409/503 全显示 Error） */
    private static statusText(status: number): string {
        if (status === 200) {
            return 'OK';
        }
        if (status === 400) {
            return 'Bad Request';
        }
        if (status === 401) {
            return 'Unauthorized';
        }
        if (status === 404) {
            return 'Not Found';
        }
        if (status === 408) {
            return 'Request Timeout';
        }
        if (status === 409) {
            return 'Conflict';
        }
        if (status === 413) {
            return 'Payload Too Large';
        }
        if (status === 500) {
            return 'Internal Server Error';
        }
        if (status === 503) {
            return 'Service Unavailable';
        }
        return 'Error';
    }

    private static respond(client: socket.TCPSocketConnection, status: number, contentType: string,
        body: Uint8Array, disposition?: string, setCookie?: string): void {
        WifiBookServer.respondRaw(client, status, contentType, body, noopClose, setCookie, disposition);
    }

    /**
     * 构造并发送响应（唯一出口）。
     * @param onDone 响应真正发出（或发送失败）后的回调 —— 提前拒绝路径靠它 `client.close()`，
     *               保证"每个请求都有终态"（旧实现从不关连接 ⇒ 句柄只增不减）。
     */
    private static respondRaw(client: socket.TCPSocketConnection, status: number, contentType: string,
        body: Uint8Array, onDone: (c: socket.TCPSocketConnection) => void,
        setCookie?: string, disposition?: string): void {
        let head: string = `HTTP/1.1 ${status} ${WifiBookServer.statusText(status)}\r\n` +
            `Content-Type: ${contentType}\r\n` +
            `Content-Length: ${body.length}\r\n` +
            `Cache-Control: no-store\r\n` +
            `Connection: close\r\n`;
        if (disposition !== undefined && disposition !== '') {
            head += `Content-Disposition: ${WifiBookServer.headerSafe(disposition)}\r\n`;
        }
        if (setCookie !== undefined && setCookie !== '') {
            head += `Set-Cookie: ${WifiBookServer.headerSafe(setCookie)}\r\n`;
        }
        head += '\r\n';
        const out: Uint8Array = concatBytes(WifiBookServer.textBytes(head), body);
        // 下发大正文（书/下载）⇒ 换成"数据传输"档，否则慢速客户端读大书途中会被 408 掐断。
        // 这是**唯一**在响应阶段重新计时的地方（此时才知道响应体多大）。
        if (body.length >= WifiBookServer.TIMEOUT_BULK_BYTES) {
            const rearArm: ((ms: number) => void) | undefined = WifiBookServer.timerByClient.get(client.clientId);
            if (rearArm !== undefined) {
                rearArm(WifiBookServer.TIMEOUT_SERVE);
            }
            WifiBookServer.noteTraffic(body.length);
        }
        client.send({ data: out.slice().buffer as ArrayBuffer })
            .then((): void => {
                onDone(client);
                // 响应**发出之后**才允许关连接（finishByClient 由 handleClient 登记；
                // 503 拒绝路径未登记 ⇒ 取不到就只跑 onDone）。finish 幂等，重复调用无害。
                const fin: (() => void) | undefined = WifiBookServer.finishByClient.get(client.clientId);
                if (fin !== undefined) {
                    fin();
                }
            })
            .catch((err: Error): void => {
                console.error(`${TAG} send failed: ${err.message}`);
                onDone(client);
                const fin2: (() => void) | undefined = WifiBookServer.finishByClient.get(client.clientId);
                if (fin2 !== undefined) {
                    fin2();
                }
            });
    }

    /**
     * JSON 响应（`ok` + `msg`，可选附加 JSON 片段）。
     * @param extraJson 追加进 JSON 对象的片段，形如 `,"existingId":12`（调用方保证合法）
     */
    private static respondJsonCode(client: socket.TCPSocketConnection, status: number, ok: boolean,
        msg: string, extraJson: string): void {
        const json: string = `{"ok":${ok ? 'true' : 'false'},"msg":${JSON.stringify(msg)}${extraJson}}`;
        WifiBookServer.respond(client, status, 'application/json; charset=utf-8', WifiBookServer.textBytes(json));
    }

    private static respondJson(client: socket.TCPSocketConnection, ok: boolean, msg: string): void {
        WifiBookServer.respondJsonCode(client, ok ? 200 : 400, ok, msg, '');
    }

    // ── 配对页（未配对设备的唯一入口）────────────────────────────────────────
    private static pageShell(title: string, inner: string): string {
        return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'HarmonyOS Sans SC','PingFang SC','Microsoft YaHei',sans-serif;
background:#F2F3F7;min-height:100vh;color:#1a1a1a;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:#fff;border-radius:18px;box-shadow:0 2px 16px rgba(0,0,0,.06);padding:30px 26px;max-width:460px;width:100%}
h1{font-size:20px;font-weight:700;margin-bottom:10px}
p{font-size:14px;line-height:1.75;color:#5b6068;margin:8px 0}
b{color:#1a1a1a}
code{background:#F0F1F5;border-radius:6px;padding:2px 6px;font-size:13px}
.ok{color:#24B277;font-size:16px;font-weight:700;text-align:center;margin-bottom:8px}
.bad{color:#EF4444;font-size:16px;font-weight:700;text-align:center;margin-bottom:8px}
a.btn{display:block;text-align:center;margin-top:18px;background:#0A84FF;color:#fff;text-decoration:none;
font-size:15px;font-weight:600;padding:13px;border-radius:12px;cursor:pointer;border:0;width:100%}
.tip{background:#F0F7FF;border-radius:10px;padding:12px 14px;font-size:13px;color:#3f6ea8;margin-top:14px}
input.code{width:100%;font-size:26px;font-weight:800;letter-spacing:9px;text-align:center;
padding:12px 4px;border:1.5px solid #d5d9e0;border-radius:12px;outline:none;color:#1a1a1a;
font-family:-apple-system,'HarmonyOS Sans SC','PingFang SC',sans-serif}
input.code:focus{border-color:#0A84FF}
.err{color:#EF4444;font-size:13px;text-align:center;margin-top:10px;display:none}
</style></head><body><div class="card">${inner}</div></body></html>`;
    }

    /**
     * 未配对页（2026-10-06 升级为"输码弹窗"模式，用户拍板）：手机端显示 6 位配对码，
     * 电脑打开任意页面地址（/ 或 /library 或 /read）都会落到这里，输码即配对；
     * 成功后 `location.reload()` 回到**原地址**（书签/历史直达，不依赖带码链接）。
     * `?k=` 整链自动配对仍保留（二维码用），由 `serveRoot` 在本页之前拦截。
     */
    private static pairPageBytes(): Uint8Array {
        const inner: string = `<h1>配对到手机</h1>
<p>这台设备还没有被手机授权。请打开手机上的 <b>我的 → Web 服务 · WiFi 传书</b>，
把显示的 <b>6 位配对码</b>输入到这里：</p>
<input class="code" id="code" type="text" inputmode="numeric" autocomplete="one-time-code"
  maxlength="6" placeholder="······">
<div class="err" id="err"></div>
<button class="btn" id="go" type="button">配 对</button>
<div class="tip">配对码 10 分钟内可重复使用（输错可重试、可配多台设备）；每台电脑只需配对一次。
也可以直接用手机端弹出的二维码扫码自动配对。若提示网络错误，请先点亮手机屏幕再试。</div>
<script>
var box=document.getElementById('code');
var errEl=document.getElementById('err');
function showErr(t){errEl.textContent=t;errEl.style.display='block'}
function resetBtn(){var b=document.getElementById('go');b.textContent='配 对';b.disabled=false}
function withDt(u,t){return u+(u.indexOf('?')>=0?'&':'?')+'dt='+t}
function saveTok(t){try{localStorage.setItem('mr_dt',t);return true}catch(e){return false}}
/* 自愈（2026-10-06 无 Cookie 化）：本机存过令牌 ⇒ 直接带 dt 进原地址，免重输码。
   URL 里已有 dt 还落到本页 ⇒ 说明令牌已失效（手机端清除了设备）⇒ 不再跳，直接输码。 */
(function(){
  var t='';try{t=localStorage.getItem('mr_dt')||''}catch(e){}
  if(t&&location.search.indexOf('dt=')<0){location.replace(withDt(location.href,t))}
  else if(location.search.indexOf('dt=')>=0){showErr('原授权已失效（可能在手机端被清除）。请重新输入配对码。')}
})();
function submit(){
  var v=box.value.replace(/[^0-9]/g,'');
  if(v.length!==6){showErr('请输入 6 位数字配对码');return}
  var btn=document.getElementById('go');
  btn.textContent='配对中…';btn.disabled=true;errEl.style.display='none';
  var x=new XMLHttpRequest();
  x.open('POST','/pair');
  x.setRequestHeader('Content-Type','application/json');
  x.onload=function(){
    var j=null;
    try{j=JSON.parse(x.responseText)}catch(e){}
    if(j&&j.ok&&j.token){
      /* 无 Cookie 化主通道：令牌存本机 + 带 dt 跳回原地址（跳转即已授权，确定性的）。 */
      var saved=saveTok(j.token);
      location.replace(withDt(location.href,j.token));
      if(!saved){setTimeout(function(){resetBtn();showErr('已配对，但本机无法保存令牌（浏览器隐私模式？）。本次会话可直接使用，刷新后需重输。')},400)}
      return;
    }
    resetBtn();
    showErr((j&&j.msg)?j.msg:'配对失败，请重试');
  };
  x.onerror=function(){
    resetBtn();
    showErr('网络错误：手机可能已锁屏休眠——请点亮手机、保持「Web 服务」页打开，再点「配对」重试');
  };
  x.send(JSON.stringify({code:v}));
}
document.getElementById('go').onclick=submit;
box.addEventListener('keydown',function(e){if(e.key==='Enter'){submit()}});
box.focus();
</script>`;
        return WifiBookServer.textBytes(WifiBookServer.pageShell('喵阅 · 配对', inner));
    }

    /** 配对成功（?k= 自动配对路径）：页面内**保存令牌到 localStorage** 并带 dt 跳进传书页 */
    private static pairOkPageBytes(token: string): Uint8Array {
        const inner: string = `<div class="ok">✓ 配对成功</div>
<p>这台电脑已被授权，下次直接打开手机显示的地址即可（无需再配对）。</p>
<a class="btn" id="goBtn" href="/">进入 WiFi 传书</a>
<p style="text-align:center;margin-top:12px"><a id="libBtn" href="/library" style="color:#0A84FF;font-size:14px">或打开书库阅读 →</a></p>
<script>
try{localStorage.setItem('mr_dt','${token}')}catch(e){}
(function(){
  var dt='dt=${token}';
  var a=document.getElementById('goBtn');if(a){a.href='/?'+dt}
  var b=document.getElementById('libBtn');if(b){b.href='/library?'+dt}
})();
</script>`;
        return WifiBookServer.textBytes(WifiBookServer.pageShell('喵阅 · 配对成功', inner));
    }

    /** 配对失败（仅 `?k=` 自动配对路径会落到这里；输码弹窗路径的错误在页面内联提示） */
    private static pairFailPageBytes(): Uint8Array {
        const inner: string = `<div class="bad">配对码无效或已过期</div>
<p>可能原因：配对码已被用过（一次性）、已超过 10 分钟，或尝试次数过多。</p>
<div class="tip">请在手机上打开 <b>我的 → Web 服务 · WiFi 传书</b>，点<b>刷新配对码</b>后重试，
或直接在电脑上重新打开地址，<b>手动输入 6 位配对码</b>。</div>
<a class="btn" href="/">返回配对页</a>`;
        return WifiBookServer.textBytes(WifiBookServer.pageShell('喵阅 · 配对失败', inner));
    }
}