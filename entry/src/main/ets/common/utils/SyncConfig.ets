/**
 * 双端同步 v2 —— 配置 / 键名 / 槽读写的**唯一登记处**（2026-10-05）
 * ============================================================================
 * 设计依据：`docs/dual-end-sync-v2-design-2026-10-05.md`（用户已确认，含三步实施）。
 * 解决的问题：v1 把「手机读到哪 / 电脑读到哪 / 对方有没有新东西」塞进**同一个键**
 * `WebSync_<书名>` ⇒ 互相顶掉、分不清写者、同章内位移不联动、跳转靠 12~14 字模糊匹配。
 *
 * v2 结构：
 *   · `SyncPos_phone_<书名>` = SyncPos        只由**手机**写（各写各的 ⇒ 永不互顶）
 *   · `SyncPos_web_<书名>`   = { webId: SyncPos }  只由**服务端**代网页写（多台电脑各一槽）
 *   · `SyncSeen_web_<书名>`  = { webId: ts }  手机侧「已消费水位」（跳到/忽略后推进）
 *   · 浏览器侧水位在 localStorage（`mr_seenPhoneTs_<书id>`），与上面互不影响
 *   · v1 的 `WebSync_<书名>` **只读兼容**一期：读到就当作名叫 'v1' 的 web 槽，不再写
 *
 * 位置描述（两端同构）：章标题 + 本端章序/总章数（→ ratio）+ 章内位置比例（posRatio）
 * + 页首页末文本摘录（topEx/botEx，去空白口径两端一致）⇒
 * 跨端定位「文本优先、比例兜底」，本端索引**禁止跨端使用**。
 */
import { PreferencesUtil } from '@pura/harmony-utils'

/** 双端同步 v2 总开关（关掉即回 v1 行为：只读旧键、不写新键） */
export const SYNC_V2_ENABLED: boolean = true

/** 同章且章内位置差小于该值 ⇒ 视为"同一页附近"，不打扰（用户确认要"联动但不烦人"） */
export const SAME_CHAPTER_RATIO_EPS: number = 0.1

/** 一个 web 槽位置的新鲜度上限保护：ts 比手机时钟还超前 5 分钟视为坏数据，忽略 */
export const MAX_TS_SKEW_MS: number = 5 * 60 * 1000

/** 两端统一的「位置描述」 */
export interface SyncPos {
  /** 结构版本，便于将来再升级 */
  v: number
  /**
   * **全局单调序号**（2026-10-05 加，中继站的核心）。
   *
   * 由**手机进程**统一分配（它是唯一共享点：手机自己写槽、也代电脑写槽）
   * ⇒ 跨写者可比、**对两端时钟免疫**。
   * 为什么需要它：原先用 `ts` 判"谁更新"，而 ts 来自各设备 `Date.now()` ——
   * 手机时钟快 10 分钟就会把电脑的新位置判成"旧的"，提示被静默吞掉。
   */
  seq: number
  /** 章标题（两端都有；用于章节级匹配） */
  chTitle: string
  /** **本端**章序（禁止跨端使用 —— 两端切分口径不同） */
  chIndex: number
  /** **本端**总章数（与 chIndex 组成章进度） */
  chCount: number
  /** chIndex / chCount（跨端可换算的章级比例） */
  ratio: number
  /** 页首摘录（去空白，约 40 字） */
  topEx: string
  /** 页末摘录（去空白，约 40 字） */
  botEx: string
  /** 章内位置比例 0~1（手机=页首块节点号/本章节点数；网页=段号或页号比例） */
  posRatio: number
  /** 毫秒时间戳（写者本机时钟；仅用于显示与"未来时间"坏数据保护，**不用于排序**） */
  ts: number
  /** 'phone' | 'web:<webId>' */
  writer: string
}

