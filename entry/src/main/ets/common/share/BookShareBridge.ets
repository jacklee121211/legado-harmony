/**
 * 碰一碰 / 隔空传送 统一桥（2026-10-25 新增）
 *
 * ── 为什么要有这个文件 ──────────────────────────────────────────────────────
 * 碰一碰与隔空传送**不是两套 API**，只是同一个 `harmonyShare` 的两个事件名，
 * 分享数据构造完全同一条链（`systemShare.SharedData`）。所以「选定内容」必须只有
 * 一个真源、只写一份，否则「长按单本」与「管理页批量」迟早出现两套行为。
 * 本文件同时承担：
 *   ① 设备/版本闸门（逐设备门槛，见 `shareCapability()`）
 *   ② 选定态快照（`ShareSelection`，由长按弹窗 / 管理页写入）
 *   ③ SharedData 构造（utd 按后缀解析 + fileUri，两处入口共用）
 *   ④ 监听注册/注销（windowId 窗口级，官方推荐重载）
 *
 * ── 官方证据（全部来自 devecocli docs / SDK 声明，非经验）───────────────────
 * 1. `harmonyShare.on('knockShare')` 起始 5.0.0(12)；带 `SendCapabilityRegistry`
 *    的重载起始 6.0.0(20)
 *    —— `sdk\default\hms\ets\api\@hms.collaboration.harmonyShare.d.ts:456 / :486`
 * 2. `harmonyShare.on('gesturesShare')` 起始 6.0.0(20)
 *    —— 同上 `:515 / :544`
 * 3. **逐设备门槛**（本文件 `shareCapability()` 的唯一依据）
 *    —— `sdk\default\hms\ets\api\device-define\api-version\ShareKit.json`
 *      · knockShare：phone@5.0.0(12) / **tablet@6.1.0(23)** / 2in1@6.0.0(20)
 *      · gesturesShare：phone@6.0.0(20) / tablet@6.0.0(20) / 2in1@6.0.0(20)
 * 4. ⚠️ `canIUse('SystemCapability.Collaboration.HarmonyShare')` **不足以**做闸门：
 *    该 syscap 在 `syscap-version.json` 里是 phone@12 / tablet@12 / 2in1@13 ——
 *    **平板 API20 上返回 true，但 knockShare 要 API23 才可用**。
 * 5. ⚠️ `deviceInfo.apiAvailable()` 是 **@since 26.0.0**（`@ohos.deviceInfo.d.ts:643`），
 *    API20~25 上不存在。本工程 compatibleSdkVersion=6.0.0(20) ⇒ **禁止使用**，
 *    只能用 `deviceInfo.sdkApiVersion: number`（@since 6，`d.ts:369`）。
 * 6. 硬上限：`share-system-share` 原文「数据记录当前最大可支持500条，且需同时满足
 *    数据总大小不超过IPC传输上限200KB」。
 * 7. 「当前界面无可分享内容」的官方终止方式：`clarifyNonShare({message})`
 *    （6.0.2(22)）—— `knock-share-between-phones-content`「异常场景需终止分享」；
 *    更早版本退回 `reject(SharableErrorCode.NO_CONTENT_ERROR)`（5.0.3(15)）。
 * 8. `thumbnailUri` 只接受**应用文件 URI / 用户文件 URI**，不接受 http/rawfile；
 *    而 `thumbnail`（Uint8Array）有 32KB 限制 ⇒ 一律走 `thumbnailUri`
 *    —— `share-system-share` SharedRecord 字段说明。
 *
 * ── 闸门策略（2026-10-25 与用户敲定）────────────────────────────────────────
 * 不支持的设备**静默降级**：不注册、不提示、不显示引导。
 * 系统分享面板（`systemShare`，4.1.0(11) 起全支持）永远可用，与本文件完全隔离。
 */

import { harmonyShare, systemShare } from '@kit.ShareKit'
import { uniformTypeDescriptor } from '@kit.ArkData'
import { fileUri } from '@kit.CoreFileKit'
import { window } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { Books } from '../../database/entities/Books'
import { coverPathToUri } from '../utils/CoverSource'

const DOMAIN: number = 0x0000
const TAG: string = 'ShareBridge'

