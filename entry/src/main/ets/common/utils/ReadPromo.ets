/**
 * 阅读里程碑主动推广（2026-10-28 新增）——
 * **「累计阅读时长 → 评分软引导 / VIP 弹窗」的唯一调度与持久化层**。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 需求（用户 2026-10-28 原话，逐条对应下面的常量/判定）
 * ══════════════════════════════════════════════════════════════════════════
 * ③「增加阅读超过 1 小时后，出现评分评价引导，我们有现成的能力，在设置-关于我们-评分评价。
 *    现在增加阅读超过一小时后来一次。如果是老用户早就超过一小时了然后安装这个版本，
 *    进入软件判定直接出现。新用户则是超过一小时。然后没有评价的，或者拒绝的，30 天后再次弹出。
 *    然后每 30 天一次，直到评分。是否能够实现，有什么难度没？」
 * ④「阅读超过十小时，弹出 vip 开通弹窗，和上面的一个逻辑，只是这个 vip 弹窗如果用户关了，
 *    90 天才主通打开第二次，此后不会再有主动打开的第三次了，这个需要判定的是，90 天后，
 *    如果用户已经是 vip 了，则不重复推送弹窗，因为推了也是已开通状态。」
 *
 * ≈⇒ 本类只做「该不该弹、弹过几次、什么时候再弹」，**一个像素都不画**。
 * 弹窗实体与 CustomDialogController 全部由宿主持有：`pages/Index.ets` 的
 * `openPromoRatingDialog()` / `openPromoVipDialog()`（controller 必须由页面持有，
 * 理由见 `docs/标准-弹窗与按钮统一规范.md` §2.1 与 §4.4「弹窗参数不支持动态更新」）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 两个复用的既有能力（不另造）
 * ══════════════════════════════════════════════════════════════════════════
 * · 评分：`pages/view/myCenter/about/RatingPromptDialog.ets`（前置软引导，自己不 close）
 *         + `common/utils/AppGalleryUtil.ets`（系统弹窗 + 错误码语义，:99-112 的 CommentResult）
 * · VIP ：`componets/myCenter/VipDialog.ets` + 事实源 `common/utils/VipManager.ets:46 isVip()`
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 取证（本机 SDK / 工程源码，非记忆）
 * ══════════════════════════════════════════════════════════════════════════
 * ① Preferences 通道：`PreferencesUtil.getSync/putSync/deleteSync`
 *    源码 `oh_modules/@pura/harmony-utils/src/main/ets/utils/PreferencesUtil.ets`：
 *      :105 `static getSync(key: string, defValue: preferences.ValueType,
 *                           preferenceName: string = PreferencesUtil.defaultPreferenceName)`
 *      :79  `static putSync(key: string, value: preferences.ValueType, ...)`（内部 `flush()`，:82）
 *      :216 `static deleteSync(key: string, preferenceName?: string)`（同样 `flush()`）
 *    ⇒ 与 `FirstRunMode.ets:62,89`、`VipManager.ets:47,52` 是同一个落盘通道。
 *    ⚠️ 该通道内部用 `AppUtil.getContext()`（`AppUtil.ets:57-63`），而
 *       `EntryAbility.onCreate` 已 `AppUtil.init(this.context)`（`EntryAbility.ets:266`）
 *       ⇒ 在**异步回调里**也取得到 Context（这是它比裸 `getContext()` 可靠的原因，
 *       反例见 `AppGalleryUtil.ets:167-175` 的注释）。
 * ② 阅读时长真值：`database/dao/ReadDailyDao.ets:251`
 *      `async totals(p: ReadPeriod): Promise<ReadTotalRow>`，`ReadTotalRow.seconds` = 累计秒数；
 *      `ReadPeriod.mode = 'all'` ⇒ WHERE 变成 `1 = 1`（同文件 :181-191）。
 * ③ 表就绪信号：`database/index.ets:31-43 whenReady()` —— 其注释原文
 *      「修法：暴露一个 Promise，任何"依赖表结构已就绪"的查询方先 `await` 它。」
 *    且 `readDaily` 建表在 `doInitAllTable()` 里（同文件 :84），一定早于 `initDone`
 *    ⇒ **必须 await 它再去查 totals()**；否则冷启动时 `DbUtil.rdbStore` 还没赋值
 *    （`DbUtil.ets:22-35` 是 `.then()` 里赋的）⇒ `totals()` 走 `ready()==false` 返回全 0
 *    （`ReadDailyDao.ets:172-174,253-255`）⇒ 老用户「一装就弹」永远不成立。
 * ④ 阅读器是否在栈顶：`AppStorage` 键 `NightMode.READER_KEY = 'readerActive'`
 *    （`NightMode.ets:64`，写入点 `NightMode.setReaderActive`，:125-127）。
 * ⑤ 系统评分是否值得弹：`AppGalleryUtil.canComment()`（:124，syscap + API≥20 + 总开关）
 *    与 `shouldSkipPrompt(ctx)`（:196，本地记的「已评价/达上限」一年冷却）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 判定顺序（**评分优先**，这是刻意选择）
 * ══════════════════════════════════════════════════════════════════════════
 * RATING 先于 VIP 的理由：评分门槛更低（1h vs 10h），且被拒后 30 天就再来一轮；
 * VIP 是 90 天一次、总共只弹 2 次 ⇒ **晚一次几乎没有损失**，反过来若 VIP 先弹，
 * 用户刚看完 10 小时却先被推销、再被要评价，体感更差。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 一键回退（项目 AGENTS.md 第 3 条）
 * ══════════════════════════════════════════════════════════════════════════
 * 把下面 `ENABLED` 改成 `false` ⇒
 *   · `check()` 恒返回 `PromoKind.NONE` ⇒ 两个弹窗永远不主动弹；
 *   · `addSeconds()` 直接 return ⇒ 不再写盘；
 *   · `ReadTimeRecorder` 的两处埋点是**无条件**调用本类的（不判 ENABLED），
 *     所以回退只需改这一个常量，不必改 `ReadTimeRecorder.ets` / `Index.ets` 任何一行。
 * 回退后要验证：① 读满 1h 退书不弹评分引导；② 读满 10h 不弹 VIP；③ 阅读时长统计页数字不变。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 开发者调试
 * ══════════════════════════════════════════════════════════════════════════
 * `debugReset()` 抹掉本模块全部键（**不**新增任何设置页入口）。
 * 想快速看到弹窗，最稳的是**临时把阈值调小**（`RATING_THRESHOLD_SEC = 10`），
 * 原因见 `debugReset()` 的注释（历史秒数下次冷启动会从 `readDaily` 表重新并入）。
 */