/** v1 遗留键（只读；水位已改序号语义 ⇒ v1 的单一 ts 水位不再读，见 readWatermarks 注释） */
const V1_POS_PREFIX: string = 'WebSync_'
/** v2 键前缀 —— 新增按名存储时必须同时登记到 `BookRename` 清单（改名迁移 + 删书清理） */
export const PHONE_POS_PREFIX: string = 'SyncPos_phone_'
export const WEB_POS_PREFIX: string = 'SyncPos_web_'
export const WEB_SEEN_PREFIX: string = 'SyncSeen_web_'
/** 中继站：最新一次写入的位置（两端读写同一份 ⇒ "谁最新"只有一个答案） */
export const LATEST_PREFIX: string = 'SyncLatest_'
/** 全局序号计数器（每本书一个） */
export const SEQ_PREFIX: string = 'SyncSeq_'

/** 水位里大于这个值的数字一定是旧的"时间戳水位"（秒/毫秒级），不是序号 ⇒ 视为无水位 */
const TS_LIKE_THRESHOLD: number = 1e11

/** 空位置（解析失败/无数据时的返回值，绝不把半成品交给渲染） */
export function emptyPos(): SyncPos {
  return {
    v: 2, seq: 0, chTitle: '', chIndex: 0, chCount: 0, ratio: 0,
    topEx: '', botEx: '', posRatio: 0, ts: 0, writer: ''
  }
}

/** 比例 → 本端下标（clamp 到 [0, count-1]；count<=0 时返回 0） */
export function ratioToIndex(ratio: number, count: number): number {
  if (count <= 0) {
    return 0
  }
  const r: number = isFinite(ratio) ? Math.max(0, Math.min(1, ratio)) : 0
  return Math.max(0, Math.min(count - 1, Math.round(r * (count - 1))))
}

class SyncConfig {
  // ── 中继站（2026-10-05）：全局序号 + 最新位置 ────────────────────────────
  /**
   * 分配下一个全局序号（**手机进程内单调递增** ⇒ 跨写者可比、对时钟免疫）。
   * 读-改-写全在一次同步调用里完成（PreferencesUtil 是同步 API，无竞态）。
   */
  private nextSeq(bookName: string): number {
    let cur: number = 0
    try {
      cur = Number(PreferencesUtil.getSync(SEQ_PREFIX + bookName, 0) as number)
    } catch (err) {
      cur = 0
    }
    const next: number = (isFinite(cur) && cur > 0 ? cur : 0) + 1
    try {
      PreferencesUtil.putSync(SEQ_PREFIX + bookName, next)
    } catch (err) {
      console.error('SyncConfig.nextSeq failed: ' + JSON.stringify(err))
    }
    return next
  }

  /**
   * 盖章：给位置打上全局序号与写者名，并把它记为"最新位置"（中继站的唯一真相）。
   * 手机槽与网页槽都必须走这里 ⇒ `SyncLatest_<书名>` 永远等于"最后一次写入"。
   */
  private stamp(bookName: string, writer: string, pos: SyncPos): SyncPos {
    const now: number = Date.now()
    // ts 只作显示与"未来时间"坏数据保护（排序一律用 seq）。两个约束：
    //   ① 手机自己的写保持**单调**：`webSyncAnchors()` 是异步的，连续翻页时旧请求可能后返回
    //      （原实现注释 §ts 单调），故只接受"比现在更晚"的 ts；
    //   ② 绝不采用**电脑**的 ts —— 那是另一台设备的时钟，会把基准搞歪。
    const ts: number = writer === 'phone' && pos.ts > now ? pos.ts : now
    const out: SyncPos = {
      v: 2,
      seq: this.nextSeq(bookName),
      chTitle: pos.chTitle,
      chIndex: pos.chIndex,
      chCount: pos.chCount,
      ratio: pos.ratio,
      topEx: pos.topEx,
      botEx: pos.botEx,
      posRatio: pos.posRatio,
      ts: ts,
      writer: writer
    }
    try {
      PreferencesUtil.putSync(LATEST_PREFIX + bookName, JSON.stringify(out))
    } catch (err) {
      console.error('SyncConfig.stamp latest failed: ' + JSON.stringify(err))
    }
    return out
  }