// ═══════════════════════════════════════════════════════════════════════════
// 一键回退开关（AGENTS.md §3「不可本地验证的改动必须可一键回退」）
// 把任意一个改成 false，该通道立刻退回"未接入"状态，其余通道不受影响。
// ═══════════════════════════════════════════════════════════════════════════
export const SHARE_KNOCK_ENABLED: boolean = true
export const SHARE_GESTURE_ENABLED: boolean = true
export const SHARE_GUIDE_ANIM_ENABLED: boolean = true

/** 官方硬上限：单次分享最多 500 条记录（超了直接拒绝，不截断） */
export const MAX_SHARE_RECORDS: number = 500

/** AppStorage 键：当前是否存在可分享的选定内容（引导动画/UI 用它做反应式判断） */
export const SHARE_HAS_CONTENT_KEY: string = 'shareHasContent'

/**
 * 设备 + 版本能力。
 *
 * 逐设备门槛是本文件的**唯一真相**，不要再用 canIUse 当闸门（见文件头证据 4）。
 */
export class ShareCapability {
  /** 碰一碰可用 */
  knock: boolean = false
  /** 隔空传送可用 */
  gesture: boolean = false
  /** clarifyNonShare 可用（6.0.2(22)+；不可用时退回 reject） */
  clarify: boolean = false

  constructor(knock: boolean, gesture: boolean, clarify: boolean) {
    this.knock = knock
    this.gesture = gesture
    this.clarify = clarify
  }

  /** 两条通道都不可用 ⇒ 上层无需注册、无需引导 */
  any(): boolean {
    return this.knock || this.gesture
  }
}

/**
 * 计算当前设备的能力。
 *
 * ⚠️ 只用 `deviceInfo.sdkApiVersion`（API 等级整数，@since 6），
 * 因为 `deviceInfo.apiAvailable()` 要 26.0.0 才有（文件头证据 5）。
 */
export function shareCapability(): ShareCapability {
  let type: string = ''
  let api: number = 0
  try {
    type = deviceInfo.deviceType
    api = deviceInfo.sdkApiVersion
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'read deviceInfo failed')
  }
  // 碰一碰：phone>=12 / tablet>=23 / 2in1>=20（证据 3）
  // 隔空传送：phone/tablet/2in1 全部 >=20（证据 3）
  let knock: boolean = false
  let gesture: boolean = false
  if (type === 'phone') {
    knock = api >= 12
    gesture = api >= 20
  } else if (type === 'tablet') {
    knock = api >= 23
    gesture = api >= 20
  } else if (type === '2in1') {
    knock = api >= 20
    gesture = api >= 20
  }
  // clarifyNonShare @since 6.0.2(22)
  const clarify: boolean = api >= 22
  return new ShareCapability(knock && SHARE_KNOCK_ENABLED, gesture && SHARE_GESTURE_ENABLED, clarify)
}

/**
 * 选定快照（「长按单本」与「批量管理」写进同一份结构）。
 *
 * 只有两个写入点：
 *   · `BookInfoDialogs`（长按单本）打开时 set / 关闭时 clear
 *   · `BookManagePage`（批量管理）勾选变化时 set / 离开页面时 clear
 */
export class ShareSelection {
  books: Books[] = []
  /** 碰一碰卡片标题（官方：>1:1 白卡 / <1:1 沉浸式大卡，都吃 title） */
  title: string = ''
  /** 碰一碰卡片描述（仅 1 行） */
  description: string = ''
  /** 预览图 URI（只接受应用文件 URI / 用户文件 URI） */
  thumbUri: string = ''

  constructor(books: Books[], title: string, description: string, thumbUri: string) {
    this.books = books
    this.title = title
    this.description = description
    this.thumbUri = thumbUri
  }
}

/** 后缀 → utd（官方推荐 `getUniformDataTypeByFilenameExtension`，解析失败退回 general.text） */
function utdOf(path: string): string {
  const dot: number = path.lastIndexOf('.')
  if (dot < 0) {
    return 'general.text'
  }
  const suffix: string = path.substring(dot)
  try {
    const id: string = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(suffix) ?? ''
    return id !== '' ? id : 'general.text'
  } catch (e) {
    return 'general.text'
  }
}

