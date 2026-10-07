/**
 * 防窥保护管理器（2026-10-07 新增；方案移植自用户提供的成熟实现 D:\Arkts\xiaowei
 * `AntiPeepManager.ets`，交互按本工程阅读器底栏按钮重做）。
 *
 * ── 两层防护 ──────────────────────────────────────────────────────────────
 * 第 1 层 窗口隐私模式：`window.setWindowPrivacyMode(true)` —— 最近任务模糊 + 防截屏
 *   录屏（普通权限 `ohos.permission.PRIVACY_WINDOW`），所有机型立即可用。
 * 第 2 层 DLP 防窥：`@kit.DeviceSecurityKit` 的 `dlpAntiPeep` —— 检测到非机主注视屏幕
 *   时拉起系统级蒙层遮盖窗口。受限权限 `ohos.permission.DLP_GET_HIDE_STATUS`
 *   （官方错误码文档：201 = "只允许清单内的应用申请该权限"）；能力门禁用 canIUse
 *   （官方 FAQ faqs-device-security-8），不支持的设备报 801 ⇒ 静默降级为只有第 1 层。
 *
 * ── SDK 取证（`@hms.security.dlpAntiPeep.d.ts`，起始版本 6.0.0(20)）──────────
 * · `isDlpAntiPeepSwitchOn(): Promise<boolean>`（:98）；
 * · `requestAntiPeepOptions(context): Promise<AntiPeepOptionsResult>`（:192，拉起系统
 *   防窥开关设置页，用户授权后返回）；
 * · `on/off('dlpAntiPeep', cb)`（:113/:129）+ `DlpAntiPeepStatus.HIDE`（:38）；
 * · `setAntiPeepMaskLayer(windowId): Promise<void>`（:175）。
 *
 * ── 状态归属 ──────────────────────────────────────────────────────────────
 * Preferences 键 `antiPeepOn` 持久化 + AppStorage 同名键驱动 UI（阅读器顶栏眼睛图标、
 * 设置开关同源）。进程内单例；窗口通过 `getLastWindow` 取（应用单窗口）。
 */
import { dlpAntiPeep } from '@kit.DeviceSecurityKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';

/** 防窥开关的 Preferences / AppStorage 同名键（默认关） */
export const KEY_ANTI_PEEP: string = 'antiPeepOn';

export class AntiPeep {
  private static readonly TAG: string = 'testTag';
  private static ctx: common.UIAbilityContext | null = null;
  private static win: window.Window | null = null;
  private static dlpSubscribed: boolean = false;
  private static applying: boolean = false;

  /** 阅读页进场调用：存上下文、取窗口；若上次开着则自动恢复两层防护 */
  static ensureInit(ctx: common.UIAbilityContext): void {
    AntiPeep.ctx = ctx;
    if (AntiPeep.win === null) {
      window.getLastWindow(ctx).then((w: window.Window): void => {
        AntiPeep.win = w;
        if (AntiPeep.isOn()) {
          AntiPeep.setEnabled(true);
        }
      }).catch((e: BusinessError): void => {
        hilog.warn(0x0000, AntiPeep.TAG, 'AntiPeep getLastWindow failed: %{public}d', e.code ?? 0);
      });
    }
  }

  static isOn(): boolean {
    try {
      return PreferencesUtil.getSync(KEY_ANTI_PEEP, false) === true;
    } catch (e) {
      return false;
    }
  }

  /** 开关切回（阅读器顶栏按钮）。始终落盘 + 同步 AppStorage；两层按能力尽力而为。 */
  static setEnabled(enabled: boolean): void {
    try {
      PreferencesUtil.putSync(KEY_ANTI_PEEP, enabled);
    } catch (e) {
      // 落盘失败不影响本次会话
    }
    AppStorage.setOrCreate(KEY_ANTI_PEEP, enabled);
    if (AntiPeep.applying) {
      return;
    }
    AntiPeep.applying = true;
    const done = (): void => {
      AntiPeep.applying = false;
    };
    if (enabled) {
      AntiPeep.applyPrivacyMode(true)
        .then((): Promise<void> => AntiPeep.tryEnableDlp())
        .then((): void => done())
        .catch((e: BusinessError): void => {
          hilog.warn(0x0000, AntiPeep.TAG, 'AntiPeep enable: %{public}d %{public}s',
            e.code ?? 0, e.message ?? '');
          done();
        });
    } else {
      AntiPeep.applyPrivacyMode(false)
        .then((): Promise<void> => AntiPeep.unsubscribeDlp())
        .then((): void => done())
        .catch((e: BusinessError): void => {
          hilog.warn(0x0000, AntiPeep.TAG, 'AntiPeep disable: %{public}d %{public}s',
            e.code ?? 0, e.message ?? '');
          done();
        });
    }
  }

  /** 第 1 层：窗口隐私模式（最近任务模糊 + 防截屏录屏） */
  private static async applyPrivacyMode(enable: boolean): Promise<void> {
    if (AntiPeep.win === null) {
      return;
    }
    try {
      await AntiPeep.win.setWindowPrivacyMode(enable);
    } catch (e) {
      const err = e as BusinessError;
      // 隐私模式失败不阻断 DLP 层
      hilog.warn(0x0000, AntiPeep.TAG, 'setWindowPrivacyMode(%{public}s) failed: %{public}d',
        String(enable), err.code ?? 0);
    }
  }

  /** 第 2 层：DLP 防窥（能力不支持 / 权限未批 ⇒ 静默降级，只有第 1 层） */
  private static async tryEnableDlp(): Promise<void> {
    // 能力门禁（官方 FAQ faqs-device-security-8 建议 canIUse 判断）
    if (!canIUse('SystemCapability.Security.DlpAntiPeep')) {
      return;
    }
    try {
      const sysOn: boolean = await dlpAntiPeep.isDlpAntiPeepSwitchOn();
      if (sysOn) {
        AntiPeep.subscribeDlp();
        return;
      }
      // 系统防窥开关未开 ⇒ 拉起系统设置引导用户开启（用户授权后按结果重查）
      const r: dlpAntiPeep.AntiPeepOptionsResult =
        await dlpAntiPeep.requestAntiPeepOptions(AntiPeep.currentContext());
      hilog.info(0x0000, AntiPeep.TAG, 'requestAntiPeepOptions result=%{public}d', r);
      const on2: boolean = await dlpAntiPeep.isDlpAntiPeepSwitchOn();
      if (on2) {
        AntiPeep.subscribeDlp();
      }
    } catch (e) {
      const err = e as BusinessError;
      // 201 = DLP_GET_HIDE_STATUS 受限权限未批；801 = 设备不支持 ⇒ 都静默降级
      hilog.info(0x0000, AntiPeep.TAG, 'DLP unavailable: %{public}d（仅第1层隐私模式生效）', err.code ?? 0);
    }
  }

  private static subscribeDlp(): void {
    if (AntiPeep.dlpSubscribed) {
      return;
    }
    try {
      dlpAntiPeep.on('dlpAntiPeep', (status: dlpAntiPeep.DlpAntiPeepStatus): void => {
        if (status === dlpAntiPeep.DlpAntiPeepStatus.HIDE && AntiPeep.win !== null) {
          // 检测到非机主注视 ⇒ 系统级蒙层遮盖窗口（防窥关闭时已退订，不会再走到这）
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

  private static currentContext(): common.UIAbilityContext {
    // ensureInit 时存下的阅读页上下文（单例内复用，避免再引 AbilityStage）
    return AntiPeep.ctx as common.UIAbilityContext;
  }
}