  /** 读中继站：最新一次写入的位置（无数据返回 null） */
  readLatest(bookName: string): SyncPos | null {
    try {
      const raw: string = PreferencesUtil.getSync(LATEST_PREFIX + bookName, '') as string
      if (typeof raw !== 'string' || raw.length === 0) {
        return null
      }
      const p: SyncPos = SyncConfig.parsePosObject(JSON.parse(raw) as object)
      return p.seq > 0 ? p : null
    } catch (err) {
      return null
    }
  }

  // ── 手机槽 ────────────────────────────────────────────────────────────────
  readPhonePos(bookName: string): SyncPos {
    return SyncConfig.parsePos(PreferencesUtil.getSync(PHONE_POS_PREFIX + bookName, '') as string)
  }

  writePhonePos(bookName: string, pos: SyncPos): void {
    if ((bookName ?? '') === '') {
      return
    }
    try {
      const stamped: SyncPos = this.stamp(bookName, 'phone', pos)
      PreferencesUtil.putSync(PHONE_POS_PREFIX + bookName, JSON.stringify(stamped))
    } catch (err) {
      console.error('SyncConfig.writePhonePos failed: ' + JSON.stringify(err))
    }
  }

  // ── 网页槽（多台电脑各一条）──────────────────────────────────────────────
  readWebSlots(bookName: string): Record<string, SyncPos> {
    const out: Record<string, SyncPos> = {}
    const raw: string = PreferencesUtil.getSync(WEB_POS_PREFIX + bookName, '') as string
    if (typeof raw === 'string' && raw.length > 0) {
      try {
        const obj = JSON.parse(raw) as Record<string, object>
        for (const id of Object.keys(obj)) {
          const p: SyncPos = SyncConfig.parsePosObject(obj[id])
          if (p.ts > 0) {
            out[id] = p
          }
        }
      } catch (err) {
        console.error('SyncConfig.readWebSlots failed: ' + JSON.stringify(err))
      }
    }
    // v1 只读兼容：老键当作名叫 'v1' 的网页槽（`src==='web'` 才算网页写的）
    const legacy: SyncPos | null = this.readLegacyWebPos(bookName)
    if (legacy !== null && out['v1'] === undefined) {
      out['v1'] = legacy
    }
    return out
  }

  writeWebSlot(bookName: string, webId: string, pos: SyncPos): void {
    if ((bookName ?? '') === '') {
      return
    }
    const id: string = (webId ?? '') === '' ? 'v1' : webId
    try {
      // 读-改-写全在同一事件循环 tick 内（PreferencesUtil 是**同步** API）⇒ 多台电脑不会互相清掉
      const slots: Record<string, SyncPos> = this.readWebSlots(bookName)
      slots[id] = this.stamp(bookName, 'web:' + id, pos)
      PreferencesUtil.putSync(WEB_POS_PREFIX + bookName, JSON.stringify(slots))
    } catch (err) {
      console.error('SyncConfig.writeWebSlot failed: ' + JSON.stringify(err))
    }
  }

  /** v1 老键只读解析：只有 `src === 'web'` 才当网页槽（`src === 'phone'` 是手机自己写的，忽略） */
  private readLegacyWebPos(bookName: string): SyncPos | null {
    return this.parseLegacy(bookName, false)
  }

  /**
   * v1 老键只读解析（手机槽用）：v1 里手机写的是 `src:'phone'`（更早的版本没有 src 字段）。
   * 生产环境里 `GET /sync` 需要它在"手机还没升到 v2"时兜底，避免网页端看到空进度。
   */
  readLegacyPhonePos(bookName: string): SyncPos {
    const p: SyncPos | null = this.parseLegacy(bookName, true)
    return p === null ? emptyPos() : p
  }