/**
 * 书籍封面 → 可直接给 `thumbnailUri` 的 URI。
 *
 * 只接受**本地**封面（沙箱路径 / file / datashare）：官方字段说明里
 * `thumbnailUri` 只支持应用文件 URI 与用户文件 URI，http 与 rawfile 都不行（证据 8）。
 * 无本地封面 ⇒ 返回 ''（卡片退回系统默认图标，不阻塞分享）。
 */
export function thumbUriOf(book: Books): string {
  const builtin: string = coverPathToUri(book.builtinCoverUrl ?? '')
  if (builtin !== '') {
    return builtin
  }
  const custom: string = book.customCoverUrl ?? ''
  if (custom.startsWith('file://') || custom.startsWith('datashare://')) {
    return custom
  }
  // default:// 是 rawfile 内置封面、http(s):// 是网络图 —— 都不满足 thumbnailUri 的 URI 要求
  if (custom !== '' && !custom.startsWith('default://')
    && !custom.startsWith('http://') && !custom.startsWith('https://')) {
    return coverPathToUri(custom)
  }
  return ''
}

/** 取第一本有本地封面的书作为预览图（多本拼图见文件末尾 TODO） */
function firstThumb(books: Books[]): string {
  for (const b of books) {
    const u: string = thumbUriOf(b)
    if (u !== '') {
      return u
    }
  }
  return ''
}

/**
 * 由书籍列表构造选定快照（两个入口共用，保证「选定内容一致」）。
 *
 * 卡片文案规则（2026-10-25 默认值，用户已确认）：
 *   单本 → title=书名，description=作者（空则用书名）
 *   多本 → title=`已选 N 本书`，description=前 3 个书名以「、」连接
 */
export function buildSelection(books: Books[]): ShareSelection {
  if (books.length === 1) {
    const b: Books = books[0]
    const name: string = (b.bookName ?? '') !== '' ? b.bookName : '书籍'
    const author: string = b.author ?? ''
    return new ShareSelection(books, name, author !== '' ? author : name, thumbUriOf(b))
  }
  const names: string[] = []
  for (let i = 0; i < books.length && i < 3; i++) {
    names.push((books[i].bookName ?? '') !== '' ? books[i].bookName : '书籍')
  }
  const desc: string = names.join('、')
  return new ShareSelection(books, `已选 ${books.length} 本书`, desc, firstThumb(books))
}

/**
 * 碰一碰 / 隔空传送 桥（进程内单例）。
 *
 * 宿主（owner）模型：**同一时刻只允许一个界面持有监听**。
 * 官方要求「进入可分享页面注册、离开（含退后台）注销」，单点持有天然满足，
 * 也避免两个界面抢注造成"在 A 页碰一碰发出 B 页内容"。
 */
export class BookShareBridge {
  private static instance: BookShareBridge | null = null

  static get(): BookShareBridge {
    if (BookShareBridge.instance === null) {
      BookShareBridge.instance = new BookShareBridge()
    }
    return BookShareBridge.instance
  }

  private selection: ShareSelection | null = null
  private owner: string = ''
  private windowId: number = -1
  private knockOn: boolean = false
  private gestureOn: boolean = false

  // 官方 off 需要同一个 callback 引用 ⇒ 必须存成稳定的箭头字段
  private readonly knockCb = (target: harmonyShare.SharableTarget): void => {
    this.handleTarget(target, 'knock')
  }
  private readonly gestureCb = (target: harmonyShare.SharableTarget): void => {
    this.handleTarget(target, 'gesture')
  }

  /** 当前选定快照（无内容返回 null） */
  currentSelection(): ShareSelection | null {
    return this.selection
  }

  /**
   * 写入/清空选定快照。
   *
   * 预览图在**写入选定时**就已算好（`buildSelection` 里同步取本地封面 URI），
   * 回调里不再做任何重活 —— 官方要求 3 秒内调 `share()`。
   */
  setSelection(sel: ShareSelection | null): void {
    this.selection = sel
    const has: boolean = sel !== null && sel.books.length > 0
    AppStorage.setOrCreate(SHARE_HAS_CONTENT_KEY, has)
  }

