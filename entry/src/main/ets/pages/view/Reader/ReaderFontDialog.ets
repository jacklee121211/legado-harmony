/**
 * 「字体管理」弹窗（2026-09-26 新增，用户设计）。
 *
 * ── 需求原文（要点）─────────────────────────────────────────────────────────
 * 「直接把字体甚至原有的字号、间距都提取到一个新的弹窗中」「必须要有恢复默认的快捷项」
 * 「必须支持自定义改名」「做好下载：点击后弹窗输入**直链字体下载地址**，下载要有
 *   进度动画和取消按钮，下载后直接入库」「字体列表做好删除按钮以及确认弹窗」
 * 「查询加粗/下划线/斜体/中划线是否支持」。
 *
 * ── 能力边界（取证）─────────────────────────────────────────────────────────
 * · **加粗**：官方支持 —— `ReaderSetting.fontWeight: number`（SDK
 *   `@hms.core.readerservice.readerComponent.d.ets:93-99`），常规 400 / 加粗 700；
 * · **下划线 / 斜体 / 中划线**：官方**不支持** —— `ReaderSetting` 全部 13 个字段里没有
 *   对应属性（同文件 :69-200），引擎内部不可达，不做（UI 上不出现，避免无效开关）。
 *
 * ── 结构与风格 ──────────────────────────────────────────────────────────────
 * 弹窗配方与「更多材质」同款（@CustomDialog + 页面每次新建 controller + 沉浸光感材质 +
 * 弹簧出入场）；列表橙圈沿用背景方案的选中语言；正文字色随 colorMode 日/夜切换。
 * 字体文件登记/导入/下载/删除全部委托 `ReaderFontLib`（本弹窗只管 UI）。
 *
 * ── 2026-10-24 新增（用户需求）──────────────────────────────────────────────
 * ① **内置字体库**（`ReaderFontCatalog`）：字体文件**不打进安装包**（上游 5 支约 69MB，
 *    OPPO Sans 单支 21.7MB）。库里未下载的字体以「灰色 + 下载图标」出现在列表末尾，
 *    点一下才下载落库 —— 落库后与导入/直链下载走完全同一条持久化链路
 *    （沙箱 `filesDir/fonts/` + Preferences 登记表），重启不丢。
 *    ⚠️ 清单**完全来自远端同步拉取，代码里不硬编码任何字体**：上游往仓库加字体，
 *    用户下次打开本弹窗就能看到，不用发版。
 * ② **智能合并**：内置库有 A、用户又用直链下了一遍 A 时，**不会出现两个 A**。
 *    判据是文件名归一化（`ReaderFontLib.normKey()`）而不是可被用户改名的显示名。
 * ③ **上游更新**：目录里的 blob `sha` 就是版本指纹。本地装的是旧 sha ⇒ 该行变成
 *    「有新版本 · 点击更新」，点一下**原地覆盖**（保住显示名、正在使用状态、列表位置）。
 *    改过名的字体（`renamed`）**不跟随上游改名**，没改过的跟随 —— 规则见
 *    `ReaderFontLib.syncCatalog()`。
 *
 * ── 下载链路的健壮性（2026-10-24 修「贴直链下载失败」+「OPPO 下载失败」）──────
 * 真机日志（`docs/日志.md`）两次取证：
 * · 10:53:25 —— `response_code:200` 但 `content_type:text/html`、55KB：用户贴的是
 *   gitcode 的**文件浏览页**（HTML），不是真直链；旧代码静默拒收、只报「失败 1 个」。
 * · 11:13:32 —— 内置库 `OPPO Sans 4.0.ttf` 失败：netstack `not a normalized URL` /
 *   `CURLcode result 3`（CURLE_URL_MALFORMAT）/ `errCode:2300003`。
 *   根因是**文件名带空格**，原串直接交给 `http.request()` 被本地拒收，请求根本没发出。
 *   ⇒ 现在所有请求 URL 都过 `ReaderFontLib.encodeUrl()`。
 * 现在：
 *   · 前置：明显不是字体的地址（.html/.zip/…）当场提示；
 *   · 请求：带 `User-Agent`（部分 CDN 无 UA 直接 403/返回网页）；URL 统一编码；
 *   · 响应：`responseCode` 非 2xx ⇒ 报 HTTP 码；内容是 HTML ⇒ 明确提示「这是网页」；
 *     魔数不对 ⇒ 提示「不是字体文件」；
 *   · 文件名：`ReaderFontLib.baseName()` 统一解析（旧代码 `lastIndexOf('/')` 用错串，
 *     query 里带 `/` 会算出空文件名 ⇒ 直接判失败）；
 *   · 错误文案：`BusinessError` 的 `code`/`message` 要读出来（旧代码只得到 `[object Object]`）；
 *   · 全链路 hilog（URL 去 query、状态码、字节数、魔数结论）。
 */
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ReaderFontLib, FontLibItem, CatalogMeta, FontRename
} from '../../../common/utils/ReaderFontLib';
import { ReaderFontCatalog, CatalogFont } from '../../../common/utils/ReaderFontCatalog';
import { Haptics } from '../../../common/utils/Haptics';
// ── 会员化（2026-09-28）：导入/下载字体为 VIP 特权 ──────────────────────────
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil';
import UiMotion from '../../../common/utils/UiMotion';
import { VipDialog } from '../../../componets/myCenter/VipDialog';
import { VipManager } from '../../../common/utils/VipManager';
import { STORAGE_KEY_OFFLINE_MODE } from '../../../common/utils/OfflineMode';

/** 与原面板一致的快捷档位（字号） */
const FONT_PRESETS: number[] = [12, 18, 24, 32, 40, 48];
/** 与原面板一致的快捷档位（行距） */
const LINE_HEIGHT_PRESETS: number[] = [1.2, 1.6, 1.9, 2.4, 3.0];
/** 列表预览样张（用户定名「喵阅阅读」）：中文字形差异一眼可辨 */
const SAMPLE_TEXT: string = '喵阅阅读';
/** 日志域 */
const LOG_TAG: string = 'ReaderFontDialog';
/** 直链下载的 UA（部分 CDN/网盘无 UA 会回 403 或 HTML 防盗链页） */
const DL_UA: string =
  'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36';
