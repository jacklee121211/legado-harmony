import { fileIo as fs } from '@kit.CoreFileKit'

/**
 * 分块上传会话（断点续传的服务端一半）。
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 * 旧实现是"整文件一个 `POST /upload`（multipart）+ 一次性读进内存"：
 *  · 浏览器一旦断线/关页/刷新，**整本书都要重传**（用户明确要求"应具备断点续传能力"）；
 *  · 服务端把整个请求体攒在内存里，还要再复制一次写盘；
 *  · 没有大小上限（已由 `WifiBookServer.MAX_BODY_BYTES` = 100 MB 兜底）。
 *
 * ── 协议（与 `web/src/uploader.ts` 一一对应）────────────────────────────────
 *   POST /up/init    body(JSON) {name, size}      → {ok, sid, chunk, received}
 *        · name+size 即"文件指纹"：同一文件重新选择时返回**已完成块表** ⇒ 续传
 *   POST /up/chunk?sid=..&i=..  body=原始二进制块 → {ok, received}
 *   POST /up/done    body(JSON) {sid, name}       → 与 /upload 同样的导入结果
 *   POST /up/abort   body(JSON) {sid}             → {ok}
 *
 * ── 落盘策略（重要，性能与风险的取舍）──────────────────────────────────────
 * 块先**按序收在内存里**（单块 4 MB，总量 ≤ 100 MB），`done` 时**一次性**写盘并入库。
 * 这样：
 *  · 不会写坏文件（不需要依赖 `writeSync` 的随机写语义）；
 *  · 撞名时**根本不落盘**（旧实现是 TRUNC 覆盖已存在的书）；
 *  · 与"每次 append 小块"相比也没有 O(n²) 的复制（用数组存块，只在最后拼一次）。
 * 【待验证/后续优化】若真机上大文件内存吃紧，可改为 `openSync(APPEND)` 流式落盘 +
 * `fs.seek` 随机写；那需要先在本机验证 `fileIo` 的随机写语义再改。
 *
 * 会话是**内存态**：服务停止 / 进程回收即失效（客户端会重新从 0 开始，行为安全）。
 */

/** 单块大小（浏览器侧切片口径；服务端只校验上限，不强制等于它） */
export const CHUNK_SIZE: number = 4 * 1024 * 1024
/** 单文件上限（与 `WifiBookServer.MAX_BODY_BYTES` 同口径：100 MB） */
export const MAX_FILE_BYTES: number = 100 * 1024 * 1024
/** 会话空闲回收时间（毫秒）——浏览器关掉后 30 分钟清掉，避免占内存 */
const SESSION_IDLE_MS: number = 30 * 60 * 1000

interface UploadSession {
    sid: string
    name: string
    size: number
    /** 已收到的块（下标 = 块序号） */
    chunks: Array<Uint8Array | null>
    /** 已收到的字节总数 */
    received: number
    updatedAt: number
}

class UploadSessions {
    private map: Map<string, UploadSession> = new Map<string, UploadSession>()

    /** 清理空闲会话（每次新请求顺手做，不做定时器） */
    private sweep(): void {
        const now: number = new Date().getTime()
        const dead: string[] = []
        this.map.forEach((s: UploadSession, k: string) => {
            if (now - s.updatedAt > SESSION_IDLE_MS) {
                dead.push(k)
            }
        })
        dead.forEach((k: string) => this.map.delete(k))
    }

