import { updateManager, commentManager } from '@kit.AppGalleryKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import type { common } from '@kit.AbilityKit'

/**
 * ── 应用市场（AppGallery Kit）统一封装 ─────────────────────────────────────────
 * 覆盖三件事：
 *   1. 检查更新 —— updateManager.checkAppUpdate / showUpdateDialog
 *   2. 应用内评分弹窗 —— commentManager.showCommentDialog
 *   3. 跳转应用市场应用详情页（写评论 / 通用详情）
 *
 * ══ 取证（全部来自本机 SDK，非记忆）═════════════════════════════════════════
 *
 * 【updateManager】`<DEVECO_SDK_HOME>\default\hms\ets\api\@hms.core.appgalleryservice.updateManager.d.ts`
 *   @syscap SystemCapability.AppGalleryService.Distribution.Update
 *   @stagemodelonly
 *   @since 5.0.0(12)
 *   function checkAppUpdate(context: common.UIAbilityContext): Promise<CheckUpdateResult>;
 *   function showUpdateDialog(context: common.UIAbilityContext): Promise<ShowUpdateResultCode>;
 *   枚举：UpdateAvailableCode { LATER_VERSION_EXIST = 1, LATER_VERSION_NOT_EXIST = 0 }
 *        ShowUpdateResultCode { SHOW_DIALOG_SUCCESS = 0, SHOW_DIALOG_FAILURE = 1 }
 *   错误码：401 / 1009400001 SA connect error / 1009400002 Request to service error /
 *          1009400003 Network error / 1009400004 The application is not in the foreground /
 *          1009400005 Not agreeing to the privacy agreement / 1009400006 Time limited / 1009400007 Other error
 *
 * 【commentManager】`...\api\@hms.core.appgalleryservice.commentManager.d.ts`
 *   @syscap SystemCapability.AppGalleryService.Distribution.Comment
 *   @stagemodelonly
 *   @since 6.0.0(20)
 *   function showCommentDialog(context: common.UIExtensionContext | common.UIAbilityContext): Promise<void>;
 *   错误码：1021500001~1021500009（详见下方 switch 注释）
 *
 * 【canIUse】`...\openharmony\ets\api\@internal\full\global.d.ts:374`
 *   `export declare function canIUse(syscap: string): boolean;`  @since 11
 *   ⚠️ 它是**全局函数**（ArkUI global.d.ts），**不要从 @kit.BasicServicesKit 导入** —— 导不到。
 *
 * 【deviceInfo.sdkApiVersion】`...\openharmony\ets\api\@ohos.deviceInfo.d.ts:369`
 *   `const sdkApiVersion: number;`  @since 6
 *
 * ══ 官方硬约束（决定"未上架能不能用"）══════════════════════════════════════
 *  开发指南/AppGallery_Kit_应用市场服务/应用市场更新功能/store-update 原文：
 *    「应用市场更新功能为**已上架应用**提供版本检测、显示更新提醒能力。」
 *    「约束与限制：… **应用已在应用市场上架。**」
 *  ⇒ 未上架时 checkAppUpdate 会失败或恒返回 LATER_VERSION_NOT_EXIST。
 *    因此本类所有调用**必须**能优雅降级，不允许把失败抛给用户。
 *
 * ══ 真机实测修正（2026-10-18，`docs/日志.md` 原文）═════════════════════════
 *  原推断「未上架 ⇒ 1021500003 连不上应用市场」被真机**推翻**：
 *    11:09:37.683 The session is created with bundle=com.huawei.hmsapp.appgallery,
 *                 ability=CommentInAppAbility, componentId=624, sessionType=1.
 *    11:09:38.228 AppGalleryKit OnResultForModal ShowCommentDialogUICallback, 1021500007
 *    11:09:38.228 AppGalleryUtil showCommentDialog failed, code=1021500007,
 *                 msg=The user has already commented on the current version.
 *  ⇒ AGC 应用已创建（APP ID 6917617154596659920，"2.1.5准备提交"）时，
 *    **应用市场侧已能识别包名**，评分弹窗能正常拉起 —— 只是该账号**已评价过当前版本**。
 *  ⇒ 因此 0007/0008/0009 **不是故障**，是正常业务结局，**绝不能再降级去跳商店**
 *    （用户已评价却被丢进商店 = 体验事故）。本类据此把返回值细分为 CommentResult。
 *
 * ══ 回退方式（符合项目 AGENTS.md 第 3 条）═══════════════════════════════════
 *  顶部 `APPGALLERY_ENABLED = false` ⇒ 所有能力关闭，全部走本地降级分支，
 *  不发起任何应用市场调用。改这一个常量即可整体回退，不需要动调用点。
 */