/** 明显不是字体的地址后缀（前置拦截，避免白跑一趟网络） */
const NON_FONT_EXT: string[] = ['.html', '.htm', '.zip', '.rar', '.7z', '.txt', '.json', '.png', '.jpg'];

/** 一条下载任务（直链队列 / 内置库点击 / 内置库更新 共用同一条队列） */
interface DlTask {
  url: string;
  /** 入库显示名；空串 = 用 URL 里的文件名（直链场景） */
  name: string;
  /** 内置库条目 key（行内进度定位用）；直链为空串 */
  key: string;
  /** 内置库版本指纹（直链为空串） */
  sha: string;
  /** 非空 = 这是「更新已安装字体」，值为已安装条目的显示名（空串 = 全新下载） */
  updateOf: string;
}

/** 「有新版本」行：目录项 + 它在本地登记表里的显示名（两者可能不同：用户改过名） */
interface UpdateRow {
  font: CatalogFont;
  entryName: string;
}

@CustomDialog
export struct ReaderFontDialog {
  controller?: CustomDialogController

  // ── 页面注入：当前值快照（controller 每次新建 ⇒ 打开时即最新）────────────
  @Prop initFontSize: number = 18
  @Prop initLineHeight: number = 1.9
  /** 当前正在用的字体名（橙圈 + 删除保护） */
  @Prop curFontName: string = ReaderFontLib.DEFAULT_NAME

  /** 应用回调：页面侧改 readerSetting + setPageConfig + updateHighlight */
  onFontSize: (v: number) => void = (): void => {}
  onLineHeight: (v: number) => void = (): void => {}
  onFont: (name: string, path: string) => void = (): void => {}

  /**
   * 关闭回调（2026-09-26 弹窗协调）：「完成」由**页面**关本弹窗并恢复父弹窗（设置面板）
   * —— 关闭权在页面（弹窗内 controller?.close() 曾失灵，见页面侧注释）。
   */
  onClose: () => void = (): void => {}

  @StorageLink('readerColorMode') colorMode: number = 1

  /**
   * 精简模式（2026-10-13 方案 A）：只用于隐藏**真联网**的「下载字体」区。
   *
   * ── 为什么只有下载要藏 ────────────────────────────────────────────────
   * 本弹窗里两件事网络属性完全不同：
   *   · 「导入字体文件」= 本地文件选择器（`picker`）+ `ReaderFontLib` 登记，
   *     `ReaderFontLib.ets:23-26` 只依赖 ArkUI / AbilityKit / CoreFileKit / Preferences ⇒ **离线可用**；
   *   · 「下载字体」= `http.createHttp()` 拉直链（本文件 `:22` import `@kit.NetworkKit`）
   *     ⇒ **必须联网**，精简模式（「断网能用」）下留着就是"功能存在但不可用"。
   * ⇒ 导入留、下载藏。两者都是 VIP 权益，所以精简模式仍能正常转化。
   *
   * 回退：把 `if (!this.offlineOn)` 处的条件直接删掉即可恢复常显。
   */
  @StorageLink(STORAGE_KEY_OFFLINE_MODE) offlineOn: boolean = false

  // ── 本地编辑态（页面是真源，这里只镜像当前会话的编辑）────────────────────
  @State fontSize: number = 18
  @State lineHeight: number = 1.9
  /** 列表（aboutToAppear 一次性读库；导入/下载/删除后手动刷新） */
  @State fonts: FontLibItem[] = []
  /** 内置库里**还没下载**的字体（灰色 + 下载图标；下载完自动从这里消失） */
  @State pending: CatalogFont[] = []
  /** 内置库里**已装但是旧版本**的字体（有新版本 · 点击更新） */
  @State updatable: UpdateRow[] = []
  /** 目录是否正在联网拉取（列表里那个刷新图标转圈） */
  @State catalogRefreshing: boolean = false
  /** 正在改名的字体名（'' = 无）；改名输入框内容 */
  @State renamingName: string = ''
  @State renameText: string = ''
  /** 0 = 空闲；2 = 有下载在进行（含排队等待） */
  @State dlState: number = 0
  @State dlUrl: string = ''
  /** 当前这一支的真实进度（0-100）。`totalSize` 未知时恒为 0，UI 改显已下载字节 */
  @State dlPercent: number = 0
  /** 当前这一支已收到的字节 / 总字节（-1 = 服务端没给 Content-Length） */
  @State dlReceived: number = 0
  @State dlTotalBytes: number = -1
  /** 正在下载的任务 key（行内转圈用；'' = 直链任务或无 key） */
  @State dlRunningKey: string = ''
  /** 排队中的任务 key 列表（行内显示「排队中」） */
  @State dlQueuedKeys: string[] = []
  /** 本轮队列规模（正在下载 + 排队），仅用于底部文案 */
  @State dlQueueTotal: number = 0
  /** 本轮已处理数（成功 + 失败），仅用于底部文案 */
  @State dlDoneCount: number = 0
  @State dlFail: number = 0
  /** 等待队列（**不含**正在下载那一支） */
  private queue: DlTask[] = []
  /** 正在下载的那一支（null = 空闲） */
  private running: DlTask | null = null
  /** 首个失败原因（结束时一并提示，别再只说"失败 N 个"） */
  private dlLastErr: string = ''
  private dlReq: http.HttpRequest | null = null
  /** 内置库清单（缓存 / 远端拉取结果，见 ReaderFontCatalog） */
  private catalog: CatalogFont[] = []

  aboutToAppear(): void {
    this.fontSize = this.initFontSize
    this.lineHeight = this.initLineHeight
    // ① 先用缓存渲染（有缓存就是上次拉到的清单；首次为空，等下面的拉取结果）
    this.catalog = ReaderFontCatalog.load()
    this.refreshList()
    // ② 再按需联网同步（>5 分钟才真联网；失败静默降级）
    this.refreshCatalog(false)
  }

  /** 「VIP 购买」弹窗控制器（嵌套打开：字体管理保持打开，VIP 弹窗盖上） */
  private vipDialog: CustomDialogController | null = null