import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { PreferencesUtil } from '@pura/harmony-utils'
import AppGalleryUtil from './AppGalleryUtil'
import { VipManager } from './VipManager'
import { NightMode } from './NightMode'
import ReadDailyDao, { ReadPeriod, ReadTotalRow } from '../../database/dao/ReadDailyDao'
import DataBase from '../../database'

const TAG: string = 'ReadPromo'

/** 该弹什么（`NONE` = 什么都不弹） */
export enum PromoKind {
  NONE = 0,
  RATING = 1,
  VIP = 2
}

export class ReadPromo {

  // ── 总闸与阈值 ──────────────────────────────────────────────────────────

  /**
   * ★ 一键回退总闸 ★ `false` ⇒ `check()` 恒 `NONE`、`addSeconds()` 不写盘。
   * 见文件头「一键回退」段。
   */
  static readonly ENABLED: boolean = true

  /** 评分软引导门槛：累计阅读 1 小时（用户原话「超过 1 小时」） */
  static readonly RATING_THRESHOLD_SEC: number = 60 * 60

  /** 评分被拒后的重试间隔：30 天（用户原话「30 天后再次弹出…每 30 天一次，直到评分」） */
  static readonly RATING_RETRY_MS: number = 30 * 24 * 60 * 60 * 1000

  /** VIP 弹窗门槛：累计阅读 10 小时（用户原话「超过十小时」） */
  static readonly VIP_THRESHOLD_SEC: number = 10 * 60 * 60

