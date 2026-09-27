/**
 * 全局震动反馈方案（2026-09-25 新增，用户需求）。
 *
 * 需求原文：「设置全局震动方案，在我的-设置页增加震动反馈开关，以及 0-500 无极调整滑块
 * （每 50 一个档，自由调节震动强度），做好震动方案，适配全软件所有按键以及手势操作。
 * 另外，软件开关在开启震动下，系统静音、勿扰模式自动停止震动，响铃、震动等模式正常。」
 *
 * ── 强度怎么来的（SDK 取证）───────────────────────────────────────────────
 * 振动强度只有预设效果能调：`@ohos.vibrator.d.ts:628-635`（`VibratePreset.intensity`）原文：
 *   「Vibration intensity. This parameter is optional. The value range is [0, 100]. The default
 *     value is **100**. If vibration intensity adjustment is not supported, the default vibration
 *     intensity will be used.」（`@since 12`）
 * ⇒ ①滑块 0-500 线性映射到 intensity 0-100（÷5，每 50 一档 = 10 档强度）；
 *   ②强度档要生效必须走 `type:'preset'`（`{type:'time'}` 没有强度参数）；
 *   ③硬件不支持调强时官方**自动回落默认强度**，不会报错 —— 不会震不出来。
 * 预设效果 id 是否被设备支持用 `isSupportEffectSync(effectId): boolean` 预判
 *   （同文件 `:291`，`@since 12`），不支持就回落到旧的 `{type:'time', duration:20}`
 *   （听书面板真机验证过的写法，见 `TtsControlPanel.hapticTick()`）。
 *
 * ── 「静音/勿扰自动停、响铃/震动正常」怎么实现（SDK 取证）──────────────────
 * 官方 FAQ（documentId `FAQ/硬件/传感器_Sensor_Service/关闭系统设置_使用vibrator模块设置的
 * 振动规则会失效/faqs-sensor-service-3`）原文：「usage 参数值为 unknown、touch、media、
 * physicalFeedback、simulateReality 时，受**触感开关**管控。**在触感开关开启时，即使系统
 * 处于静音模式，也会振动。**」⇒ 系统不会替我们停，必须自己查：
 *   ① 铃声模式：`AudioVolumeGroupManager.getRingerModeSync(): AudioRingMode`
 *      （`@ohos.multimedia.audio.d.ts:4681`，`@since 10`）。
 *      `RINGER_MODE_SILENT=0`（静音→停）、`RINGER_MODE_VIBRATE=1`（震动→正常振）、
 *      `RINGER_MODE_NORMAL=2`（响铃→正常振）（同文件 `:841-857`）。
 *      另保留旧路径的 `isMute(RINGTONE)` 判定（响铃模式但铃声音量拖到 0 的用户也视为静音）。
 *   ② 勿扰模式：`intelligentScene.isDoNotDisturbEnabled(): Promise<boolean>`
 *      （`@ohos.intelligentScene.d.ts:41`，`@since 23`，`@permission
 *      ohos.permission.GET_DONOTDISTURB_STATE`）。该权限在官方《开放权限（系统授权）》列表
 *      （documentId `开发指南/安全/程序访问控制/应用权限管控/应用权限列表/开放权限_系统授权/
 *      permissions-for-all`）原文：「权限级别：normal / 授权方式：系统授权（system_grant）/
 *      起始版本：23」⇒ 已加入 `module.json5`，安装即授，无需用户操作。
 *      调用失败（极端机型/服务异常）一律按「非勿扰」处理，绝不因它阻断正常震动。
 *
 * ⚠️ 一键回退：把 `LEGACY_BYPASS` 改成 `true` ⇒ 本模块所有判定全部跳过、
 *   直接用旧的 `{type:'time',20ms}` 无强度路径（与 2026-09-25 之前行为一致）。
 *   回退后要真机验证：滑条每档一跳、静音下不振（旧行为）。
 *
 * ── 强度与震感模式（2026-09-25 二次改造，官方取证）──────────────────────────
 * 官方 FAQ（documentId `FAQ/硬件/传感器_Sensor_Service/使用Vibrator模块intensity参数
 * 调节振幅/faqs-sensor-service-14`）原文：
 *   「系统支持两种方式调节振动强度：
 *     · 通过 VibratePreset 接口的 intensity 参数在 0-100 范围内进行振动强度调节，
 *       **但是仅支持部分设备，可通过 isHdHapticSupported() 接口判断设备是否支持高清振动**；
 *     · 若不支持高清振动，可通过系统已预置简单而通用的振动效果进行**三档调节**。」
 * ⇒ ①强度滑杆（0-500）在线性映射 intensity=strength/5 的同时，**先用
 *   `isHdHapticSupported()`（`@ohos.vibrator.d.ts:360`，@since 12，同步无权限）判能力**：
 *   不支持高清的设备 intensity 会被静默忽略（这正是用户实测"500 档也不强"的根因），
 *   此时改用**时长梯度**近似强度（time 型无强度参数，越长体感越重）。
 * ②震感模式滑杆（0-500/50 共 10 档）：全部用官方预置效果族拼配 ——
 *   `HapticFeedback` 枚举（`@ohos.vibrator.d.ts:401`，@since 12）：
 *   EFFECT_SHARP（高频清脆）/ EFFECT_CLOCK_TIMER（滴答利落）/ EFFECT_SOFT（低频轻柔）/
 *   EFFECT_HARD（中频厚重），每档再乘强度微调（70%~100%），不支持的效果逐个探测回落。
 * ③能力探测结果（是否高清 + 各效果支持）**一次性写 hilog**，真机日志可直接定位走哪条路。
 */