  private openVip(): void {
    this.vipDialog = new CustomDialogController({
      builder: VipDialog({
        dark: this.colorMode == 0,
        vipOwned: VipManager.isVip(),
        onClose: (): void => {
          this.vipDialog?.close()
          this.vipDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.vipDialog = null
      }
    })
    this.vipDialog.open()
  }

  /** 读库 + 预注册（导入/下载字体的预览与测量通道都要注册，串行幂等） */
  private refreshList(): void {
    const items: FontLibItem[] = ReaderFontLib.list()
    for (const f of items) {
      if (f.src !== 'system') {
        ReaderFontLib.ensureRegistered(this.getUIContext(), f.name, f.path)
      }
    }
    this.fonts = items
    this.rebuildPending()
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 内置字体库（2026-10-24）：远端同步拉取 + 智能合并 + 可更新检测
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 同步目录。
   * @param force true = 手动刷新图标点的（无视 5 分钟 TTL，并给 toast 反馈）
   */
  private refreshCatalog(force: boolean): void {
    if (this.catalogRefreshing) {
      return
    }
    this.catalogRefreshing = true
    const task: Promise<CatalogFont[]> = force
      ? ReaderFontCatalog.refreshNow()
      : ReaderFontCatalog.refreshIfStale()
    task.then((list: CatalogFont[]) => {
      this.catalogRefreshing = false
      this.catalog = list
      this.applyCatalogSync()
      if (force) {
        if (ReaderFontCatalog.didLastRefreshFail()) {
          this.toast('字体库同步失败，请检查网络')
        } else {
          this.toast(`字体库已同步（${list.length} 支）`)
        }
      }
    }).catch((): void => {
      // refreshNow/refreshIfStale 本身不 reject，这里只是兜底
      this.catalogRefreshing = false
      if (force) {
        this.toast('字体库同步失败，请检查网络')
      }
    })
  }

  /**
   * 把本地登记表和上游目录对齐，然后重刷列表。
   *
   * 上游改名 ⇒ `syncCatalog()` 返回改名清单；若改的正是**当前正在用**的字体，
   * 必须把 `curFontName` 与页面的 `readerSetting.fontName` 一起改掉，
   * 否则这本书会按旧族名渲染 ⇒ 回落系统字形（看起来像"字体丢了"）。
   */
  private applyCatalogSync(): void {
    if (this.catalog.length > 0) {
      const metas: CatalogMeta[] = []
      for (const c of this.catalog) {
        metas.push({ key: c.key, name: c.name, sha: c.sha })
      }
      const renames: FontRename[] = ReaderFontLib.syncCatalog(metas)
      for (const r of renames) {
        hilog.info(0x0000, LOG_TAG, 'catalog rename %{public}s -> %{public}s', r.oldName, r.newName)
        if (this.curFontName === r.oldName) {
          this.curFontName = r.newName
          this.onFont(r.newName, r.path)
        }
      }
    }
    this.refreshList()
  }

  /**
   * 重算「可下载 / 可更新」两个列表。
   *
   * ★ 智能合并的实现点 ★
   * 已安装判定用 **归一化文件名**（`normKey`）+ `catalogKey` + 内容 sha 三级匹配，
   * 而不是显示名（显示名用户可以随便改）。于是「内置库有 MiSans-Regular.ttf」+
   * 「用户直链下了 MiSans-Regular.ttf」⇒ 同一个键 ⇒ 只显示一条。
   */
  private rebuildPending(): void {
    const installed: FontLibItem[] = this.fonts.filter((f: FontLibItem) => f.src !== 'system')
    const taken: string[] = []
    const pending: CatalogFont[] = []
    const updatable: UpdateRow[] = []
    for (const c of this.catalog) {
      const hit: FontLibItem | undefined = this.matchInstalled(c, installed, taken)
      if (hit === undefined) {
        pending.push(c)
        continue
      }
      taken.push(hit.name)
      const localSha: string = (hit.catalogSha !== undefined) ? hit.catalogSha : ''
      // 本地版本指纹 ≠ 上游当前指纹 ⇒ 上游换过字体文件 ⇒ 提示可更新
      if (localSha.length > 0 && c.sha.length > 0 && localSha !== c.sha) {
        updatable.push({ font: c, entryName: hit.name })
      }
    }
    this.pending = pending
    this.updatable = updatable
  }

  /** 找某条目录项对应的已安装条目（三级匹配，顺序即优先级） */
  private matchInstalled(c: CatalogFont, installed: FontLibItem[],
    taken: string[]): FontLibItem | undefined {
    // ① 内置库来源键（下载/更新时写入的强键）
    for (const f of installed) {
      if (taken.indexOf(f.name) >= 0) {
        continue
      }
      if (f.catalogKey !== undefined && f.catalogKey.length > 0 && f.catalogKey === c.key) {
        return f
      }
    }
    // ② 文件名归一化（直链下的同款字体）
    const want: string = ReaderFontLib.normKey(c.key)
    for (const f of installed) {
      if (taken.indexOf(f.name) >= 0) {
        continue
      }
      const file: string = (f.file !== undefined && f.file.length > 0) ? f.file : f.path
      if (ReaderFontLib.normKey(file) === want) {
        return f
      }
    }
    // ③ 内容指纹相同（上游只改了文件名、内容没变 ⇒ 仍是同一支）
    if (c.sha.length > 0) {
      for (const f of installed) {
        if (taken.indexOf(f.name) >= 0) {
          continue
        }
        if (f.catalogSha !== undefined && f.catalogSha === c.sha) {
          return f
        }
      }
    }
    return undefined
  }

  /**
   * 点击内置库条目 ⇒ **入队**（不再"请稍候"）。
   * 正在下载时点别的，就排到后面，队首完成自动接上。
   * @param updateOf 非空 = 更新这支已安装字体（传它的显示名）
   */
  private downloadCatalog(item: CatalogFont, updateOf: string): void {
    Haptics.tap()
    if (!VipManager.isVip()) {
      this.openVip()
      return
    }
    const task: DlTask = {
      url: item.url,
      name: item.name,
      key: item.key,
      sha: item.sha,
      updateOf: updateOf
    }
    this.enqueue([task])
  }

  private toast(m: string): void {
    this.getUIContext().getPromptAction().showToast({ message: m, duration: 1500 })
  }

  private pick(item: FontLibItem): void {
    Haptics.tap();
    ReaderFontLib.ensureRegistered(this.getUIContext(), item.name, item.path)
    this.curFontName = item.name
    this.onFont(item.name, item.path)
  }

  // ── 导入（文件选择器 → 拷沙箱 → 登记；支持一次多选，逐个入库）──────────────
  private importFont(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    const docPicker = new picker.DocumentViewPicker()
    const opts = new picker.DocumentSelectOptions()
    // 不限一个：用户要求"爱多少就多少个"（上限给 100 防失控，字库另有总量保险丝）
    opts.maxSelectNumber = 100
    docPicker.select(opts).then((uris: string[]) => {
      if (uris.length === 0) {
        return
      }
      let ok: number = 0
      let fail: number = 0
      const next = (i: number): void => {
        if (i >= uris.length) {
          this.refreshList()
          if (fail === 0) {
            this.toast(`已导入 ${ok} 个字体`)
          } else {
            this.toast(`导入 ${ok} 个，失败 ${fail} 个（仅支持 .ttf/.otf/.woff2）`)
          }
          return
        }
        ReaderFontLib.importFromUri(ctx, uris[i]).then((item: FontLibItem | null) => {
          if (item === null) {
            fail++
          } else {
            ok++
          }
          next(i + 1)
        })
      }
      next(0)
    }).catch((): void => {
      // 用户取消选择，不提示
    })
  }

  // ── 下载（直链 → 进度 + 取消 → 入库；支持一次粘贴多条串行下载）──────────────
  private startDownload(): void {
    // 分隔符全覆盖：空白 / 半角; / 全角； / 半角, / 全角， / 顿号、（3.4 用户要求）
    const parts: string[] = this.dlUrl.split(new RegExp('[\\s;,，、；]+'))
    const tasks: DlTask[] = []
    for (const p of parts) {
      const u: string = p.trim()
      if (u.length === 0) {
        continue
      }
      if (!ReaderFontDialog.isHttpUrl(u)) {
        this.toast('不是有效链接：' + u)
        return
      }
      // 2026-10-24：只在「后缀一眼就不是字体」时拦截（.html/.zip…）；
      // 无扩展名的直链（.../download?id=1）**放行**，交给响应端按魔数判定 ——
      // 旧实现用 indexOf('.ttf') 判定，既拦不住网页（页面 URL 里带 .ttf 也能过），
      // 又会把合法的无扩展名直链直接拒掉。
      if (ReaderFontDialog.looksNonFont(u)) {
        this.toast('这不是字体直链（.html/.zip 等）：' + u)
        return
      }
      tasks.push({ url: u, name: '', key: '', sha: '', updateOf: '' })
    }
    if (tasks.length === 0) {
      this.toast('请先粘贴字体直链')
      return
    }
    this.enqueue(tasks)
  }

  private static isHttpUrl(u: string): boolean {
    const s: string = u.toLowerCase()
    return s.startsWith('http://') || s.startsWith('https://')
  }

  /** 地址后缀一眼就不是字体（去 query 后判定） */
  private static looksNonFont(u: string): boolean {
    let s: string = u.toLowerCase()
    const q: number = s.indexOf('?')
    if (q >= 0) {
      s = s.substring(0, q)
    }
    for (const ext of NON_FONT_EXT) {
      if (s.endsWith(ext)) {
        return true
      }
    }
    return false
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 下载队列（2026-10-24 重做：连点即排队，最多 1 个并发，随时可取消）
  //
  // ── 旧实现的两个体验问题（用户实测反馈）─────────────────────────────────
  // ① 「下载一个，点第二个提示请等候」—— 想批量下载的人被迫一支一支点、一支一支等；
  // ② 进度条"是假的"—— 只在 `dataReceiveProgress` 给了 `totalSize` 时才更新百分比，
  //    服务端不给 Content-Length（chunked）时永远停在 0%，看着像假的。
  // ⇒ 现在：点多少进队列多少，队首自动跑；进度同时显示百分比（已知总长）或
  //    已下载字节（总长未知）；底部常驻「取消」，一次清空整个队列。
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 入队（直链批量 / 内置库单条 / 内置库更新 都走这里）。
   * 已有同名任务在跑或在排队 ⇒ 直接跳过，避免重复点出多条。
   */
  private enqueue(tasks: DlTask[]): void {
    let added: number = 0
    for (const t of tasks) {
      if (this.isBusy(t)) {
        continue
      }
      this.queue.push(t)
      added++
    }
    if (added === 0) {
      this.toast('这些字体已在下载队列中')
      return
    }
    // 队列规模 = 正在跑的 + 排队的
    this.dlQueueTotal = this.queue.length + (this.running !== null ? 1 : 0)
    this.syncQueueView()
    if (this.running === null) {
      this.startNext()
    } else {
      this.toast(`已加入队列（前面还有 ${this.queue.length - 1} 个）`)
    }
  }

  /** 是否已在队列里（同 URL，或同 key） */
  private isBusy(t: DlTask): boolean {
    if (this.running !== null && ReaderFontDialog.sameTask(this.running, t)) {
      return true
    }
    for (const q of this.queue) {
      if (ReaderFontDialog.sameTask(q, t)) {
        return true
      }
    }
    return false
  }

  private static sameTask(a: DlTask, b: DlTask): boolean {
    if (a.url === b.url) {
      return true
    }
    if (a.key.length > 0 && b.key.length > 0 && a.key === b.key) {
      return true
    }
    return false
  }

  /** 把"排队中"的 key 列表同步给 UI（@State 必须整体赋值才会触发重渲染） */
  private syncQueueView(): void {
    const keys: string[] = []
    for (const q of this.queue) {
      if (q.key.length > 0) {
        keys.push(q.key)
      }
    }
    this.dlQueuedKeys = keys
    this.dlState = (this.running !== null || this.queue.length > 0) ? 2 : 0
  }

  /** 取队首开跑；队列空 ⇒ 收尾 */
  private startNext(): void {
    if (this.queue.length === 0) {
      this.finishQueue()
      return
    }
    const task: DlTask = this.queue.shift() as DlTask
    this.running = task
    this.dlState = 2
    this.dlRunningKey = task.key
    this.dlPercent = 0
    this.dlReceived = 0
    this.dlTotalBytes = -1
    this.syncQueueView()
    this.doRequest(task)
  }

  /** 整个队列跑完：复位 + 汇总提示 */
  private finishQueue(): void {
    const total: number = this.dlQueueTotal
    const fail: number = this.dlFail
    this.running = null
    this.queue = []
    this.dlState = 0
    this.dlRunningKey = ''
    this.dlQueuedKeys = []
    this.dlPercent = 0
    this.dlReceived = 0
    this.dlTotalBytes = -1
    this.dlReq = null
    this.refreshList()
    if (total === 0) {
      return
    }
    if (fail === 0) {
      this.toast(total > 1 ? `全部下载完成（${total} 个）` : '已下载并入库')
    } else if (fail >= total) {
      this.toast('下载失败：' + this.dlLastErr)
    } else {
      this.toast(`完成 ${total - fail} 个，失败 ${fail} 个（${this.dlLastErr}）`)
    }
    this.dlQueueTotal = 0
    this.dlDoneCount = 0
    this.dlFail = 0
    this.dlLastErr = ''
  }

  /** 真正发一次请求（当前 running 那一支） */
  private doRequest(task: DlTask): void {
    // ★ 2026-10-24 修「OPPO Sans 下载失败」★
    // 仓库里 `OPPO Sans 4.0.ttf` 文件名带空格，原串交给 http 会被 netstack 直接拒收
    // （`not a normalized URL` / `CURLcode 3` / errCode 2300003），请求根本没发出去。
    // ⇒ 统一百分号编码（`%20`），已编码的 `%XX` 原样保留。
    const url: string = ReaderFontLib.encodeUrl(task.url)
    const req = http.createHttp()
    this.dlReq = req
    req.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
      // 真实进度：`totalSize > 0` 才算百分比；否则只累计字节（服务端 chunked 时就是这样）
      this.dlReceived = data.receiveSize
      if (data.totalSize > 0) {
        this.dlTotalBytes = data.totalSize
        this.dlPercent = Math.min(100, Math.round(data.receiveSize * 100 / data.totalSize))
      } else {
        this.dlTotalBytes = -1
        this.dlPercent = 0
      }
    })
    hilog.info(0x0000, LOG_TAG, 'download start %{public}s', ReaderFontDialog.safeUrl(url))
    req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 60000,
      // 2026-10-24：部分 CDN / 网盘无 UA 直接 403 或回防盗链 HTML
      header: { 'User-Agent': DL_UA, 'Accept': '*/*' }
    }).then((resp: http.HttpResponse) => {
      req.destroy()
      this.dlReq = null
      if (this.running !== task) {
        return // 已被取消 / 已被换下
      }
      const code: number = resp.responseCode
      const buf: ArrayBuffer = resp.result as ArrayBuffer
      const size: number = (buf !== undefined && buf !== null) ? buf.byteLength : 0
      hilog.info(0x0000, LOG_TAG,
        'download resp code=%{public}d bytes=%{public}d type=%{public}s url=%{public}s',
        code, size, ReaderFontDialog.headerOf(resp, 'content-type'), ReaderFontDialog.safeUrl(url))
      // ① HTTP 状态码（旧实现完全不看 ⇒ 404/403 页面只能靠魔数兜底，且不告诉用户原因）
      if (code < 200 || code >= 300) {
        this.failCurrent(`服务器返回 HTTP ${code}`)
        return
      }
      // ② 内容不是字体（最常见的失败：贴成了网页/仓库页/防盗链页）
      if (size === 0) {
        this.failCurrent('返回内容为空')
        return
      }
      if (ReaderFontLib.sniffFontExt(buf).length === 0) {
        this.failCurrent(ReaderFontLib.looksLikeHtml(buf)
          ? '该链接返回的是网页（HTML），不是字体文件，请用 raw/直链地址'
          : '返回内容不是字体文件（仅支持 .ttf/.otf/.woff2）')
        return
      }
      // ③ 落库（扩展名由魔数决定；文件名解析统一走 ReaderFontLib.baseName）
      this.dlPercent = 100
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      if (task.updateOf.length > 0) {
        // ── 更新已安装字体（原地覆盖，保住显示名/正在使用状态/列表位置）────────
        const entry: FontLibItem | undefined =
          this.fonts.find((f: FontLibItem) => f.name === task.updateOf)
        if (entry === undefined) {
          this.failCurrent('本地条目已不存在，请刷新列表')
          return
        }
        const updated = ReaderFontLib.updateFromCatalog(ctx, entry, buf, task.name, task.sha)
        if (updated === null) {
          this.failCurrent('更新失败（写入沙箱或登记失败）')
          return
        }
        if (this.curFontName === task.updateOf) {
          this.curFontName = updated.name
          this.onFont(updated.name, updated.path)
        }
        this.succeedCurrent('已更新：' + updated.name)
      } else {
        // ── 全新下载 ────────────────────────────────────────────────────────
        const fileName: string = ReaderFontLib.baseName(task.url)
        const item = ReaderFontLib.saveDownloaded(ctx, fileName, buf, task.name, task.key, task.sha)
        if (item === null) {
          this.failCurrent('写入沙箱或登记失败（文件可能过大或沙箱无空间）')
          return
        }
        this.succeedCurrent('已入库：' + item.name)
      }
    }).catch((e: Object) => {
      this.dlReq = null
      if (this.running !== task) {
        return // 已取消
      }
      this.failCurrent('网络请求失败（' + ReaderFontDialog.errText(e) + '）')
    })
  }

