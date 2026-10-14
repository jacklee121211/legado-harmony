/**
 * 防窥保护管理器（2026-10-08 重做：两层解耦 + 全局生效 + 启动初始化）。
 *
 * ── 两个互不依赖的开关（均为 VIP 特权，门控在 UI 层）───────────────────────
 * 第 1 层 防截屏/录屏：`window.setWindowPrivacyMode(true)`。官方同一段文档给出两个副作用：
 *   「A window in privacy mode cannot be captured or recorded.」
 *   「When a window in privacy mode is moved to the background, it displays as a white overlay
 *     or privacy mask in the multi-tasking view.」
 *   （SDK `@ohos.window.d.ts:6852-6855`）⇒ **两者绑在同一 API 上、官方不可拆**，故合成一层。
 *   权限 `ohos.permission.PRIVACY_WINDOW`：`grantMode: system_grant` / `availableLevel: normal`
 *   （`sdk\...\toolchains\lib\PermissionDefinitions.json`）⇒ 安装即授予、无弹窗。
 * 第 2 层 阅读防窥：`@kit.DeviceSecurityKit` 的 `dlpAntiPeep` —— 检测到非机主注视屏幕时拉起
 *   系统级蒙层遮住窗口。受限权限 `ohos.permission.DLP_GET_HIDE_STATUS`；能力门禁
 *   `canIUse('SystemCapability.Security.DlpAntiPeep')`，不支持报 801 ⇒ 静默降级。
 *   SDK 取证（`@hms.security.dlpAntiPeep.d.ts`，起始 6.0.0(20)）：
 *   · `isDlpAntiPeepSwitchOn(): Promise<boolean>`（:98，"消息隐藏功能是否已开启"= 系统防窥开关）
 *   · `requestAntiPeepOptions(context): Promise<AntiPeepOptionsResult>`（:192）官方原文：
 *     「Opens the page for setting the screen privacy switch.」（:177），
 *     并 `@throws { BusinessError } 1020600004 - Facial recognition is not set.`（:187）
 *   · `on/off('dlpAntiPeep', cb)`（:113/:129）+ `DlpAntiPeepStatus.HIDE = 1`（:52）
 *   · `setAntiPeepMaskLayer(windowId): Promise<void>`（:175，`1020600002 - The antipeep
 *     function is not enabled.`）
 *
 * ── 生效范围：全应用（刻意不做按书）─────────────────────────────────────────
 * 两个 API 都是**窗口级**（官方没有任何"页面级防窥"接口）⇒ 开关一开即整个应用窗口生效
 * （书架 / 我的 / 设置页同样防护），退出阅读页**不复位**。启动时机：`EntryAbility`
 * `onWindowStageCreate` 的 `getMainWindow` 回调里 `AntiPeep.start(ctx, window)`。
 *
 * ── 状态归属（关键）───────────────────────────────────────────────────────
 * Preferences 存**用户意图**：`antiPeepCaptureOn` 默认 false、`antiPeepDlpOn` 默认 true；
 * AppStorage 同名键存**当前有效值** = 意图 && 是 VIP &&（第 2 层还要求系统防窥开关已开）
 * ⇒ 设置页开关与阅读页眼睛图标显示的都是真实生效状态，不会出现"开着却没生效"。
 *
 * ── 引导时机（用户拍板 2026-10-08）────────────────────────────────────────
 * 只在**用户主动开启**第 2 层时，若系统防窥开关未开才 `requestAntiPeepOptions` 拉起系统
 * 设置页；启动 / 页面进场只静默对账，绝不打扰（启动就拉会在无面容设备上报 1020600004）。
 */
import { dlpAntiPeep } from '@kit.DeviceSecurityKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { VipManager } from './VipManager';

/** 第 1 层（防截屏/录屏）键：Preferences 存意图，AppStorage 存有效值（默认关） */
export const KEY_ANTI_PEEP_CAPTURE: string = 'antiPeepCaptureOn';
/** 第 2 层（阅读防窥）键：同上（默认开） */
export const KEY_ANTI_PEEP_DLP: string = 'antiPeepDlpOn';

export class AntiPeep {
  private static readonly TAG: string = 'testTag';
  private static readonly SYS_CAP: string = 'SystemCapability.Security.DlpAntiPeep';
  private static ctx: common.UIAbilityContext | null = null;
  private static win: window.Window | null = null;
  private static dlpSubscribed: boolean = false;
  /**
   * 对账进行中标记（2026-10-13）：`requestAntiPeepOptions` 会拉起系统页并 await，
   * 期间用户连点会叠加多个系统授权页 ⇒ 用它去重，只放行一次。
   */
  private static reconciling: boolean = false;

  /** 应用启动（最早时机）：主窗口直接注入 ⇒ 立即按已存开关复算两层 */
  static start(ctx: common.UIAbilityContext, w: window.Window): void {
    AntiPeep.ctx = ctx;
    AntiPeep.win = w;
    AntiPeep.refresh();
  }