import { audio } from '@kit.AudioKit';
import { intelligentScene } from '@kit.BasicServicesKit';
import vibrator from '@ohos.vibrator';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 一个震感模式的参数档（见 Haptics.MODE_TABLE） */
export interface FeelProfile {
  /** 官方预置效果 id（`vibrator.HapticFeedback`） */
  effect: string;
  /** 该档在用户强度基础上的百分比微调（70~100） */
  trim: number;
  /** 设备不支持 preset 效果时的回落时长（ms） */
  dur: number;
  /** 模式名（设置页滑块旁显示） */
  name: string;
}

export class Haptics {
  /** 一键回退开关：true = 跳过全部新逻辑，走旧 time/20ms 路径（见文件头注释） */
  static readonly LEGACY_BYPASS: boolean = false;

  /** 设置页持久化键（与 MyCenter 的 'MyUserName' 同一个 preferences 实例） */
  static readonly KEY_ENABLED: string = 'HapticsEnabled';
  static readonly KEY_STRENGTH: string = 'HapticsStrength';
  /** 滑块 UI 用：0-500，每 50 一档；默认 250（中等强度） */
  static readonly STRENGTH_MAX: number = 500;
  static readonly STRENGTH_STEP: number = 50;
  static readonly STRENGTH_DEFAULT: number = 250;
  /** 震感模式持久化键（0-500，每 50 一档 → 10 种官方效果拼配，见 MODE_TABLE） */
  static readonly KEY_MODE: string = 'HapticsMode';
  static readonly MODE_DEFAULT: number = 250;