  /** 当前这支成功 ⇒ 计数 + 立刻开下一支（队列不因单支失败而中断） */
  private succeedCurrent(msg: string): void {
    this.dlDoneCount++
    this.running = null
    this.dlRunningKey = ''
    // 单支就提示"已入库"，批量只在最后汇总（避免 toast 刷屏）
    if (this.dlQueueTotal <= 1) {
      this.toast(msg)
    }
    this.startNext()
  }

  /** 当前这支失败 ⇒ 记原因 + 继续下一支 */
  private failCurrent(reason: string): void {
    this.dlLastErr = reason
    this.dlFail++
    this.dlDoneCount++
    this.running = null
    this.dlRunningKey = ''
    hilog.warn(0x0000, LOG_TAG, 'download fail: %{public}s', reason)
    this.startNext()
  }

  /**
   * 取消（底部按钮）：**中止当前下载 + 清空整个等待队列**。
   * 用户连点好几支后想收手，一次点干净，不用逐个去删。
   */
  private cancelDownload(): void {
    Haptics.tap()
    const left: number = this.queue.length
    this.queue = []
    this.running = null
    this.dlState = 0
    this.dlRunningKey = ''
    this.dlQueuedKeys = []
    this.dlPercent = 0
    this.dlReceived = 0
    this.dlTotalBytes = -1
    this.dlReq?.destroy()
    this.dlReq = null
    this.dlQueueTotal = 0
    this.dlDoneCount = 0
    this.dlFail = 0
    this.dlLastErr = ''
    this.refreshList()
    this.toast(left > 0 ? `已取消（同时清掉 ${left} 个排队任务）` : '已取消')
  }