const TAG: string = 'AppGalleryUtil'

/** 【一键回退总开关】false ⇒ 完全停用应用市场能力，全部走降级分支 */
const APPGALLERY_ENABLED: boolean = true

/** 应用评论服务 syscap（.d.ts @syscap 原文） */
const SYSCAP_COMMENT: string = 'SystemCapability.AppGalleryService.Distribution.Comment'
/** 应用市场更新功能 syscap（.d.ts @syscap 原文） */
const SYSCAP_UPDATE: string = 'SystemCapability.AppGalleryService.Distribution.Update'

/** commentManager 起始版本 6.0.0(20) ⇒ API 20 */
const MIN_API_COMMENT: number = 20
/** updateManager 起始版本 5.0.0(12) ⇒ API 12 */
const MIN_API_UPDATE: number = 12

/** 本应用包名（与 AppScope/app.json5 的 bundleName 一致；改包名时这里必须同步） */
const BUNDLE_NAME: string = 'com.jk.reader'

/** 检查更新的业务结果（把 SDK 的枚举 + 各类异常收敛成调用方好用的三态） */
export enum UpdateCheckState {
  /** 有新版本 */
  HAS_UPDATE = 0,
  /** 已是最新 */
  LATEST = 1,
  /** 无法检查（未上架 / 网络 / 服务不可用 / 能力缺失）—— 调用方应提示"暂时无法检查" */
  UNAVAILABLE = 2
}

/** 跳转应用市场的目标页 */
export enum StorePage {
  /** 应用详情页 */
  DETAIL = 0,
  /** 写评论页（详情页下一步自动拉起写评论） */
  WRITE_REVIEW = 1
}

/**
 * 应用内评分弹窗的业务结局。
 * 把 `.d.ts` 的 9 个错误码收敛成「调用方该怎么应对」的语义，而不是非黑即白的 bool。
 * ⇒ 只有 UNAVAILABLE 才允许降级跳商店；其余都是正常结局，**只给中性文案**。
 */
export enum CommentResult {
  /** 弹窗已成功拉起（用户可见，后续系统接管） */
  SHOWN = 0,
  /** 1021500007 该版本已评价过 ⇒ 感谢，不跳商店 */
  ALREADY_REVIEWED_CURRENT = 1,
  /** 1021500009 已评价且不满一年 ⇒ 感谢，不跳商店 */
  REVIEWED_WITHIN_YEAR = 2,
  /** 1021500008 评论数已达上限 ⇒ 感谢，不跳商店 */
  LIMIT_REACHED = 3,
  /** 1021500006 未登录华为账号 ⇒ 引导登录，不跳商店 */
  NOT_LOGGED_IN = 4,
  /** 0001/0002/0003/0005/未知 ⇒ 真不可用，允许跳商店兜底 */
  UNAVAILABLE = 5
}

export class AppGalleryUtil {

  // ── 能力探测 ────────────────────────────────────────────────────────────

  /** 版本守卫：当前设备 API 是否 >= 指定版本 */
  private static apiAtLeast(minApi: number): boolean {
    return deviceInfo.sdkApiVersion >= minApi
  }