  /** VIP 第二次弹出的间隔：90 天（用户原话「90 天才主动打开第二次」） */
  static readonly VIP_RETRY_MS: number = 90 * 24 * 60 * 60 * 1000

  /**
   * VIP 弹窗自动弹出的**总次数上限**：2（第一次 + 90 天后第二次）。
   * 用户原话「此后不会再有主动打开的第三次了」⇒ 这是硬上限，
   * `markVipShown()` 里 `count` 永远夹在 `[0, VIP_MAX_SHOWS]`。
   */
  static readonly VIP_MAX_SHOWS: number = 2

  // ── Preferences 键（统一 'readPromo' 前缀，避免与 AppGalleryUtil 的 RATING_* 撞车）─

  /** 累计阅读秒数（**单调递增**，只增不减） */
  private static readonly KEY_TOTAL_SEC: string = 'readPromoTotalSec'
  /** 上次评分软引导弹出的时间戳（ms；0 = 从没弹过） */
  private static readonly KEY_RATING_SHOWN_AT: string = 'readPromoRatingShownAt'
  /** 是否已达「不用再问」的终态（true = 永久不再弹评分引导） */
  private static readonly KEY_RATING_DONE: string = 'readPromoRatingDone'
  /** VIP 弹窗已自动弹出的次数（0 / 1 / 2） */
  private static readonly KEY_VIP_COUNT: string = 'readPromoVipCount'
  /** 上次 VIP 弹窗的时间戳（ms；0 = 从没弹过） */
  private static readonly KEY_VIP_LAST_AT: string = 'readPromoVipLastAt'

  // ── 运行态 ──────────────────────────────────────────────────────────────

  /** `init()` 是否已经跑过（幂等闸：宿主可能重复调用） */
  private static inited: boolean = false
  /** 历史时长一次性入账是否已经**跑完**（含 DB 等待；宿主据 `isReady()` 决定要不要再试） */
  private static synced: boolean = false
  /** 入账任务是否在途（防重入） */
  private static syncing: boolean = false

  /**
   * 入账看门狗（ms）。
   * 为什么需要：`DataBase.whenReady()` 的 Promise **只在 `initAllTable()` 跑完时才 resolve**
   * （`database/index.ets:48-56`：`finally` 里 `readyResolve?.()`），而它挂在
   * `DbUtil.initDB(...).then(...)` 链上（`EntryAbility.ets:468`）——
   * 若 `initDB` **reject**（磁盘满 / 库损坏），`.then` 不会执行 ⇒ `whenReady()` 永远 pending
   * ⇒ 若只等它，推广模块会被**永久挂死**（`isReady()` 恒 false ⇒ 每次退书都不判定）。
   * 8s 兜底放行：宁可这一次按本地值判定（最多漏弹一次），也不能让模块整体失效。
   */
  private static readonly DB_WAIT_WATCHDOG_MS: number = 8000

  // ── 对外 API ────────────────────────────────────────────────────────────

  /**
   * 冷启动初始化（宿主 `aboutToAppear` 调一次，内部幂等）。
   *
   * 做两件事：
   *  ① 把「系统侧一年冷却」同步成永久完成位 —— 否则冷启动白 new 一个弹窗 controller
   *     （`canComment()` 之后 `shouldSkipPrompt()` 为真时弹出来也只会被系统拒，见 `AppGalleryUtil.ets:187-207`）；
   *  ② 启动**历史时长一次性入账**（老用户「装了新版本直接弹」的唯一依据）：
   *     读 `readDaily` 的 `mode:'all'` 汇总（`ReadDailyDao.ets:251`），与本地现值取 **max**
   *     ⇒ 幂等、单调、重复调用无副作用。
   *
   * ⚠️ 不 await、不阻塞启动：DB 未就绪时 `whenReady()` 会等（`database/index.ets:31-43`），
   *    宿主用 `isReady()` 判断「历史入账跑完没有」，没跑完就先不判定（见 `Index.ets` 的重试）。
   *
   * @param ctx 宿主 Ability 上下文（本类的落盘走 `PreferencesUtil`，不需要它；
   *            这里**真实用途**是把 `AppGalleryUtil.shouldSkipPrompt(ctx)` 的冷却态同步过来）
   */
  static init(ctx: common.UIAbilityContext): void {
    if (!ReadPromo.ENABLED || ReadPromo.inited) {
      return
    }
    ReadPromo.inited = true
    try {
      if (!ReadPromo.readBool(ReadPromo.KEY_RATING_DONE, false) &&
        AppGalleryUtil.shouldSkipPrompt(ctx)) {
        // 系统口径「一年内已评过/达上限」⇒ 本模块永久静默（用户不会再看到软引导）
        ReadPromo.writeBool(ReadPromo.KEY_RATING_DONE, true)
        hilog.info(0x0000, TAG, 'init: system cooldown active, pin rating done')
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'init cooldown check failed: ' + JSON.stringify(e))
    }
    ReadPromo.startHistorySync()
  }