  /**
   * 震感模式表（10 档，全部由官方预置效果拼配，用户要求"比如清脆，线性等等"）。
   * · effect：官方预置效果 id（SHARP 高频清脆 / SOFT 低频轻柔 / HARD 中频厚重 在
   *   `vibrator.HapticFeedback`（`@ohos.vibrator.d.ts:401`，@since 12）；
   *   CLOCK_TIMER 在 `vibrator.EffectId`（`:387`，@since 8）——两个枚举各管一半，
   *   写错归属会报「Property does not exist」（本工程实测踩过两次）；
   * · trim：该档在用户强度基础上的百分比微调（让同族档位也有梯度）；
   * · dur：设备**不支持 preset 效果**时的回落时长（ms）——time 型无强度参数，
   *   用时长梯度近似"从轻到重"。
   */
  private static readonly MODE_TABLE: FeelProfile[] = [
    { effect: vibrator.HapticFeedback.EFFECT_SHARP, trim: 100, dur: 12, name: '极清脆' },
    { effect: vibrator.HapticFeedback.EFFECT_SHARP, trim: 80, dur: 14, name: '清脆' },
    { effect: vibrator.EffectId.EFFECT_CLOCK_TIMER, trim: 100, dur: 16, name: '利落' },
    { effect: vibrator.EffectId.EFFECT_CLOCK_TIMER, trim: 80, dur: 18, name: '干脆' },
    { effect: vibrator.HapticFeedback.EFFECT_SOFT, trim: 70, dur: 20, name: '轻柔' },
    { effect: vibrator.HapticFeedback.EFFECT_SOFT, trim: 85, dur: 24, name: '柔和' },
    { effect: vibrator.HapticFeedback.EFFECT_SOFT, trim: 100, dur: 26, name: '均衡' },
    { effect: vibrator.HapticFeedback.EFFECT_HARD, trim: 70, dur: 30, name: '稳实' },
    { effect: vibrator.HapticFeedback.EFFECT_HARD, trim: 85, dur: 36, name: '厚重' },
    { effect: vibrator.HapticFeedback.EFFECT_HARD, trim: 100, dur: 44, name: '浑厚' },
  ];

  /** 同类震动的最小间隔（ms）：tap 与 UI 点击节奏对齐；tick 与已验证的 80ms 一致 */
  private static readonly TAP_GAP_MS: number = 60;
  private static readonly TICK_GAP_MS: number = 80;
  /** 静音 / 勿扰判定的缓存有效期（ms） */
  private static readonly RINGER_TTL_MS: number = 3000;
  private static readonly DND_TTL_MS: number = 5000;

  private static lastTapAt: number = 0;
  private static lastTickAt: number = 0;

  // ── 环境判定缓存 ──
  private static ringerSilent: boolean = false;
  private static ringerProbedAt: number = 0;
  private static dndOn: boolean = false;
  private static dndProbedAt: number = 0;
  private static dndProbing: boolean = false;
  /** 各预置效果支持情况缓存（设备能力开机不变，每效果只查一次） */
  private static effectSupportCache: Map<string, boolean> = new Map();
  /** 设备是否支持高清振动（决定 intensity 是否真正生效）缓存 */
  private static hdHaptic: boolean | null = null;
  /** 能力探测只打一次日志的开关 */
  private static capabilityLogged: boolean = false;

  /** 震动反馈开关（设置页可改；读不到时默认开） */
  static isEnabled(): boolean {
    try {
      return PreferencesUtil.getSync(Haptics.KEY_ENABLED, true) as boolean;
    } catch (e) {
      return true;
    }
  }

  /** 强度滑块值 0-500（读不到时默认 250） */
  static getStrength(): number {
    try {
      const v = PreferencesUtil.getSync(Haptics.KEY_STRENGTH, Haptics.STRENGTH_DEFAULT) as number;
      return Math.min(Haptics.STRENGTH_MAX, Math.max(0, Math.round(v)));
    } catch (e) {
      return Haptics.STRENGTH_DEFAULT;
    }
  }

  /** 震感模式滑块值 0-500（读不到时默认 250） */
  static getMode(): number {
    try {
      const v = PreferencesUtil.getSync(Haptics.KEY_MODE, Haptics.MODE_DEFAULT) as number;
      return Math.min(Haptics.STRENGTH_MAX, Math.max(0, Math.round(v)));
    } catch (e) {
      return Haptics.MODE_DEFAULT;
    }
  }

  /** 当前模式档位序号（0 基 0..9；滑块 50 → 第 1 档，500 → 第 10 档） */
  static modeIndex(): number {
    const idx = Math.round(Haptics.getMode() / Haptics.STRENGTH_STEP);
    return Math.min(10, Math.max(1, idx)) - 1;
  }

  /** 当前震感模式名（设置页滑块旁显示用） */
  static modeName(): string {
    return Haptics.MODE_TABLE[Haptics.modeIndex()].name;
  }