    /**
     * 开启（或复用）上传会话。
     * @param name 文件名（已净化）
     * @param size 文件总字节数（0 = 未知，此时每块必须带全量校验）
     * @returns 会话 id、块大小、已完成的块序号列表（用于断点续传）
     */
    init(name: string, size: number): UploadInitResult {
        this.sweep()
        if (size > MAX_FILE_BYTES) {
            return { ok: false, sid: '', chunk: CHUNK_SIZE, have: [], reason: 'oversize' }
        }
        // 复用同一指纹（name+size）的未完成会话 ⇒ 断点续传。
        // ⚠️ 不用 forEach 闭包累加（ArkTS 窄化分析看不到闭包内赋值，实测报 "type 'never'"），
        //    也不需要 Array.find（ArkTS 对 find 的谓词签名较严）⇒ 直接 for 同步查找。
        let found: UploadSession | null = null
        const keys: string[] = Array.from(this.map.keys())
        for (let i = 0; i < keys.length; i++) {
            const s: UploadSession | undefined = this.map.get(keys[i])
            if (s !== undefined && s.name === name && s.size === size) {
                found = s
                break
            }
        }
        if (found === null) {
            const sid: string = `u${new Date().getTime().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`
            const chunks: Array<Uint8Array | null> = []
            this.map.set(sid, {
                sid: sid, name: name, size: size, chunks: chunks, received: 0,
                updatedAt: new Date().getTime()
            })
            return { ok: true, sid: sid, chunk: CHUNK_SIZE, have: [], reason: '' }
        }
        found.updatedAt = new Date().getTime()
        const have: number[] = []
        for (let i = 0; i < found.chunks.length; i++) {
            if (found.chunks[i] !== null && found.chunks[i] !== undefined) {
                have.push(i)
            }
        }
        return { ok: true, sid: found.sid, chunk: CHUNK_SIZE, have: have, reason: '' }
    }

    /**
     * 落一块。
     * @returns 当前已收字节数；会话不存在返回 -1；总字节越界返回 -2
     */
    putChunk(sid: string, index: number, bytes: Uint8Array): number {
        const s: UploadSession | undefined = this.map.get(sid)
        if (s === undefined) {
            return -1
        }
        if (s.received + bytes.length > MAX_FILE_BYTES) {
            return -2
        }
        const old: Uint8Array | null | undefined = s.chunks[index]
        if (old !== null && old !== undefined) {
            // 重传同一块（例如客户端没收到响应就重试）：以最新一份为准，不重复计数
            s.received -= old.length
        }
        s.chunks[index] = bytes
        s.received += bytes.length
        s.updatedAt = new Date().getTime()
        return s.received
    }

    /** 会话是否存在 */
    has(sid: string): boolean {
        return this.map.get(sid) !== undefined
    }

    /** 会话元信息（`done` 时要用文件名与总大小） */
    meta(sid: string): UploadSessionMeta | null {
        const s: UploadSession | undefined = this.map.get(sid)
        if (s === undefined) {
            return null
        }
        s.updatedAt = new Date().getTime()
        return { name: s.name, size: s.size, received: s.received }
    }

    /** 取完整字节（按块序号从小到大拼接；缺块返回 null） */
    assemble(sid: string): Uint8Array | null {
        const s: UploadSession | undefined = this.map.get(sid)
        if (s === undefined) {
            return null
        }
        let total: number = 0
        for (let i = 0; i < s.chunks.length; i++) {
            const c: Uint8Array | null | undefined = s.chunks[i]
            if (c === null || c === undefined) {
                return null
            }
            total += c.length
        }
        const out: Uint8Array = new Uint8Array(total)
        let at: number = 0
        for (let i = 0; i < s.chunks.length; i++) {
            const c: Uint8Array = s.chunks[i] as Uint8Array
            out.set(c, at)
            at += c.length
        }
        return out
    }

    /**
     * 收尾：把临时文件写到沙箱最终路径（`ctx.filesDir/<name>`）。
     * @returns 最终路径；会话不存在返回 ''
     */
    flushToFile(sid: string, filesDir: string): string {
        const bytes: Uint8Array | null = this.assemble(sid)
        const s: UploadSession | undefined = this.map.get(sid)
        if (bytes === null || s === undefined) {
            return ''
        }
        const dst: string = `${filesDir}/${s.name}`
        const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
        try {
            fs.writeSync(file.fd, bytes.slice().buffer as ArrayBuffer)
        }
        finally {
            fs.closeSync(file)
        }
        return dst
    }

    /** 结束会话（成功后调用；失败/放弃也要调，避免内存滞留） */
    drop(sid: string): void {
        this.map.delete(sid)
    }

    /** 当前会话数（诊断用） */
    count(): number {
        return this.map.size
    }
}

export interface UploadInitResult {
    ok: boolean
    sid: string
    chunk: number
    /** 已收到的块序号（断点续传：客户端只补这些之外的块） */
    have: number[]
    reason: string
}

export interface UploadSessionMeta {
    name: string
    size: number
    received: number
}

const uploadSessions = new UploadSessions()
export default uploadSessions as UploadSessions