  /**
   * 历史时长入账是否**可以据此判定**。
   *  · 已跑完（成功/失败都算）⇒ true；
   *  · 还没跑完，但**本地已攒够评分门槛** ⇒ 也可以判：历史入账只会让 total 更大，
   *    不会把「够 1 小时」翻成「不够」⇒ 结论已确定，不必再等 DB
   *    （这一条同时保证"老用户装新版本、本地已有时长"时**立刻**能弹，不被 DB 窗口拖住）。
   * 返回 false ⇒ `totalSeconds()` 还可能是 0，此时判定会把老用户判成新用户（漏弹），
   * 宿主应稍后再试。
   */
  static isReady(): boolean {
    if (ReadPromo.synced) {
      return true
    }
    return ReadPromo.totalSeconds() >= ReadPromo.RATING_THRESHOLD_SEC
  }

  /**
   * 累加阅读秒数（`ReadTimeRecorder.commitSegment()` 每落一段就调一次，见那边的埋点注释）。
   * **写失败绝不影响阅读**：所有异常在本方法内吞掉。
   */
  static addSeconds(sec: number): void {
    if (!ReadPromo.ENABLED) {
      return
    }
    const s: number = Math.floor(sec)
    if (!Number.isFinite(s) || s <= 0) {
      return
    }
    try {
      const cur: number = ReadPromo.totalSeconds()
      ReadPromo.writeNumber(ReadPromo.KEY_TOTAL_SEC, cur + s)
    } catch (e) {
      hilog.warn(0x0000, TAG, 'addSeconds failed: ' + JSON.stringify(e))
    }
  }

  /** 累计阅读秒数（0 = 没有任何记录） */
  static totalSeconds(): number {
    const t: number = ReadPromo.readNumber(ReadPromo.KEY_TOTAL_SEC, 0)
    return t > 0 ? t : 0
  }

