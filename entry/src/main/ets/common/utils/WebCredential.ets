import { util } from '@kit.ArkTS'
import { PreferencesUtil } from '@pura/harmony-utils'

/**
 * Web 服务（WiFi 传书 / 电脑阅读）的**配对凭证**唯一登记处。
 *
 * ── 为什么需要它（2026-10-06 审计 P0-1）─────────────────────────────────────
 * 旧实现监听 `0.0.0.0:1122` 且**所有接口零校验**：同局域网任何人都能下载书架里
 * 全部本地书、按 time 删任意书签、往手机沙箱传任意文件并直接进书架。
 *
 * ── 配对模型（用户拍板 A2「像 TOTP 配对、要常态化、要能清历史设备」）─────────
 *   ① 手机端打开传书开关 ⇒ 生成**一次性配对码**（6 位数字，默认 10 分钟有效）
 *      显示在对话框里，同时给出带码的完整地址 `http://<ip>:1122/?k=123456`
 *   ② 电脑浏览器打开该地址 ⇒ 服务端核销配对码、下发**设备令牌**（HttpOnly Cookie）
 *      ⇒ 页面上不再需要任何输入，后续请求浏览器自动带 Cookie
 *   ③ 令牌永久保存在手机 Preferences（跨服务重启、跨电脑重启都有效）
 *      ⇒ 「一旦电脑端不再使用或更换设备」，在手机端**单个移除 / 全部清除 / 换口令**
 *
 * ── 安全口径 ────────────────────────────────────────────────────────────────
 *   · 配对码：6 位随机数字、**TTL 内可重复使用**（2026-10-06 复盘：一次性核销会在
 *     "响应丢失"时把用户锁死在门外，且对明文 HTTP 嗅探零防御收益，见 verifyPairCode 注释）、
 *     TTL 默认 10 分钟。
 *   · 防暴力枚举（2026-10-06 修正）：连接层拿不到对端 IP（`remoteInfo` 在 message 事件、
 *     `getRemoteAddress()` 是异步 ⇒ 配对校验发生在回调里等不到），按"来源 IP"限流不可实现；
 *     而浏览器每次 fetch 都是新连接（Connection: close），**按连接计数恒为 0 ⇒ 形同虚设**。
 *     ⇒ 改为**全局滑动窗口**：任意 10 分钟内全部来源累计最多 `GLOBAL_FAIL_MAX` 次失败，
 *     超出直接拒绝（不区分来源）。6 位码 100 万种 × 每窗口 10 次 ⇒ 穷举需数月，实际不可行。
 *     代价：有人恶意刷失败会短暂挡住正常配对 ⇒ 手机端"刷新配对码"立即重置（换码即清零）。
 *   · 设备令牌：`util.generateRandomUUID()`（SDK `@ohos.util.d.ts:154`，@since 9）取
 *     UUID 去掉连字符 = 128 bit 随机；比较用**定长顺序比较**（不做提前返回）
 *   · 口令轮换（`rotatePairing`）：同时作废配对码与**全部已配对设备** ⇒ 换口令即全下线
 *
 * 存储（按项目规范：所有新键都必须登记进 `BookRename` 的清理清单）
 *   `WebAuth_devices` = JSON 字符串 `DevToken[]`
 * 配对码**刻意不落盘**：它是内存态、随服务重启即失效（更安全，也不会留下陈旧密钥）。
 *
 * 回退方式：`WifiBookServer.WEB_AUTH_ENABLED = false` ⇒ 完全恢复旧行为（不校验）。
 */