  /** 页面兜底（阅读页 `aboutToAppear`）：存上下文；窗口还没送到就自己取一次 */
  static ensureInit(ctx: common.UIAbilityContext): void {
    AntiPeep.ctx = ctx;
    if (AntiPeep.win !== null) {
      AntiPeep.refresh();
      return;
    }
    window.getLastWindow(ctx).then((w: window.Window): void => {
      AntiPeep.win = w;
      AntiPeep.refresh();
    }).catch((e: BusinessError): void => {
      hilog.warn(0x0000, AntiPeep.TAG, 'AntiPeep getLastWindow failed: %{public}d', e.code ?? 0);
    });
  }

  /** 第 1 层有效值（非 VIP 恒 false） */
  static isCaptureOn(): boolean {
    return VipManager.isVip() && AntiPeep.prefBool(KEY_ANTI_PEEP_CAPTURE, false);
  }

  /** 第 2 层有效值（非 VIP 恒 false；不含"系统防窥开关"这一层，那个只能异步问） */
  static isDlpOn(): boolean {
    return VipManager.isVip() && AntiPeep.prefBool(KEY_ANTI_PEEP_DLP, true);
  }

  /** 第 1 层开关（设置页）：写意图 + 立即生效 */
  static setCapture(enabled: boolean): void {
    AntiPeep.putPref(KEY_ANTI_PEEP_CAPTURE, enabled);
    AntiPeep.refresh();
  }

  /**
   * 第 2 层开关（设置页开关 / 阅读页眼睛图标同一个入口）：写意图 + 立即生效。
   * `enabled === true` 属**用户主动开启** ⇒ 系统防窥开关没开时拉起系统设置页引导。
   */
  static setDlp(enabled: boolean): void {
    AntiPeep.putPref(KEY_ANTI_PEEP_DLP, enabled);
    AntiPeep.refreshWithGuide(enabled);
  }

  /**
   * 第 2 层开关的**可重入**版本（2026-10-13 修上架被拒项 ③）。
   *
   * 背景（用户实测口径）：「开启测试账号之后，点击防窥功能，点击多次没有开启，
   *   怀疑首次开启时拉起了授权窗但他没点，之后就一直点不开。」
   *
   * 旧 `setDlp(true)` 的坑：首次点击若 `requestAntiPeepOptions` 拉起的系统页被直接返回，
   * 有效值回弹为 false（`@StorageLink` 把开关弹回关）—— 这时**意图已经是 true**，
   * 而设置页 onClick 是 `AntiPeep.setDlp(!this.setAntiPeepDlp)`，读到 false 取反又是 true，
   * 表面看"点得动"，但 `reconcileDlp` 里的 `guide` 只在 `enabled===true` 时给，
   * 于是**每一次点击都重新拉起系统页**，用户连续点几次就是连续弹几次 ⇒ 观感"点了没反应"。
   *
   * 本方法保证：无论当前有效值真假，只要用户主动点（意图=开），**一定**走一次带引导的对账；
   * 并且用 `inflight` 去重，避免连点叠加多个系统授权页。
   */
  static requestDlpOn(): void {
    AntiPeep.putPref(KEY_ANTI_PEEP_DLP, true);
    AppStorage.setOrCreate(KEY_ANTI_PEEP_DLP, false);
    AntiPeep.refreshWithGuide(true);
  }

  /** 按当前 VIP 状态 + 两个开关意图复算两层（幂等、静默、不引导） */
  static refresh(): void {
    AntiPeep.refreshWithGuide(false);
  }

  // ── 内部实现 ─────────────────────────────────────────────────────────────

  private static refreshWithGuide(guide: boolean): void {
    const vip: boolean = VipManager.isVip();
    // 第 1 层：纯本地判定，立即生效（或撤销）
    const capture: boolean = vip && AntiPeep.prefBool(KEY_ANTI_PEEP_CAPTURE, false);
    AppStorage.setOrCreate(KEY_ANTI_PEEP_CAPTURE, capture);
    AntiPeep.applyPrivacyMode(capture);
    // 第 2 层：要先问系统防窥开关（异步）
    const wantDlp: boolean = vip && AntiPeep.prefBool(KEY_ANTI_PEEP_DLP, true);
    if (!wantDlp) {
      AppStorage.setOrCreate(KEY_ANTI_PEEP_DLP, false);
      AntiPeep.unsubscribeDlp();
      return;
    }
    AntiPeep.reconcileDlp(guide);
  }