  /**
   * 判定表（顺序即优先级，见文件头「判定顺序」）：
   *
   * | 条件 | 结果 |
   * |---|---|
   * | 总闸关 / 阅读器在栈顶 | NONE |
   * | **未评分** && ≥1h && 系统支持应用内评分 && (没弹过 ‖ 距上次推送 ≥30 天) && 系统没说过"一年内已评/达上限" | **RATING** |
   * | 系统不支持应用内评分（`canComment()` false） | 跳过 RATING（继续看 VIP）—— 弹了只会跳商店，属骚扰 |
   * | 系统说"一年内已评/达上限"（`shouldSkipPrompt()` true） | 顺手钉成永久完成，继续看 VIP |
   * | 已是 VIP | NONE（**已开通绝不推**，用户原话） |
   * | <10h / 已弹满 2 次 | NONE |
   * | VIP 弹过 0 次 && ≥10h | **VIP** |
   * | VIP 弹过 1 次 && 距上次 ≥90 天 && ≥10h | **VIP**（第二次，也是最后一次） |
   *
   * ⚠️ 2026-10-28 用户口径（评分那两行）：
   *   「无需知道用户是否真的评价了…只要是判断**未评分**且**上次推送评分超过三十天**，则推第二次」。
   *   ⇒ 「已评分」的唯一判据是既有 `AppGalleryUtil.shouldSkipPrompt()`（系统错误码 0007/0009/0008
   *      落到本地 `RATING_REVIEWED_AT`/`RATING_LIMIT_AT`，`AppGalleryUtil.ets:196-219`）；
   *      点过「去评分」**不算**评分，只把 30 天计时清零（`markRatingShown`）。
   */
  static check(ctx: common.UIAbilityContext): PromoKind {
    if (!ReadPromo.ENABLED) {
      return PromoKind.NONE
    }
    // 阅读器在栈顶时绝不弹：弹窗会盖在阅读页上，且退出转场还没结束时弹窗会跟着抖
    if (AppStorage.get<boolean>(NightMode.READER_KEY) === true) {
      return PromoKind.NONE
    }
    try {
      const total: number = ReadPromo.totalSeconds()
      const now: number = Date.now()

      // ── ① 评分软引导（优先级最高，理由见文件头）────────────────────────────
      if (!ReadPromo.readBool(ReadPromo.KEY_RATING_DONE, false) && total >= ReadPromo.RATING_THRESHOLD_SEC) {
        if (!AppGalleryUtil.canComment()) {
          // 设备/版本不支持应用内评分（`AppGalleryUtil.ets:124`：syscap + API≥20 + 总开关）
          // ⇒ 不弹。弹了只能降级去跳商店，而"自动弹窗 + 突然跳应用市场"是骚扰。
          hilog.info(0x0000, TAG, 'check: comment capability unavailable, skip rating')
        } else if (AppGalleryUtil.shouldSkipPrompt(ctx)) {
          // 系统说一年内已评过 / 评论数达上限（`AppGalleryUtil.ets:196-207`）
          // ⇒ 问下去必然被拒，直接钉成完成位，永久静默。
          ReadPromo.writeBool(ReadPromo.KEY_RATING_DONE, true)
          hilog.info(0x0000, TAG, 'check: shouldSkipPrompt true, pin rating done')
        } else {
          const shownAt: number = ReadPromo.readNumber(ReadPromo.KEY_RATING_SHOWN_AT, 0)
          if (shownAt <= 0 || now - shownAt >= ReadPromo.RATING_RETRY_MS) {
            return PromoKind.RATING
          }
        }
      }

      // ── ② VIP 弹窗 ────────────────────────────────────────────────────────
      // 已开通 ⇒ 绝不推（推出来也是"已开通"状态，用户原话）
      if (VipManager.isVip()) {
        return PromoKind.NONE
      }
      if (total < ReadPromo.VIP_THRESHOLD_SEC) {
        return PromoKind.NONE
      }
      const count: number = Math.floor(ReadPromo.readNumber(ReadPromo.KEY_VIP_COUNT, 0))
      if (count >= ReadPromo.VIP_MAX_SHOWS) {
        // 第一次 + 第二次都弹过了 ⇒ 此后永不再主动弹
        return PromoKind.NONE
      }
      if (count <= 0) {
        return PromoKind.VIP
      }
      const lastAt: number = ReadPromo.readNumber(ReadPromo.KEY_VIP_LAST_AT, 0)
      if (lastAt <= 0 || now - lastAt >= ReadPromo.VIP_RETRY_MS) {
        return PromoKind.VIP
      }
      return PromoKind.NONE
    } catch (e) {
      // 任何异常都不许冒泡到 UI
      hilog.warn(0x0000, TAG, 'check failed: ' + JSON.stringify(e))
      return PromoKind.NONE
    }
  }

  // ── 记账（宿主在弹窗的每条关闭路径上调用）──────────────────────────────────