/** 配对码位数 */
export const PAIR_CODE_LEN: number = 6
/** 配对码默认有效期（毫秒） */
export const PAIR_CODE_TTL_MS: number = 10 * 60 * 1000
/** 同一 IP 允许的配对尝试次数（超出即锁定到服务重启；仅用于提示文案，真正的闸门是全局窗口） */
export const PAIR_MAX_ATTEMPTS: number = 5
/** 全局失败滑动窗口宽度（毫秒） */
export const GLOBAL_FAIL_WINDOW_MS: number = 10 * 60 * 1000
/** 全局滑动窗口内允许的失败总次数（全部来源累计；防"换连接重置计数"的暴力枚举） */
export const GLOBAL_FAIL_MAX: number = 10
/** 最多保留的设备条目数（防偏好存储无限膨胀） */
export const MAX_DEVICES: number = 32
/** 设备令牌 Cookie 名 */
export const DEVICE_COOKIE: string = 'mr_dev'
/** 配对码在 URL 上的参数名 */
export const PAIR_QUERY_KEY: string = 'k'

/** 已配对设备（手机端"历史设备"列表的每一行） */
export interface DevToken {
    /** 128 bit 随机令牌（UUID 去连字符） */
    token: string
    /** 配对时刻（毫秒） */
    pairedAt: number
    /** 最近一次带该令牌的请求时刻（毫秒；0 = 尚未使用过） */
    lastSeen: number
    /** 首次配对时的来源 IP（仅用于让用户辨认设备） */
    ip: string
    /** 首次配对时的 User-Agent（截断，仅用于辨认） */
    ua: string
}

const DEVICES_KEY: string = 'WebAuth_devices'

function safeNow(): number {
    return new Date().getTime()
}

/**
 * 等长比较：**不做提前返回**，避免通过响应时间差猜令牌。
 * 长度不同直接 false（长度不是秘密）。
 */
export function constTimeEqual(a: string, b: string): boolean {
    if (a.length !== b.length) {
        return false
    }
    let diff: number = 0
    for (let i = 0; i < a.length; i++) {
        diff |= (a.charCodeAt(i) ^ b.charCodeAt(i))
    }
    return diff === 0
}

/** 校验 6 位数字配对码（严格：长度 + 全数字） */
export function isWellFormedPairCode(s: string): boolean {
    if (s.length !== PAIR_CODE_LEN) {
        return false
    }
    for (let i = 0; i < s.length; i++) {
        const c: number = s.charCodeAt(i)
        if (c < 0x30 || c > 0x39) {
            return false
        }
    }
    return true
}

class WebCredential {
    /** 当前配对码（内存态；'' = 尚未生成） */
    private code: string = ''
    /** 当前配对码过期时刻（毫秒） */
    private codeExpireAt: number = 0
    /** 每个来源 IP 已尝试次数（防爆破提示用；服务重启即清零） */
    private attempts: Map<string, number> = new Map<string, number>()
    /** 全局失败时间戳表（滑动窗口闸门；只在配对码有效时才记录，防恶意刷过期码灌满窗口） */
    private globalFails: number[] = []

    // ── 配对码 ─────────────────────────────────────────────────────────────
    /**
     * 生成新配对码（服务启动、或用户在对话框点"换口令"时调用）。
     * @param ttlMs 有效期，默认 `PAIR_CODE_TTL_MS`
     */
    newPairCode(ttlMs: number = PAIR_CODE_TTL_MS): string {
        let code: string = ''
        for (let i = 0; i < PAIR_CODE_LEN; i++) {
            code += String(Math.floor(Math.random() * 10))
        }
        this.code = code
        this.codeExpireAt = safeNow() + ttlMs
        this.attempts.clear()
        this.globalFails = []
        return code
    }

    /** 当前有效配对码（已过期 ⇒ 空串；调用方据此提示"请刷新配对码"） */
    currentPairCode(): string {
        if (this.code === '' || safeNow() > this.codeExpireAt) {
            return ''
        }
        return this.code
    }

    /** 配对码剩余有效秒数（手机端倒计时用；0 = 已失效） */
    pairCodeSecondsLeft(): number {
        if (this.code === '' || safeNow() > this.codeExpireAt) {
            return 0
        }
        return Math.ceil((this.codeExpireAt - safeNow()) / 1000)
    }