  /** 清空选定（等价 setSelection(null)，语义化别名） */
  clearSelection(): void {
    this.setSelection(null)
  }

  /**
   * 取得监听（宿主进入可分享界面时调用）。
   *
   * 幂等：同一宿主重复调用不会重复注册；不同宿主接手时只迁移持有权，
   * 不重复注册（避免同窗口双注册行为未定义，见收尾说明）。
   */
  async acquire(owner: string, ctx: common.UIAbilityContext): Promise<void> {
    const cap: ShareCapability = shareCapability()
    if (!cap.any()) {
      // 静默降级：不支持的设备/版本一律不注册（用户已确认不要任何提示）
      hilog.info(DOMAIN, TAG, 'share unsupported, skip register')
      return
    }
    if (this.owner !== '' && this.owner !== owner) {
      // 已有其它宿主持有：只迁移持有权，注册状态不变
      this.owner = owner
      return
    }
    this.owner = owner
    if (this.windowId < 0) {
      await this.resolveWindowId(ctx)
    }
    if (this.windowId < 0) {
      hilog.warn(DOMAIN, TAG, 'no windowId, skip register')
      return
    }
    const registry: harmonyShare.SendCapabilityRegistry = { windowId: this.windowId }
    if (cap.knock && !this.knockOn) {
      try {
        harmonyShare.on('knockShare', registry, this.knockCb)
        this.knockOn = true
        hilog.info(DOMAIN, TAG, 'knockShare registered, winId=%{public}d', this.windowId)
      } catch (e) {
        const err = e as BusinessError
        hilog.error(DOMAIN, TAG, 'knockShare register failed: %{public}s', err.message ?? '')
      }
    }
    if (cap.gesture && !this.gestureOn) {
      try {
        harmonyShare.on('gesturesShare', registry, this.gestureCb)
        this.gestureOn = true
        hilog.info(DOMAIN, TAG, 'gesturesShare registered, winId=%{public}d', this.windowId)
      } catch (e) {
        const err = e as BusinessError
        hilog.error(DOMAIN, TAG, 'gesturesShare register failed: %{public}s', err.message ?? '')
      }
    }
  }

  /**
   * 释放监听（宿主离开可分享界面 / 应用退后台时调用）。
   *
   * 只有当前宿主能释放，避免"旧页面 onPageHide 把新页面刚注册的监听拆掉"。
   */
  release(owner: string): void {
    if (this.owner !== owner) {
      return
    }
    this.owner = ''
    this.clearSelection()
    const registry: harmonyShare.SendCapabilityRegistry = { windowId: this.windowId }
    if (this.knockOn) {
      try {
        harmonyShare.off('knockShare', registry, this.knockCb)
        hilog.info(DOMAIN, TAG, 'knockShare unregistered')
      } catch (e) {
        const err = e as BusinessError
        hilog.error(DOMAIN, TAG, 'knockShare off failed: %{public}s', err.message ?? '')
      }
      this.knockOn = false
    }
    if (this.gestureOn) {
      try {
        harmonyShare.off('gesturesShare', registry, this.gestureCb)
        hilog.info(DOMAIN, TAG, 'gesturesShare unregistered')
      } catch (e) {
        const err = e as BusinessError
        hilog.error(DOMAIN, TAG, 'gesturesShare off failed: %{public}s', err.message ?? '')
      }
      this.gestureOn = false
    }
  }

  /** 应用退后台的兜底释放（无论宿主是谁都拆干净） */
  releaseAll(): void {
    const owner: string = this.owner
    this.owner = owner !== '' ? owner : '__bg__'
    this.release(this.owner)
    this.owner = ''
  }