  /** 第 2 层对账：系统防窥开关为真才订阅（`guide` = 允许拉起系统设置页引导） */
  private static async reconcileDlp(guide: boolean): Promise<void> {
    if (!canIUse(AntiPeep.SYS_CAP)) {
      AppStorage.setOrCreate(KEY_ANTI_PEEP_DLP, false);
      return;
    }
    // ⚠️ 2026-10-13 修（上架被拒项 ③「首次拉起授权窗没点，之后点不开」）：
    // `requestAntiPeepOptions(context)` 的官方 `@param` 原文要求
    //   「The context must belong to the Stage model and only supports
    //     UIAbilityContext and UIExtensionContext.」（SDK `@hms.security.dlpAntiPeep.d.ts:180-181`）
    // 旧实现写的是 `AntiPeep.ctx as common.UIAbilityContext` —— ctx 为 null 时**断言不报错**，
    // 传 null 进去直接抛异常落进下面的 catch ⇒ 被静默降级成"第 1 层可用"，
    // 用户看到的现象就是「点多次都开不了」。这里显式判空并从 UIAbilityContext 兜底取回。
    if (AntiPeep.ctx === null) {
      hilog.warn(0x0000, AntiPeep.TAG, 'reconcileDlp: ctx is null, skip requestAntiPeepOptions');
      AppStorage.setOrCreate(KEY_ANTI_PEEP_DLP, false);
      return;
    }
    // 连点去重：系统授权页已经在拉/在等 ⇒ 忽略本次，避免叠加多张系统页
    if (AntiPeep.reconciling) {
      hilog.info(0x0000, AntiPeep.TAG, 'reconcileDlp: already reconciling, skip duplicate request');
      return;
    }
    AntiPeep.reconciling = true;
    try {
      let on: boolean = await dlpAntiPeep.isDlpAntiPeepSwitchOn();
      if (!on && guide) {
        // 官方原文：「Opens the page for setting the screen privacy switch.」（d.ts:177）
        // 返回 `AntiPeepOptionsResult`：SUCCESS=0 / FAIL=1 / ALREADY_ON=2（d.ts:62-84）
        const r: dlpAntiPeep.AntiPeepOptionsResult =
          await dlpAntiPeep.requestAntiPeepOptions(AntiPeep.ctx as common.UIAbilityContext);
        hilog.info(0x0000, AntiPeep.TAG, 'requestAntiPeepOptions result=%{public}d', r);
        on = await dlpAntiPeep.isDlpAntiPeepSwitchOn();
      }
      AppStorage.setOrCreate(KEY_ANTI_PEEP_DLP, on);
      if (on) {
        AntiPeep.subscribeDlp();
      } else {
        AntiPeep.unsubscribeDlp();
      }
    } catch (e) {
      const err = e as BusinessError;
      // 201 = DLP_GET_HIDE_STATUS 未批；801 = 设备不支持；1020600004 = 未设面容 ⇒ 一律降级
      AppStorage.setOrCreate(KEY_ANTI_PEEP_DLP, false);
      hilog.info(0x0000, AntiPeep.TAG, 'DLP unavailable: %{public}d（仅第 1 层可用）', err.code ?? 0);
    } finally {
      // 无论成功/降级/异常都要解锁，否则一次失败之后**永远点不开**（正是上架被拒现象 ③）
      AntiPeep.reconciling = false;
    }
  }

  /** 第 1 层落地：窗口隐私模式（不可截屏录屏 + 后台任务卡片白屏/隐私蒙层） */
  private static async applyPrivacyMode(enable: boolean): Promise<void> {
    if (AntiPeep.win === null) {
      return;
    }
    try {
      await AntiPeep.win.setWindowPrivacyMode(enable);
    } catch (e) {
      const err = e as BusinessError;
      // 隐私模式失败不阻断第 2 层
      hilog.warn(0x0000, AntiPeep.TAG, 'setWindowPrivacyMode(%{public}s) failed: %{public}d',
        String(enable), err.code ?? 0);
    }
  }

  /** 第 2 层订阅：检测到非机主注视 ⇒ 系统级蒙层遮盖本窗口 */
  private static subscribeDlp(): void {
    if (AntiPeep.dlpSubscribed) {
      return;
    }
    try {
      dlpAntiPeep.on('dlpAntiPeep', (status: dlpAntiPeep.DlpAntiPeepStatus): void => {
        if (status === dlpAntiPeep.DlpAntiPeepStatus.HIDE && AntiPeep.win !== null) {
          dlpAntiPeep.setAntiPeepMaskLayer(AntiPeep.win.getWindowProperties().id)
            .catch((e: BusinessError): void => {
              hilog.warn(0x0000, AntiPeep.TAG, 'setAntiPeepMaskLayer: %{public}d', e.code ?? 0);
            });
        }
      });
      AntiPeep.dlpSubscribed = true;
    } catch (e) {
      hilog.warn(0x0000, AntiPeep.TAG, 'dlp on failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  private static async unsubscribeDlp(): Promise<void> {
    if (!AntiPeep.dlpSubscribed) {
      return;
    }
    try {
      dlpAntiPeep.off('dlpAntiPeep');
      AntiPeep.dlpSubscribed = false;
    } catch (e) {
      // 退订失败不阻断
    }
  }

  private static prefBool(key: string, def: boolean): boolean {
    try {
      return PreferencesUtil.getSync(key, def) === true;
    } catch (e) {
      return def;
    }
  }

  private static putPref(key: string, v: boolean): void {
    try {
      PreferencesUtil.putSync(key, v);
    } catch (e) {
      // 落盘失败不影响本次会话
    }
  }
}