    /** 直接作废配对码（关闭服务时调用） */
    invalidatePairCode(): void {
        this.code = ''
        this.codeExpireAt = 0
        this.attempts.clear()
        this.globalFails = []
    }

    /**
     * 核对配对码（**含限流**）。
     *
     * ⚠️ 2026-10-06 真机复盘（用户实测"输对了码也配不上"）：原设计是**一次性核销**
     * （成功即作废），但配对恰发生在"手机可能锁屏冻结"的窗口——若服务端已核销+已配对、
     * 而响应在锁屏瞬间丢失（网页报"网络错误"），浏览器拿不到 Cookie ⇒ 码已死、用户被
     * 锁在门外 ⇒ 重输必失败，恶性循环（用户报告的完整复现路径）。
     * ⇒ 改为 **TTL 内可重复使用**：同一码在 10 分钟内可配多台设备、可抗响应丢失重试。
     * 安全账：传输是明文 HTTP，嗅探者本就能先于任何人用掉"一次性"码 ⇒ 一次性对嗅探
     * 零收益，却 100% 制造上述死锁；真正的闸门是 TTL + 全局限流 + 设备管理（可随时清除）。
     */
    verifyPairCode(input: string, ip: string): boolean {
        const cur: string = this.currentPairCode()
        if (cur === '') {
            return false
        }
        const now: number = safeNow()
        const recent: number[] = []
        for (let i = 0; i < this.globalFails.length; i++) {
            if (now - this.globalFails[i] < GLOBAL_FAIL_WINDOW_MS) {
                recent.push(this.globalFails[i])
            }
        }
        this.globalFails = recent
        if (this.globalFails.length >= GLOBAL_FAIL_MAX) {
            return false
        }
        const used: number = this.attempts.get(ip) ?? 0
        if (used >= PAIR_MAX_ATTEMPTS) {
            return false
        }
        if (!isWellFormedPairCode(input) || !constTimeEqual(input, cur)) {
            this.attempts.set(ip, used + 1)
            this.globalFails.push(now)
            return false
        }
        // 成功：不核销（TTL 内可重复配对，见方法注释）；只清失败计数
        this.attempts.clear()
        this.globalFails = []
        return true
    }

    /**
     * 该来源是否已达单来源尝试上限（配对页/服务端据此区分"码不对"与"尝试过多"文案）。
     * 真正的防爆破闸门是全局窗口（`verifyPairCode`），这里只影响提示文案。
     */
    isLocked(ip: string): boolean {
        if (this.currentPairCode() === '') {
            return false
        }
        return (this.attempts.get(ip) ?? 0) >= PAIR_MAX_ATTEMPTS
    }

    // ── 设备表 ─────────────────────────────────────────────────────────────
    /** 全部已配对设备（按配对时间倒序） */
    listDevices(): DevToken[] {
        const raw: string = PreferencesUtil.getSync(DEVICES_KEY, '') as string
        if (typeof raw !== 'string' || raw.length === 0) {
            return []
        }
        try {
            const parsed = JSON.parse(raw) as DevToken[]
            if (!Array.isArray(parsed)) {
                return []
            }
            const out: DevToken[] = []
            parsed.forEach((d: DevToken) => {
                if (d !== null && d !== undefined && typeof d.token === 'string' && d.token.length > 0) {
                    out.push({
                        token: d.token,
                        pairedAt: Number(d.pairedAt ?? 0),
                        lastSeen: Number(d.lastSeen ?? 0),
                        ip: String(d.ip ?? ''),
                        ua: String(d.ua ?? '')
                    })
                }
            })
            out.sort((a: DevToken, b: DevToken): number => b.pairedAt - a.pairedAt)
            return out
        }
        catch (err) {
            console.error('WebCredential.listDevices failed: ' + JSON.stringify(err))
            return []
        }
    }