  /** 应用内评分弹窗是否可用（syscap + 版本 + 总开关） */
  static canComment(): boolean {
    if (!APPGALLERY_ENABLED) {
      return false
    }
    if (!AppGalleryUtil.apiAtLeast(MIN_API_COMMENT)) {
      return false
    }
    return canIUse(SYSCAP_COMMENT)
  }

  /** 检查更新是否可用（syscap + 版本 + 总开关） */
  static canCheckUpdate(): boolean {
    if (!APPGALLERY_ENABLED) {
      return false
    }
    if (!AppGalleryUtil.apiAtLeast(MIN_API_UPDATE)) {
      return false
    }
    return canIUse(SYSCAP_UPDATE)
  }

  // ── 1. 检查更新 ─────────────────────────────────────────────────────────

  /**
   * 检查是否有新版本。**永不抛异常**，失败一律返回 UNAVAILABLE。
   * 官方约束：仅已上架应用可用；本地版本须低于在架版本且签名一致；不支持邀请/公开测试。
   */
  static async checkUpdate(context: common.UIAbilityContext): Promise<UpdateCheckState> {
    if (!AppGalleryUtil.canCheckUpdate()) {
      hilog.info(0x0000, TAG, 'checkUpdate skipped: capability unavailable')
      return UpdateCheckState.UNAVAILABLE
    }
    try {
      const result: updateManager.CheckUpdateResult = await updateManager.checkAppUpdate(context)
      if (result.updateAvailable === updateManager.UpdateAvailableCode.LATER_VERSION_EXIST) {
        hilog.info(0x0000, TAG, 'checkUpdate: LATER_VERSION_EXIST')
        return UpdateCheckState.HAS_UPDATE
      }
      hilog.info(0x0000, TAG, 'checkUpdate: LATER_VERSION_NOT_EXIST')
      return UpdateCheckState.LATEST
    } catch (e) {
      const err = e as BusinessError
      // 1009400001 SA 未连接（模拟器 / 能力缺失）、1009400003 网络错误、1009400007 其他
      // 未上架场景最可能落在 1009400002（Request to service error）或 1009400007
      hilog.warn(0x0000, TAG, `checkUpdate failed, code=${err.code}, msg=${err.message}`)
      return UpdateCheckState.UNAVAILABLE
    }
  }

  /**
   * 拉起系统升级弹窗。**永不抛异常**。
   * 返回 true = 弹窗已成功显示；false = 无法显示（调用方应给本地提示）。
   */
  static async showUpdateDialog(context: common.UIAbilityContext): Promise<boolean> {
    if (!AppGalleryUtil.canCheckUpdate()) {
      return false
    }
    try {
      const code: updateManager.ShowUpdateResultCode = await updateManager.showUpdateDialog(context)
      const ok: boolean = code === updateManager.ShowUpdateResultCode.SHOW_DIALOG_SUCCESS
      hilog.info(0x0000, TAG, `showUpdateDialog resultCode=${code}, ok=${ok}`)
      return ok
    } catch (e) {
      const err = e as BusinessError
      hilog.warn(0x0000, TAG, `showUpdateDialog failed, code=${err.code}, msg=${err.message}`)
      return false
    }
  }

  /**
   * 「检查更新」一键流程：先查 → 有更新则拉起系统升级弹窗。
   * 返回最终状态，供 UI 决定提示文案。
   */
  static async checkAndPromptUpdate(context: common.UIAbilityContext): Promise<UpdateCheckState> {
    const state: UpdateCheckState = await AppGalleryUtil.checkUpdate(context)
    if (state === UpdateCheckState.HAS_UPDATE) {
      const shown: boolean = await AppGalleryUtil.showUpdateDialog(context)
      if (!shown) {
        hilog.warn(0x0000, TAG, 'update dialog not shown, fallback to store page')
      }
    }
    return state
  }

  // ── 2. 应用内评分弹窗 ───────────────────────────────────────────────────