  /**
   * 「这次推送过了」⇒ 30 天计时从此刻起算（**不代表评没评**）。
   *
   * 2026-10-28 用户口径：「无需知道用户是否真的评价了…只要是判断**未评分**且
   * **上次推送评分超过三十天**，则推第二次」。
   * ⇒ 三条关闭路径（「以后再说」/ 点遮罩 / 点「去评分」）都只走这里，把 30 天计时清零；
   *   「已评分」只由 `AppGalleryUtil.shouldSkipPrompt()`（系统错误码落盘）判定，
   *   命中时 `check()` 会调 `markRatingDone()` 钉终态。
   */
  static markRatingShown(): void {
    try {
      ReadPromo.writeNumber(ReadPromo.KEY_RATING_SHOWN_AT, Date.now())
      ReadPromo.writeBool(ReadPromo.KEY_RATING_DONE, false)
    } catch (e) {
      hilog.warn(0x0000, TAG, 'markRatingShown failed: ' + JSON.stringify(e))
    }
  }

  /**
   * 「已经评过 / 不必再问」⇒ 永久静默（不再弹软引导）。
   * ⚠️ 只由 `check()` 在 `AppGalleryUtil.shouldSkipPrompt()` 为真时调用（系统 0007/0009/0008
   * 已经落盘），**不要**在"用户点了去评分"时调用（那样等于点一次就永不再问）。
   */
  static markRatingDone(): void {
    try {
      ReadPromo.writeBool(ReadPromo.KEY_RATING_DONE, true)
    } catch (e) {
      hilog.warn(0x0000, TAG, 'markRatingDone failed: ' + JSON.stringify(e))
    }
  }

  /** 「VIP 弹窗被关掉了」⇒ 次数 +1、记时间戳（第 2 次之后 `check()` 恒 NONE） */
  static markVipShown(): void {
    try {
      const count: number = Math.floor(ReadPromo.readNumber(ReadPromo.KEY_VIP_COUNT, 0))
      const next: number = Math.min(ReadPromo.VIP_MAX_SHOWS, count + 1)
      ReadPromo.writeNumber(ReadPromo.KEY_VIP_COUNT, next)
      ReadPromo.writeNumber(ReadPromo.KEY_VIP_LAST_AT, Date.now())
    } catch (e) {
      hilog.warn(0x0000, TAG, 'markVipShown failed: ' + JSON.stringify(e))
    }
  }

  /**
   * 「关窗那一刻已经是 VIP」（用户在弹窗里买成了 / 本来就是会员）⇒ 永久停推。
   * 直接置 `count = VIP_MAX_SHOWS` ⇒ `check()` 的第一条 VIP 判定就 return NONE。
   */
  static markVipBought(): void {
    try {
      ReadPromo.writeNumber(ReadPromo.KEY_VIP_COUNT, ReadPromo.VIP_MAX_SHOWS)
      ReadPromo.writeNumber(ReadPromo.KEY_VIP_LAST_AT, Date.now())
    } catch (e) {
      hilog.warn(0x0000, TAG, 'markVipBought failed: ' + JSON.stringify(e))
    }
  }

  /**
   * 开发者用：抹掉本模块全部键（真机快速验证 / 重放弹窗）。**不新增任何设置页入口**。
   *
   * ⚠️ 两个必须知道的边界（否则会以为"没生效"）：
   *  ① 它只清本模块的 Preferences 键，**不动 `readDaily` 表**；
   *     而 `init()` 下次冷启动会把表里的历史秒数重新 max 合并进来
   *     ⇒ 「模拟一个从没读过书的新用户」不能靠它，请临时调小阈值或改 `ENABLED`。
   *  ② 它把 `synced` 置 true（保持"已就绪"语义），所以本会话内不会被在途的入账任务回写。
   */
  static debugReset(): void {
    ReadPromo.synced = true
    try {
      PreferencesUtil.deleteSync(ReadPromo.KEY_TOTAL_SEC)
      PreferencesUtil.deleteSync(ReadPromo.KEY_RATING_SHOWN_AT)
      PreferencesUtil.deleteSync(ReadPromo.KEY_RATING_DONE)
      PreferencesUtil.deleteSync(ReadPromo.KEY_VIP_COUNT)
      PreferencesUtil.deleteSync(ReadPromo.KEY_VIP_LAST_AT)
      hilog.info(0x0000, TAG, 'debugReset done, all readPromo* keys removed')
    } catch (e) {
      hilog.warn(0x0000, TAG, 'debugReset failed: ' + JSON.stringify(e))
    }
  }