  private parseLegacy(bookName: string, wantPhone: boolean): SyncPos | null {
    try {
      const raw: string = PreferencesUtil.getSync(V1_POS_PREFIX + bookName, '') as string
      if (typeof raw !== 'string' || raw.length === 0) {
        return null
      }
      const obj = JSON.parse(raw) as Record<string, number | string>
      const src: string = String(obj['src'] ?? '')
      // wantPhone=true ⇒ 要"手机写的"（src 为 phone 或旧数据缺省）；false ⇒ 要"网页写的"
      const isPhone: boolean = src === 'phone' || src === ''
      if (wantPhone !== isPhone) {
        return null
      }
      const ts: number = Number(obj['ts'] ?? 0)
      if (ts <= 0) {
        return null
      }
      return {
        seq: 0,
        v: 1,
        chTitle: String(obj['title'] ?? ''),
        // v1 的 chapterIndex 是**写者本端**口径 —— 跨端不可用，故记 -1
        chIndex: -1,
        chCount: 0,
        ratio: -1,
        topEx: normEx(String(obj['topEx'] ?? '')),
        botEx: normEx(String(obj['botEx'] ?? '')),
        posRatio: -1,
        ts: ts,
        writer: isPhone ? 'phone:v1' : 'web:v1'
      }
    } catch (err) {
      return null
    }
  }

  // ── 手机侧已消费水位（**按全局序号**，2026-10-05 从 ts 改为 seq）──────────
  /**
   * 读水位：`{ webId: seq }`。
   * 兼容：升级前存的是**时间戳**（> `TS_LIKE_THRESHOLD`）⇒ 视为"无水位"（最坏后果是升级后
   * 多弹一次提示，无害；这比把 ts 误当 seq 从而**永远不再提示**安全得多）。
   */
  readWatermarks(bookName: string): Record<string, number> {
    const out: Record<string, number> = {}
    try {
      const raw: string = PreferencesUtil.getSync(WEB_SEEN_PREFIX + bookName, '') as string
      if (typeof raw === 'string' && raw.length > 0) {
        const obj = JSON.parse(raw) as Record<string, number>
        for (const id of Object.keys(obj)) {
          const v: number = Number(obj[id] ?? 0)
          if (v > 0 && v < TS_LIKE_THRESHOLD) {
            out[id] = v
          }
        }
      }
    } catch (err) {
      console.error('SyncConfig.readWatermarks failed: ' + JSON.stringify(err))
    }
    return out
  }

  setWatermark(bookName: string, webId: string, seq: number): void {
    if ((bookName ?? '') === '' || !(seq > 0)) {
      return
    }
    try {
      const marks: Record<string, number> = this.readWatermarks(bookName)
      marks[(webId ?? '') === '' ? 'v1' : webId] = seq
      PreferencesUtil.putSync(WEB_SEEN_PREFIX + bookName, JSON.stringify(marks))
    } catch (err) {
      console.error('SyncConfig.setWatermark failed: ' + JSON.stringify(err))
    }
  }