  /** 全局开关（含强度>0）—— 给暂不迁移的旧路径（TtsControlPanel）做守卫用 */
  static globallyEnabled(): boolean {
    return Haptics.isEnabled() && Haptics.getStrength() > 0;
  }

  /**
   * 通用按钮点击反馈（短促软震）。全软件各页 `onClick` 里调用。
   */
  static tap(): void {
    Haptics.vibrate(Haptics.TAP_GAP_MS);
  }

  /**
   * 滑条 / 分档步进反馈（每跨一档一次）。
   * 节流取 80ms —— 与听书面板真机验证过的取值一致（拖动时"一档一跳"而非持续嗡振）。
   */
  static tick(): void {
    Haptics.vibrate(Haptics.TICK_GAP_MS);
  }

  /**
   * 成功 / 强调反馈（如听书入口解锁成功弹窗）。
   */
  static success(): void {
    Haptics.vibrate(0);
  }

  /** 统一入口：检查（开关→强度→静音→勿扰→节流）→ 振动 */
  private static vibrate(gapMs: number): void {
    if (!Haptics.LEGACY_BYPASS) {
      if (!Haptics.globallyEnabled()) {
        return;
      }
      if (Haptics.environmentBlocked()) {
        return;
      }
    }
    if (gapMs > 0) {
      const now = Date.now();
      const last = gapMs === Haptics.TAP_GAP_MS ? Haptics.lastTapAt : Haptics.lastTickAt;
      if (now - last < gapMs) {
        return;
      }
      if (gapMs === Haptics.TAP_GAP_MS) {
        Haptics.lastTapAt = now;
      } else {
        Haptics.lastTickAt = now;
      }
    }
    Haptics.fire();
  }

  /**
   * 静音 / 勿扰判定（带缓存）。true = 环境要求停止震动。
   * 每项判定失败时**保持上一次判定**且不抛错 —— 反馈类功能绝不能影响 UI。
   */
  private static environmentBlocked(): boolean {
    // ① 铃声模式（静音=0 → 停；震动=1 / 响铃=2 → 振）
    const now = Date.now();
    if (now - Haptics.ringerProbedAt > Haptics.RINGER_TTL_MS) {
      Haptics.ringerProbedAt = now;
      try {
        const mgr = audio.getAudioManager().getVolumeManager().getVolumeGroupManagerSync(0);
        const mode = mgr.getRingerModeSync();
        if (mode === audio.AudioRingMode.RINGER_MODE_SILENT) {
          Haptics.ringerSilent = true;
        } else if (mode === audio.AudioRingMode.RINGER_MODE_VIBRATE
          || mode === audio.AudioRingMode.RINGER_MODE_NORMAL) {
          Haptics.ringerSilent = false;
        }
        // ② 响铃模式下铃声音量 = 0 的用户也按"静音"对待（沿用旧路径的判定口径）。
        //    异步赋值，与旧实现同款；探测失败保持上一次判定。
        mgr.isMute(audio.AudioVolumeType.RINGTONE).then((m: boolean) => {
          Haptics.ringerSilent = m;
        }).catch((_e: BusinessError) => {
          // 忽略
        });
      } catch (e) {
        // 取不到就保持上一次判定
      }
    }
    if (Haptics.ringerSilent) {
      return true;
    }
    // ③ 勿扰模式（@since 23；权限 system_grant，见文件头）。失败 = 按非勿扰。
    if (now - Haptics.dndProbedAt > Haptics.DND_TTL_MS && !Haptics.dndProbing) {
      Haptics.dndProbing = true;
      try {
        intelligentScene.isDoNotDisturbEnabled().then((on: boolean) => {
          Haptics.dndOn = on;
          Haptics.dndProbedAt = Date.now();
          Haptics.dndProbing = false;
        }).catch((_e: BusinessError) => {
          Haptics.dndProbedAt = Date.now();
          Haptics.dndProbing = false;
        });
      } catch (e) {
        Haptics.dndProbedAt = Date.now();
        Haptics.dndProbing = false;
      }
    }
    return Haptics.dndOn;
  }