  /** 点某一支「排队中」的行 ⇒ 只把它从队列里撤掉 */
  private removeQueued(key: string): void {
    if (key.length === 0) {
      return
    }
    const next: DlTask[] = []
    for (const q of this.queue) {
      if (q.key !== key) {
        next.push(q)
      }
    }
    if (next.length === this.queue.length) {
      return
    }
    this.queue = next
    this.dlQueueTotal = this.queue.length + (this.running !== null ? 1 : 0)
    this.syncQueueView()
    Haptics.tap()
    this.toast('已移出队列')
  }

  /** 日志用：去掉 query 的短 URL（避免把 token 打出去） */
  private static safeUrl(u: string): string {
    const q: number = u.indexOf('?')
    const s: string = q >= 0 ? u.substring(0, q) : u
    return s.length > 120 ? s.substring(0, 120) + '…' : s
  }

  /**
   * 把 `catch` 里的错误对象变成**人能看懂**的文案。
   *
   * ⚠️ 2026-10-24 修：`http` 抛的是 `BusinessError`（不是 `Error` 实例），
   * 旧代码 `String(e)` 只能得到 `[object Object]` —— 真机上 OPPO 那次失败的
   * `errCode 2300003` 就这样被吞掉了，日志里全是「网络请求失败（[object Object]）」。
   */
  private static errText(e: Object): string {
    if (e instanceof Error) {
      return e.message
    }
    const be = e as BusinessError
    if (be !== undefined && be !== null && be.code !== undefined && be.code !== null) {
      const code: number = be.code
      const msg: string = (be.message !== undefined && be.message !== null) ? be.message : ''
      // 2300003 = 参数/URL 非法（真机上"文件名带空格"就落在这里）
      if (code === 2300003) {
        return 'code=2300003 URL 非法（链接里可能有空格或未编码的中文）'
      }
      return 'code=' + code + (msg.length > 0 ? ' ' + msg : '')
    }
    return String(e)
  }