  /**
   * 拉起应用内评分弹窗。**永不抛异常**。
   * 返回值区分「正常业务结局」与「真不可用」——见 CommentResult 注释。
   *
   * 真机实证（docs/日志.md）：已评价过时返回 1021500007，但弹窗 UI 其实**已经拉起过**
   * （日志有 `The session is created with ... CommentInAppAbility`），系统判定后立即关闭。
   * ⇒ 这类情况**不能**再跳商店，只给中性感谢文案。
   */
  static async showCommentDialog(context: common.UIAbilityContext): Promise<CommentResult> {
    if (!AppGalleryUtil.canComment()) {
      hilog.info(0x0000, TAG, 'showCommentDialog skipped: capability unavailable')
      return CommentResult.UNAVAILABLE
    }
    try {
      await commentManager.showCommentDialog(context)
      hilog.info(0x0000, TAG, 'showCommentDialog succeeded')
      return CommentResult.SHOWN
    } catch (e) {
      const err = e as BusinessError
      hilog.warn(0x0000, TAG, `showCommentDialog failed, code=${err.code}, msg=${err.message}`)
      return AppGalleryUtil.mapCommentErrorCode(err.code)
    }
  }

  /**
   * 把 commentManager 错误码映射成业务结局。
   * 错误码语义全部取自 `@hms.core.appgalleryservice.commentManager.d.ts` 的 @throws 原文。
   */
  private static mapCommentErrorCode(code: number): CommentResult {
    // 1021500007 - The user has already commented on the current version.
    if (code === 1021500007) {
      return CommentResult.ALREADY_REVIEWED_CURRENT
    }
    // 1021500009 - The user has already left a comment, and less than a year has elapsed since then.
    if (code === 1021500009) {
      return CommentResult.REVIEWED_WITHIN_YEAR
    }
    // 1021500008 - The number of comments has reached the maximum limit.
    if (code === 1021500008) {
      return CommentResult.LIMIT_REACHED
    }
    // 1021500006 - The user has not signed in to their HUAWEI ID.
    if (code === 1021500006) {
      return CommentResult.NOT_LOGGED_IN
    }
    // 其余（0001 Internal system error / 0002 Service request failed /
    //       0003 Failed to connect to AppGallery / 0005 The app context is invalid）
    // 以及未知码 ⇒ 真不可用，允许调用方跳商店兜底
    return CommentResult.UNAVAILABLE
  }

  // ── 3. 跳转应用市场 ─────────────────────────────────────────────────────

  /**
   * 构造应用市场 Deep Linking 链接。
   * 官方原文（开发指南/AppGallery_Kit_应用市场服务/应用评论服务/appgallery-comment）：
   *   `store://appgallery.huawei.com/app/detail?id=<bundleName>&action=write-review`
   *   action 隐式指定 write-review 表示进入详情页后下一步拉起写评论页。
   */
  static buildStoreUri(page: StorePage): string {
    const base: string = `store://appgallery.huawei.com/app/detail?id=${BUNDLE_NAME}`
    return page === StorePage.WRITE_REVIEW ? `${base}&action=write-review` : base
  }

  /**
   * 跳转应用市场（详情页 / 写评论页）。**永不抛异常**。
   * 返回 true = startAbility 已成功；false = 拉不起来（如未安装应用市场、未上架找不到条目）。
   */
  static async openStore(context: common.UIAbilityContext, page: StorePage): Promise<boolean> {
    if (!APPGALLERY_ENABLED) {
      return false
    }
    try {
      // 官方原文：action 隐式指定 ohos.want.action.appdetail
      await context.startAbility({
        action: 'ohos.want.action.appdetail',
        uri: AppGalleryUtil.buildStoreUri(page)
      })
      hilog.info(0x0000, TAG, `openStore succeeded, page=${page}`)
      return true
    } catch (e) {
      const err = e as BusinessError
      hilog.warn(0x0000, TAG, `openStore failed, page=${page}, code=${err.code}, msg=${err.message}`)
      return false
    }
  }
}

export default AppGalleryUtil