  // ── 内部：历史时长入账 ───────────────────────────────────────────────────

  /** 起一次入账任务（`init()` 内部调用；重入保护 + 吞掉 rejection） */
  private static startHistorySync(): void {
    if (ReadPromo.syncing) {
      return
    }
    ReadPromo.syncing = true
    // 看门狗（理由见 `DB_WAIT_WATCHDOG_MS` 注释）：DB 链路真的挂了也要放行，否则模块永久失效
    setTimeout((): void => {
      if (!ReadPromo.synced) {
        ReadPromo.synced = true
        hilog.warn(0x0000, TAG, 'history sync watchdog fired (DB not ready), pass through')
      }
    }, ReadPromo.DB_WAIT_WATCHDOG_MS)
    ReadPromo.runHistorySync().catch((e: Error): void => {
      // 理论上进不来（runHistorySync 内部已兜），这里只为杜绝 unhandled rejection
      ReadPromo.synced = true
      ReadPromo.syncing = false
      hilog.warn(0x0000, TAG, 'history sync rejected: ' + e.message)
    })
  }

  /**
   * 把 `readDaily` 表的历史累计秒数**一次性**并入本地现值（取 max）。
   *
   * 为什么必须 `await DataBase.whenReady()`：`readDaily` 建表在
   * `DataBase.doInitAllTable()`（`database/index.ets:84`）里，而冷启动时
   * `DbUtil.rdbStore` 是 `EntryAbility.onWindowStageCreate` 异步赋值的
   * （`EntryAbility.ets:468` + `DbUtil.ets:22-35`）⇒ 不等就可能查到 0
   * （`ReadDailyDao.ets:172-174` 的 `ready()` 直接返回空）。
   */
  private static async runHistorySync(): Promise<void> {
    try {
      await DataBase.whenReady()
      const period: ReadPeriod = { mode: 'all', from: '', to: '' }
      const row: ReadTotalRow = await ReadDailyDao.totals(period)
      const dbSec: number = Math.max(0, Math.floor(row.seconds))
      const cur: number = ReadPromo.totalSeconds()
      if (dbSec > cur) {
        ReadPromo.writeNumber(ReadPromo.KEY_TOTAL_SEC, dbSec)
      }
      hilog.info(0x0000, TAG, `history sync: dbSec=${dbSec}, prev=${cur}`)
    } catch (e) {
      hilog.warn(0x0000, TAG, 'history sync failed: ' + JSON.stringify(e))
    } finally {
      ReadPromo.synced = true
      ReadPromo.syncing = false
    }
  }

  // ── 内部：Preferences 读写（全部 try/catch，绝不冒泡）──────────────────────

  private static readNumber(key: string, def: number): number {
    try {
      // 注：`PreferencesUtil.getSync` 的返回类型是 `preferences.ValueType`（联合类型），
      // 与 `VipManager.ets:47` 同款断言；再用 typeof 兜一层脏数据。
      const raw: number = PreferencesUtil.getSync(key, def) as number
      if (typeof raw !== 'number' || !Number.isFinite(raw)) {
        return def
      }
      return raw
    } catch (e) {
      hilog.warn(0x0000, TAG, `readNumber(${key}) failed: ` + JSON.stringify(e))
      return def
    }
  }

  private static readBool(key: string, def: boolean): boolean {
    try {
      const raw: boolean = PreferencesUtil.getSync(key, def) as boolean
      return raw === true
    } catch (e) {
      hilog.warn(0x0000, TAG, `readBool(${key}) failed: ` + JSON.stringify(e))
      return def
    }
  }

  private static writeNumber(key: string, value: number): void {
    try {
      PreferencesUtil.putSync(key, value)
    } catch (e) {
      hilog.warn(0x0000, TAG, `writeNumber(${key}) failed: ` + JSON.stringify(e))
    }
  }

  private static writeBool(key: string, value: boolean): void {
    try {
      PreferencesUtil.putSync(key, value)
    } catch (e) {
      hilog.warn(0x0000, TAG, `writeBool(${key}) failed: ` + JSON.stringify(e))
    }
  }
}

export default ReadPromo