  /**
   * 读响应头（ArkTS 里 `HttpResponse.header` 的静态类型是 `Object`，
   * 直接下标访问会被严格模式拦下 ⇒ 统一走 Record + try/catch，取不到就回空串）。
   * 仅用于日志与 HTML 提示，**判定字形真伪一律看魔数**（content-type 会撒谎）。
   */
  private static headerOf(resp: http.HttpResponse, key: string): string {
    try {
      const h = resp.header as Record<string, Object>
      if (h === null || h === undefined) {
        return ''
      }
      const v: Object = h[key]
      return typeof v === 'string' ? v as string : ''
    } catch (e) {
      return ''
    }
  }

  private askDelete(item: FontLibItem): void {
    this.getUIContext().showAlertDialog({
      message: '删除字体「' + item.name + '」？文件与登记将一并移除。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E5310A',
        action: (): void => {
          Haptics.tap();
          const inUse: boolean = item.name === this.curFontName
          if (ReaderFontLib.remove(item.name, inUse)) {
            this.refreshList()
            this.toast('已删除')
          } else {
            this.toast(inUse ? '正在使用中，请先换成其他字体' : '删除失败')
          }
        }
      }
    })
  }

  private confirmRename(): void {
    const item: FontLibItem | undefined = this.fonts.find((f: FontLibItem) => f.name === this.renamingName)
    this.renamingName = ''
    if (item === undefined) {
      return
    }
    const renamed = ReaderFontLib.rename(item.name, this.renameText)
    if (renamed === null) {
      this.toast('改名失败：名字为空或已被占用')
      return
    }
    // 正在用的字体改了名 ⇒ readerSetting.fontName 同步走一遍（测量通道按名注册）
    if (this.curFontName === item.name) {
      this.curFontName = renamed.name
      this.onFont(renamed.name, renamed.path)
    }
    this.refreshList()
    this.toast('已改名：' + renamed.name)
  }

  // ── 配色小工具（日/夜双档）──────────────────────────────────────────────
  private textColor(): string {
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'
  }

  private subColor(): string {
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)'
  }

  /** 内置库未下载条目：灰色（"还没拥有"的视觉语言） */
  private dimColor(): string {
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 0.35)' : 'rgba(19, 19, 19, 0.35)'
  }

  private rowBg(): string {
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 0.06)' : 'rgba(19, 19, 19, 0.03)'
  }

  /** 内置库待下载条目的副标题：体积（API 不返回 ⇒ 通常没有）+ "点击下载" */
  private catalogSub(c: CatalogFont): string {
    const size: string = ReaderFontCatalog.sizeText(c.size)
    return size.length > 0 ? size + ' · 点击下载' : '点击下载'
  }

  // ── 下载进度文案（2026-10-24：真实进度，不再"假"）──────────────────────────

  /** 该 key 是否在等待队列里 */
  private isQueued(key: string): boolean {
    return key.length > 0 && this.dlQueuedKeys.indexOf(key) >= 0
  }

  /**
   * 当前这一支的进度文案。
   * · 服务端给了 `Content-Length` ⇒ 百分比（真实）；
   * · 没给（chunked）⇒ 已下载字节数，**绝不编造百分比**。
   */
  private progressText(): string {
    if (this.dlTotalBytes > 0) {
      return `${this.dlPercent}%`
    }
    const s: string = ReaderFontCatalog.sizeText(this.dlReceived)
    return s.length > 0 ? s : '下载中'
  }

  /** 底部队列文案：`2/5 43% · 排队3` */
  private queueLabel(): string {
    let out: string = ''
    if (this.dlQueueTotal > 1) {
      const n: number = Math.min(this.dlDoneCount + 1, this.dlQueueTotal)
      out = `${n}/${this.dlQueueTotal} `
    }
    out += this.progressText()
    if (this.queue.length > 0) {
      out += ` · 排队${this.queue.length}`
    }
    return out
  }

  /**
   * 行内状态：下载中（转圈 + 真实进度）/ 排队中（可点掉）/ 可下载图标。
   * @param isUpdate true = 可更新行（刷新图标），false = 未下载行（下载图标）
   */
  @Builder
  rowStatus(key: string, isUpdate: boolean) {
    if (key.length > 0 && this.dlRunningKey === key) {
      Row({ space: 4 }) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color('#007DFF')
        Text(this.progressText())
          .fontSize(11)
          .fontColor('#007DFF')
      }
    } else if (this.isQueued(key)) {
      Text('排队中')
        .fontSize(11)
        .fontColor('#007DFF')
        .padding(4)
    } else if (isUpdate) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(20)
        .fontColor(['#007DFF'])
    } else {
      SymbolGlyph($r('sys.symbol.arrow_down_circle'))
        .fontSize(22)
        .fontColor([this.dimColor()])
    }
  }

  build() {
    Column({ space: 12 }) {
      // 顶栏：标题 + 完成（与「更多材质」同款）
      Row() {
        Text('字体管理')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.textColor())
        Blank()
        Text('完成')
          .fontSize(15)
          .fontColor('#007DFF')
          .onClick(() => {
            Haptics.tap();
            this.onClose()
          })
      }
      .width('100%')

      // ── 字号 / 行距（从阅读器-设置迁入，含快捷档位）────────────────────────
      Row({ space: 12 }) {
        Text('字号')
          .fontColor(this.textColor())
        Slider({ value: this.fontSize, max: 48, min: 12, step: 1, style: SliderStyle.InSet })
          .selectedColor('#007DFF')
          .blockSize({ width: 30, height: 30 })
          .borderRadius(20)
          .padding({ left: 8, right: 8 })
          .layoutWeight(1)
          .onChange((value: number) => {
            Haptics.tick();
            this.fontSize = Math.round(value)
            this.onFontSize(this.fontSize)
          })
        Text(`${this.fontSize}`)
          .fontSize(13).fontColor('#007DFF').width(34).textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('档位')
          .fontSize(12)
          .fontColor(this.subColor())
          .width(28)
        ForEach(FONT_PRESETS, (v: number) => {
          Text(`${v}`)
            .fontSize(13)
            .fontColor(this.fontSize === v ? '#007DFF' : this.textColor())
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(this.fontSize === v ? 'rgba(0,125,255,0.15)' : Color.Transparent)
            .onClick(() => {
              Haptics.tap();
              this.fontSize = v
              this.onFontSize(v)
            })
        }, (v: number) => `fs-${v}`)
      }
      .width('100%')

      Row({ space: 12 }) {
        Text('行距')
          .fontColor(this.textColor())
        Slider({ value: this.lineHeight, max: 3, min: 1, step: 0.1, style: SliderStyle.InSet })
          .selectedColor('#007DFF')
          .blockSize({ width: 30, height: 30 })
          .borderRadius(20)
          .padding({ left: 8, right: 8 })
          .layoutWeight(1)
          .onChange((value: number) => {
            Haptics.tick();
            this.lineHeight = Math.round(value * 10) / 10
            this.onLineHeight(this.lineHeight)
          })
        Text(`${this.lineHeight.toFixed(1)}`)
          .fontSize(13).fontColor('#007DFF').width(34).textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('档位')
          .fontSize(12)
          .fontColor(this.subColor())
          .width(28)
        ForEach(LINE_HEIGHT_PRESETS, (v: number) => {
          Text(v.toFixed(1))
            .fontSize(13)
            .fontColor(this.lineHeight === v ? '#007DFF' : this.textColor())
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(this.lineHeight === v ? 'rgba(0,125,255,0.15)' : Color.Transparent)
            .onClick(() => {
              Haptics.tap();
              this.lineHeight = v
              this.onLineHeight(v)
            })
        }, (v: number) => `lh-${v}`)
      }
      .width('100%')

      // ── 字体列表（橙圈 = 当前使用；导入/下载项带 改名/删除）────────────────
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.fonts, (item: FontLibItem) => {
            if (this.renamingName === item.name) {
              // ── 改名行：输入框 + 确定/取消 ─────────────────────────────────
              Row({ space: 8 }) {
                TextInput({ text: item.name })
                  .onChange((v: string) => {
                    this.renameText = v
                  })
                  .fontSize(14)
                  .layoutWeight(1)
                  .height(36)
                Text('确定')
                  .fontSize(14).fontColor('#007DFF')
                  .onClick(() => {
                    Haptics.tap();
                    this.confirmRename()
                  })
                Text('取消')
                  .fontSize(14)
                  .fontColor(this.subColor())
                  .onClick(() => {
                    Haptics.tap();
                    this.renamingName = ''
                  })
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(10)
              .backgroundColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.10)' : 'rgba(19, 19, 19, 0.05)')
            } else {
              Row({ space: 8 }) {
                Text(SAMPLE_TEXT)
                  .fontSize(18)
                  .fontFamily(item.name)
                  .fontColor(this.textColor())
                  .maxLines(1)
                Column({ space: 2 }) {
                  Text(item.name + (item.name === ReaderFontLib.DEFAULT_NAME ? '（默认）' : ''))
                    .fontSize(12)
                    .fontColor(this.subColor())
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (item.src !== 'system') {
                  Text('改名')
                    .fontSize(13).fontColor('#007DFF')
                    .padding(6)
                    .onClick(() => {
                      Haptics.tap();
                      this.renamingName = item.name
                      this.renameText = item.name
                    })
                  Text('删除')
                    .fontSize(13)
                    .fontColor(item.name === this.curFontName
                      ? (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.35)' : 'rgba(19, 19, 19, 0.35)')
                      : '#E5310A')
                    .padding(6)
                    .onClick(() => {
                      Haptics.tap();
                      this.askDelete(item)
                    })
                }
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(10)
              .borderWidth(item.name === this.curFontName ? 1.5 : 0)
              .borderColor('#ff6600')
              .backgroundColor(this.rowBg())
              .onClick(() => {
                this.pick(item)
              })
            }
          }, (item: FontLibItem) => item.name + '|' + item.path)

          // ── 内置字体库（2026-10-24）：远端同步拉取，未下载的灰色 + 下载图标 ────
          //    联网才能下 ⇒ 精简模式下整块隐藏（与直链下载区同一套门控逻辑）。
          //    标题右侧是**手动刷新图标**（用户要求：去掉"不占安装包"那句无意义提示）。
          if (!this.offlineOn) {
            Row({ space: 6 }) {
              Text('在线字体库')
                .fontSize(12)
                .fontColor(this.subColor())
              if (this.catalogRefreshing) {
                Text('同步中')
                  .fontSize(11)
                  .fontColor(this.dimColor())
              }
              Blank()
              if (this.catalogRefreshing) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color('#007DFF')
              } else {
                SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                  .fontSize(18)
                  .fontColor([this.subColor()])
                  .padding(4)
                  .onClick(() => {
                    Haptics.tap();
                    this.refreshCatalog(true)
                  })
              }
            }
            .width('100%')
            .padding({ top: 6, bottom: 2 })

            // ── 有新版本（本地 sha ≠ 上游 sha）：原地更新 ──────────────────────
            ForEach(this.updatable, (row: UpdateRow) => {
              Row({ space: 8 }) {
                Text(SAMPLE_TEXT)
                  .fontSize(18)
                  .fontFamily(row.entryName)
                  .fontColor(this.textColor())
                  .maxLines(1)
                Column({ space: 2 }) {
                  Text(row.entryName)
                    .fontSize(12)
                    .fontColor(this.textColor())
                  Text('有新版本 · 点击更新')
                    .fontSize(10)
                    .fontColor('#007DFF')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                this.rowStatus(row.font.key, true)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(10)
              .borderWidth(1)
              .borderColor('rgba(0,125,255,0.35)')
              .backgroundColor(this.rowBg())
              .onClick(() => {
                // 更新：传**已安装条目的显示名**（原地覆盖，不新建条目）
                if (this.isQueued(row.font.key)) {
                  this.removeQueued(row.font.key)
                } else {
                  this.downloadCatalog(row.font, row.entryName)
                }
              })
            }, (row: UpdateRow) => 'upd|' + row.font.key + '|' + row.font.sha)

            // ── 还没下载：灰色 + 下载图标 ─────────────────────────────────────
            ForEach(this.pending, (c: CatalogFont) => {
              Row({ space: 8 }) {
                // 未安装 ⇒ `.fontFamily(c.name)` 解析不到，自动回落系统字形
                // （正好就是"还没下载、预览不了"的真实状态，不做假预览）
                Text(SAMPLE_TEXT)
                  .fontSize(18)
                  .fontFamily(c.name)
                  .fontColor(this.dimColor())
                  .maxLines(1)
                Column({ space: 2 }) {
                  Text(c.name)
                    .fontSize(12)
                    .fontColor(this.dimColor())
                  Text(this.catalogSub(c))
                    .fontSize(10)
                    .fontColor(this.dimColor())
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                this.rowStatus(c.key, false)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(10)
              .backgroundColor(this.rowBg())
              .onClick(() => {
                // 排队中再点一次 ⇒ 撤出队列；否则入队下载
                if (this.isQueued(c.key)) {
                  this.removeQueued(c.key)
                } else {
                  this.downloadCatalog(c, '')
                }
              })
            }, (c: CatalogFont) => 'cat|' + c.key)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      // ★ 2026-10-25 官方 UX 自检 2.1.5.3.3「滑动过界反馈动效一致性」修复：
      //   `scroll.d.ts` 原文「…Default value: **EdgeEffect.None**」⇒ 字体列表用的是
      //   `Scroll`，不写就没有越界反馈（字体多时滑到底"硬停"）。
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

      // ── 下载区（3.3：去掉"展开"按钮，输入框常驻；3.4：占位文案 + 多直链）────
      //    2026-10-24：队列化后这里常驻「进度 + 队列长度 + 取消」，
      //    连点多个不再需要等前一个下完（点击即入队）。
      if (this.dlState === 2) {
        Row({ space: 10 }) {
          Progress({ value: this.dlPercent, total: 100, type: ProgressType.Linear })
            .color('#007DFF')
            .layoutWeight(1)
          Text(this.queueLabel())
            .fontSize(12)
            .fontColor(this.subColor())
          Text('取消')
            .fontSize(14).fontColor('#E5310A')
            .padding({ left: 4, right: 2, top: 2, bottom: 2 })
            .onClick(() => {
              this.cancelDownload()
            })
        }
        .width('100%')
      } else {
        // ⚠️ 2026-10-13 方案 A：直链输入框只服务「下载字体」（联网）⇒ 精简模式下隐藏。
        //    「导入字体文件」按本地文件选择器工作，**保留**在下面的 Row 里。
        if (!this.offlineOn) {
          TextInput({ text: this.dlUrl, placeholder: '粘贴字体直链，空格或；以输入多个' })
            .onChange((v: string) => {
              this.dlUrl = v
            })
            .fontSize(13)
            .width('100%')
            .height(36)
        }

        Row({ space: 12 }) {
          Button('导入字体文件')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#007DFF')
            .borderRadius(18)
            .height(34)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              // 会员化（2026-09-28）：导入字体为 VIP 特权，免费用户 → VIP 弹窗
              if (!VipManager.isVip()) {
                this.openVip()
                return
              }
              this.importFont()
            })
          // ⚠️ 2026-10-13 方案 A：「开始下载字体」需联网（`http.createHttp`）⇒ 精简模式下隐藏。
          //    只藏这个按钮、不藏整行，是为了让「导入字体文件」在精简模式下仍可点、
          //    仍能命中 VIP 门控（保住这项权益的售卖面）。
          if (!this.offlineOn) {
            Button('开始下载字体')
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor('#007DFF')
              .borderRadius(18)
              .height(34)
              .padding({ left: 14, right: 14 })
              .onClick(() => {
                Haptics.tap();
                // 会员化（2026-09-28）：下载字体为 VIP 特权，免费用户 → VIP 弹窗
                if (!VipManager.isVip()) {
                  this.openVip()
                  return
                }
                this.startDownload()
              })
          }
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
    }
    .padding(16)
    .width('100%')
    .height('78%')
  }
}