    private saveDevices(list: DevToken[]): void {
        try {
            PreferencesUtil.putSync(DEVICES_KEY, JSON.stringify(list))
        }
        catch (err) {
            console.error('WebCredential.saveDevices failed: ' + JSON.stringify(err))
        }
    }

    /**
     * 新配对一台设备 ⇒ 返回其令牌（超出上限时淘汰最久未使用的）。
     *
     * **同设备去重（2026-10-06 用户实测修复）**：同一台电脑每次输码都新增一条 ⇒ 列表
     * 无限累计。现在按（真实 IP + User-Agent）识别同一设备：命中 ⇒ 复用原令牌直接返回
     * （重配对后 Set-Cookie 值也一致，旧 Cookie 依然有效）。对端 IP 由服务端从
     * `SocketMessageInfo.remoteInfo.address` 贯通而来（此前用 `c<连接id>` 顶着 ⇒ 每次都不同
     * ⇒ 去重从未生效，这正是列表膨胀的根因）。
     */
    pairDevice(ip: string, ua: string): string {
        const list: DevToken[] = this.listDevices()
        const normIp: string = ip === '' ? '未知' : ip
        const normUa: string = ua.length > 120 ? ua.substring(0, 120) : ua
        for (let i = 0; i < list.length; i++) {
            if (list[i].ip === normIp && list[i].ua === normUa) {
                return list[i].token
            }
        }
        const token: string = util.generateRandomUUID(false).replace(/-/g, '')
        list.push({
            token: token,
            pairedAt: safeNow(),
            lastSeen: 0,
            ip: normIp,
            ua: normUa
        })
        // 只保留最近 MAX_DEVICES 台
        while (list.length > MAX_DEVICES) {
            let oldest: number = 0
            for (let i = 1; i < list.length; i++) {
                if (list[i].pairedAt < list[oldest].pairedAt) {
                    oldest = i
                }
            }
            list.splice(oldest, 1)
        }
        this.saveDevices(list)
        return token
    }

    /**
     * 校验令牌是否有效（有效则顺手刷新 `lastSeen`，供"历史设备"显示最近活跃时间）。
     * @returns 命中的设备条目，未命中返回 null
     */
    verifyToken(token: string): DevToken | null {
        if (token === '') {
            return null
        }
        const list: DevToken[] = this.listDevices()
        for (let i = 0; i < list.length; i++) {
            if (constTimeEqual(list[i].token, token)) {
                const hit: DevToken = list[i]
                // 刷新最近活跃时间：每 60s 才落盘一次（避免每个请求都写偏好存储）
                const now: number = safeNow()
                if (now - hit.lastSeen > 60000) {
                    hit.lastSeen = now
                    list[i] = hit
                    this.saveDevices(list)
                }
                return hit
            }
        }
        return null
    }

    /** 移除一台设备（手机端"清除该设备"）；返回是否命中 */
    removeDevice(token: string): boolean {
        const list: DevToken[] = this.listDevices()
        const kept: DevToken[] = []
        let hit: boolean = false
        list.forEach((d: DevToken) => {
            if (constTimeEqual(d.token, token)) {
                hit = true
                return
            }
            kept.push(d)
        })
        if (hit) {
            this.saveDevices(kept)
        }
        return hit
    }

    /** 清除全部已配对设备（手机端"全部清除"）⇒ 所有电脑立刻失效，需重新配对 */
    clearDevices(): void {
        try {
            PreferencesUtil.deleteSync(DEVICES_KEY)
        }
        catch (err) {
            console.error('WebCredential.clearDevices failed: ' + JSON.stringify(err))
        }
    }

    deviceCount(): number {
        return this.listDevices().length
    }

    /**
     * 换口令（用户明确要求的能力）：作废旧配对码 + **全部已配对设备**，并立刻生成新码。
     * @returns 新配对码
     */
    rotatePairing(): string {
        this.clearDevices()
        return this.newPairCode()
    }
}

const webCredential = new WebCredential()
export default webCredential as WebCredential