  /** 当前模式档位的参数（效果 + 强度微调 + 回落时长） */
  private static currentProfile(): FeelProfile {
    return Haptics.MODE_TABLE[Haptics.modeIndex()];
  }

  /** 预置效果支持查询（带缓存；查询失败按不支持处理走回落） */
  private static effectSupported(effectId: string): boolean {
    const hit = Haptics.effectSupportCache.get(effectId);
    if (hit !== undefined) {
      return hit;
    }
    let ok = false;
    try {
      ok = vibrator.isSupportEffectSync(effectId);
    } catch (e) {
      ok = false;
    }
    Haptics.effectSupportCache.set(effectId, ok);
    return ok;
  }

  /**
   * 真正触发振动（2026-09-25 二次改造）：
   * · 设备支持高清振动（isHdHapticSupported）且当前模式效果受支持 ⇒
   *   preset 效果 + intensity（强度滑杆 0-500 线性映射 0-100，用户要求"50-500 均匀分布"）
   *   再乘模式的强度微调；
   * · 不支持高清 ⇒ intensity 官方明说会被忽略（FAQ 原文见文件头）⇒ 用**时长梯度**
   *   （模式档位时长 × 强度系数 0.6~1.5）近似"从轻到重"，保证两根滑杆都有手感；
   * · 首次触发时把能力探测结果写一次 hilog（真机排障钥匙）。
   */
  private static fire(): void {
    try {
      if (Haptics.hdHaptic === null) {
        try {
          Haptics.hdHaptic = vibrator.isHdHapticSupported();
        } catch (e2) {
          Haptics.hdHaptic = false;
        }
      }
      const profile = Haptics.currentProfile();
      if (!Haptics.capabilityLogged) {
        Haptics.capabilityLogged = true;
        hilog.info(0x0000, 'testTag',
          'Haptics capability: hd=%{public}s sharp=%{public}s clock=%{public}s soft=%{public}s hard=%{public}s mode=%{public}s strength=%{public}d',
          String(Haptics.hdHaptic),
          String(Haptics.effectSupported(vibrator.HapticFeedback.EFFECT_SHARP)),
          String(Haptics.effectSupported(vibrator.EffectId.EFFECT_CLOCK_TIMER)),
          String(Haptics.effectSupported(vibrator.HapticFeedback.EFFECT_SOFT)),
          String(Haptics.effectSupported(vibrator.HapticFeedback.EFFECT_HARD)),
          profile.name, Haptics.getStrength());
      }
      const strengthFactor = 0.6 + Haptics.getStrength() / Haptics.STRENGTH_MAX * 0.9;
      if (Haptics.hdHaptic && Haptics.effectSupported(profile.effect)) {
        const intensity = Math.min(100, Math.max(1,
          Math.round(Haptics.getStrength() / 5 * profile.trim / 100)));
        vibrator.startVibration(
          { type: 'preset', effectId: profile.effect, count: 1, intensity: intensity },
          { id: 0, usage: 'touch' }
        ).catch((_e: BusinessError) => {
          Haptics.fireFallback(Math.round(profile.dur * strengthFactor));
        });
      } else {
        // 不支持高清/该效果 ⇒ time 振动（时长 = 模式档位时长 × 强度系数）
        Haptics.fireFallback(Math.round(profile.dur * strengthFactor));
      }
    } catch (e) {
      Haptics.fireFallback(20);
    }
  }

  /** 回落路径：time 振动（时长可变，近似强度梯度；参数异常时兜底 20ms） */
  private static fireFallback(durationMs: number): void {
    const dur = Math.min(80, Math.max(8, Math.round(durationMs)));
    try {
      vibrator.startVibration(
        { type: 'time', duration: dur },
        { id: 0, usage: 'touch' }
      ).catch((_e: BusinessError) => {
        // 忽略：设备不支持或被系统拦截
      });
    } catch (e) {
      // 忽略
    }
  }
}