  /**
   * 挑出**值得提示**的网页槽（规则 R1/R2/R3）。
   *
   * R1 **中继站规则（"谁最新谁不弹"，用户 2026-10-05 提的方案）**：
   *    `SyncLatest` 的写者是**手机自己** ⇒ 说明最近一次进度更新就发生在手机上
   *    （用户正在手机上看 / 刚看过）⇒ **不提示**。
   *    这正是用户要的生命周期：手机 58、电脑 60 → 手机开书时最新是电脑 ⇒ 弹（R1 不成立）；
   *    点「忽略」后继续在手机读到 59（手机会不断写槽 ⇒ 最新变成手机）⇒ 再进手机不弹 ✓。
   *
   *    反过来说：**只要另一端没写新的，本端就不打扰** —— "忽略"因此不需要单独的过期逻辑，
   *    它天然只在"对方再次推进"时失效。
   * R2 该槽的 `seq` 必须大于它的水位（这一版没消费过）；
   * R3 同章且章内位置差 < `SAME_CHAPTER_RATIO_EPS` ⇒ 同一页附近，只推进水位不打扰。
   *
   * @param ownChTitle 本端当前章标题（"同章"判断）
   * @param ownPosRatio 本端章内位置比例
   */
  pendingWebPos(bookName: string, ownChTitle: string, ownPosRatio: number): WebPending | null {
    const slots: Record<string, SyncPos> = this.readWebSlots(bookName)
    const marks: Record<string, number> = this.readWatermarks(bookName)
    // R1：中继站说"最新是手机自己" ⇒ 不提示
    const latest: SyncPos | null = this.readLatest(bookName)
    if (latest !== null && latest.writer === 'phone') {
      return null
    }
    let best: SyncPos | null = null
    let bestId: string = ''
    for (const id of Object.keys(slots)) {
      const p: SyncPos = slots[id]
      const seen: number = marks[id] ?? 0
      if (p.seq <= seen) {
        continue
      }
      // 时钟畸变保护（seq 排序不依赖时钟，这里只拦"未来时间"的坏数据，避免显示错乱）
      if (p.ts - Date.now() > MAX_TS_SKEW_MS) {
        continue
      }
      const emptyAnchor: boolean = p.topEx === '' && p.botEx === '' && p.chTitle === ''
      if (emptyAnchor) {
        continue
      }
      if (best === null || p.seq > best.seq) {
        best = p
        bestId = id
      }
    }
    if (best === null) {
      return null
    }
    // R3：同章且差得不多 ⇒ 视为同一处，只推进水位不打扰
    const sameChapter: boolean = best.chTitle !== '' && ownChTitle !== '' && best.chTitle === ownChTitle
    const near: boolean = sameChapter && best.posRatio >= 0
      && Math.abs(best.posRatio - ownPosRatio) < SAME_CHAPTER_RATIO_EPS
    if (near) {
      this.setWatermark(bookName, bestId, best.seq)
      return null
    }
    return { id: bestId, pos: best }
  }

  // 文本规整 / 摘录键：见文件末尾的模块级导出函数 `normEx` / `excerptKey`
  // （两端共用同一口径；放在模块级是为了让调用方直接 import，不必经由实例）

  private static parsePos(raw: string): SyncPos {
    if (typeof raw !== 'string' || raw.length === 0) {
      return emptyPos()
    }
    try {
      return SyncConfig.parsePosObject(JSON.parse(raw) as object)
    } catch (err) {
      return emptyPos()
    }
  }

  private static parsePosObject(o: object): SyncPos {
    const r = o as Record<string, number | string>
    const p: SyncPos = {
      v: Number(r['v'] ?? 2),
      seq: Number(r['seq'] ?? 0),
      chTitle: String(r['chTitle'] ?? r['title'] ?? ''),
      chIndex: Number(r['chIndex'] ?? -1),
      chCount: Number(r['chCount'] ?? 0),
      ratio: Number(r['ratio'] ?? -1),
      topEx: normEx(String(r['topEx'] ?? '')),
      botEx: normEx(String(r['botEx'] ?? '')),
      posRatio: Number(r['posRatio'] ?? -1),
      ts: Number(r['ts'] ?? 0),
      writer: String(r['writer'] ?? '')
    }
    return p
  }
}

/** `pendingWebPos` 的返回值 */
export interface WebPending {
  id: string
  pos: SyncPos
}

/** 文本规整：去**所有**空白（两端同口径，用于摘录匹配） */
export function normEx(s: string): string {
  return String(s ?? '').replace(/\s+/g, '')
}

/** 摘录匹配键：规整化后取前 N 字 */
export function excerptKey(s: string, len: number): string {
  return normEx(s).slice(0, len)
}

const syncConfig = new SyncConfig()
export default syncConfig as SyncConfig