  /** 官方推荐用 windowId 绑定触发窗口；拿不到就放弃注册（宁可不注册也不误触发） */
  private async resolveWindowId(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(ctx)
      this.windowId = win.getWindowProperties().id
    } catch (e) {
      const err = e as BusinessError
      hilog.error(DOMAIN, TAG, 'getLastWindow failed: %{public}s', err.message ?? '')
      this.windowId = -1
    }
  }

  /** 构造 SharedData（首条进构造器，其余 addRecord —— 官方范式） */
  static buildSharedData(sel: ShareSelection): systemShare.SharedData | null {
    let data: systemShare.SharedData | null = null
    for (const b of sel.books) {
      const path: string = b.bookUrl ?? ''
      if (path === '') {
        continue
      }
      let uri: string = ''
      try {
        uri = fileUri.getUriFromPath(path)
      } catch (e) {
        continue
      }
      const record: systemShare.SharedRecord = {
        utd: utdOf(path),
        uri: uri,
        title: (b.bookName ?? '') !== '' ? b.bookName : '书籍'
      }
      if (data === null) {
        data = new systemShare.SharedData(record)
      } else {
        // `addRecord` 官方声明会抛（类型不支持 / 超出 500 条 / IPC 超限）
        // ⇒ 单条失败只跳过这一条，绝不整包失败（编译器也会对此报
        //   "Function may throw exceptions" 告警）。
        try {
          data.addRecord(record)
        } catch (e) {
          const err = e as BusinessError
          hilog.warn(DOMAIN, TAG, 'addRecord skipped: %{public}s', err.message ?? '')
        }
      }
    }
    return data
  }

  /**
   * 事件回调（碰一碰 / 隔空传送共用）。
   *
   * 注意：这里**只做取快照 + 发数据**，任何重活（渲染缩略图、下载封面）都会
   * 撞上官方「3 秒内必须调 share()」的硬限制。
   */
  private handleTarget(target: harmonyShare.SharableTarget, channel: string): void {
    const sel: ShareSelection | null = this.selection
    if (sel === null || sel.books.length === 0) {
      hilog.info(DOMAIN, TAG, '%{public}s fired but nothing selected', channel)
      this.endShare(target, '请先在书架或管理页选中要分享的书')
      return
    }
    if (sel.books.length > MAX_SHARE_RECORDS) {
      hilog.warn(DOMAIN, TAG, 'too many records: %{public}d', sel.books.length)
      this.endShare(target, `单次最多分享 ${MAX_SHARE_RECORDS} 本`)
      return
    }
    const data: systemShare.SharedData | null = BookShareBridge.buildSharedData(sel)
    if (data === null) {
      this.endShare(target, '选中的书籍没有可分享的文件')
      return
    }
    target.share(data).then((): void => {
      hilog.info(DOMAIN, TAG, '%{public}s share ok, books=%{public}d', channel, sel.books.length)
    }).catch((e: BusinessError): void => {
      hilog.error(DOMAIN, TAG, '%{public}s share failed: %{public}s', channel, e.message ?? '')
    })
  }

  /**
   * 终止本次分享并给用户一句话。
   *
   * 官方口径（`knock-share-between-phones-content`「异常场景需终止分享」）：
   *   6.0.2(22)+ ⇒ `clarifyNonShare({message})`
   *   更早版本   ⇒ `reject(SharableErrorCode.NO_CONTENT_ERROR)`
   * 两者都失败就静默 —— 绝不让异常冒到 UI 线程。
   */
  private endShare(target: harmonyShare.SharableTarget, msg: string): void {
    const cap: ShareCapability = shareCapability()
    if (cap.clarify) {
      try {
        target.clarifyNonShare({ message: msg }).catch((e: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'clarifyNonShare failed: %{public}s', e.message ?? '')
        })
        return
      } catch (e) {
        // 落到 reject
      }
    }
    try {
      target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR).catch((e: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'reject failed: %{public}s', e.message ?? '')
      })
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'endShare fallback failed')
    }
  }
}

// ── TODO（下一步，需真机验证后再上）────────────────────────────────────────
// 多本「封面宫格拼图」预览图：目前 `firstThumb()` 退化为「首本封面」。
// 升级方案（已调研，未落地）：用 `UIContext.getComponentSnapshot().createFromBuilder()`
// （SDK `@ohos.arkui.componentSnapshot.d.ts:581` 全局版 @since 10，UIContext 版推荐）
// 把 2×2 / 3×3 宫格 builder 截成 PixelMap → ImagePacker 落 cache → thumbnailUri。
// 之所以先不做：它依赖离屏渲染时序，必须在真机上验证 3 秒预算，不能凭经验设默认值。
